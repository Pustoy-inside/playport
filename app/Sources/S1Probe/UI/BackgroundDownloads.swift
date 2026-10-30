// SPDX-License-Identifier: GPL-3.0-or-later
// Settings › Downloads › Download in the background: while a download runs and
// Playport is not on screen (another app, the home screen, the phone locked),
// it plays silence, as an app playing audio keeps running, so iOS does not
// suspend the download a few seconds after Playport leaves the screen. The app
// already declares the audio background mode (the pairing code's picture in
// picture). Off in Playport, when the downloads are done, or while a game runs.
// iOS may still end Playport for memory; the queue goes on at the next start.

import AVFAudio
import Foundation
import PlayportKit
import UIKit

@MainActor
final class BackgroundDownloads {
    static let shared = BackgroundDownloads()

    private var engine: AVAudioEngine?
    private var clock: Timer?
    private var task: UIBackgroundTaskIdentifier = .invalid
    private weak var installs: Downloads?

    /// Once, when the product UI appears.
    func start(installs: Downloads) {
        self.installs = installs
        guard clock == nil else { return }
        clock = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { BackgroundDownloads.shared.check() }
        }
    }

    /// The scene left the screen or came back (AppShell).
    func sceneChanged() {
        // The silence must start before iOS suspends the app: a background task covers the gap.
        if task == .invalid, UIApplication.shared.applicationState != .active {
            task = UIApplication.shared.beginBackgroundTask(withName: "Playport download") { [weak self] in
                MainActor.assumeIsolated { self?.endTask() }
            }
        }
        check()
        endTask()
    }

    private func endTask() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }

    private func check() {
        let wanted = DownloadPreferences.current.background && installs?.isBusy == true
            && UIApplication.shared.applicationState != .active && !TitleLaunch.shared.running
            && !AppRestart.shared.restarting
        if wanted { play() } else { stop() }
    }

    private func play() {
        if let engine, engine.isRunning { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            let e = AVAudioEngine()
            let format = e.outputNode.inputFormat(forBus: 0)
            let silence = Self.silence(format)
            e.attach(silence)
            e.connect(silence, to: e.mainMixerNode, format: format)
            try e.start()
            engine = e
            LibraryModel.log("background downloads: on (silence playing)")
        } catch {
            LibraryModel.log("background downloads: could not play silence: \(error)")
        }
    }

    /// Zeros, on the audio thread: built outside the main actor, so its render
    /// block carries no main-actor check.
    nonisolated private static func silence(_ format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, _, buffers in
            for b in UnsafeMutableAudioBufferListPointer(buffers) {
                if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) }
            }
            return noErr
        }
    }

    private func stop() {
        guard let engine else { return }
        engine.stop()
        self.engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        LibraryModel.log("background downloads: off")
    }
}
