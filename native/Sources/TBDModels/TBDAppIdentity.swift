import Foundation

/// Which identity this process runs as: the owner's live TBD, or the DEBUG-only development copy ("TBD Dev").
///
/// The one switch is the Debug build setting `PRODUCT_BUNDLE_IDENTIFIER = com.tealbrick.tbd.dev` (companion/Dayflow
/// project, Debug configuration only). A DEBUG build running under that bundle id is the dev identity; every per-user
/// location then gets a separate name, so the dev app never reads or writes the live app's data:
///
/// - folders (`~/Library/Application Support/TBD`, `~/Library/Logs/TBD`, `~/Documents/TBD`): `folder("TBD")` → `TBD-dev`
/// - Keychain services: `service("com.tealbrick.tbd.models")` → `com.tealbrick.tbd.models.dev`
/// - UserDefaults: separate by bundle id (`com.tealbrick.tbd.dev`); no code uses the live suite in the app
///
/// `--design-shots <dir>` (DEBUG only) renders companion screens to PNG; it uses `TBD-dev-shots` so a run starts from
/// its own demo data and never touches the dev person's data either.
///
/// Release builds compile the `#else` branches: `isDev` is the constant `false` and `folder(_:)` / `service(_:)` return
/// their argument unchanged, so every call site resolves to the same literal it had before.
public enum TBDIdentity {
    public static let liveBundleID = "com.tealbrick.tbd"
    public static let devBundleID = "com.tealbrick.tbd.dev"

    #if DEBUG
    /// True in a DEBUG build running as `com.tealbrick.tbd.dev`.
    public static let isDev: Bool = Bundle.main.bundleIdentifier == devBundleID
    /// True when the dev app was launched with `--design-shots <dir>`.
    public static let isDesignShots: Bool = isDev && CommandLine.arguments.contains("--design-shots")

    /// A per-user folder name: `TBD` → `TBD-dev` (`TBD-dev-shots` in a design-shots run).
    public static func folder(_ live: String) -> String {
        guard isDev else { return live }
        return live + (isDesignShots ? "-dev-shots" : "-dev")
    }

    /// A Keychain service name: `com.tealbrick.tbd.chat` → `com.tealbrick.tbd.chat.dev`.
    public static func service(_ live: String) -> String { isDev ? live + ".dev" : live }
    #else
    public static let isDev = false
    public static let isDesignShots = false
    @inline(__always) public static func folder(_ live: String) -> String { live }
    @inline(__always) public static func service(_ live: String) -> String { live }
    #endif

    /// `~/Library/Application Support/<folder(name)>`.
    public static func applicationSupport(_ name: String = "TBD") -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folder(name), isDirectory: true)
    }
}
