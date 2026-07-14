import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: stamp-bios-checksum.swift ROM\n".utf8))
    exit(2)
}

let url = URL(fileURLWithPath: CommandLine.arguments[1])
var bytes = [UInt8](try Data(contentsOf: url))
guard bytes.count == 65_536 else {
    FileHandle.standardError.write(Data("system BIOS must be exactly 65536 bytes\n".utf8))
    exit(1)
}

let checksumOffset = 0xFFEF
bytes[checksumOffset] = 0
let partial = bytes.reduce(UInt8(0)) { $0 &+ $1 }
bytes[checksumOffset] = 0 &- partial
try Data(bytes).write(to: url, options: .atomic)
