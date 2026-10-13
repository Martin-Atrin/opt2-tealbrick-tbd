import TBDDesign
import TBDModels
import SwiftUI

struct TBDAboutView: View {
  @AppStorage(TBDProductLinks.supportKey) private var support = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("TBD").font(.title2)
      Text("Chat · Companion · Listening")
      Text("Local build · updates are installed manually. No donor update feed is used.").foregroundStyle(.secondary)
      TBDUpdatesSection()
      Link("Website", destination: TBDProductLinks.website)
      TextField("Support URL (https://…)", text: $support).tbdField()
      if let url = TBDProductLinks.support() { Link("Open support", destination: url) }
      else { Text("Support is not configured. No reports are sent to upstream projects.").font(.callout).foregroundStyle(.secondary) }
      Divider()
      Text("Privacy").font(.headline)
      Text("Speech recognition runs on this Mac. AI cleanup, summaries and screen analysis use the models you select and may send text or screenshots to a network endpoint. Vendor telemetry is disabled. Diagnostic files and histories remain local unless you explicitly export them.")
      Text("Data").font(.headline)
      Text("Storage manages screenshots and timelapses. System manages speech history, audio retention and downloads. Voice notes keep their raw transcript alongside optional cleanup; interrupted note audio remains in Listening/VoiceNotes for recovery.")
      Divider()
      Text("Open-source components").font(.headline)
      Text("Companion includes Dayflow (MIT); Chat started from an MIT-licensed chat client; Listening is a Teal Brick rewrite of MacParakeet's features (GPL-3.0) and uses FluidAudio (Apache-2.0), WhisperKit (MIT) and GRDB (MIT). Licences are bundled with this app. For video links Listening downloads yt-dlp (Unlicense) from its official GitHub release on first use.").font(.callout)
    }
  }
}
