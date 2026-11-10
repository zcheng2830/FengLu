#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FLDecodedAudio {
    float *samples;
    int32_t sampleRate;
    int32_t channelCount;
    int64_t frameCount;
    double duration;
    // Core Audio AudioChannelLayoutTag describing the channel order when
    // channelCount > 2; 0 means plain mono/stereo.
    uint32_t channelLayoutTag;
    // Packets the decoder rejected and skipped while producing this audio.
    int32_t corruptPacketCount;
} FLDecodedAudio;

// Lets another thread abort a decode that is in progress. A token may be
// cancelled from any thread; create/destroy must bracket every decode using it.
typedef struct FLCancelToken FLCancelToken;
FLCancelToken *fl_ffmpeg_cancel_token_create(void);
void fl_ffmpeg_cancel_token_cancel(FLCancelToken *token);
void fl_ffmpeg_cancel_token_destroy(FLCancelToken *token);

// Returned by the cancellable decode when the token was cancelled.
#define FL_FFMPEG_DECODE_CANCELLED (-2)

// startSeconds is measured from the first decoded sample of the file, and the
// returned audio starts at exactly that sample. durationSeconds <= 0 decodes
// to the end of the file.
int32_t fl_ffmpeg_decode_file_segment_cancellable(const char *path, double startSeconds, double durationSeconds, const FLCancelToken *cancelToken, FLDecodedAudio *outAudio, char *errorBuffer, int32_t errorBufferSize);
int32_t fl_ffmpeg_decode_file(const char *path, FLDecodedAudio *outAudio, char *errorBuffer, int32_t errorBufferSize);
int32_t fl_ffmpeg_decode_file_segment(const char *path, double startSeconds, double durationSeconds, FLDecodedAudio *outAudio, char *errorBuffer, int32_t errorBufferSize);
int32_t fl_ffmpeg_probe_duration(const char *path, double *outDuration, char *errorBuffer, int32_t errorBufferSize);
void fl_ffmpeg_free_decoded_audio(FLDecodedAudio *audio);
const char *fl_ffmpeg_version(void);

#ifdef __cplusplus
}
#endif
