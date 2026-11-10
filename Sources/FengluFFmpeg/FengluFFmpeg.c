#include "FengluFFmpeg.h"

#include <libavcodec/avcodec.h>
#include <libavcodec/codec_desc.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/mem.h>
#include <libavutil/samplefmt.h>
#include <libavutil/version.h>
#include <libswresample/swresample.h>

#include <CoreAudioTypes/CoreAudioTypes.h>

#include <stdarg.h>
#include <stdatomic.h>
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void fl_write_error(char *buffer, int32_t size, const char *format, ...) {
    if (buffer == NULL || size <= 0) {
        return;
    }

    va_list args;
    va_start(args, format);
    vsnprintf(buffer, (size_t)size, format, args);
    va_end(args);
}

static void fl_write_av_error(char *buffer, int32_t size, const char *prefix, int result) {
    char avError[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(result, avError, sizeof(avError));
    fl_write_error(buffer, size, "%s: %s", prefix, avError);
}

struct FLCancelToken {
    atomic_int cancelled;
};

FLCancelToken *fl_ffmpeg_cancel_token_create(void) {
    FLCancelToken *token = (FLCancelToken *)calloc(1, sizeof(FLCancelToken));
    if (token != NULL) {
        atomic_init(&token->cancelled, 0);
    }
    return token;
}

void fl_ffmpeg_cancel_token_cancel(FLCancelToken *token) {
    if (token != NULL) {
        atomic_store(&token->cancelled, 1);
    }
}

void fl_ffmpeg_cancel_token_destroy(FLCancelToken *token) {
    free(token);
}

static int fl_is_cancelled(const FLCancelToken *token) {
    return token != NULL && atomic_load(&((FLCancelToken *)token)->cancelled) != 0;
}

static int fl_interrupt_callback(void *opaque) {
    return fl_is_cancelled((const FLCancelToken *)opaque);
}

// Return codes shared by the frame helpers below.
#define FL_STEP_CONTINUE 0
#define FL_STEP_REACHED_LIMIT 1
#define FL_STEP_CORRUPT 2

// A run of undecodable packets longer than this is treated as a broken file
// rather than a damaged spot that can be skipped.
#define FL_MAX_CONSECUTIVE_CORRUPT_PACKETS 100
#define FL_SEEK_GAP_FILL_LIMIT_SECONDS 1.0
#define FL_STREAM_GAP_FILL_LIMIT_SECONDS 30.0
// Timestamp jitter below this is not treated as missing audio mid-stream.
#define FL_STREAM_GAP_MINIMUM_SECONDS 0.05
#define FL_LOSSY_SEEK_PREROLL_SECONDS 0.25

typedef struct FLDecodeState {
    AVCodecContext *codecContext;
    AVStream *stream;
    SwrContext *resampler;
    const FLCancelToken *cancelToken;

    // Output is fixed for the whole call; the input side follows the frames.
    AVChannelLayout outputLayout;
    int outputRate;
    int outputChannels;
    AVChannelLayout inputLayout;
    int inputLayoutInitialized;
    int inputFormat;
    int inputRate;

    float *samples;
    int64_t frameCount;
    int64_t capacityFrames;
    int64_t maxOutputFrames;

    // Stream time (seconds) of output sample 0. NAN until known.
    double originSeconds;
    // Stream time where the next input frame starts if it carries no usable pts.
    double nextInputSeconds;
    int64_t lastRawTimestamp;
    int trimsLeadingAudio;
    int hasOutputAudio;
    int skippedCorruptPacket;
    double gapToleranceSeconds;

    int corruptPacketCount;
    int consecutiveCorruptPackets;

    char *errorBuffer;
    int32_t errorBufferSize;
} FLDecodeState;

static int fl_ensure_capacity(FLDecodeState *state, int64_t neededFrames) {
    if (neededFrames <= state->capacityFrames) {
        return 0;
    }

    int64_t newCapacity = state->capacityFrames > 0 ? state->capacityFrames : 8192;
    while (newCapacity < neededFrames) {
        newCapacity *= 2;
    }

    size_t sampleCount = (size_t)newCapacity * (size_t)state->outputChannels;
    float *newSamples = (float *)realloc(state->samples, sampleCount * sizeof(float));
    if (newSamples == NULL) {
        fl_write_error(state->errorBuffer, state->errorBufferSize, "Could not allocate decoded PCM buffer");
        return AVERROR(ENOMEM);
    }

    state->samples = newSamples;
    state->capacityFrames = newCapacity;
    return 0;
}

static int64_t fl_remaining_output_frames(const FLDecodeState *state) {
    if (state->maxOutputFrames <= 0) {
        return INT64_MAX;
    }

    int64_t remaining = state->maxOutputFrames - state->frameCount;
    return remaining > 0 ? remaining : 0;
}

static int fl_append_silence(FLDecodeState *state, int64_t frames) {
    int64_t remaining = fl_remaining_output_frames(state);
    if (frames > remaining) {
        frames = remaining;
    }
    if (frames <= 0) {
        return 0;
    }

    int result = fl_ensure_capacity(state, state->frameCount + frames);
    if (result < 0) {
        return result;
    }

    memset(
        state->samples + (state->frameCount * state->outputChannels),
        0,
        (size_t)frames * (size_t)state->outputChannels * sizeof(float)
    );
    state->frameCount += frames;
    return 0;
}

static int fl_configure_resampler(
    FLDecodeState *state,
    const AVChannelLayout *inputLayout,
    int inputFormat,
    int inputRate
) {
    AVChannelLayout normalizedLayout;
    memset(&normalizedLayout, 0, sizeof(normalizedLayout));

    int channels = inputLayout != NULL ? inputLayout->nb_channels : 0;
    if (channels <= 0) {
        channels = 2;
        av_channel_layout_default(&normalizedLayout, channels);
    } else if (inputLayout->order == AV_CHANNEL_ORDER_UNSPEC) {
        // Decoders that only know the channel count get FFmpeg's default
        // arrangement for that count so the resampler can remix it.
        av_channel_layout_default(&normalizedLayout, channels);
    } else {
        int result = av_channel_layout_copy(&normalizedLayout, inputLayout);
        if (result < 0) {
            fl_write_av_error(state->errorBuffer, state->errorBufferSize, "Could not copy FFmpeg channel layout", result);
            return result;
        }
    }

    if (inputRate <= 0 || inputFormat < 0) {
        av_channel_layout_uninit(&normalizedLayout);
        fl_write_error(state->errorBuffer, state->errorBufferSize, "FFmpeg reported an invalid audio frame format");
        return AVERROR_INVALIDDATA;
    }

    SwrContext *resampler = NULL;
    int result = swr_alloc_set_opts2(
        &resampler,
        &state->outputLayout,
        AV_SAMPLE_FMT_FLT,
        state->outputRate,
        &normalizedLayout,
        (enum AVSampleFormat)inputFormat,
        inputRate,
        0,
        NULL
    );
    if (result < 0 || resampler == NULL) {
        av_channel_layout_uninit(&normalizedLayout);
        fl_write_av_error(state->errorBuffer, state->errorBufferSize, "Could not configure FFmpeg resampler", result);
        return result < 0 ? result : AVERROR(ENOMEM);
    }

    result = swr_init(resampler);
    if (result < 0) {
        swr_free(&resampler);
        av_channel_layout_uninit(&normalizedLayout);
        fl_write_av_error(state->errorBuffer, state->errorBufferSize, "Could not initialize FFmpeg resampler", result);
        return result;
    }

    if (state->resampler != NULL) {
        swr_free(&state->resampler);
    }
    if (state->inputLayoutInitialized) {
        av_channel_layout_uninit(&state->inputLayout);
    }

    state->resampler = resampler;
    state->inputLayout = normalizedLayout;
    state->inputLayoutInitialized = 1;
    state->inputFormat = inputFormat;
    state->inputRate = inputRate;
    return 0;
}

// The resampler is configured from the codec parameters before the first
// frame. Chained Ogg streams and some AAC files change format mid-stream;
// feeding such a frame to the old configuration reads the wrong planes.
static int fl_frame_matches_resampler(const FLDecodeState *state, const AVFrame *frame) {
    if (frame->format != state->inputFormat || frame->sample_rate != state->inputRate) {
        return 0;
    }

    if (frame->ch_layout.nb_channels != state->inputLayout.nb_channels) {
        return 0;
    }

    if (frame->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC) {
        return 1;
    }

    return av_channel_layout_compare(&frame->ch_layout, &state->inputLayout) == 0;
}

static double fl_frame_start_seconds(FLDecodeState *state, const AVFrame *frame) {
    int64_t timestamp = frame->best_effort_timestamp;
    if (timestamp == AV_NOPTS_VALUE) {
        timestamp = frame->pts;
    }

    double startSeconds = NAN;
    // A decoder that emits several frames per packet may stamp each of them
    // with the packet's timestamp; only the first one is a real position.
    int isRepeatedTimestamp =
        timestamp != AV_NOPTS_VALUE &&
        timestamp == state->lastRawTimestamp &&
        isfinite(state->nextInputSeconds);
    if (timestamp != AV_NOPTS_VALUE && !isRepeatedTimestamp) {
        startSeconds = (double)timestamp * av_q2d(state->stream->time_base);
    } else {
        startSeconds = state->nextInputSeconds;
    }
    state->lastRawTimestamp = timestamp;

    if (isfinite(startSeconds) && frame->sample_rate > 0) {
        state->nextInputSeconds = startSeconds + ((double)frame->nb_samples / (double)frame->sample_rate);
    } else {
        state->nextInputSeconds = NAN;
    }

    return startSeconds;
}

static int fl_append_decoded_frame(FLDecodeState *state, AVFrame *frame) {
    if (frame->nb_samples <= 0) {
        return FL_STEP_CONTINUE;
    }

    if (!fl_frame_matches_resampler(state, frame)) {
        int result = fl_configure_resampler(state, &frame->ch_layout, frame->format, frame->sample_rate);
        if (result < 0) {
            return result;
        }
    }

    double frameStartSeconds = fl_frame_start_seconds(state, frame);

    int64_t delay = swr_get_delay(state->resampler, state->inputRate);
    int outputSamples = (int)av_rescale_rnd(delay + frame->nb_samples, state->outputRate, state->inputRate, AV_ROUND_UP);
    if (outputSamples <= 0) {
        return FL_STEP_CONTINUE;
    }

    uint8_t **convertedData = NULL;
    int lineSize = 0;
    int result = av_samples_alloc_array_and_samples(
        &convertedData,
        &lineSize,
        state->outputChannels,
        outputSamples,
        AV_SAMPLE_FMT_FLT,
        0
    );
    if (result < 0) {
        fl_write_av_error(state->errorBuffer, state->errorBufferSize, "Could not allocate FFmpeg resample buffer", result);
        return result;
    }

    int stepResult = FL_STEP_CONTINUE;
    int convertedSamples = swr_convert(
        state->resampler,
        convertedData,
        outputSamples,
        (const uint8_t **)frame->extended_data,
        frame->nb_samples
    );
    if (convertedSamples < 0) {
        fl_write_av_error(state->errorBuffer, state->errorBufferSize, "Could not resample decoded frame", convertedSamples);
        stepResult = convertedSamples;
        goto done;
    }

    if (!isfinite(state->originSeconds) && isfinite(frameStartSeconds)) {
        state->originSeconds = frameStartSeconds;
    }

    int64_t leadingFramesToDrop = 0;
    if (isfinite(state->originSeconds) && isfinite(frameStartSeconds)) {
        double expectedSeconds = state->originSeconds + ((double)state->frameCount / (double)state->outputRate);
        double offsetSeconds = frameStartSeconds - expectedSeconds;
        int64_t offsetFrames = (int64_t)llround(offsetSeconds * (double)state->outputRate);

        if (offsetFrames < 0 && state->trimsLeadingAudio && !state->hasOutputAudio) {
            // The seek landed on a packet before the requested start; cut the
            // decoded audio so output sample 0 is exactly the requested time.
            leadingFramesToDrop = -offsetFrames;
        } else if (offsetFrames > 0) {
            // Audio is missing: the seek landed late, corrupt packets were
            // skipped, or the demuxer dropped damaged data. Pad with silence so
            // the timeline stays honest and later chunks line up.
            double minimumGap = state->gapToleranceSeconds;
            double maximumGap = 0;
            if (state->skippedCorruptPacket) {
                maximumGap = FL_STREAM_GAP_FILL_LIMIT_SECONDS;
            } else if (state->hasOutputAudio) {
                minimumGap = fmax(minimumGap, FL_STREAM_GAP_MINIMUM_SECONDS);
                maximumGap = FL_STREAM_GAP_FILL_LIMIT_SECONDS;
            } else if (state->trimsLeadingAudio) {
                maximumGap = FL_SEEK_GAP_FILL_LIMIT_SECONDS;
            }

            if (offsetSeconds > minimumGap && offsetSeconds <= maximumGap) {
                result = fl_append_silence(state, offsetFrames);
                if (result < 0) {
                    stepResult = result;
                    goto done;
                }
            }
        }
    }

    if (leadingFramesToDrop >= (int64_t)convertedSamples) {
        goto done;
    }
    convertedSamples -= (int)leadingFramesToDrop;

    int64_t remainingFrames = fl_remaining_output_frames(state);
    if (remainingFrames <= 0) {
        stepResult = FL_STEP_REACHED_LIMIT;
        goto done;
    }
    if ((int64_t)convertedSamples > remainingFrames) {
        convertedSamples = (int)remainingFrames;
    }

    result = fl_ensure_capacity(state, state->frameCount + convertedSamples);
    if (result < 0) {
        stepResult = result;
        goto done;
    }

    memcpy(
        state->samples + (state->frameCount * state->outputChannels),
        convertedData[0] + ((size_t)leadingFramesToDrop * (size_t)state->outputChannels * sizeof(float)),
        (size_t)convertedSamples * (size_t)state->outputChannels * sizeof(float)
    );
    state->frameCount += convertedSamples;
    state->hasOutputAudio = 1;
    state->skippedCorruptPacket = 0;
    state->consecutiveCorruptPackets = 0;

    if (state->maxOutputFrames > 0 && state->frameCount >= state->maxOutputFrames) {
        stepResult = FL_STEP_REACHED_LIMIT;
    }

done:
    if (convertedData != NULL) {
        av_freep(&convertedData[0]);
        av_freep(&convertedData);
    }
    return stepResult;
}

static int fl_is_fatal_decode_error(int result) {
    return result == AVERROR(ENOMEM) || result == AVERROR(EINVAL) || result == AVERROR_EXIT;
}

static int fl_note_corrupt_packet(FLDecodeState *state, int result) {
    state->corruptPacketCount += 1;
    state->consecutiveCorruptPackets += 1;
    state->skippedCorruptPacket = 1;
    // Positions carried over from before the damage are no longer trustworthy.
    state->nextInputSeconds = NAN;

    if (state->consecutiveCorruptPackets > FL_MAX_CONSECUTIVE_CORRUPT_PACKETS) {
        fl_write_av_error(
            state->errorBuffer,
            state->errorBufferSize,
            "Too many consecutive undecodable FFmpeg packets",
            result
        );
        return result < 0 ? result : AVERROR_INVALIDDATA;
    }

    return FL_STEP_CORRUPT;
}

static int fl_receive_available_frames(FLDecodeState *state, AVFrame *frame) {
    while (1) {
        if (fl_is_cancelled(state->cancelToken)) {
            return AVERROR_EXIT;
        }

        int result = avcodec_receive_frame(state->codecContext, frame);
        if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) {
            return FL_STEP_CONTINUE;
        }

        if (result < 0) {
            if (fl_is_fatal_decode_error(result)) {
                fl_write_av_error(state->errorBuffer, state->errorBufferSize, "Could not receive decoded FFmpeg frame", result);
                return result;
            }
            return fl_note_corrupt_packet(state, result);
        }

        result = fl_append_decoded_frame(state, frame);
        av_frame_unref(frame);

        if (result != FL_STEP_CONTINUE) {
            return result;
        }
    }
}

