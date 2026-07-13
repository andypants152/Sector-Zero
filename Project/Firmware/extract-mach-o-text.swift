import Foundation

enum ExtractionError: Error, CustomStringConvertible {
    case usage
    case malformed(String)

    var description: String {
        switch self {
        case .usage:
            return "usage: extract-mach-o-text.swift INPUT.o OUTPUT.bin [INPUT.o OUTPUT.bin ...]"
        case .malformed(let message):
            return "malformed Mach-O object: \(message)"
        }
    }
}

func uint32(_ data: Data, at offset: Int) throws -> UInt32 {
    guard offset >= 0, offset + 4 <= data.count else {
        throw ExtractionError.malformed("truncated 32-bit field")
    }
    return UInt32(data[offset])
        | UInt32(data[offset + 1]) << 8
        | UInt32(data[offset + 2]) << 16
        | UInt32(data[offset + 3]) << 24
}

func fixedName(_ data: Data, at offset: Int) throws -> String {
    guard offset >= 0, offset + 16 <= data.count else {
        throw ExtractionError.malformed("truncated section name")
    }
    let bytes = data[offset..<(offset + 16)].prefix { $0 != 0 }
    return String(decoding: bytes, as: UTF8.self)
}

func extractText(from object: Data) throws -> Data {
    let mhMagic = try uint32(object, at: 0)
    guard mhMagic == 0xFEEDFACE else {
        throw ExtractionError.malformed("expected a little-endian 32-bit object")
    }

    let loadCommandCount = Int(try uint32(object, at: 16))
    var commandOffset = 28
    for _ in 0..<loadCommandCount {
        let command = try uint32(object, at: commandOffset)
        let commandSize = Int(try uint32(object, at: commandOffset + 4))
        guard commandSize >= 8, commandOffset + commandSize <= object.count else {
            throw ExtractionError.malformed("invalid load-command size")
        }

        if command == 1 { // LC_SEGMENT for 32-bit Mach-O.
            let sectionCount = Int(try uint32(object, at: commandOffset + 48))
            var sectionOffset = commandOffset + 56
            for _ in 0..<sectionCount {
                guard sectionOffset + 68 <= commandOffset + commandSize else {
                    throw ExtractionError.malformed("truncated section table")
                }
                if try fixedName(object, at: sectionOffset) == "__text" {
                    let byteCount = Int(try uint32(object, at: sectionOffset + 36))
                    let fileOffset = Int(try uint32(object, at: sectionOffset + 40))
                    guard fileOffset >= 0, byteCount >= 0,
                          fileOffset + byteCount <= object.count else {
                        throw ExtractionError.malformed("text section extends past file")
                    }
                    return object[fileOffset..<(fileOffset + byteCount)]
                }
                sectionOffset += 68
            }
        }
        commandOffset += commandSize
    }
    throw ExtractionError.malformed("no __text section")
}

do {
    let paths = CommandLine.arguments.dropFirst()
    guard !paths.isEmpty, paths.count.isMultiple(of: 2) else {
        throw ExtractionError.usage
    }
    for pairStart in stride(from: 0, to: paths.count, by: 2) {
        let inputURL = URL(fileURLWithPath: paths[paths.index(paths.startIndex, offsetBy: pairStart)])
        let outputURL = URL(fileURLWithPath: paths[paths.index(paths.startIndex, offsetBy: pairStart + 1)])
        let binary = try extractText(from: Data(contentsOf: inputURL))
        try binary.write(to: outputURL, options: .atomic)
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
