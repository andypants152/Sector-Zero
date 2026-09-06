protocol ConsoleFont {
    var cellWidth: Int { get }
    var cellHeight: Int { get }

    func rowBits(for codePoint: UInt8, row: Int) -> UInt8
}

/// The original IBM PC character set, including its box-drawing, Greek,
/// mathematical, and extended Latin glyphs.
///
/// `CP437Glyphs` holds one readable 16-byte bitmap for every possible byte.
/// Keeping the table separate makes this renderer's job deliberately simple:
/// text-video memory stores the byte, and that byte directly selects its glyph.
struct CP437Font: ConsoleFont {
    let cellWidth = 8
    let cellHeight = 16

    func rowBits(for codePoint: UInt8, row: Int) -> UInt8 {
        guard row >= 0, row < cellHeight else {
            return 0
        }

        // CP437 uses byte values as glyph indices, so no Unicode conversion or
        // fallback substitution is needed here. This preserves DOS's symbols
        // and line-drawing characters exactly as software wrote them to VRAM.
        return CP437Glyphs.glyphs[Int(codePoint)][row]
    }
}
