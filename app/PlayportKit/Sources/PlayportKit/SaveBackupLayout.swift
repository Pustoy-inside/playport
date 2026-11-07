// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Dishnur: where a game's saves go in the player's backup folder (Settings › Save backups;
/// the app's SaveBackups): `<folder>/<game>/`, with each Steam Cloud file under its root
/// (`WinAppDataLocalLow/Team Cherry/Hollow Knight/user1.dat`), a file the game keeps through
/// the Steam API under `Steam Cloud/`, and the Steam emulator's folder under `Steam emulator/`.
public enum SaveBackupLayout {
    public static let emulatorFolder = "Steam emulator"
    public static let remoteFolder = "Steam Cloud"

    /// The game's folder name: its name, with what Files cannot show in a name made `-`.
    public static func folderName(_ game: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        var out = String(game.unicodeScalars.map { bad.contains($0) ? "-" : Character($0) })
            .trimmingCharacters(in: .whitespaces)
        while out.hasPrefix(".") { out.removeFirst() }
        return out.isEmpty ? "Game" : out
    }

    /// A Steam Cloud name's path in the game's folder: `%Root%a/b` is `Root/a/b`, a name
    /// without a root is under `Steam Cloud`. Nil for a name that would leave the folder.
    public static func path(forCloudName name: String) -> String? {
        var root = remoteFolder
        var rest = Substring(name)
        if rest.hasPrefix("%"), let end = rest.dropFirst().firstIndex(of: "%") {
            let token = rest[rest.index(after: rest.startIndex)..<end]
            if !token.isEmpty { root = String(token) }
            rest = rest[rest.index(after: end)...]
        }
        let parts = rest.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { return nil }
        return ([root] + parts).joined(separator: "/")
    }

    /// Whether a played game is due a backup: played since its last one, or never backed up.
    public static func due(lastPlayed: Date?, lastBackup: Date?) -> Bool {
        guard let lastPlayed else { return false }
        guard let lastBackup else { return true }
        return lastPlayed > lastBackup
    }
}
