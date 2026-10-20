import Foundation

enum LocalAudioRelayMachO {
    struct Dependencies: Equatable {
        var loads = Set<String>()
        var rpaths = Set<String>()
    }
    enum Failure: Error { case malformed }

    static func inspect(_ data: Data) throws -> Dependencies? {
        guard data.count >= 4 else { return nil }
        let reader = Reader(data: data)
        let magic = try reader.number(0, bytes: 4, little: false, limit: data.count)
        if magic == 0xcffaedfe { return try reader.slice(0..<data.count) }
        guard [0xcafebabe, 0xcafebabf].contains(magic) else {
            if [0xfeedfacf, 0xfeedface, 0xcefaedfe, 0xbebafeca, 0xbfbafeca].contains(magic) {
                throw Failure.malformed
            }
            return nil
        }
        let count = try reader.number(4, bytes: 4, little: false, limit: data.count)
        guard (1...16).contains(count) else { throw Failure.malformed }
        let wide = magic == 0xcafebabf
        let stride = wide ? 32 : 20
        let tableEnd = 8 + Int(count) * stride
        guard tableEnd <= data.count else { throw Failure.malformed }
        var ranges = [Range<Int>](), architectures = Set<UInt64>(), result = Dependencies()
        for index in 0..<Int(count) {
            let base = 8 + index * stride
            let cpu = try reader.number(base, bytes: 4, little: false, limit: tableEnd)
            let subtype = try reader.number(base + 4, bytes: 4, little: false, limit: tableEnd)
            let offset = try reader.number(base + 8, bytes: wide ? 8 : 4, little: false, limit: tableEnd)
            let size = try reader.number(base + (wide ? 16 : 12), bytes: wide ? 8 : 4, little: false, limit: tableEnd)
            let alignment = try reader.number(base + (wide ? 24 : 16), bytes: 4, little: false, limit: tableEnd)
            guard alignment < 32, offset >= UInt64(tableEnd), offset <= UInt64(data.count),
                  size >= 32, size <= UInt64(data.count) - offset,
                  offset % (UInt64(1) << alignment) == 0,
                  architectures.insert((cpu << 32) | subtype).inserted else { throw Failure.malformed }
            if wide, try reader.number(base + 28, bytes: 4, little: false, limit: tableEnd) != 0 {
                throw Failure.malformed
            }
            let range = Int(offset)..<Int(offset + size)
            guard !ranges.contains(where: { $0.overlaps(range) }),
                  try reader.number(range.lowerBound + 4, bytes: 4, little: true, limit: range.upperBound) == cpu,
                  try reader.number(range.lowerBound + 8, bytes: 4, little: true, limit: range.upperBound) == subtype else {
                throw Failure.malformed
            }
            ranges.append(range)
            let slice = try reader.slice(range)
            result.loads.formUnion(slice.loads)
            result.rpaths.formUnion(slice.rpaths)
        }
        return result
    }

    private struct Reader {
        let data: Data

        func number(_ offset: Int, bytes: Int, little: Bool, limit: Int) throws -> UInt64 {
            guard offset >= 0, offset <= limit, bytes <= limit - offset, limit <= data.count else {
                throw Failure.malformed
            }
            var value: UInt64 = 0
            for index in 0..<bytes {
                let shift = 8 * (little ? index : bytes - index - 1)
                value |= UInt64(data[data.startIndex + offset + index]) << shift
            }
            return value
        }

        func string(command: Int, size: Int, minimum: Int, limit: Int) throws -> String {
            let offset = try number(command + 8, bytes: 4, little: true, limit: limit)
            guard offset >= UInt64(minimum), offset < UInt64(size) else { throw Failure.malformed }
            let start = command + Int(offset), end = command + size
            guard let zero = (start..<end).first(where: { data[data.startIndex + $0] == 0 }),
                  zero > start, zero - start <= 4096,
                  let text = String(data: data[(data.startIndex + start)..<(data.startIndex + zero)], encoding: .utf8),
                  !text.contains("\n"), !text.contains("\r") else { throw Failure.malformed }
            return text
        }

        func slice(_ range: Range<Int>) throws -> Dependencies {
            let start = range.lowerBound, end = range.upperBound
            guard range.count >= 32,
                  try number(start, bytes: 4, little: true, limit: end) == 0xfeedfacf,
                  [0x0100000c, 0x01000007].contains(try number(start + 4, bytes: 4, little: true, limit: end)) else {
                throw Failure.malformed
            }
            let count = try number(start + 16, bytes: 4, little: true, limit: end)
            let bytes = try number(start + 20, bytes: 4, little: true, limit: end)
            guard count <= 4096, bytes <= UInt64(range.count - 32) else { throw Failure.malformed }
            let commandsEnd = start + 32 + Int(bytes)
            var offset = start + 32, result = Dependencies()
            for _ in 0..<count {
                let command = try number(offset, bytes: 4, little: true, limit: commandsEnd) & 0x7fffffff
                let size = try number(offset + 4, bytes: 4, little: true, limit: commandsEnd)
                guard size >= 8, size % 8 == 0, size <= UInt64(commandsEnd - offset) else { throw Failure.malformed }
                switch command {
                case 0xc, 0x18, 0x1f, 0x20, 0x23:
                    guard size >= 24 else { throw Failure.malformed }
                    result.loads.insert(try string(command: offset, size: Int(size), minimum: 24, limit: commandsEnd))
                case 0x1c:
                    result.rpaths.insert(try string(command: offset, size: Int(size), minimum: 12, limit: commandsEnd))
                case 0xe:
                    guard try string(command: offset, size: Int(size), minimum: 12, limit: commandsEnd) == "/usr/lib/dyld" else {
                        throw Failure.malformed
                    }
                case 0x27: throw Failure.malformed
                default: break
                }
                offset += Int(size)
            }
            guard offset == commandsEnd else { throw Failure.malformed }
            return result
        }
    }
}
