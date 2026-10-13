// The kit's one face: Nunito (SIL OFL 1.1, Fonts/Nunito-OFL.txt), self-hosted in this module's resources.
import AppKit
import CoreText
import SwiftUI

public enum TBDFonts {
    /// The family every TBD surface uses (same as the web: --tb-font).
    public static let family = "Nunito"

    /// Registers the bundled Nunito for this process once. A host that already ships it (Info.plist fonts) keeps its copy.
    public static func register() { _ = registered }

    private static let registered: Bool = {
        if NSFont(name: family, size: 12) != nil { return true }
        guard let url = Bundle.module.url(forResource: "Nunito-VariableFont_wght", withExtension: "ttf", subdirectory: "Fonts") else {
            assertionFailure("TBDDesign: Nunito missing from the module resources")
            return false
        }
        var error: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if !ok { NSLog("TBDDesign: Nunito registration failed: %@", String(describing: error?.takeRetainedValue())) }
        return ok
    }()

    /// Nunito at a kit size and weight, scaling with the user's text size like `.body`.
    public static func nunito(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        register()
        return .custom(family, size: size, relativeTo: .body).weight(weight)
    }

    /// SF Symbols beside text: the system symbol font at a kit size (icons are not text; Nunito has no symbols).
    public static func symbol(_ size: CGFloat, _ weight: Font.Weight = TBDKit.weightNav) -> Font {
        .system(size: size, weight: weight)
    }

    /// The kit's mono (--tb-font-mono = system monospace) for code, ids, timestamps and model names only.
    public static func mono(_ size: CGFloat = TBDKit.textHint, _ weight: Font.Weight = TBDKit.weightBody) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
