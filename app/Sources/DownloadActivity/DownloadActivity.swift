// SPDX-License-Identifier: GPL-3.0-or-later
// Dishnur: the download Live Activity's data, shared by the app (DownloadIsland,
// which starts and updates it) and the widget extension (PlayportWidgets, which
// draws it in the Dynamic Island and on the Lock Screen).

import ActivityKit
import Foundation

public struct PlayportDownloadAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        /// The running job's game.
        public var name: String
        /// 0…1, nil before its size is known.
        public var fraction: Double?
        /// `Downloading 42%`, `Paused`, `Done`.
        public var status: String
        /// `1.20 GB of 5.31 GB · 12.4 MB/s`.
        public var detail: String?
        /// `about 4 min left`.
        public var timeLeft: String?
        /// Jobs waiting after this one.
        public var waiting: Int
        public var done: Bool

        public init(name: String, fraction: Double?, status: String, detail: String?, timeLeft: String?,
                    waiting: Int, done: Bool) {
            self.name = name
            self.fraction = fraction
            self.status = status
            self.detail = detail
            self.timeLeft = timeLeft
            self.waiting = waiting
            self.done = done
        }
    }

    public init() {}
}