static int fl_codec_needs_seek_preroll(const AVCodecParameters *parameters) {
    const AVCodecDescriptor *descriptor = avcodec_descriptor_get(parameters->codec_id);
    if (descriptor == NULL) {
        return 1;
    }

    int isLossless = (descriptor->props & AV_CODEC_PROP_LOSSLESS) != 0;
    int isLossy = (descriptor->props & AV_CODEC_PROP_LOSSY) != 0;
    return !(isLossless && !isLossy);
}

// Seeks to a packet at or before `targetSeconds` (stream time). Landing early
// is fine: the caller trims decoded audio to the exact sample. Landing late is
// not, because the skipped audio would be labelled as starting at the target.
static int fl_seek_audio_stream(
    AVFormatContext *formatContext,
    AVStream *stream,
    int streamIndex,
    double targetSeconds
) {
    double prerollSeconds = 0;
    if (fl_codec_needs_seek_preroll(stream->codecpar)) {
        prerollSeconds = FL_LOSSY_SEEK_PREROLL_SECONDS;
        if (stream->codecpar->seek_preroll > 0 && stream->codecpar->sample_rate > 0) {
            double codecPreroll = (double)stream->codecpar->seek_preroll / (double)stream->codecpar->sample_rate;
            if (codecPreroll > prerollSeconds) {
                prerollSeconds = codecPreroll;
            }
        }
    }

    double seekSeconds = targetSeconds - prerollSeconds;
    int64_t seekTarget = (int64_t)floor(seekSeconds / av_q2d(stream->time_base));

    int result = avformat_seek_file(formatContext, streamIndex, INT64_MIN, seekTarget, seekTarget, 0);
    if (result >= 0) {
        return result;
    }

    result = av_seek_frame(formatContext, streamIndex, seekTarget, AVSEEK_FLAG_BACKWARD);
    if (result >= 0) {
        return result;
    }

    int64_t globalSeekTarget = (int64_t)floor(seekSeconds * (double)AV_TIME_BASE);
    result = av_seek_frame(formatContext, -1, globalSeekTarget, AVSEEK_FLAG_BACKWARD);
    if (result >= 0) {
        return result;
    }

    // Last resort for demuxers that cannot seek backward: accept any packet
    // near the target. A late landing is padded with silence up to
    // FL_SEEK_GAP_FILL_LIMIT_SECONDS by the decode loop.
    return avformat_seek_file(formatContext, streamIndex, INT64_MIN, seekTarget, INT64_MAX, AVSEEK_FLAG_ANY);
}

