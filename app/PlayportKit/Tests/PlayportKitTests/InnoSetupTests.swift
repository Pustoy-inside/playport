// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import PlayportKit
import SteamClientKit

final class InnoSetupTests: XCTestCase {
    /// What Fixtures/words.lzma1 and .lzma2 hold (made with Python's lzma, an 8 KiB dictionary,
    /// so the window wraps many times): words from a small list, now and then a stray byte.
    static func words(_ n: Int) -> [UInt8] {
        let list = ["the ", "game ", "file ", "pak ", "data ", "voice ", "text ", "font ", "menu ", "save ",
                    "lzma ", "inno ", "rus ", "exe ", "dll ", "ok "].map { Array($0.utf8) }
        var x: UInt32 = 12345
        var out: [UInt8] = []
        while out.count < n {
            x = x &* 1103515245 &+ 12345
            let r = (x >> 16) & 0x7FFF
            if r % 61 == 0 { out.append(UInt8(r & 0xFF)) } else { out += list[Int(r % 16)] }
        }
        return Array(out.prefix(n))
    }

    private func fixture(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "Fixtures/words", withExtension: name))))
    }

    func testLZMA1DecodesThroughASmallWindow() throws {
        let raw = try fixture("lzma1")
        var out: [UInt8] = []
        try raw.withUnsafeBytes { try InnoLZMA.decodeLZMA1($0, limit: .max) { out += $0 } }
        XCTAssertEqual(out, Self.words(100_000))
        // A limit stops it there.
        var part: [UInt8] = []
        try raw.withUnsafeBytes { try InnoLZMA.decodeLZMA1($0, limit: 12_345) { part += $0 } }
        XCTAssertEqual(part, Array(Self.words(100_000).prefix(12_345)))
    }

    func testLZMA2DecodesItsChunks() throws {
        let raw = try fixture("lzma2")
        var out: [UInt8] = []
        try raw.withUnsafeBytes { try InnoLZMA.decodeLZMA2($0, limit: .max) { out += $0 } }
        XCTAssertEqual(out, Self.words(100_000))
    }

    func testDamagedLZMAIsAnErrorNotACrash() throws {
        var raw = try fixture("lzma1")
        for i in stride(from: 40, to: raw.count, by: 97) { raw[i] ^= 0x5A }
        XCTAssertThrowsError(try raw.withUnsafeBytes { try InnoLZMA.decodeLZMA1($0, limit: 100_000) { _ in } })
    }

    /// Inno's compiler side of the CALL filter, to check the decoder undoes it.
    private func encode(_ input: [UInt8], flip: Bool) -> [UInt8] {
        var b = input
        var i = 0
        while i < b.count {
            let c = b[i]
            i += 1
            guard c == 0xE8 || c == 0xE9, 0x10000 - ((i - 1) % 0x10000) >= 5, i + 4 <= b.count else { continue }
            if b[i + 3] == 0x00 || b[i + 3] == 0xFF {
                let addr = UInt32(i + 4) & 0xFF_FFFF
                let rel = UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16
                let abs = rel &+ addr
                if flip, rel & 0x80_0000 != 0 { b[i + 3] = ~b[i + 3] }
                b[i] = UInt8(truncatingIfNeeded: abs)
                b[i + 1] = UInt8(truncatingIfNeeded: abs >> 8)
                b[i + 2] = UInt8(truncatingIfNeeded: abs >> 16)
            }
            i += 4
        }
        return b
    }

    func testTheCallFilterIsUndoneAcrossPieces() throws {
        var x: UInt32 = 7
        var original: [UInt8] = []
        for k in 0..<200_000 {
            x = x &* 1664525 &+ 1013904223
            let r = UInt8(truncatingIfNeeded: x >> 24)
            original.append(k % 37 == 0 ? 0xE8 : (k % 37 == 4 ? (r & 1 == 0 ? 0x00 : 0xFF) : r))
        }
        for flip in [false, true] {
            let stored = encode(original, flip: flip)
            XCTAssertNotEqual(stored, original)
            var filter = InnoCallFilter(flip: flip)
            var out: [UInt8] = []
            var at = 0
            for size in [1, 3, 4, 5, 4093, 65_536, 1_000_000] where at < stored.count {
                let n = min(size, stored.count - at)
                try stored[at..<(at + n)].withUnsafeBytes { buf in
                    try filter.process(buf, end: at + n == stored.count) { out += $0 }
                }
                at += n
            }
            XCTAssertEqual(out, original, "flip \(flip)")
        }
    }

    func testOnlyTheGamesFolderIsUnpacked() {
        XCTAssertEqual(InnoSetup.appPath("{app}\\Data\\Text.pak"), "Data/Text.pak")
        XCTAssertEqual(InnoSetup.appPath("{APP}\\readme.txt"), "readme.txt")
        XCTAssertNil(InnoSetup.appPath("{tmp}\\setup.dll"))
        XCTAssertNil(InnoSetup.appPath("{app}\\..\\evil.dll"))
        XCTAssertNil(InnoSetup.appPath("{app}\\{code:Dir}\\x.pak"))
        XCTAssertNil(InnoSetup.appPath("{app}"))
    }

    func testANonInstallerIsRecognisedAsNone() throws {
        let exe = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/icon", withExtension: "exe"))
        XCTAssertFalse(InnoSetup.recognizes(exe))
        XCTAssertThrowsError(try InnoSetup(exe)) { XCTAssertEqual($0 as? InnoSetupError, .notInno) }
    }

    // MARK: real installers (downloaded; skipped without the network)

    private func download(_ url: String, to name: String) throws -> URL {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        let done = DispatchSemaphore(value: 0)
        var result: URL?
        let task = URLSession.shared.downloadTask(with: URL(string: url)!) { tmp, response, _ in
            if let tmp, (response as? HTTPURLResponse)?.statusCode == 200 {
                try? FileManager.default.moveItem(at: tmp, to: dest)
                result = dest
            }
            done.signal()
        }
        task.resume()
        guard done.wait(timeout: .now() + 300) == .success, let result else { throw XCTSkip("\(url) not downloaded") }
        return result
    }

    private func unpack(_ installer: URL, expect: String, files: Int) throws {
        let setup = try InnoSetup(installer)
        XCTAssertEqual(setup.versionName, expect)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("inno-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        var last = InnoSetup.Progress(bytesDone: 0, bytesTotal: 0)
        let written = try setup.extract(into: out) { last = $0 }   // each file checked against its hash
        XCTAssertEqual(written.count, files)
        XCTAssertEqual(last.bytesDone, last.bytesTotal)
        for p in written.prefix(50) { XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent(p).path), p) }
    }

    /// Inno Setup 5.5.7 (Unicode), LZMA1 chunks.
    func testWinMergesInstaller() throws {
        let exe = try download("https://github.com/WinMerge/winmerge/releases/download/v2.16.44/WinMerge-2.16.44-x64-Setup.exe",
                               to: "WinMerge-2.16.44-x64-Setup.exe")
        try unpack(exe, expect: "Inno Setup Setup Data (5.5.7) (u)", files: 311)
    }

    /// Inno Setup 6.3, one solid LZMA2 chunk of 357 MB with filtered executables.
    func testGitForWindowsInstaller() throws {
        let exe = try download("https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.1/Git-2.47.1-64-bit.exe",
                               to: "Git-2.47.1-64-bit.exe")
        try unpack(exe, expect: "Inno Setup Setup Data (6.3.0)", files: InnoSetup.expectedGitFiles)
    }

    /// A game's folder gets an installer's files over its own, with the game's spelling.
    func testUnpackingIntoAGamesFolderMovesTheFilesIn() throws {
        let exe = try download("https://github.com/WinMerge/winmerge/releases/download/v2.16.44/WinMerge-2.16.44-x64-Setup.exe",
                               to: "WinMerge-2.16.44-x64-Setup.exe")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unpack-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appendingPathComponent("Games/WinMerge")
        try FileManager.default.createDirectory(at: game.appendingPathComponent("FILTERS"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: game.appendingPathComponent("winmergeu.exe"))
        var importer = GameImporter(layout: InstallLayout.root(root.appendingPathComponent("container")))
        importer.freeSpace = { _ in 1 << 40 }
        importer.reserveBytes = 0
        let written = try importer.unpack(installer: exe, into: game)
        XCTAssertEqual(written.count, 311)
        XCTAssertTrue(written.contains("winmergeu.exe"))
        XCTAssertGreaterThan(try Data(contentsOf: game.appendingPathComponent("winmergeu.exe")).count, 1_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: game.appendingPathComponent(".playport-unpack").path))
        let top = try FileManager.default.contentsOfDirectory(atPath: game.path)
        XCTAssertTrue(top.contains("FILTERS"))
        XCTAssertFalse(top.contains("Filters"))   // the installer's Filters went into the game's FILTERS
    }
}

extension InnoSetup {
    /// Git 2.47.1's files under {app}, as its installer lists them.
    static let expectedGitFiles = 6407
}
