// SPDX-License-Identifier: GPL-3.0-or-later
// Playport's performance HUD over a game (Settings › Performance HUD; the app's
// PerformanceHUDView draws it): which lines it shows, where, and how a sample
// of the game's figures reads. Apple's Metal HUD stays a separate switch.

import Foundation

/// One line's worth of the HUD.
public enum HUDItem: String, CaseIterable, Codable, Sendable {
    case fps
    case frameTime
    case cpu
    case gpu
    case thermal
    case battery
    case memory
    case resolution
}

/// What the HUD shows: a preset, or the person's own choice of items.
public enum HUDPreset: String, CaseIterable, Codable, Sendable {
    case off
    case fps
    case compact
    case full
    case custom

    /// The items, in the HUD's order; `custom` is the person's own set.
    public func items(custom: Set<HUDItem>) -> [HUDItem] {
        switch self {
        case .off: []
        case .fps: [.fps]
        case .compact: [.fps, .frameTime, .cpu, .gpu]
        case .full: HUDItem.allCases
        case .custom: HUDItem.allCases.filter(custom.contains)
        }
    }

    /// The in-game menu's next one: Off, FPS, Compact, Full, Off. Custom goes to Off.
    public var next: HUDPreset {
        switch self {
        case .off: .fps
        case .fps: .compact
        case .compact: .full
        case .full, .custom: .off
        }
    }
}

/// Where on the screen the HUD sits.
public enum HUDPosition: String, CaseIterable, Codable, Sendable {
    case topLeft
    case topCenter
    case topRight
    case bottomLeft
    case bottomRight
}

/// The HUD's settings, kept in UserDefaults under these keys.
public struct HUDSettings: Equatable, Sendable {
    public static let presetKey = "hud.preset"
    public static let itemsKey = "hud.items"
    public static let positionKey = "hud.position"
    /// What a custom HUD starts with.
    public static let defaultCustom: Set<HUDItem> = [.fps, .frameTime, .cpu, .gpu]

    public var preset: HUDPreset
    public var custom: Set<HUDItem>
    public var position: HUDPosition

    public init(preset: HUDPreset = .off, custom: Set<HUDItem> = HUDSettings.defaultCustom,
                position: HUDPosition = .topLeft) {
        self.preset = preset
        self.custom = custom
        self.position = position
    }

    public var items: [HUDItem] { preset.items(custom: custom) }

    /// What `defaults` holds; a key missing or not understood reads as its default.
    public static func load(_ defaults: UserDefaults = .standard) -> HUDSettings {
        var s = HUDSettings()
        if let p = defaults.string(forKey: presetKey).flatMap(HUDPreset.init(rawValue:)) { s.preset = p }
        if let list = defaults.string(forKey: itemsKey) { s.custom = items(list) }
        if let p = defaults.string(forKey: positionKey).flatMap(HUDPosition.init(rawValue:)) { s.position = p }
        return s
    }

    /// A custom set as it is stored: its items' names, comma-separated, in the HUD's order.
    public static func list(_ items: Set<HUDItem>) -> String {
        HUDItem.allCases.filter(items.contains).map(\.rawValue).joined(separator: ",")
    }

    /// The items a stored list names; names this build does not know are left out.
    public static func items(_ list: String) -> Set<HUDItem> {
        Set(list.split(separator: ",").compactMap { HUDItem(rawValue: String($0)) })
    }

    public func save(_ defaults: UserDefaults = .standard) {
        defaults.set(preset.rawValue, forKey: Self.presetKey)
        defaults.set(Self.list(custom), forKey: Self.itemsKey)
        defaults.set(position.rawValue, forKey: Self.positionKey)
    }
}

/// The game's figures over the last half second or so.
public struct HUDSample: Equatable, Sendable {
    /// Frames the game started a second.
    public var fps: Double
    /// The mean and the longest time between them, in milliseconds.
    public var frameMs: Double
    public var worstMs: Double
    /// The process's CPU use, as a share of all cores (0–100).
    public var cpuPercent: Double
    /// The GPU's busy time a frame, in milliseconds, and as a share of the time (0–100); nil when not measured.
    public var gpuMs: Double?
    public var gpuPercent: Double?
    /// ProcessInfo.ThermalState's raw value: 0 nominal, 1 fair, 2 serious, 3 critical.
    public var thermal: Int
    /// 0–1, nil when iOS does not say.
    public var battery: Double?
    public var charging: Bool
    public var memoryBytes: UInt64
    /// The game's frame and what is shown on the screen, in pixels; the upscaler's name, nil for none.
    public var render: Size?
    public var output: Size?
    public var upscaler: String?

    public struct Size: Equatable, Sendable {
        public var width: Int
        public var height: Int
        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    public init(fps: Double = 0, frameMs: Double = 0, worstMs: Double = 0, cpuPercent: Double = 0, gpuMs: Double? = nil,
                gpuPercent: Double? = nil, thermal: Int = 0, battery: Double? = nil, charging: Bool = false,
                memoryBytes: UInt64 = 0, render: Size? = nil, output: Size? = nil, upscaler: String? = nil) {
        self.fps = fps
        self.frameMs = frameMs
        self.worstMs = worstMs
        self.cpuPercent = cpuPercent
        self.gpuMs = gpuMs
        self.gpuPercent = gpuPercent
        self.thermal = thermal
        self.battery = battery
        self.charging = charging
        self.memoryBytes = memoryBytes
        self.render = render
        self.output = output
        self.upscaler = upscaler
    }

    /// The HUD's lines for `items`, in their order.
    public func lines(_ items: [HUDItem]) -> [String] {
        func one(_ v: Double) -> String { String(format: "%.1f", v) }
        var out: [String] = []
        for item in items {
            switch item {
            case .fps: out.append("\(Int(fps.rounded())) FPS")
            case .frameTime: out.append("Frame \(one(frameMs)) ms · max \(Int(worstMs.rounded()))")
            case .cpu: out.append("CPU \(Int(cpuPercent.rounded()))%")
            case .gpu:
                if let gpuMs, let gpuPercent {
                    out.append("GPU \(one(gpuMs)) ms · \(Int(gpuPercent.rounded()))%")
                } else {
                    out.append("GPU —")
                }
            case .thermal: out.append("Heat " + (["normal", "warm", "hot", "critical"].indices.contains(thermal)
                                                  ? ["normal", "warm", "hot", "critical"][thermal] : "?"))
            case .battery:
                out.append("Battery " + (battery.map { "\(Int(($0 * 100).rounded()))%" } ?? "—") + (charging ? " ⚡" : ""))
            case .memory: out.append(String(format: "Memory %.1f GB", Double(memoryBytes) / 1_073_741_824))
            case .resolution:
                guard let render else { out.append("Resolution —"); continue }
                var line = "\(render.width)×\(render.height)"
                if let upscaler, let output { line += " → \(output.width)×\(output.height) \(upscaler)" }
                out.append(line)
            }
        }
        return out
    }
}