// Picks the output channel arrangement. Mono and stereo pass through; common
// surround layouts keep their channels and report the matching Core Audio
// layout tag; anything else is remixed to 5.1 or stereo by the resampler.
static uint32_t fl_select_output_layout(const AVChannelLayout *inputLayout, AVChannelLayout *outputLayout) {
    static const struct {
        AVChannelLayout layout;
        uint32_t tag;
    } surroundLayouts[] = {
        { AV_CHANNEL_LAYOUT_2POINT1, kAudioChannelLayoutTag_DVD_4 },
        { AV_CHANNEL_LAYOUT_SURROUND, kAudioChannelLayoutTag_MPEG_3_0_A },
        { AV_CHANNEL_LAYOUT_3POINT1, kAudioChannelLayoutTag_DVD_10 },
        { AV_CHANNEL_LAYOUT_4POINT0, kAudioChannelLayoutTag_MPEG_4_0_A },
        { AV_CHANNEL_LAYOUT_QUAD, kAudioChannelLayoutTag_Quadraphonic },
        { AV_CHANNEL_LAYOUT_5POINT0_BACK, kAudioChannelLayoutTag_MPEG_5_0_A },
        { AV_CHANNEL_LAYOUT_5POINT0, kAudioChannelLayoutTag_MPEG_5_0_A },
        { AV_CHANNEL_LAYOUT_5POINT1_BACK, kAudioChannelLayoutTag_MPEG_5_1_A },
        { AV_CHANNEL_LAYOUT_5POINT1, kAudioChannelLayoutTag_MPEG_5_1_A }
    };

    int channels = inputLayout->nb_channels;
    if (channels <= 1) {
        av_channel_layout_default(outputLayout, 1);
        return 0;
    }
    if (channels == 2) {
        av_channel_layout_default(outputLayout, 2);
        return 0;
    }

    AVChannelLayout normalizedLayout;
    memset(&normalizedLayout, 0, sizeof(normalizedLayout));
    if (inputLayout->order == AV_CHANNEL_ORDER_UNSPEC) {
        av_channel_layout_default(&normalizedLayout, channels);
    } else if (av_channel_layout_copy(&normalizedLayout, inputLayout) < 0) {
        av_channel_layout_default(outputLayout, 2);
        return 0;
    }

    for (size_t index = 0; index < sizeof(surroundLayouts) / sizeof(surroundLayouts[0]); index++) {
        if (av_channel_layout_compare(&normalizedLayout, &surroundLayouts[index].layout) == 0) {
            av_channel_layout_uninit(&normalizedLayout);
            av_channel_layout_copy(outputLayout, &surroundLayouts[index].layout);
            return surroundLayouts[index].tag;
        }
    }
    av_channel_layout_uninit(&normalizedLayout);

    if (channels >= 6) {
        AVChannelLayout fivePointOne = AV_CHANNEL_LAYOUT_5POINT1_BACK;
        av_channel_layout_copy(outputLayout, &fivePointOne);
        return kAudioChannelLayoutTag_MPEG_5_1_A;
    }

    av_channel_layout_default(outputLayout, 2);
    return 0;
}

