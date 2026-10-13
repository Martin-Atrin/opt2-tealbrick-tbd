import AppKit
import SwiftUI
import XCTest
@testable import TBDDesign

final class TBDDesignTokensTests: XCTestCase {
    /// The bundled Nunito (OFL) registers and resolves by family name, with its licence beside it.
    func testNunitoIsBundledWithItsLicence() throws {
        TBDFonts.register()
        let font = try XCTUnwrap(NSFont(name: TBDFonts.family, size: 14))
        XCTAssertEqual(font.familyName, "Nunito")
        let ofl = try XCTUnwrap(Bundle.module.url(forResource: "Nunito-OFL", withExtension: "txt", subdirectory: "Fonts"))
        XCTAssertTrue(try String(contentsOf: ofl, encoding: .utf8).contains("The Nunito Project Authors"))
    }

    /// C125/C126: one brick radius; every legacy radius name is the brick.
    func testOneBrickRadius() {
        XCTAssertEqual(TBDKit.radiusBrick, 6)
        for r in [TBDTokens.Radius.base, TBDTokens.Radius.xs, TBDTokens.Radius.sm, TBDTokens.Radius.brick] { XCTAssertEqual(r, 6) }
        XCTAssertEqual(TBDKit.radiusSwatch, 2)
    }

    /// One Lift Rule: the old hard offset shadows draw nothing.
    func testNoHardOffsetShadows() {
        for s in [TBDTokens.Shadow.brickSm, TBDTokens.Shadow.brickMd, TBDTokens.Shadow.brickLg] {
            XCTAssertEqual(s.x, 0); XCTAssertEqual(s.y, 0); XCTAssertEqual(s.opacity, 0)
        }
    }

    /// Light and dark resolve to the kit values (ink #171717 / #f3ede0; primary fill = ink, primary on = paper).
    func testDynamicColoursFollowTheAppearance() {
        func hex(_ color: Color, dark: Bool) -> String {
            var out = ""
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                let c = NSColor(color).usingColorSpace(.sRGB)!
                out = String(format: "%02x%02x%02x", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
            }
            return out
        }
        XCTAssertEqual(hex(TBDColor.ink, dark: false), "171717")
        XCTAssertEqual(hex(TBDColor.ink, dark: true), "f3ede0")
        XCTAssertEqual(hex(TBDColor.primaryFill, dark: false), hex(TBDColor.ink, dark: false))
        XCTAssertEqual(hex(TBDColor.primaryOn, dark: true), hex(TBDColor.paper, dark: true))
        XCTAssertEqual(hex(TBDTokens.accent, dark: false), hex(TBDColor.tealInk, dark: false))
        XCTAssertEqual(hex(TBDColor.overlayFill, dark: true), "171717")
    }

    /// The type roles use the kit ramp: controls 14/800, dense body 15, display 26/900.
    func testTypeRamp() {
        XCTAssertEqual(TBDKit.textControl, 14)
        XCTAssertEqual(TBDKit.textLabel, 15)
        XCTAssertEqual(TBDKit.textH2, 26)
        XCTAssertEqual(TBDKit.weightLabel, .heavy)
        XCTAssertEqual(TBDKit.weightHead, .black)
    }
}
