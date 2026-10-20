import Foundation

var checks = 0
func check(_ value: Bool) { precondition(value); checks += 1 }
func word(_ value: UInt64, _ bytes: Int = 4, little: Bool = true) -> [UInt8] {
    (0..<bytes).map { UInt8(truncatingIfNeeded: value >> (8 * (little ? $0 : bytes - $0 - 1))) }
}
func command(_ kind: UInt64, _ path: String, header: Int = 24) -> [UInt8] {
    var value = word(kind) + word(0) + word(UInt64(header))
    value += Array(repeating: 0, count: header - value.count)
    value += Array(path.utf8) + [0]
    while value.count % 8 != 0 { value.append(0) }
    value.replaceSubrange(4..<8, with: word(UInt64(value.count)))
    return value
}
func thin(_ commands: [[UInt8]], cpu: UInt64 = 0x0100000c) -> [UInt8] {
    let body = commands.flatMap { $0 }
    return word(0xfeedfacf) + word(cpu) + word(0) + word(2) + word(UInt64(commands.count)) +
        word(UInt64(body.count)) + word(0) + word(0) + body
}
func fat(_ first: [UInt8], _ second: [UInt8], wide: Bool) -> Data {
    let offset = 128, next = ((offset + first.count + 63) / 64) * 64
    var bytes = word(wide ? 0xcafebabf : 0xcafebabe, little: false) + word(2, little: false)
    for (cpu, start, size) in [(UInt64(0x0100000c), offset, first.count), (UInt64(0x01000007), next, second.count)] {
        bytes += word(cpu, little: false) + word(0, little: false)
        bytes += word(UInt64(start), wide ? 8 : 4, little: false) + word(UInt64(size), wide ? 8 : 4, little: false)
        bytes += word(6, little: false)
        if wide { bytes += word(0, little: false) }
    }
    bytes += Array(repeating: 0, count: offset - bytes.count) + first
    bytes += Array(repeating: 0, count: next - bytes.count) + second
    return Data(bytes)
}
func rejects(_ data: Data) {
    do { _ = try LocalAudioRelayMachO.inspect(data); preconditionFailure("accepted malformed native image") }
    catch { checks += 1 }
}

check(try LocalAudioRelayMachO.inspect(Data("module.exports = {};".utf8)) == nil)
let kinds: [UInt64] = [0xc, 0x80000018, 0x8000001f, 0x20, 0x80000023]
let paths = kinds.indices.map { "@loader_path/lib\($0).dylib" }
let loads = zip(kinds, paths).map { command($0.0, $0.1) }
let image = Data(thin(loads + [command(0xd, "@rpath/identity.dylib"), command(0x8000001c, "@loader_path/lib", header: 12), command(0xe, "/usr/lib/dyld", header: 12)]))
let actual = try LocalAudioRelayMachO.inspect(image)!
check(actual.loads == Set(paths) && actual.rpaths == ["@loader_path/lib"])
for count in 4..<image.count { rejects(Data(image.prefix(count))) }
let arm = thin([command(0xc, "@loader_path/arm.dylib")])
let intel = thin([command(0xc, "@loader_path/intel.dylib")], cpu: 0x01000007)
for wide in [false, true] {
    let both = fat(arm, intel, wide: wide)
    check(try LocalAudioRelayMachO.inspect(both)?.loads == ["@loader_path/arm.dylib", "@loader_path/intel.dylib"])
    var wrongCPU = both
    wrongCPU.replaceSubrange(8..<12, with: word(0x01000007, little: false))
    rejects(wrongCPU)
    var overlap = both
    let secondOffset = 8 + (wide ? 32 : 20) + 8
    overlap.replaceSubrange(secondOffset..<(secondOffset + (wide ? 8 : 4)), with: word(128, wide ? 8 : 4, little: false))
    rejects(overlap)
    for count in [4, 7, 15, 127, both.count - 1] { rejects(Data(both.prefix(count))) }
}
rejects(Data(thin([command(0x27, "DYLD_INSERT_LIBRARIES=/tmp/evil", header: 12)])))
rejects(Data(thin([command(0xe, "/tmp/dyld", header: 12)])))
var tooLarge = image
tooLarge.replaceSubrange(36..<40, with: word(UInt64(UInt32.max)))
rejects(tooLarge)
var insideHeader = image
insideHeader.replaceSubrange(40..<44, with: word(8))
rejects(insideHeader)
var badSize = image
badSize.replaceSubrange(20..<24, with: word(UInt64(UInt32.max)))
rejects(badSize)
let rows = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [[String: Any]]
for row in rows {
    let data = Data(base64Encoded: row["data"] as! String)!
    let dependencies = try LocalAudioRelayMachO.inspect(data)!
    check(dependencies.loads == Set(row["loads"] as! [String]))
    check(dependencies.rpaths == Set(row["rpaths"] as! [String]))
}
print("PASS \(checks) Mach-O boundary checks")