static int32_t fl_ffmpeg_decode_file_internal(
    const char *path,
    double startSeconds,
    double durationSeconds,
    const FLCancelToken *cancelToken,
    FLDecodedAudio *outAudio,
    char *errorBuffer,
    int32_t errorBufferSize
) {
    if (outAudio == NULL) {
        fl_write_error(errorBuffer, errorBufferSize, "Missing output audio pointer");
        return -1;
    }

    memset(outAudio, 0, sizeof(FLDecodedAudio));

    if (path == NULL) {
        fl_write_error(errorBuffer, errorBufferSize, "Missing file path");
        return -1;
    }

    AVFormatContext *formatContext = NULL;
    const AVCodec *codec = NULL;
    AVPacket *packet = NULL;
    AVFrame *frame = NULL;
    int outputLayoutInitialized = 0;
    uint32_t channelLayoutTag = 0;
    int streamIndex = -1;
    int result = 0;

    FLDecodeState state;
    memset(&state, 0, sizeof(state));
    state.cancelToken = cancelToken;
    state.originSeconds = NAN;
    state.nextInputSeconds = NAN;
    state.lastRawTimestamp = AV_NOPTS_VALUE;
    state.errorBuffer = errorBuffer;
    state.errorBufferSize = errorBufferSize;

    if (!isfinite(startSeconds) || startSeconds < 0) {
        startSeconds = 0;
    }

    formatContext = avformat_alloc_context();
    if (formatContext == NULL) {
        fl_write_error(errorBuffer, errorBufferSize, "Could not allocate FFmpeg format context");
        result = AVERROR(ENOMEM);
        goto fail;
    }
    formatContext->interrupt_callback.callback = fl_interrupt_callback;
    formatContext->interrupt_callback.opaque = (void *)cancelToken;

    result = avformat_open_input(&formatContext, path, NULL, NULL);
    if (result < 0) {
        fl_write_av_error(errorBuffer, errorBufferSize, "Could not open audio file with FFmpeg", result);
        goto fail;
    }

    result = avformat_find_stream_info(formatContext, NULL);
    if (result < 0) {
        fl_write_av_error(errorBuffer, errorBufferSize, "Could not read FFmpeg stream information", result);
        goto fail;
    }

    result = av_find_best_stream(formatContext, AVMEDIA_TYPE_AUDIO, -1, -1, &codec, 0);
    if (result < 0) {
        fl_write_av_error(errorBuffer, errorBufferSize, "Could not find an audio stream", result);
        goto fail;
    }
    streamIndex = result;

    AVStream *stream = formatContext->streams[streamIndex];
    state.stream = stream;
    state.codecContext = avcodec_alloc_context3(codec);
    if (state.codecContext == NULL) {
        fl_write_error(errorBuffer, errorBufferSize, "Could not allocate FFmpeg codec context");
        result = AVERROR(ENOMEM);
        goto fail;
    }

    result = avcodec_parameters_to_context(state.codecContext, stream->codecpar);
    if (result < 0) {
        fl_write_av_error(errorBuffer, errorBufferSize, "Could not copy FFmpeg codec parameters", result);
        goto fail;
    }
    state.codecContext->pkt_timebase = stream->time_base;

    result = avcodec_open2(state.codecContext, codec, NULL);
    if (result < 0) {
        fl_write_av_error(errorBuffer, errorBufferSize, "Could not open FFmpeg decoder", result);
        goto fail;
    }

    if (state.codecContext->sample_rate <= 0) {
        fl_write_error(errorBuffer, errorBufferSize, "FFmpeg reported an invalid sample rate");
        result = AVERROR_INVALIDDATA;
        goto fail;
    }
    state.outputRate = state.codecContext->sample_rate;

    if (durationSeconds > 0) {
        state.maxOutputFrames = (int64_t)ceil(durationSeconds * (double)state.outputRate);
        if (state.maxOutputFrames <= 0) {
            fl_write_error(errorBuffer, errorBufferSize, "Requested FFmpeg segment is empty");
            result = AVERROR(EINVAL);
            goto fail;
        }
    }

    double timeBaseSeconds = av_q2d(stream->time_base);
    state.gapToleranceSeconds = fmax(0.002, 2.0 * timeBaseSeconds);

    if (startSeconds > 0) {
        // Times passed in are relative to the first decoded sample, which is
        // what a decode from the beginning of the file produces.
        double streamStartSeconds = stream->start_time != AV_NOPTS_VALUE
            ? (double)stream->start_time * timeBaseSeconds
            : 0;
        // Quantise to the output sample grid so the cut is on a whole sample.
        double targetSeconds = streamStartSeconds +
            (round(startSeconds * (double)state.outputRate) / (double)state.outputRate);

        result = fl_seek_audio_stream(formatContext, stream, streamIndex, targetSeconds);
        if (result < 0) {
            fl_write_av_error(errorBuffer, errorBufferSize, "Could not seek FFmpeg audio stream", result);
            goto fail;
        }
        avcodec_flush_buffers(state.codecContext);

        state.originSeconds = targetSeconds;
        state.trimsLeadingAudio = 1;
    }

    AVChannelLayout codecLayout;
    memset(&codecLayout, 0, sizeof(codecLayout));
    if (state.codecContext->ch_layout.nb_channels > 0) {
        result = av_channel_layout_copy(&codecLayout, &state.codecContext->ch_layout);
        if (result < 0) {
            fl_write_av_error(errorBuffer, errorBufferSize, "Could not copy FFmpeg channel layout", result);
            goto fail;
        }
    } else {
        av_channel_layout_default(&codecLayout, 2);
    }

    channelLayoutTag = fl_select_output_layout(&codecLayout, &state.outputLayout);
    outputLayoutInitialized = 1;
    state.outputChannels = state.outputLayout.nb_channels;

    result = fl_configure_resampler(&state, &codecLayout, state.codecContext->sample_fmt, state.codecContext->sample_rate);
    av_channel_layout_uninit(&codecLayout);
    if (result < 0) {
        goto fail;
    }

    packet = av_packet_alloc();
    frame = av_frame_alloc();
    if (packet == NULL || frame == NULL) {
        fl_write_error(errorBuffer, errorBufferSize, "Could not allocate FFmpeg packet or frame");
        result = AVERROR(ENOMEM);
        goto fail;
    }

    int reachedLimit = 0;
    while (!reachedLimit) {
        if (fl_is_cancelled(cancelToken)) {
            result = AVERROR_EXIT;
            goto fail;
        }

        result = av_read_frame(formatContext, packet);
        if (result < 0) {
            break;
        }

        if (packet->stream_index == streamIndex) {
            result = avcodec_send_packet(state.codecContext, packet);
            if (result < 0 && result != AVERROR(EAGAIN)) {
                av_packet_unref(packet);
                if (fl_is_fatal_decode_error(result)) {
                    fl_write_av_error(errorBuffer, errorBufferSize, "Could not send packet to FFmpeg decoder", result);
                    goto fail;
                }

                // A damaged packet should cost that packet, not the rest of
                // the track.
                result = fl_note_corrupt_packet(&state, result);
                if (result < 0) {
                    goto fail;
                }
                continue;
            }

            result = fl_receive_available_frames(&state, frame);
            if (result < 0) {
                av_packet_unref(packet);
                goto fail;
            }
            if (result == FL_STEP_REACHED_LIMIT) {
                reachedLimit = 1;
            }
        }

        av_packet_unref(packet);
        result = 0;
    }

    if (fl_is_cancelled(cancelToken)) {
        result = AVERROR_EXIT;
        goto fail;
    }

    if (!reachedLimit && result != 0 && result != AVERROR_EOF) {
        // A read error after some audio was decoded ends the stream there
        // instead of discarding what was read.
        if (state.frameCount <= 0) {
            fl_write_av_error(errorBuffer, errorBufferSize, "Could not read FFmpeg audio packet", result);
            goto fail;
        }
    }

    if (!reachedLimit) {
        result = avcodec_send_packet(state.codecContext, NULL);
        if (result < 0 && result != AVERROR_EOF && fl_is_fatal_decode_error(result)) {
            fl_write_av_error(errorBuffer, errorBufferSize, "Could not flush FFmpeg decoder", result);
            goto fail;
        }

        result = fl_receive_available_frames(&state, frame);
        if (result < 0) {
            goto fail;
        }
    }

    if (state.frameCount <= 0 || state.samples == NULL) {
        fl_write_error(errorBuffer, errorBufferSize, "FFmpeg decoded no audio samples");
        result = AVERROR_INVALIDDATA;
        goto fail;
    }

    outAudio->samples = state.samples;
    outAudio->sampleRate = state.outputRate;
    outAudio->channelCount = state.outputChannels;
    outAudio->frameCount = state.frameCount;
    outAudio->duration = (double)state.frameCount / (double)state.outputRate;
    outAudio->channelLayoutTag = channelLayoutTag;
    outAudio->corruptPacketCount = state.corruptPacketCount;
    state.samples = NULL;
    result = 0;

fail:
    if (state.samples != NULL) {
        free(state.samples);
    }
    if (packet != NULL) {
        av_packet_free(&packet);
    }
    if (frame != NULL) {
        av_frame_free(&frame);
    }
    if (state.resampler != NULL) {
        swr_free(&state.resampler);
    }
    if (state.codecContext != NULL) {
        avcodec_free_context(&state.codecContext);
    }
    if (formatContext != NULL) {
        avformat_close_input(&formatContext);
    }
    if (state.inputLayoutInitialized) {
        av_channel_layout_uninit(&state.inputLayout);
    }
    if (outputLayoutInitialized) {
        av_channel_layout_uninit(&state.outputLayout);
    }

    if (result == 0) {
        return 0;
    }
    if (result == AVERROR_EXIT || fl_is_cancelled(cancelToken)) {
        fl_write_error(errorBuffer, errorBufferSize, "FFmpeg decode was cancelled");
        return FL_FFMPEG_DECODE_CANCELLED;
    }
    return -1;
}

