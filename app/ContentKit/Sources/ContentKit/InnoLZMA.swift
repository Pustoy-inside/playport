// SPDX-License-Identifier: GPL-3.0-or-later
// LZMA1 and LZMA2 as Inno Setup stores them (InnoSetup.swift): a stream of unknown
// length read from memory, its output handed on in pieces, with a window of the
// dictionary's size so a chunk of gigabytes never has to be held whole. After Igor
// Pavlov's public-domain reference decoder (LzmaSpec.cpp), as ContentKit's LZMA
// (LZMA.swift, which decodes a Steam chunk of known size into memory) is.

import Foundation

public enum InnoLZMAError: Error, CustomStringConvertible {
    case corrupt(String)

    public var description: String {
        switch self {
        case let .corrupt(why): "the installer's data is damaged (\(why))"
        }
    }
}

/// The decoder's output: the bytes since the last call, in order.
public typealias InnoSink = (UnsafeRawBufferPointer) throws -> Void

/// The dictionary: the last `size` bytes out, written on in a ring; what has not been
/// handed to the sink yet is flushed before the ring wraps over it.
final class InnoWindow {
    let size: Int
    let buf: UnsafeMutablePointer<UInt8>
    private(set) var pos = 0
    private var full = false
    private var flushed = 0
    /// Every byte out so far.
    private(set) var total: UInt64 = 0
    private let sink: InnoSink

    init(size: Int, sink: @escaping InnoSink) {
        self.size = size
        buf = .allocate(capacity: size)
        self.sink = sink
    }

    deinit { buf.deallocate() }

    @inline(__always) func has(_ dist: Int) -> Bool { dist <= (full ? size : pos) }

    @inline(__always) func get(_ dist: Int) -> UInt8 {
        var i = pos - dist
        if i < 0 { i += size }
        return buf[i]
    }

    @inline(__always) func put(_ b: UInt8) throws {
        buf[pos] = b
        pos += 1
        total += 1
        if pos == size { try wrap() }
    }

    /// `len` bytes from `dist` back (a match).
    @inline(__always) func copy(_ dist: Int, _ len: Int) throws {
        var n = len
        var src = pos - dist
        if src < 0 { src += size }
        while n > 0 {
            buf[pos] = buf[src]
            pos += 1
            src += 1
            if src == size { src = 0 }
            n -= 1
            total += 1
            if pos == size { try wrap() }
        }
    }

    private func wrap() throws {
        try flush()
        pos = 0
        flushed = 0
        full = true
    }

    /// What was written since the last flush, to the sink.
    func flush() throws {
        guard pos > flushed else { return }
        try sink(UnsafeRawBufferPointer(start: buf + flushed, count: pos - flushed))
        flushed = pos
    }
}

/// The range decoder over the stream in memory. A read past its end gives zero and sets
/// `overrun`: a stream with no end marker ends there, and the symbol that wanted it is not
/// one.
struct InnoRangeDecoder {
    private let p: UnsafePointer<UInt8>
    private let end: Int
    private(set) var i: Int
    private(set) var overrun = false
    var range: UInt32 = 0xFFFF_FFFF
    var code: UInt32 = 0

    init(_ data: UnsafeRawBufferPointer, at start: Int) throws {
        p = data.baseAddress!.assumingMemoryBound(to: UInt8.self)
        end = data.count
        guard start + 5 <= end, p[start] == 0 else { throw InnoLZMAError.corrupt("range coder start") }
        for k in 1...4 { code = code << 8 | UInt32(p[start + k]) }
        i = start + 5
    }

    @inline(__always) mutating func next() -> UInt32 {
        guard i < end else { overrun = true; return 0 }
        defer { i += 1 }
        return UInt32(p[i])
    }

    @inline(__always) mutating func normalize() {
        if range < 0x0100_0000 {
            range <<= 8
            code = code << 8 | next()
        }
    }

