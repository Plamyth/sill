import Foundation

@MainActor
func journalRollbackChecks() {
    let fake = PrivacyFakeHAL()
    let format = PrivacyAudioStream.Format(sampleRate: 48_000, formatID: 0x6c70636d, flags: 12,
        bytesPerPacket: 128, framesPerPacket: 1, bytesPerFrame: 128, channels: 32, bitsPerChannel: 32, reserved: 0)
    let streams = [PrivacyAudioStream(id: 127, ownerID: 126, direction: .output, startingChannel: 1,
        virtualFormat: format, physicalFormat: format, active: false, activeSettable: true),
        PrivacyAudioStream(id: 128, ownerID: 126, direction: .input, startingChannel: 1,
        virtualFormat: format, physicalFormat: format, active: true, activeSettable: true)]
    fake.snapshot.devices.append(.init(id: 126, uid: "journal-32-channel", transport: .other, plugin: nil,
        inputChannels: 32, outputChannels: 32, streams: streams))
    let original = try! LocalAudioState(fake.snapshot)
    expect(original.isValid && original.devices.last?.streams == streams, "롤백 fixture는 서로 다른 원래 active와 전체 stream identity를 보유")

    var stored: Data?
    var stores = 0
    let v2 = try! JSONEncoder().encode(LocalAudioJournal.Envelope(version: 2, latched: true, original: original))
    let destructive = LegacyLocalAudioJournal(data: v2, store: { stored = $0; stores += 1 },
        load: { stored }, synchronize: { true })
    expect(destructive.write(latched: destructive.latched, original: destructive.original) && stores == 1,
           "실제 214 codec은 streams를 포함한 v2를 읽고 다시 저장")
    let damaged = try! JSONDecoder().decode(LocalAudioJournal.Envelope.self, from: stored!)
    expect(damaged.original?.devices.last?.streams == nil && damaged.original != original,
           "구버전 v2 roundtrip 데이터 손실 재현: streams 2개에서 nil")

    let journal = LocalAudioJournal(data: nil, store: { stored = $0 }, load: { stored }, synchronize: { true })
    expect(journal.write(latched: true, original: original), "새 저널 원상태 저장 성공")
    let durable = stored!
    stores = 0
    let old = LegacyLocalAudioJournal(data: durable, store: { stored = $0; stores += 1 },
        load: { stored }, synchronize: { true })
    let accepted = old.write(latched: old.latched, original: old.original)
    print("ROLLBACK oldLatched=\(old.latched) oldOriginalNil=\(old.original == nil) write=\(accepted) stores=\(stores) bytesPreserved=\(stored == durable)")
    expect(old.latched && old.original == nil && !accepted && stores == 0 && stored == durable,
           "214는 새 envelope를 거부하고 write 실패·store 0으로 원상태 바이트 보존")
    expect(LocalAudioJournal.key == LegacyLocalAudioJournal.key, "신구 저널은 같은 UserDefaults key 하나 사용")
    let restarted = LocalAudioJournal(data: stored, store: { stored = $0 }, load: { stored }, synchronize: { true })
    expect(restarted.latched && restarted.original == original && restarted.original?.devices.last?.streams == streams,
           "217 재시작은 구버전 실행 뒤에도 stream 원상태 전체를 정확히 복구")
    expect(try! JSONDecoder().decode(LocalAudioJournal.Envelope.self, from: durable).version == 3 && original.version == 2,
           "저널 envelope만 3이며 LocalAudioState는 2 유지")

    let legacyOriginal = try! LegacyLocalAudioState(fake.snapshot)
    let legacy = LegacyLocalAudioJournal(data: nil, store: { stored = $0 }, load: { stored }, synchronize: { true })
    expect(legacy.write(latched: true, original: legacyOriginal), "실제 214 writer로 기존 v2 fixture 생성")
    let migrated = LocalAudioJournal(data: stored, store: { stored = $0 }, load: { stored }, synchronize: { true })
    expect(migrated.latched && migrated.original?.devices.last?.streams == nil && migrated.original?.isValid == true,
           "새 reader는 streams 없는 실제 legacy v2 수용")
    expect(migrated.write(latched: migrated.latched, original: migrated.original) &&
           (try! JSONDecoder().decode(LocalAudioJournal.Envelope.self, from: stored!).version) == 3,
           "legacy v2 다음 저장은 v3으로 migration")
    let augmented = try! migrated.original!.recordingStreams(fake.snapshot)
    expect(augmented == original, "migration 뒤 관측한 streams를 기존 원상태에 정확히 추가")
    for version in [2, 3] {
        stored = try! JSONEncoder().encode(LocalAudioJournal.Envelope(version: version, latched: true, original: original))
        let read = LocalAudioJournal(data: stored, store: { stored = $0 }, load: { stored }, synchronize: { true })
        expect(read.original == original && read.write(latched: true, original: read.original),
               "새 reader는 v\(version)의 stream 원상태를 읽고 저장")
        expect((try! JSONDecoder().decode(LocalAudioJournal.Envelope.self, from: stored!).version) == 3,
               "v\(version)에서 시작한 저장도 envelope3")
    }

    var rejected = [Data([0]), Data("{\"version\":3}".utf8),
        try! JSONEncoder().encode(LocalAudioJournal.Envelope(version: 3, latched: true, original: nil))]
    for version in [-1, 0, 1, 4, 999] {
        for latched in [true, false] {
            rejected.append(try! JSONEncoder().encode(LocalAudioJournal.Envelope(version: version, latched: latched, original: original)))
        }
    }
    for data in rejected {
        stored = data; stores = 0
        let closed = LocalAudioJournal(data: data, legacyLatched: false, legacyOriginal: original,
            store: { stored = $0; stores += 1 }, load: { stored }, synchronize: { true })
        let hal = PrivacyFakeHAL()
        let privacy = HostAudioPrivacy(hal: CoreAudioPrivacyHAL(ops: hal.operations), latched: closed.latched,
            persist: { closed.write(latched: true, original: closed.original) }, localState: closed.original,
            saveLocal: { closed.write(latched: $0 != nil, original: $0) })
        expect(closed.latched && closed.original == nil && !closed.write(latched: true, original: nil) &&
               !privacy.armAndVerify() && stores == 0 && stored == data && hal.writes.isEmpty,
               "unknown/corrupt envelope는 fallback 없이 fail-closed·store 0·property writes 0")
        privacy.stop()
    }
    for version in [2, 3] {
        stored = try! JSONEncoder().encode(LocalAudioJournal.Envelope(version: version, latched: false, original: nil))
        let cleared = LocalAudioJournal(data: stored, store: { stored = $0 }, load: { stored }, synchronize: { true })
        expect(!cleared.latched && cleared.original == nil && cleared.write(latched: false, original: nil),
               "v\(version) latch 해제 상태 수용과 저장")
        expect((try! JSONDecoder().decode(LocalAudioJournal.Envelope.self, from: stored!).version) == 3,
               "latch 해제도 envelope3 저장")
    }
    for latched in [false, true] {
        for failure in ["store", "synchronize", "readback"] {
            let hal = PrivacyFakeHAL()
            stored = latched ? durable : nil
            let before = stored
            let failing = LocalAudioJournal(data: stored, store: { if failure != "store" { stored = $0 } },
                load: { failure == "readback" ? Data([0]) : stored }, synchronize: { failure != "synchronize" })
            let privacy = HostAudioPrivacy(hal: CoreAudioPrivacyHAL(ops: hal.operations), latched: failing.latched,
                persist: { failing.write(latched: true, original: failing.original) }, localState: failing.original,
                saveLocal: { failing.write(latched: $0 != nil, original: $0) })
            expect(!privacy.armAndVerify() && hal.writes.isEmpty && failing.latched == latched &&
                   failing.original == (latched ? original : nil),
                   "latched=\(latched) \(failure) 실패는 메모리 원상태 유지·property writes 0")
            if failure == "store" { expect(stored == before, "저장 거부는 기존 바이트 유지") }
            privacy.stop()
        }
    }
    print("Journal rollback: all memory-only checks passed; actual property writes 0")
}