int32_t fl_ffmpeg_decode_file(const char *path, FLDecodedAudio *outAudio, char *errorBuffer, int32_t errorBufferSize) {
    return fl_ffmpeg_decode_file_internal(path, 0, -1, NULL, outAudio, errorBuffer, errorBufferSize);
}

int32_t fl_ffmpeg_decode_file_segment(const char *path, double startSeconds, double durationSeconds, FLDecodedAudio *outAudio, char *errorBuffer, int32_t errorBufferSize) {
    return fl_ffmpeg_decode_file_internal(path, startSeconds, durationSeconds, NULL, outAudio, errorBuffer, errorBufferSize);
}

int32_t fl_ffmpeg_decode_file_segment_cancellable(const char *path, double startSeconds, double durationSeconds, const FLCancelToken *cancelToken, FLDecodedAudio *outAudio, char *errorBuffer, int32_t errorBufferSize) {
    return fl_ffmpeg_decode_file_internal(path, startSeconds, durationSeconds, cancelToken, outAudio, errorBuffer, errorBufferSize);
}

int32_t fl_ffmpeg_probe_duration(const char *path, double *outDuration, char *errorBuffer, int32_t errorBufferSize) {
    if (outDuration == NULL) {
        fl_write_error(errorBuffer, errorBufferSize, "Missing output duration pointer");
        return -1;
    }

    *outDuration = 0;

    if (path == NULL) {
        fl_write_error(errorBuffer, errorBufferSize, "Missing file path");
        return -1;
    }

    AVFormatContext *formatContext = NULL;
    int result = avformat_open_input(&formatContext, path, NULL, NULL);
    if (result < 0) {
        fl_write_av_error(errorBuffer, errorBufferSize, "Could not open audio file with FFmpeg", result);
        goto fail;
    }

    result = avformat_find_stream_info(formatContext, NULL);
    if (result < 0) {
        fl_write_av_error(errorBuffer, errorBufferSize, "Could not read FFmpeg stream information", result);
        goto fail;
    }

    result = av_find_best_stream(formatContext, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (result < 0) {
        fl_write_av_error(errorBuffer, errorBufferSize, "Could not find an audio stream", result);
        goto fail;
    }

    AVStream *stream = formatContext->streams[result];
    double duration = 0;
    if (stream != NULL && stream->duration != AV_NOPTS_VALUE && stream->duration > 0) {
        duration = (double)stream->duration * av_q2d(stream->time_base);
    }

    if (!(duration > 0) && formatContext->duration != AV_NOPTS_VALUE && formatContext->duration > 0) {
        duration = (double)formatContext->duration / (double)AV_TIME_BASE;
    }

    if (!(duration > 0) || !isfinite(duration)) {
        fl_write_error(errorBuffer, errorBufferSize, "FFmpeg did not report a usable duration");
        result = -1;
        goto fail;
    }

    *outDuration = duration;
    result = 0;

fail:
    if (formatContext != NULL) {
        avformat_close_input(&formatContext);
    }

    return result == 0 ? 0 : -1;
}

void fl_ffmpeg_free_decoded_audio(FLDecodedAudio *audio) {
    if (audio == NULL) {
        return;
    }

    if (audio->samples != NULL) {
        free(audio->samples);
    }

    memset(audio, 0, sizeof(FLDecodedAudio));
}

const char *fl_ffmpeg_version(void) {
    return av_version_info();
}
