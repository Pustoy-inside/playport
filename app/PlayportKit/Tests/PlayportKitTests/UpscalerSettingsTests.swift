// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import PlayportKit

final class UpscalerSettingsTests: XCTestCase {
    /// MetalFX unless chosen; a game's choice wins over Settings', and an unknown one inherits.
    func testAGameUpscalerOverridesTheGlobalOne() throws {
        let none = LaunchSettings.resolve(game: nil, global: LaunchSettings())
        XCTAssertEqual(none.upscaler, .metalFX)
        XCTAssertEqual(Upscaler.default, .metalFX)
        XCTAssertEqual(none.sharpness, LaunchSettings.defaultSharpness)
        let global = LaunchSettings(upscaler: .fsr1, sharpness: 50)
        XCTAssertEqual(LaunchSettings.resolve(game: nil, global: global).upscaler, .fsr1)
        XCTAssertEqual(LaunchSettings.resolve(game: nil, global: global).sharpness, 50)
        let game = LaunchSettings(upscaler: .metalFX)
        XCTAssertEqual(LaunchSettings.resolve(game: game, global: global).upscaler, .metalFX)
        XCTAssertEqual(LaunchSettings.resolve(game: game, global: global).sharpness, 50)
        XCTAssertEqual(LaunchSettings.resolve(game: LaunchSettings(upscaler: .off), global: global).upscaler, .off)
        XCTAssertEqual(LaunchSettings.resolve(game: LaunchSettings(sharpness: 0), global: global).sharpness, 0)
        // A sharpness outside 0...100 is skipped, as if unset.
        XCTAssertEqual(LaunchSettings.resolve(game: LaunchSettings(sharpness: 400), global: global).sharpness, 50)

        let saved = try JSONDecoder().decode(LaunchSettings.self, from: Data(#"{"upscaler":"metalfx","sharpness":25}"#.utf8))
        XCTAssertEqual(saved, LaunchSettings(upscaler: .metalFX, sharpness: 25))
        XCTAssertFalse(saved.isEmpty)
        let again = try JSONDecoder().decode(LaunchSettings.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(again, saved)
        let newer = try JSONDecoder().decode(LaunchSettings.self, from: Data(#"{"upscaler":"fsr3","screen":"900"}"#.utf8))
        XCTAssertNil(newer.upscaler)
        XCTAssertEqual(newer.screen, "900")
        XCTAssertTrue(LaunchSettings().isEmpty)
        XCTAssertFalse(LaunchSettings(sharpness: 0).isEmpty)
    }

    /// A person's own upscaler over a compatibility default, which can set one too.
    func testAnUpscalerOverACompatibilityDefault() {
        let base = LaunchSettings(screen: "540", upscaler: .fsr1, sharpness: 100)
        XCTAssertEqual(LaunchSettings(upscaler: .metalFX).over(base),
                       LaunchSettings(screen: "540", upscaler: .metalFX, sharpness: 100))
        XCTAssertEqual(LaunchSettings().over(base), base)
    }

    /// The percentages become RCAS's stops (AMD's FsrRcasCon): 100 % the sharpest.
    func testSharpnessPercentagesAreRCASStops() {
        XCTAssertEqual(LaunchSettings.sharpnessSteps, [0, 25, 50, 75, 100])
        XCTAssertTrue(LaunchSettings.sharpnessSteps.contains(LaunchSettings.defaultSharpness))
        XCTAssertNil(LaunchSettings.rcasStops(0))
        XCTAssertEqual(LaunchSettings.rcasStops(100), 0)
        XCTAssertEqual(LaunchSettings.rcasStops(75), 0.5)
        XCTAssertEqual(LaunchSettings.rcasStops(50), 1)
        XCTAssertEqual(LaunchSettings.rcasStops(25), 1.5)
        XCTAssertEqual(Upscaler.allCases.map(\.rawValue), ["off", "metalfx", "fsr1"])
        XCTAssertEqual(Upscaler.allCases.map(\.mode), [0, 1, 2])
    }
}
