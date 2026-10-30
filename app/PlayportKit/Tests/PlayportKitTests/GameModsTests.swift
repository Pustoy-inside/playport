// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import PlayportKit
import SteamClientKit

final class GameModsTests: XCTestCase {
    var root: URL!
    var game: URL { root.appendingPathComponent("Games/Witcher") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mods-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("Data/Text.pak", "english", in: game)
        try write("Game.exe", "MZ game", in: game)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ rel: String, _ text: String, in base: URL) throws {
        let url = base.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ rel: String) throws -> String {
        try String(contentsOf: game.appendingPathComponent(rel), encoding: .utf8)
    }

    private var importer: GameImporter {
        var i = GameImporter(layout: InstallLayout.root(root.appendingPathComponent("container")))
        i.freeSpace = { _ in 1 << 40 }
        i.reserveBytes = 0
        return i
    }

    /// A translation's folder over the game's: each file where the game names it, whatever
    /// the case; the wrapper folder left out; the game's own files kept.
    func testATranslationsFolderGoesOverTheGamesWithTheGamesSpelling() throws {
        let rus = root.appendingPathComponent("Files/Witcher Rus")
        try write("data/text.pak", "русский", in: rus)
        try write("readme.txt", "how to", in: rus)
        let written = try importer.merge(try GameImporter.plan(.folder(rus)), into: game)
        XCTAssertEqual(written, ["Data/Text.pak", "readme.txt"])
        XCTAssertEqual(try read("Data/Text.pak"), "русский")
        XCTAssertEqual(try read("readme.txt"), "how to")
        XCTAssertEqual(try read("Game.exe"), "MZ game")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: game.path).sorted(), ["Data", "Game.exe", "readme.txt"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: game.appendingPathComponent("Data").path), ["Text.pak"])
    }

    /// A picked folder the game has too (its Data) is that folder.
    func testAPickedFolderTheGameHasIsThatFolder() throws {
        let data = root.appendingPathComponent("Files/DATA")
        try write("text.pak", "русский", in: data)
        try write("fonts/ru.ttf", "font", in: data)
        let written = try importer.merge(try GameImporter.plan(.folder(data)), into: game)
        XCTAssertEqual(written, ["Data/fonts/ru.ttf", "Data/Text.pak"])
        XCTAssertEqual(try read("Data/Text.pak"), "русский")
        XCTAssertEqual(try read("Data/fonts/ru.ttf"), "font")
    }

    func testAFileWhereTheGameHasAFolderIsRefused() throws {
        let bad = root.appendingPathComponent("Files/Bad")
        try write("data", "not a folder", in: bad)
        XCTAssertThrowsError(try importer.merge(try GameImporter.plan(.folder(bad)), into: game))
        XCTAssertEqual(try read("Data/Text.pak"), "english")
    }

    /// An installer goes into the game's folder; one of the game's own programs is not replaced.
    func testAProgramIsCopiedIntoTheGamesFolder() throws {
        let setup = root.appendingPathComponent("Files/Setup_RU.exe")
        try write("Setup_RU.exe", "MZ setup", in: root.appendingPathComponent("Files"))
        XCTAssertEqual(try importer.copyProgram(setup, into: game, replacing: false), "Setup_RU.exe")
        XCTAssertEqual(try read("Setup_RU.exe"), "MZ setup")
        XCTAssertThrowsError(try importer.copyProgram(setup, into: game, replacing: false))
        XCTAssertEqual(try importer.copyProgram(setup, into: game, replacing: true), "Setup_RU.exe")
        let game2 = root.appendingPathComponent("Files/game.EXE")
        try write("game.EXE", "MZ other", in: root.appendingPathComponent("Files"))
        XCTAssertThrowsError(try importer.copyProgram(game2, into: game, replacing: false))
        XCTAssertEqual(try read("Game.exe"), "MZ game")
        let text = root.appendingPathComponent("Files/notes.txt")
        try write("notes.txt", "x", in: root.appendingPathComponent("Files"))
        XCTAssertThrowsError(try importer.copyProgram(text, into: game, replacing: false))
    }

    func testRecordsKeepEachPathOnceAndRoundTrip() throws {
        var r = GameModRecord()
        XCTAssertTrue(r.isEmpty)
        r.add(files: ["Data/Text.pak", "readme.txt"])
        r.add(files: ["data/text.pak", "Data/Font.ttf"])
        r.add(program: "Setup_RU.exe")
        XCTAssertEqual(r.files, ["Data/Font.ttf", "Data/Text.pak", "readme.txt", "Setup_RU.exe"])
        XCTAssertEqual(r.programs, ["Setup_RU.exe"])
        let store = GameModStore(url: root.appendingPathComponent("state/mods.json"))
        XCTAssertEqual(store.load(), [:])
        try store.save(["steam-292030": r])
        XCTAssertEqual(store.load(), ["steam-292030": r])
    }
}
