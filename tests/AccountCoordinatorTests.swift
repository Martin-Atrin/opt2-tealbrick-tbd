import Foundation
import SwiftUI

@MainActor
final class TBDChatRuntime {
  static let shared = TBDChatRuntime()
  var session: [String: Any]? = ["email": "person@example.test", "expiresAt": Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000]
  var workspaceFails = false
  var transportFails = false
  var reloaded = false
  func reloadAccountUI() { reloaded = true }
  func accountCall(_ name: String, args: [Any] = []) async throws -> Any {
    if transportFails { throw NSError(domain: "Test", code: 1) }
    switch name {
    case "controlPlanes": return ["activeId": "test", "profiles": [["id": "test", "name": "Test Portal", "issuer": "https://example.test"]]]
    case "session": return session as Any? ?? NSNull()
    case "portalWorkspaces":
      if workspaceFails { throw NSError(domain: "Offline", code: 2) }
      return ["selectedId": "workspace", "workspaces": [["id": "workspace", "name": "Workspace"]]]
    case "signOut": session = nil; return NSNull()
    case "signIn": return ["userCode": "TEST-CODE"]
    case "awaitSignIn": session = ["email": "new@example.test", "expiresAt": Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000]; return session!
    default: return NSNull()
    }
  }
}
@main struct Tests {
  @MainActor static func main() async {
    let a = TBDAccountCoordinator()
    precondition(!a.hasCheckedSession && !a.signedIn)
    await a.refresh(workspace: true)
    precondition(a.hasCheckedSession)
    precondition(a.signedIn && a.email == "person@example.test" && a.activeWorkspace == "workspace")
    precondition(a.profiles.first?.issuer == "https://example.test")
    TBDChatRuntime.shared.workspaceFails = true
    await a.refresh(workspace: true)
    precondition(a.signedIn && !a.error.isEmpty, "Offline workspace query must not become a logout")
    TBDChatRuntime.shared.workspaceFails = false
    TBDChatRuntime.shared.transportFails = true
    await a.refresh()
    precondition(a.signedIn && a.status.contains("unavailable"))
    TBDChatRuntime.shared.transportFails = false
    await a.perform("signOut")
    precondition(!a.signedIn && a.workspaces.isEmpty && a.email.isEmpty)
    await a.signIn()
    precondition(a.signedIn && a.email == "new@example.test" && TBDChatRuntime.shared.reloaded)
    precondition(!a.busy && a.code.isEmpty)
    print("PASS: account identity, issuer, workspace, offline preservation, transport failure, logout, login and renderer refresh")
  }
}
