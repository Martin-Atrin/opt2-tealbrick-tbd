import SwiftUI

struct BugReportView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Support").font(.title2)
      Text("Support destinations and local-build information are managed in one place.")
      Button("Open support settings") {
        NotificationCenter.default.post(name: Notification.Name("tbdOpenSettings"), object: "about")
      }
    }.padding(24)
  }
}