    @inline(__always) mutating func bit(_ prob: UnsafeMutablePointer<UInt16>) -> Int {
        let v = UInt32(prob.pointee)
        let bound = (range >> 11) &* v
        let b: Int
        if code < bound {
            range = bound
            prob.pointee = UInt16(v + ((2048 - v) >> 5))
            b = 0
        } else {
            range &-= bound
            code &-= bound
            prob.pointee = UInt16(v - (v >> 5))
            b = 1
        }
        normalize()
        return b
    }

    @inline(__always) mutating func tree(_ probs: UnsafeMutablePointer<UInt16>, _ bits: Int) -> Int {
        var m = 1
        for _ in 0..<bits { m = (m << 1) | bit(probs + m) }
        return m - (1 << bits)
    }

    @inline(__always) mutating func reverseTree(_ probs: UnsafeMutablePointer<UInt16>, _ bits: Int) -> Int {
        var m = 1, r = 0
        for k in 0..<bits {
            let b = bit(probs + m)
            m = (m << 1) | b
            r |= b << k
        }
        return r
    }

    mutating func direct(_ bits: Int) -> UInt32 {
        var r: UInt32 = 0
        for _ in 0..<bits {
            range >>= 1
            if code >= range {
                code &-= range
                r = (r << 1) | 1
            } else {
                r <<= 1
            }
            normalize()
        }
        return r
    }
}

/// LZMA's model: the state, the four last distances and every probability.
final class InnoLZMAModel {
    private(set) var lc = 0, lp = 0, pb = 0
    private var probs: UnsafeMutablePointer<UInt16>
    private var count = 0
    var state = 0
    var reps = (0, 0, 0, 0)

    // Offsets into `probs` (LzmaSpec's layout).
    private static let isMatch = 0
    private static let isRep = isMatch + (12 << 4)
    private static let isRep0 = isRep + 12
    private static let isRep1 = isRep0 + 12
    private static let isRep2 = isRep1 + 12
    private static let isRep0Long = isRep2 + 12
    private static let posSlot = isRep0Long + (12 << 4)
    private static let posSpecial = posSlot + (4 << 6)
    private static let align = posSpecial + 115
    private static let lenCoder = align + 16
    private static let lenSize = 2 + (16 << 3) * 2 + 256
    private static let repLenCoder = lenCoder + lenSize
    private static let literal = repLenCoder + lenSize

    init(properties: UInt8) throws {
        probs = .allocate(capacity: 1)
        try set(properties: properties)
    }

    deinit { probs.deallocate() }

    /// A properties byte (lc, lp, pb), and the model reset.
    func set(properties: UInt8) throws {
        var d = Int(properties)
        guard d < 9 * 5 * 5 else { throw InnoLZMAError.corrupt("properties \(d)") }
        lc = d % 9; d /= 9
        lp = d % 5
        pb = d / 5
        guard lc + lp <= 12 else { throw InnoLZMAError.corrupt("properties lc+lp") }
        let n = Self.literal + (0x300 << (lc + lp))
        if n != count {
            probs.deallocate()
            probs = .allocate(capacity: n)
            count = n
        }
        reset()
    }

    func reset() {
        probs.initialize(repeating: 1024, count: count)
        state = 0
        reps = (0, 0, 0, 0)
    }

    private func length(_ rc: inout InnoRangeDecoder, _ base: Int, _ posState: Int) -> Int {
        let p = probs + base
        if rc.bit(p) == 0 { return rc.tree(p + 2 + (posState << 3), 3) }
        if rc.bit(p + 1) == 0 { return 8 + rc.tree(p + 2 + (16 << 3) + (posState << 3), 3) }
        return 16 + rc.tree(p + 2 + (16 << 3) * 2, 8)
    }

