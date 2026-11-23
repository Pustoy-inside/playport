// SPDX-License-Identifier: GPL-3.0-or-later
// Dishnur: the running download in the Dynamic Island and on the Lock Screen,
// as a Live Activity (DownloadActivity's attributes, drawn by the
// PlayportWidgets extension). It starts with a download while Playport is on
// screen (iOS starts a Live Activity only then), follows the queue from
// BackgroundDownloads' clock, and ends a few minutes after the queue is done.
// Settings › Downloads › Progress in the Dynamic Island turns it off.

import ActivityKit
import DownloadActivity
import Foundation
import PlayportKit
import UIKit

@MainActor
final class DownloadIsland {
    static let shared = DownloadIsland()
    static let enabledKey = "downloads.liveActivity"

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private var activity: Activity<PlayportDownloadAttributes>?
    private var shown: PlayportDownloadAttributes.ContentState?
    private var shownAt = Date.distantPast
    private var lastName: String?

    private static func log(_ line: String) { SteamUILog.logger.info("live-activity", line) }

    private init() {
        // One left from an earlier run of Playport is this run's to update or end.
        activity = Activity<PlayportDownloadAttributes>.activities.first
    }

    /// From BackgroundDownloads' clock, every few seconds, and when the setting changes.
    func update(_ installs: Downloads?) {
        let jobs = installs?.order ?? []
        let paused = { (j: Downloads.Job) -> Bool in if case .paused = j.phase { return true }; return false }
        let current = jobs.first { $0.isRunning } ?? jobs.first { !paused($0) }
        guard Self.enabled else {
            finish(nil, immediately: true)
            return
        }
        guard let job = current else {
            // Done when the queue emptied after a download; only paused ones left: gone at once.
            let done = jobs.isEmpty && lastName != nil
            finish(done ? .init(name: lastName!, fraction: 1, status: "Done", detail: nil, timeLeft: nil,
                                waiting: 0, done: true) : nil, immediately: !done)
            return
        }
        lastName = job.name
        let state = PlayportDownloadAttributes.ContentState(
            name: job.name, fraction: job.fraction, status: job.status, detail: job.detail,
            timeLeft: job.timeLeft, waiting: jobs.filter { !$0.isRunning && !paused($0) && $0.key != job.key }.count,
            done: false)
        if activity == nil {
            guard UIApplication.shared.applicationState == .active,
                  ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            do {
                activity = try Activity.request(attributes: PlayportDownloadAttributes(),
                                                content: .init(state: state, staleDate: nil), pushType: nil)
                shown = state
                shownAt = Date()
                Self.log("started for \(job.name)")
            } catch {
                Self.log("not started: \(error)")
            }
            return
        }
        // A new percent, a new status or game, or 15 s since the last: iOS rations updates.
        let percent = { (s: PlayportDownloadAttributes.ContentState?) in s?.fraction.map { Int($0 * 100) } }
        guard shown?.name != state.name || shown?.status != state.status || percent(shown) != percent(state)
                || Date().timeIntervalSince(shownAt) > 15 else { return }
        shown = state
        shownAt = Date()
        guard let a = activity else { return }
        let box = ActivityBox(activity: a)
        Task { await box.activity.update(.init(state: state, staleDate: nil)) }
    }

    /// The queue is done (`last` shows it a few minutes), or the setting is off.
    private func finish(_ last: PlayportDownloadAttributes.ContentState?, immediately: Bool) {
        lastName = nil
        shown = nil
        guard let a = activity else { return }
        activity = nil
        Self.log(immediately ? "ended" : "done")
        let box = ActivityBox(activity: a)
        Task {
            await box.activity.end(last.map { .init(state: $0, staleDate: nil) },
                        dismissalPolicy: immediately ? .immediate : .after(Date().addingTimeInterval(300)))
        }
    }
}

/// ActivityKit's Activity isn't Sendable on this SDK; it is safe to update and end
/// from any task, so the box carries it to one.
private struct ActivityBox: @unchecked Sendable {
    let activity: Activity<PlayportDownloadAttributes>
}
