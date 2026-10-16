import CoreAudio
import Foundation

private enum ProbeError: Error {
    case property(AudioObjectID, AudioObjectPropertySelector, OSStatus)
    case size(AudioObjectID, AudioObjectPropertySelector)
}

private func property(_ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

private func number(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> UInt32 {
    var address = property(selector)
    var size = UInt32(MemoryLayout<UInt32>.size)
    var result: UInt32 = 0
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result)
    guard status == noErr else { throw ProbeError.property(object, selector, status) }
    guard size == MemoryLayout<UInt32>.size else { throw ProbeError.size(object, selector) }
    return result
}

private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    var address = property(selector)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var result: Unmanaged<CFString>?
    let status = withUnsafeMutablePointer(to: &result) {
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
    }
    guard status == noErr else { throw ProbeError.property(object, selector, status) }
    guard size == MemoryLayout<Unmanaged<CFString>?>.size, let result else {
        throw ProbeError.size(object, selector)
    }
    return result.takeRetainedValue() as String
}

private func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
    var address = property(selector, scope: scope)
    var size: UInt32 = 0
    let sizeStatus = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
    guard sizeStatus == noErr else { throw ProbeError.property(object, selector, sizeStatus) }
    guard size <= 4096, size % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else {
        throw ProbeError.size(object, selector)
    }
    if size == 0 { return [] }
    var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    let status = try result.withUnsafeMutableBytes { bytes -> OSStatus in
        guard let base = bytes.baseAddress else { throw ProbeError.size(object, selector) }
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, base)
    }
    guard status == noErr else { throw ProbeError.property(object, selector, status) }
    guard size == result.count * MemoryLayout<AudioObjectID>.size else {
        throw ProbeError.size(object, selector)
    }
    return result
}

private struct ProcessObservation: Encodable {
    let pid: Int32
    let inputActive: Bool
    let inputDeviceUIDs: [String]
}

private struct Report: Encodable {
    let bundleID: String
    let processes: [ProcessObservation]
}

@main
private enum ProcessProbe {
    static func main() throws {
        let bundleID = CommandLine.arguments.dropFirst().first ?? "com.openai.codex"
        let system = AudioObjectID(kAudioObjectSystemObject)
        var matches: [ProcessObservation] = []
        for object in try objects(system, kAudioHardwarePropertyProcessObjectList) {
            guard (try? string(object, kAudioProcessPropertyBundleID)) == bundleID else { continue }
            let pid = try Int32(bitPattern: number(object, kAudioProcessPropertyPID))
            let active = try number(object, kAudioProcessPropertyIsRunningInput) != 0
            let devices = try objects(object, kAudioProcessPropertyDevices,
                                      scope: kAudioObjectPropertyScopeInput)
            let uids = try devices.map { try string($0, kAudioDevicePropertyDeviceUID) }
            matches.append(ProcessObservation(pid: pid, inputActive: active,
                                              inputDeviceUIDs: uids.sorted()))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Report(bundleID: bundleID,
                                             processes: matches.sorted { $0.pid < $1.pid }))
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}
