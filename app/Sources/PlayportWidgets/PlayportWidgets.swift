// SPDX-License-Identifier: GPL-3.0-or-later
// Dishnur: the download Live Activity in the Dynamic Island and on the Lock
// Screen (PlayportDownloadAttributes; the app's DownloadIsland feeds it).

import ActivityKit
import DownloadActivity
import SwiftUI
import WidgetKit

@_cdecl("pp_widgets_main")
public func ppWidgetsMain() {
    PlayportWidgets.main()
}

struct PlayportWidgets: WidgetBundle {
    var body: some Widget {
        DownloadLiveActivity()
    }
}

private let accent = Color(red: 0.36, green: 0.62, blue: 1.0)

struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlayportDownloadAttributes.self) { context in
            LockScreenView(state: context.state)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: s.done ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .font(.title2).foregroundStyle(s.done ? .green : accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(percent(s)).font(.title3.monospacedDigit().weight(.semibold))
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(s.name).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: s.done ? 1 : (s.fraction ?? 0)).tint(s.done ? .green : accent)
                        HStack {
                            Text(s.detail ?? s.status).lineLimit(1)
                            Spacer()
                            Text(trailer(s)).lineLimit(1)
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: s.done ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(s.done ? .green : accent)
            } compactTrailing: {
                Text(percent(s)).font(.caption.monospacedDigit().weight(.semibold))
            } minimal: {
                ProgressView(value: s.done ? 1 : (s.fraction ?? 0))
                    .progressViewStyle(.circular).tint(s.done ? .green : accent)
            }
        }
    }
}

private func percent(_ s: PlayportDownloadAttributes.ContentState) -> String {
    if s.done { return "✓" }
    return s.fraction.map { "\(Int($0 * 100))%" } ?? "…"
}

private func trailer(_ s: PlayportDownloadAttributes.ContentState) -> String {
    let more = s.waiting > 0 ? "+\(s.waiting) in queue" : ""
    if let left = s.timeLeft { return more.isEmpty ? left : left + " · " + more }
    return more.isEmpty ? s.status : more
}

struct LockScreenView: View {
    let state: PlayportDownloadAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: state.done ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(state.done ? .green : accent)
                Text(state.name).font(.headline).lineLimit(1)
                Spacer()
                Text(percent(state)).font(.headline.monospacedDigit())
            }
            ProgressView(value: state.done ? 1 : (state.fraction ?? 0)).tint(state.done ? .green : accent)
            HStack {
                Text(state.detail ?? state.status).lineLimit(1)
                Spacer()
                Text(trailer(state)).lineLimit(1)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
    }
}
