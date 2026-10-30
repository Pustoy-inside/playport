// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import PlayportKit
import SteamClientKit

/// A game on the external drive: C:\Games\<folder> is a link to it (the app's ExternalStorage).
final class ExternalDriveTests: XCTestCase {
    func testAGameLinkedFromTheDriveIsAdopted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("drive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let games = root.appendingPathComponent("Games"), there = root.appendingPathComponent("SSD/Playport Games/Celeste")
        try FileManager.default.createDirectory(at: games, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: there, withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: there.appendingPathComponent("Celeste.exe"))
        try FileManager.default.createSymbolicLink(at: games.appendingPathComponent("Celeste"), withDestinationURL: there)
        let c = Adoption.scan(games: games, cohort: Cohort(titles: []), receipts: [], storeReceipts: [], previous: Catalog())
        XCTAssertEqual(c.titles.map(\.installDir), ["Celeste"])
        XCTAssertEqual(c.titles.first?.executable, "Celeste.exe")
        // The drive away: the link leads nowhere, and the game is not listed.
        try FileManager.default.removeItem(at: there)
        XCTAssertEqual(Adoption.scan(games: games, cohort: Cohort(titles: []), receipts: [], storeReceipts: [],
                                     previous: Catalog()).titles, [])
    }
}
