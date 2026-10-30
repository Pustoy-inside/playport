// SPDX-License-Identifier: GPL-3.0-or-later
// Playport's performance HUD over a game (PlayportKit PerformanceHUD: Settings ›
// Performance HUD chooses the lines and the corner; the in-game menu's HUD row
// cycles Off, FPS, Compact, Full for the game in play). Twice a second it reads:
// frames from the game layer (PacedMetalLayer.nextDrawable, every route's
// drawable), the process's CPU use over all its threads, the GPU's busy time
// (app/Sources/Upscale's commit hooks, counted only once a HUD shows GPU), the
// thermal state, the battery, the memory footprint, and the game's frame size,
// with the upscaled size and the upscaler's name when one is on.

#if canImport(UIKit)
import Darwin
import Foundation
import os
import PlayportKit
import QuartzCore
import UIKit
import Upscale

enum PerformanceHUD {
    private struct Frames {
        var count = 0
        var sum: Double = 0
        var worst: Double = 0
        var last: CFTimeInterval = 0
    }

    private static let frames = OSAllocatedUnfairLock(initialState: Frames())

    /// A frame the game started (PacedMetalLayer.nextDrawable, on the game's thread).
    static func frame() {
        let now = CACurrentMediaTime()
        frames.withLock { f in
            if f.last > 0 {
                let d = now - f.last
                f.sum += d
                f.worst = max(f.worst, d)
                f.count += 1
            }
            f.last = now
        }
    }

    /// The frames since the last call: how many, their mean and longest gap in seconds.
    static func takeFrames() -> (count: Int, mean: Double, worst: Double) {
        frames.withLock { f in
            defer { f.count = 0; f.sum = 0; f.worst = 0 }
            return (f.count, f.count > 0 ? f.sum / Double(f.count) : 0, f.worst)
        }
    }

    /// What this launch shows: Settings' preset, then the in-game menu's.
    @MainActor static private(set) var preset: HUDPreset = .off
    @MainActor static private(set) var settings = HUDSettings()
    /// The upscaler in effect (TitleScreen.configure), nil for none.
    @MainActor static var upscaler: String?
    @MainActor static weak var view: PerformanceHUDView?

    @MainActor static var items: [HUDItem] { preset.items(custom: settings.custom) }

    /// At the launch, from Settings.
    @MainActor static func configure() {
        settings = HUDSettings.load()
        show(settings.preset)
    }

    /// A preset for the rest of this launch (the in-game menu).
    @MainActor static func show(_ p: HUDPreset) {
        preset = p
        if items.contains(.gpu) { _ = pp_gpu_stats_start() }
        if items.contains(.battery) { UIDevice.current.isBatteryMonitoringEnabled = true }
        view?.restart()
        HostIO.log("hostio: performance HUD \(p.rawValue): \(items.map(\.rawValue).joined(separator: ","))")
    }

    // MARK: figures

    /// The process's CPU use over all its threads, as a share of all cores (0–100).
    static func cpuPercent() -> Double {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return 0 }
        defer {
            for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, threads[i]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var total = 0.0
        for i in 0..<Int(count) {
            var info = thread_basic_info()
            var n = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &n)
                }
            }
            if kr == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE)
            }
        }
        return total * 100 / Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
    }

    /// The process's memory footprint, as iOS counts it against its limit.
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    @MainActor static func sample(wall: Double) -> HUDSample {
        let f = takeFrames()
        let wanted = Set(items)
        var s = HUDSample()
        s.fps = wall > 0 ? Double(f.count) / wall : 0
        s.frameMs = f.mean * 1000
        s.worstMs = f.worst * 1000
        if wanted.contains(.cpu) { s.cpuPercent = cpuPercent() }
        if wanted.contains(.gpu) {
            var busy = 0.0, span = 0.0
            pp_gpu_stats_take(&busy, &span)
            if span > 0 {
                s.gpuPercent = min(100, busy / span * 100)
                s.gpuMs = f.count > 0 ? busy / Double(f.count) * 1000 : 0
            }
        }
        s.thermal = ProcessInfo.processInfo.thermalState.rawValue
        if wanted.contains(.battery) {
            let level = UIDevice.current.batteryLevel
            s.battery = level >= 0 ? Double(level) : nil
            s.charging = [.charging, .full].contains(UIDevice.current.batteryState)
        }
        if wanted.contains(.memory) { s.memoryBytes = footprint() }
        if wanted.contains(.resolution), let d = HostIO.shared.gameLayer?.drawableSize, d.width > 0 {
            s.render = .init(width: Int(d.width), height: Int(d.height))
            if let name = upscaler, let o = pp_upscale_output_layer()?.drawableSize, o.width > 0 {
                s.output = .init(width: Int(o.width), height: Int(o.height))
                s.upscaler = name
            }
        }
        return s
    }
}

/// The HUD's box over the game (GameSurfaceView puts it in its corner).
final class PerformanceHUDView: UIView {
    private let label = UILabel()
    private var timer: Timer?
    private var last = CACurrentMediaTime()

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = UIColor.black.withAlphaComponent(0.5)
        layer.cornerRadius = 6
        label.numberOfLines = 0
        label.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("PerformanceHUDView is created in code") }

    /// The preset changed: start or stop sampling.
    func restart() {
        timer?.invalidate()
        timer = nil
        guard !PerformanceHUD.items.isEmpty else {
            isHidden = true
            return
        }
        _ = PerformanceHUD.takeFrames()
        var busy = 0.0, span = 0.0
        pp_gpu_stats_take(&busy, &span)
        last = CACurrentMediaTime()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let sample = PerformanceHUD.sample(wall: now - last)
        last = now
        label.text = sample.lines(PerformanceHUD.items).joined(separator: "\n")
        isHidden = false
        superview?.setNeedsLayout()
    }

    /// Its size and place in `bounds` (the game view's), inside `insets`.
    func place(in bounds: CGRect, insets: UIEdgeInsets) {
        let pad: CGFloat = 6
        let size = label.sizeThatFits(CGSize(width: bounds.width / 2, height: bounds.height))
        let box = CGSize(width: ceil(size.width) + 2 * pad, height: ceil(size.height) + 2 * pad)
        let left = bounds.minX + insets.left + 8, right = bounds.maxX - insets.right - 8 - box.width
        let top = bounds.minY + insets.top + 8, bottom = bounds.maxY - insets.bottom - 8 - box.height
        let origin: CGPoint
        switch PerformanceHUD.settings.position {
        case .topLeft: origin = CGPoint(x: left, y: top)
        case .topCenter: origin = CGPoint(x: bounds.midX - box.width / 2, y: top)
        case .topRight: origin = CGPoint(x: right, y: top)
        case .bottomLeft: origin = CGPoint(x: left, y: bottom)
        case .bottomRight: origin = CGPoint(x: right, y: bottom)
        }
        frame = CGRect(origin: origin, size: box)
        label.frame = CGRect(x: pad, y: pad, width: ceil(size.width), height: ceil(size.height))
    }
}
#endif
