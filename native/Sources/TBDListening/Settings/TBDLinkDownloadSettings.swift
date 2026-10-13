import SwiftUI
import TBDDesign
import TBDSpeech

/// Video link download settings (v1 Settings › Transcription "Video download audio quality") plus
/// the managed yt-dlp status and its explicit "Update yt-dlp" action.
struct TBDLinkDownloadSettings: View {
    let preferences: TBDListeningPreferences
    @State private var quality: TBDYtDlpAudioQuality = .m4a
    @State private var status = ""
    @State private var updating = false

    var body: some View {
        VStack(spacing: 0) {
            TBDSettingsRow("Video download audio quality", help: quality.detail) {
                Picker("", selection: Binding(get: { quality }, set: { quality = $0; preferences.youtubeAudioQuality = $0 })) {
                    ForEach(TBDYtDlpAudioQuality.allCases, id: \.self) { Text($0.displayTitle).tag($0) }
                }
                .labelsHidden().frame(width: 260)
            }
            TBDSettingsRow("yt-dlp", help: status) {
                Button(updating ? "Updating…" : "Update yt-dlp") { update() }
                    .buttonStyle(TBDButtonStyle(.secondary)).disabled(updating)
            }
        }
        .onAppear {
            quality = preferences.youtubeAudioQuality
            status = Self.describe(installed: bootstrap.installedYtDlpPath() != nil, ffmpeg: TBDBinaryBootstrap.resolveFFmpegPath() != nil)
        }
    }

    private var bootstrap: TBDBinaryBootstrap { TBDBinaryBootstrap(defaults: preferences.defaults) }

    static func describe(installed: Bool, ffmpeg: Bool) -> String {
        (installed ? "Installed. Checked for updates weekly from the official GitHub release."
                   : "Downloads from the official GitHub release the first time you transcribe a video link.")
            + (ffmpeg ? " FFmpeg found." : " FFmpeg not found: links download as M4A.")
    }

    private func update() {
        updating = true
        status = "Downloading the latest yt-dlp…"
        let bootstrap = bootstrap
        Task {
            do {
                _ = try await bootstrap.ensureYtDlpAvailable(allowNetworkUpdate: true)
                status = "yt-dlp is up to date."
            } catch {
                status = error.localizedDescription
            }
            updating = false
        }
    }
}