    /// Decodes into `w` until it has put out `limit` bytes in all, or the end marker.
    /// Returns true at an end marker.
    func decode(_ rc: inout InnoRangeDecoder, into w: InnoWindow, limit: UInt64) throws -> Bool {
        let pbMask = (1 << pb) - 1, lpMask = (1 << lp) - 1
        while w.total < limit, !rc.overrun {
            let posState = Int(truncatingIfNeeded: w.total) & pbMask
            let st = state
            if rc.bit(probs + Self.isMatch + (st << 4) + posState) == 0 {
                let prev = w.has(1) ? Int(w.get(1)) : 0
                let lit = probs + Self.literal
                    + 0x300 * (((Int(truncatingIfNeeded: w.total) & lpMask) << lc) + (prev >> (8 - lc)))
                var sym = 1
                if st < 7 {
                    while sym < 0x100 { sym = (sym << 1) | rc.bit(lit + sym) }
                } else {
                    guard w.has(reps.0 + 1) else { throw InnoLZMAError.corrupt("match byte") }
                    var match = Int(w.get(reps.0 + 1))
                    while sym < 0x100 {
                        let mbit = (match >> 7) & 1
                        match <<= 1
                        let b = rc.bit(lit + ((1 + mbit) << 8) + sym)
                        sym = (sym << 1) | b
                        if mbit != b {
                            while sym < 0x100 { sym = (sym << 1) | rc.bit(lit + sym) }
                            break
                        }
                    }
                }
                if rc.overrun { break }
                try w.put(UInt8(truncatingIfNeeded: sym))
                state = st < 4 ? 0 : (st < 10 ? st - 3 : st - 6)
                continue
            }
            var len: Int
            if rc.bit(probs + Self.isRep + st) == 1 {
                guard w.has(1) else { throw InnoLZMAError.corrupt("repeat before data") }
                if rc.bit(probs + Self.isRep0 + st) == 0 {
                    if rc.bit(probs + Self.isRep0Long + (st << 4) + posState) == 0 {
                        if rc.overrun { break }
                        guard w.has(reps.0 + 1) else { throw InnoLZMAError.corrupt("distance beyond the data") }
                        state = st < 7 ? 9 : 11
                        try w.put(w.get(reps.0 + 1))
                        continue
                    }
                } else {
                    let d: Int
                    if rc.bit(probs + Self.isRep1 + st) == 0 {
                        d = reps.1
                    } else {
                        if rc.bit(probs + Self.isRep2 + st) == 0 {
                            d = reps.2
                        } else {
                            d = reps.3
                            reps.3 = reps.2
                        }
                        reps.2 = reps.1
                    }
                    reps.1 = reps.0
                    reps.0 = d
                }
                len = length(&rc, Self.repLenCoder, posState)
                state = st < 7 ? 8 : 11
            } else {
                reps.3 = reps.2
                reps.2 = reps.1
                reps.1 = reps.0
                len = length(&rc, Self.lenCoder, posState)
                state = st < 7 ? 7 : 10
                let slot = rc.tree(probs + Self.posSlot + (min(len, 3) << 6), 6)
                var dist: Int
                if slot < 4 {
                    dist = slot
                } else {
                    let nd = (slot >> 1) - 1
                    dist = (2 | (slot & 1)) << nd
                    if slot < 14 {
                        dist += rc.reverseTree(probs + Self.posSpecial + dist - slot, nd)
                    } else {
                        dist += Int(rc.direct(nd - 4)) << 4
                        dist += rc.reverseTree(probs + Self.align, 4)
                        if dist == 0xFFFF_FFFF, !rc.overrun { return true }
                    }
                }
                reps.0 = dist
            }
            if rc.overrun { break }
            len += 2
            let d = reps.0 + 1
            guard w.has(d) else { throw InnoLZMAError.corrupt("distance beyond the data") }
            try w.copy(d, Int(min(UInt64(len), limit - w.total)))
        }
        return false
    }
}

