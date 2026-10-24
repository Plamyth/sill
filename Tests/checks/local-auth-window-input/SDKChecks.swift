    private func sdkEvent(_ type: CGEventType = .keyDown, explicitZero: Bool = true,
                          state: CGEventSourceStateID = .hidSystemState,
                          pid: Int64 = 0, target: Int64 = 700, tag: Int64? = nil,
                          key: Int64 = 0, flags: CGEventFlags = [], window: Int64 = 70) -> CGEvent {
        let e = CGEvent(source: CGEventSource(stateID: state)!)!
        e.type = type
        e.flags = flags
        e.timestamp = 123456789
        e.location = CGPoint(x: 50, y: 50)
        e.setIntegerValueField(.eventSourceUnixProcessID, value: pid)
        if let tag { e.setIntegerValueField(.eventSourceUserData, value: tag) }
        else if explicitZero { e.setIntegerValueField(.eventSourceUserData, value: 0) }
        e.setIntegerValueField(.eventTargetUnixProcessID, value: target)
        e.setIntegerValueField(.keyboardEventKeycode, value: key)
        e.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: window)
        e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: window)
        e.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        e.setIntegerValueField(.mouseEventClickState, value: 2)
        e.setIntegerValueField(.mouseEventDeltaX, value: 7)
        e.setIntegerValueField(.mouseEventDeltaY, value: -3)
        e.setDoubleValueField(.mouseEventPressure, value: 0.75)
        let syntheticText: [UniChar] = [0x41, 0xD55C, 0xD83D, 0xDE00]
        e.keyboardSetUnicodeString(stringLength: syntheticText.count, unicodeString: syntheticText)
        return e
    }

    private struct Payload: Equatable {
        let type: CGEventType
        let flags: CGEventFlags
        let timestamp: CGEventTimestamp
        let point: CGPoint
        let integers: [Int64]
        let pressure: Double
        let unicode: [UniChar]

        init(_ e: CGEvent) {
            type = e.type; flags = e.flags; timestamp = e.timestamp; point = e.location
            integers = [CGEventField.keyboardEventKeycode, .keyboardEventAutorepeat,
                .eventTargetUnixProcessID, .mouseEventWindowUnderMousePointer,
                .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                .mouseEventButtonNumber, .mouseEventClickState, .mouseEventDeltaX, .mouseEventDeltaY]
                .map { e.getIntegerValueField($0) }
            pressure = e.getDoubleValueField(.mouseEventPressure)
            var chars = [UniChar](repeating: 0, count: 64), count = 0
            e.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &count, unicodeString: &chars)
            unicode = Array(chars.prefix(count))
        }
    }

    func run() async {
        for explicit in [false, true] {
            for type in [CGEventType.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp] {
                fresh()
                let key: Int64 = type == .flagsChanged ? 56 : 0
                let flags: CGEventFlags = type == .flagsChanged || type == .keyDown ? [.maskShift] : []
                let e = sdkEvent(type, explicitZero: explicit, key: key, flags: flags)
                let payload = Payload(e), proof = localAuthenticationInputPolicy.observation!
                let sources = authenticationEventSources!
                Checks.check(e.getIntegerValueField(.eventSourceUnixProcessID) == 0 &&
                    e.getIntegerValueField(.eventSourceStateID) == 1 && e.getIntegerValueField(.eventSourceUserData) == 0,
                    "SDK 양성 전제 PID0·HID1·tag0 explicit=\(explicit) type=\(type.rawValue)")
                let observed = observationCalls, signatures = Self.signatureCalls
                let first = filter(type, event: e)
                let stamped = e.getIntegerValueField(.eventSourceUserData)
                let sourcePID = e.getIntegerValueField(.eventSourceUnixProcessID)
                Checks.check(first != nil && stamped == proof.handoffTag &&
                    (sourcePID == 0 || sourcePID == Int64(getpid())) &&
                    e.getIntegerValueField(.eventSourceStateID) == 1,
                    "SDK session의 native proof 갱신·정확한 PID0 또는 HostPID·HID1 explicit=\(explicit) type=\(type.rawValue)")
                Checks.check(Payload(e) == payload, "SDK source 교체 뒤 합성 payload 보존")
                let second = filterAnnotated(type, event: e)
                Checks.check(first != nil && second != nil && e.getIntegerValueField(.eventSourceUserData) == 0,
                    "SDK 두 생산 callback의 허용과 실제 clear0 explicit=\(explicit) type=\(type.rawValue)")
                Checks.check(Payload(e) == payload, "SDK clear 뒤 합성 payload 보존")
                Checks.check(filterAnnotated(type, event: e) == nil, "SDK clear한 이벤트 재사용 거절")
                Checks.check(observed == observationCalls && signatures == Self.signatureCalls,
                    "SDK callback의 WindowServer·Security 관측 호출 0")
                Checks.check(authenticationEventSources!.stamped === sources.stamped &&
                    authenticationEventSources!.cleared === sources.cleared &&
                    sources.stamped.userData == proof.handoffTag && sources.cleared.userData == 0,
                    "SDK callback은 준비된 source 객체·proof 태그를 바꾸지 않음")
            }
        }
        fresh()
        let hosted = sdkEvent(pid: Int64(getpid()))
        Checks.check(filter(hosted.type, event: hosted) == nil, "SDK HostPID는 원래 physical session 조건을 통과하지 못함")
        Checks.check(Self.stampEventSource(hosted, source: authenticationEventSources!.stamped,
            tag: localAuthenticationInputPolicy.observation!.handoffTag) &&
            filterAnnotated(hosted.type, event: hosted) != nil && hosted.getIntegerValueField(.eventSourceUserData) == 0,
            "SDK 현재 proof·HID1의 정확한 HostPID annotated 형태와 clear0 양성")
        for explicit in [false, true] {
            for state in [CGEventSourceStateID.privateState, .combinedSessionState] {
                fresh()
                Checks.check(!transit(sdkEvent(explicitZero: explicit, state: state)), "SDK 외부 private·combined source 거절")
            }
            fresh()
            Checks.check(!transit(sdkEvent(explicitZero: explicit, pid: Int64(getpid()), tag: Self.remoteEventTag)),
                "SDK 원격 tagged credential 거절")
            Checks.check(!transit(sdkEvent(explicitZero: explicit, pid: 9876)), "SDK 임의 source PID 거절")
            for target: Int64 in [0, 100, 701, 999] {
                fresh(); let e = sdkEvent(explicitZero: explicit, target: target)
                Checks.check(filter(e.type, event: e) != nil && filterAnnotated(e.type, event: e) == nil,
                    "SDK 정상앱·TCC·unknown 대상 최종 거절 \(target)")
            }
            fresh()
            let unmarked = sdkEvent(explicitZero: explicit)
            Checks.check(filterAnnotated(unmarked.type, event: unmarked) == nil, "SDK 변환 없는 annotated physical 거절")
            let proof = localAuthenticationInputPolicy.observation!
            Checks.check(filterAnnotated(.keyDown, event: sdkEvent(pid: 9876, tag: proof.handoffTag)) == nil,
                "SDK proof가 있어도 임의 PID 거절")
            Checks.check(filterAnnotated(.keyDown, event: sdkEvent(pid: 0, tag: Self.remoteEventTag)) == nil,
                "SDK PID0이라도 원격 태그 거절")
            Checks.check(filterAnnotated(.keyDown, event: sdkEvent(state: .privateState, pid: Int64(getpid()), tag: proof.handoffTag)) == nil,
                "SDK HostPID·proof가 있어도 private state 거절")
            for action in 0..<7 {
                fresh(); let e = sdkEvent(explicitZero: explicit)
                Checks.check(filter(e.type, event: e) != nil, "SDK 지연 거절 전 session 양성 \(action)")
                switch action {
                case 0: challengeID = nil
                case 1:
                    let id = UUID(); localAuthenticationWillBegin(id); challengeID = id; refreshInputObservation()
                case 2: Self.identities[700] = .init(pid: 700, startSeconds: 100, startMicroseconds: 11)
                case 3: Self.identities[700] = nil
                case 4: rows = []; refreshInputObservation()
                case 5: annotatedTapVerified = false
                default: try? await Task.sleep(for: .milliseconds(280))
                }
                Checks.check(filterAnnotated(e.type, event: e) == nil, "SDK 취소·새 요청·PID재사용·종료·창·tap·만료 후 거절 \(action)")
            }
            fresh()
            Checks.check(!transit(sdkEvent(.leftMouseDown, explicitZero: explicit, window: 71)), "SDK 다른 클릭 처리창 거절")
            Checks.check(!transit(sdkEvent(explicitZero: explicit, flags: [.maskCommand])), "SDK 전역 modifier 거절")
        }
        for value: Int64 in [2147483648, 4294967295, 4294967296, 1234567890123456789, Int64.max] {
            let e = CGEvent(source: nil)!
            e.setIntegerValueField(.eventSourceUserData, value: value)
            Checks.check(e.getIntegerValueField(.eventSourceUserData) == value, "SDK 큰64비트 최초 write readback \(value)")
            e.setIntegerValueField(.eventSourceUserData, value: 0)
            print("SDK_REWRITE first=\(value) afterSetterClear=\(e.getIntegerValueField(.eventSourceUserData))")
        }
    }
