# Listening notice

TBD Listening (`Sources/TBDSpeech`, `Sources/TBDListening`, `Sources/TBDListenCLI`) is a Teal Brick rewrite of the
features of MacParakeet (https://github.com/moona3k/macparakeet, GPL-3.0, (c) 2026 Daniel Moon).
The GPL-3.0 text is in `LICENSE-Listening-GPL-3.0.txt` and is bundled with TBD.app.

Dependencies keep their own licences: FluidAudio (Apache-2.0), WhisperKit / argmax-oss-swift (MIT),
GRDB (MIT), yyjson (MIT), swift-argument-parser (Apache-2.0).

yt-dlp (https://github.com/yt-dlp/yt-dlp) is not bundled. For video links, Listening downloads the official
`yt-dlp_macos` release binary on first use, verifies it against the release's SHA2-256SUMS and keeps it in
Listening/bin. yt-dlp is released into the public domain under the Unlicense (https://unlicense.org); its
standalone binary includes third-party components under their own licences, listed by the yt-dlp project.