public enum InnoLZMA {
    /// Dictionaries above this are refused: the window is allocated whole.
    static let maxDictionary = 1 << 30

    /// Inno's LZMA1: 5 property bytes (properties, dictionary size), then the range coder.
    /// Decodes until `limit` bytes are out, the end marker or the input's end.
    public static func decodeLZMA1(_ data: UnsafeRawBufferPointer, limit: UInt64, sink: @escaping InnoSink) throws {
        guard data.count >= 5 else { throw InnoLZMAError.corrupt("short LZMA header") }
        let dict = Int(data.load(fromByteOffset: 1, as: UInt8.self)) | Int(data.load(fromByteOffset: 2, as: UInt8.self)) << 8
            | Int(data.load(fromByteOffset: 3, as: UInt8.self)) << 16 | Int(data.load(fromByteOffset: 4, as: UInt8.self)) << 24
        guard dict <= maxDictionary else { throw InnoLZMAError.corrupt("dictionary of \(dict) bytes") }
        let model = try InnoLZMAModel(properties: data.load(as: UInt8.self))
        let w = InnoWindow(size: max(dict, 1 << 16), sink: sink)
        var rc = try InnoRangeDecoder(data, at: 5)
        // A stream with no end marker stops where its input does.
        _ = try model.decode(&rc, into: w, limit: limit)
        try w.flush()
    }

    /// Inno's LZMA2: one dictionary byte, then LZMA2's chunks.
    public static func decodeLZMA2(_ data: UnsafeRawBufferPointer, limit: UInt64, sink: @escaping InnoSink) throws {
        guard data.count >= 2 else { throw InnoLZMAError.corrupt("short LZMA2 header") }
        let p = Int(data.load(as: UInt8.self))
        guard p <= 40 else { throw InnoLZMAError.corrupt("LZMA2 dictionary \(p)") }
        let dict = p == 40 ? Int(UInt32.max) : (2 | (p & 1)) << (p / 2 + 11)
        guard dict <= maxDictionary else { throw InnoLZMAError.corrupt("dictionary of \(dict) bytes") }
        let w = InnoWindow(size: max(dict, 1 << 16), sink: sink)
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var i = 1
        var model: InnoLZMAModel?
        func byte() throws -> Int {
            guard i < bytes.count else { throw InnoLZMAError.corrupt("LZMA2 ends early") }
            defer { i += 1 }
            return Int(bytes[i])
        }
        while w.total < limit {
            let c = try byte()
            if c == 0 { break }
            if c < 0x80 {
                guard c <= 2 else { throw InnoLZMAError.corrupt("LZMA2 control \(c)") }
                let hi = try byte(), lo = try byte()
                let size = (hi << 8 | lo) + 1
                guard i + size <= bytes.count else { throw InnoLZMAError.corrupt("LZMA2 ends early") }
                for k in 0..<size { try w.put(bytes[i + k]) }
                i += size
                continue
            }
            let u1 = try byte(), u2 = try byte(), p1 = try byte(), p2 = try byte()
            let unpacked = ((c & 0x1F) << 16 | u1 << 8 | u2) + 1
            let packed = (p1 << 8 | p2) + 1
            let reset = (c >> 5) & 3
            if reset >= 2 {
                let props = UInt8(try byte())
                if let model { try model.set(properties: props) } else { model = try InnoLZMAModel(properties: props) }
            } else if reset == 1 {
                model?.reset()
            }
            guard let m = model else { throw InnoLZMAError.corrupt("LZMA2 chunk without properties") }
            guard i + packed <= bytes.count else { throw InnoLZMAError.corrupt("LZMA2 ends early") }
            var rc = try InnoRangeDecoder(UnsafeRawBufferPointer(rebasing: data[i..<(i + packed)]), at: 0)
            _ = try m.decode(&rc, into: w, limit: min(limit, w.total + UInt64(unpacked)))
            i += packed
        }
        try w.flush()
    }
}
