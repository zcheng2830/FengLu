# Third-Party Notices

## FFmpeg

FengluPlayer decodes audio through the FFmpeg libraries (libavformat,
libavcodec, libswresample, libavutil). This repository contains no FFmpeg
binaries. The staged app links or bundles whichever FFmpeg the build machine
provides, so the licence terms of a built `FengluPlayer.app` depend on that
FFmpeg build. The notes below are an engineering description, not legal advice.

FFmpeg is LGPL-2.1-or-later only when configured without GPL or nonfree
options. Many packaged builds are not:

- **GPL builds.** Homebrew's `ffmpeg` formula enables GPL components such as
  libx264 and libx265. An app built against it combines GPL code, so it can
  only be distributed under GPL-compatible terms.
- **Nonfree builds.** FFmpeg configured with `--enable-nonfree` (for example to
  use libfdk-aac) produces binaries that may not be redistributed.

`script/build_and_run.sh` reads the FFmpeg configuration string from the staged
binaries, checks the names of the bundled dylibs, prints a warning when it finds
GPL or nonfree markers, and writes what it found to
`Contents/Resources/FFMPEG_BUILD_INFO.txt` in the app. The check recognizes
common cases; an absent warning is not a guarantee.

### What The App Bundle Contains

- This file and the project `LICENSE`, in `Contents/Resources`.
- In a dynamic build, every non-system dylib the binary depends on, copied into
  `Contents/Frameworks`. Besides FFmpeg this usually includes codec libraries
  such as libmp3lame, libopus, libvorbis, libogg, libvpx, libx264, and libx265.
  **Each of those libraries has its own licence, and their licence texts are
  not reproduced here or copied into the bundle.** Anyone distributing the app
  must add them.
- No LGPL or GPL licence text for FFmpeg itself, and no relinking materials.

Building and running the app on your own machine needs none of this. Before
giving a built app to anyone else, use an FFmpeg build whose terms you can
meet and add the licence texts and source or relinking offers those terms
require.

### LGPL-Only Static Configuration

The tested LGPL-only static FFmpeg configuration is:

```bash
./configure \
  --prefix="$PREFIX" \
  --enable-static \
  --disable-shared \
  --disable-programs \
  --disable-doc \
  --disable-debug \
  --enable-pic
```

Build against it with `./script/build_and_run.sh --ffmpeg-dir "$PREFIX"`.
Static linking to LGPL FFmpeg may require providing relinkable object files or
equivalent relinking instructions alongside the app.

FFmpeg project: https://ffmpeg.org/
FFmpeg legal information: https://www.ffmpeg.org/legal.html

## SwiftSoup

HTML parsing uses SwiftSoup 2.14.3, pinned by Swift Package Manager.

Project: https://github.com/scinfu/SwiftSoup

The MIT License

Copyright (c) 2009-2025 Jonathan Hedley <https://jsoup.org/>
Copyright (c) 2016-2025 Nabil Chatbi (Swift port)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
