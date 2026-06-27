#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// Golden tests for the vendored `SnappyDecoder` — the Snappy block decompressor
/// every Chromium (Chrome/Edge/Brave/Arc) cookie + Local Storage extraction path
/// depends on. It had ZERO direct tests. All vectors below are hand-encoded per
/// the Snappy block format (varint uncompressed length, then literal/copy tags),
/// so the expected decompressed bytes are fixed and reviewable.
final class SnappyDecoderTests: XCTestCase {

    private func bytes(_ b: [UInt8]) -> Data { Data(b) }

    func test_literal_only() {
        // varint(5) | literal-tag(len 5 → (5-1)<<2=0x10) | "hello"
        let input = bytes([0x05, 0x10, 0x68, 0x65, 0x6C, 0x6C, 0x6F])
        XCTAssertEqual(SnappyDecoder.decompress(input), Data("hello".utf8))
    }

    func test_copy_type2_two_byte_offset() {
        // "abab": literal "ab" then copy(len 2, offset 2, 2-byte-offset tag type 2)
        // varint(4) | lit("ab") tag (1<<2)=0x04 | 'a' 'b' | copy tag ((2-1)<<2|2)=0x06 | offsetLE 0x0002
        let input = bytes([0x04, 0x04, 0x61, 0x62, 0x06, 0x02, 0x00])
        XCTAssertEqual(SnappyDecoder.decompress(input), Data("abab".utf8))
    }

    func test_copy_type1_one_byte_offset() {
        // "xxxxx": literal "x" then copy(len 4, offset 1, 1-byte-offset tag type 1)
        // varint(5) | lit("x") tag 0x00 | 'x' | copy tag (offsetHi 0 | (len-4)=0 | type1)=0x01 | offsetLow 0x01
        let input = bytes([0x05, 0x00, 0x78, 0x01, 0x01])
        XCTAssertEqual(SnappyDecoder.decompress(input), Data("xxxxx".utf8))
    }

    func test_long_literal_with_extra_length_byte() {
        // 64-byte literal: tag>>2 == 60 means "1 extra length byte"; extra byte = (len-1) = 63.
        // varint(64)=0x40 | tag (60<<2)=0xF0 | extra 0x3F | 64×'A'
        var input: [UInt8] = [0x40, 0xF0, 0x3F]
        input.append(contentsOf: Array(repeating: 0x41, count: 64))
        XCTAssertEqual(SnappyDecoder.decompress(bytes(input)), Data(Array(repeating: 0x41, count: 64)))
    }

    func test_copy_repeats_overlapping_window() {
        // Overlapping copy (offset < length) must repeat the window byte-by-byte.
        // "ab" then copy(len 6, offset 2) → "ababab" + "ab" = "abababab"
        // varint(8) | lit("ab") 0x04 | 'a''b' | copy type2 tag ((6-1)<<2|2)=0x16 | offsetLE 0x0002
        let input = bytes([0x08, 0x04, 0x61, 0x62, 0x16, 0x02, 0x00])
        XCTAssertEqual(SnappyDecoder.decompress(input), Data("abababab".utf8))
    }

    func test_empty_input_returns_nil() {
        XCTAssertNil(SnappyDecoder.decompress(Data()))
    }

    func test_truncated_literal_returns_nil() {
        // Claims a 5-byte literal but only 2 bytes follow → malformed.
        XCTAssertNil(SnappyDecoder.decompress(bytes([0x05, 0x10, 0x68, 0x65])))
    }

    func test_copy_with_zero_offset_returns_nil() {
        // literal "a" then a type-2 copy with offset 0 → invalid back-reference.
        let input = bytes([0x02, 0x00, 0x61, 0x06, 0x00, 0x00])
        XCTAssertNil(SnappyDecoder.decompress(input))
    }

    func test_varint_length_is_only_a_capacity_hint() {
        // An over-large declared length must NOT change the decoded output; the
        // decoder consumes the actual literal bytes regardless.
        // varint(200) | lit("hi") (1<<2)=0x04 | 'h''i'
        let input = bytes([0xC8, 0x01, 0x04, 0x68, 0x69])
        XCTAssertEqual(SnappyDecoder.decompress(input), Data("hi".utf8))
    }
}
#endif
