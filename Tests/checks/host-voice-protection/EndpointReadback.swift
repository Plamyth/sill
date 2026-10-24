import CoreAudio
import Foundation

func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             _ element: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    .init(mSelector: selector, mScope: scope, mElement: element)
}
func scalar<T: FixedWidthInteger>(_ id: UInt32, _ selector: UInt32, _ initial: T) -> T? {
    var property = address(selector), result = initial, size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &result) { AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0) }
    guard status == noErr,
          size == MemoryLayout<T>.size else { return nil }
    return result
}
func string(_ id: UInt32, _ selector: UInt32) -> String? {
    var property = address(selector), value: CFString? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0) }
    guard status == noErr, let value else { return nil }
    return value as String
}
func channels(_ id: UInt32, _ scope: UInt32) -> Int? {
    var property = address(kAudioDevicePropertyStreamConfiguration, scope), size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr, size <= 65536 else { return nil }
    if size == 0 { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    let capacity = size
    guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, raw) == noErr, size == capacity else { return nil }
    let count = Int(raw.load(as: UInt32.self))
    let offset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
    guard count <= 128, count == 0 || offset + count * MemoryLayout<AudioBuffer>.stride <= Int(size) else { return nil }
    return count == 0 ? 0 : UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        .reduce(0) { $0 + Int($1.mNumberChannels) }
}
func writable(_ id: UInt32, _ selector: UInt32, _ scope: UInt32, _ element: UInt32) -> Bool {
    var property = address(selector, scope, element), value = DarwinBoolean(false)
    return AudioObjectHasProperty(id, &property) &&
        AudioObjectIsPropertySettable(id, &property, &value) == noErr && value.boolValue
}

func streams(_ id: UInt32, _ scope: UInt32) -> [[String: Any]]? {
    var property = address(kAudioDevicePropertyStreams, scope), size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr,
          size <= 512, size % 4 == 0 else { return nil }
    if size == 0 { return [] }
    var ids = [UInt32](repeating: 0, count: Int(size) / 4)
    let capacity = size
    guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &ids) == noErr,
          size == capacity, Set(ids).count == ids.count else { return nil }
    return ids.map { stream in
        var row: [String: Any] = ["id": stream,
            "activeSettable": writable(stream, kAudioStreamPropertyIsActive, kAudioObjectPropertyScopeGlobal, 0)]
        row["active"] = scalar(stream, kAudioStreamPropertyIsActive, UInt32(0))
        row["direction"] = scalar(stream, kAudioStreamPropertyDirection, UInt32(0))
        row["startingChannel"] = scalar(stream, kAudioStreamPropertyStartingChannel, UInt32(0))
        return row
    }
}

let system = UInt32(kAudioObjectSystemObject)
var property = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr,
      size > 0, size <= 16384, size % 4 == 0 else { exit(2) }
var devices = [UInt32](repeating: 0, count: Int(size) / 4)
guard AudioObjectGetPropertyData(system, &property, 0, nil, &size, &devices) == noErr else { exit(2) }
var result: [[String: Any]] = []
for id in devices {
    var row: [String: Any] = ["id": id, "uid": string(id, kAudioDevicePropertyDeviceUID) ?? "unknown",
        "name": string(id, kAudioObjectPropertyName) ?? "unknown",
        "hogSettable": writable(id, kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal, 0)]
    row["hogPID"] = scalar(id, kAudioDevicePropertyHogMode, Int32(-2))
    row["running"] = scalar(id, kAudioDevicePropertyDeviceIsRunningSomewhere, UInt32(0))
    for (name, scope) in [("input", kAudioObjectPropertyScopeInput), ("output", kAudioObjectPropertyScopeOutput)] {
        guard let count = channels(id, scope), (0...1024).contains(count) else { row[name] = "unreadable"; continue }
        row[name] = ["channels": count, "streams": streams(id, scope) as Any,
            "masterMuteSettable": writable(id, kAudioDevicePropertyMute, scope, 0),
            "channelMuteSettable": (1..<(count + 1)).filter { writable(id, kAudioDevicePropertyMute, scope, UInt32($0)) },
            "masterVolumeSettable": writable(id, kAudioDevicePropertyVolumeScalar, scope, 0),
            "channelVolumeSettable": (1..<(count + 1)).filter { writable(id, kAudioDevicePropertyVolumeScalar, scope, UInt32($0)) }]
    }
    result.append(row)
}
let report: [String: Any] = ["readOnly": true, "propertyWrites": 0, "audioStreamsStarted": 0,
    "devices": result, "input": scalar(system, kAudioHardwarePropertyDefaultInputDevice, UInt32(0)) ?? 0,
    "output": scalar(system, kAudioHardwarePropertyDefaultOutputDevice, UInt32(0)) ?? 0,
    "systemOutput": scalar(system, kAudioHardwarePropertyDefaultSystemOutputDevice, UInt32(0)) ?? 0]
let bytes = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
FileHandle.standardOutput.write(bytes + Data([10]))
