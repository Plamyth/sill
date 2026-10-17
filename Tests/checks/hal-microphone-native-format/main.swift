private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw HALMicrophoneFailure(description: message) }
}

private func resolveDevice(uid: String) throws -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var qualifier = uid as CFString
    var device = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = withUnsafePointer(to: &qualifier) {
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
    }
    try require(status == noErr && size == MemoryLayout<AudioDeviceID>.size && device != kAudioObjectUnknown,
        "device UID not available: \(uid), status=\(status)")
    return device
}

private func checkNativeFormat(uid: String) throws {
    let unit = try NativeMicrophoneOutputUnit()
    unit.inputEnabled = false
    unit.outputEnabled = true
    try unit.selectDevice(resolveDevice(uid: uid))
    let wanted = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
        mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
    try unit.setFormat(wanted)
    for iteration in 0..<32 {
        guard let actual = unit.format else { throw HALMicrophoneFailure(description: "missing ASBD") }
        try require(actual.mSampleRate == wanted.mSampleRate && actual.mFormatID == wanted.mFormatID &&
            actual.mFormatFlags == wanted.mFormatFlags && actual.mBytesPerPacket == wanted.mBytesPerPacket &&
            actual.mFramesPerPacket == wanted.mFramesPerPacket && actual.mBytesPerFrame == wanted.mBytesPerFrame &&
            actual.mChannelsPerFrame == wanted.mChannelsPerFrame && actual.mBitsPerChannel == wanted.mBitsPerChannel,
            "ASBD readback \(iteration): \(actual)")
        try require(!unit.resourcesAllocated && !unit.isRunning, "native check must not allocate or start hardware")
    }
    print("PASS native ASBD readback 32/32 uid=\(uid) allocated=false running=false")
}

do {
    guard CommandLine.arguments.count == 2 else {
        throw HALMicrophoneFailure(description: "expected explicit virtual device UID")
    }
    try checkNativeFormat(uid: CommandLine.arguments[1])
} catch {
    fputs("FAIL \(error)\n", stderr)
    exit(1)
}
