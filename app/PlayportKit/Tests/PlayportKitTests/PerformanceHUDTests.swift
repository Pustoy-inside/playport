// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import PlayportKit

final class PerformanceHUDTests: XCTestCase {
    func testPresetsAndTheMenusCycle() {
        XCTAssertEqual(HUDPreset.off.items(custom: [.cpu]), [])
        XCTAssertEqual(HUDPreset.fps.items(custom: []), [.fps])
        XCTAssertEqual(HUDPreset.compact.items(custom: []), [.fps, .frameTime, .cpu, .gpu])
        XCTAssertEqual(HUDPreset.full.items(custom: []), HUDItem.allCases)
        // A custom set keeps the HUD's order, whatever order it was chosen in.
        XCTAssertEqual(HUDPreset.custom.items(custom: [.memory, .fps, .battery]), [.fps, .battery, .memory])
        XCTAssertEqual([HUDPreset.off, .fps, .compact, .full, .custom].map(\.next), [.fps, .compact, .full, .off, .off])
    }

    func testSettingsRoundTripThroughDefaults() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "PerformanceHUDTests-\(UUID().uuidString)"))
        XCTAssertEqual(HUDSettings.load(d), HUDSettings())
        let s = HUDSettings(preset: .custom, custom: [.gpu, .thermal], position: .bottomRight)
        s.save(d)
        XCTAssertEqual(HUDSettings.load(d), s)
        XCTAssertEqual(HUDSettings.load(d).items, [.gpu, .thermal])
        XCTAssertEqual(d.string(forKey: HUDSettings.itemsKey), "gpu,thermal")
        XCTAssertEqual(HUDSettings.items("cpu,bogus,fps"), [.cpu, .fps])
        XCTAssertEqual(HUDSettings.list([.memory, .fps]), "fps,memory")
        d.set("huge", forKey: HUDSettings.presetKey)
        XCTAssertEqual(HUDSettings.load(d).preset, .off)
    }

    func testASampleReadsAsLines() {
        let s = HUDSample(fps: 58.6, frameMs: 17.06, worstMs: 33.4, cpuPercent: 34.4, gpuMs: 11.24, gpuPercent: 66.6,
                          thermal: 1, battery: 0.78, charging: true, memoryBytes: 3_328_599_654,
                          render: .init(width: 1564, height: 720), output: .init(width: 2867, height: 1320), upscaler: "MetalFX")
        XCTAssertEqual(s.lines(HUDItem.allCases), [
            "59 FPS", "Frame 17.1 ms · max 33", "CPU 34%", "GPU 11.2 ms · 67%", "Heat warm", "Battery 78% ⚡",
            "Memory 3.1 GB", "1564×720 → 2867×1320 MetalFX",
        ])
        var bare = HUDSample(fps: 30, render: .init(width: 1280, height: 720))
        bare.output = .init(width: 1280, height: 720)
        XCTAssertEqual(bare.lines([.gpu, .battery, .resolution]), ["GPU —", "Battery —", "1280×720"])
    }
}
