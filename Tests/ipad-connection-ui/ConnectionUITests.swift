import XCTest

@MainActor
final class ConnectionUITests: XCTestCase {
    private func existingApp() throws -> XCUIApplication {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["CCR_CONNECTION_UI_APPROVED"] == "1" else {
            throw XCTSkip("Root의 runner 설치·기기 조율 후에만 실행합니다.")
        }
        guard ProcessInfo.processInfo.environment["CCR_CONNECTION_UI_AUDIO_OFF_VERIFIED"] == "1" else {
            throw XCTSkip("직전 기기·Host metadata의 오디오 OFF를 부모가 확인한 뒤에만 활성화합니다.")
        }
        return try activateExistingApp()
    }

    private func existingMediaApp() throws -> XCUIApplication {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["CCR_CONNECTION_UI_MEDIA_APPROVED"] == "1" else {
            throw XCTSkip("부모의 명시적 media 승인과 별도 테스트 선택 후에만 실행합니다.")
        }
        return try activateExistingApp()
    }

    private func activateExistingApp() throws -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.ambrion.sillcanvas.ipad")
        guard [.runningForeground, .runningBackground, .runningBackgroundSuspended].contains(app.state) else {
            throw XCTSkip("정상 앱이 실행 중이지 않습니다. 이 후보는 앱을 launch하지 않습니다.")
        }
        app.activate()
        guard app.wait(for: .runningForeground, timeout: 10) else {
            throw NSError(domain: "ConnectionUI", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "정상 앱 활성화 미확인"])
        }
        return app
    }

    private func unique(_ query: XCUIElementQuery) throws -> XCUIElement {
        var count = query.count
        if count == 0 {
            guard query.firstMatch.waitForExistence(timeout: 5) else {
                throw NSError(domain: "ConnectionUI", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "AX 요소 미노출"])
            }
            count = query.count
        }
        guard count == 1 else {
            throw NSError(domain: "ConnectionUI", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "동일 AX 요소가 여러 개면 조작하지 않습니다."])
        }
        return query.element(boundBy: 0)
    }

    private func ensureToolbarVisible(_ app: XCUIApplication) throws {
        let toggles = app.buttons.matching(identifier: "iPadToolbarToggle")
        let count = toggles.count
        guard count <= 1 else { throw NSError(domain: "ConnectionUI", code: 10) }
        if count == 0 { return }
        let toggle = toggles.element(boundBy: 0)
        let label = toggle.label
        if label == "상단 메뉴 숨기기" { return }
        guard label == "상단 메뉴 표시", toggle.isHittable, toggle.isEnabled else {
            throw NSError(domain: "ConnectionUI", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "숨겨진 상단바의 정확한 표시 버튼 미확인"])
        }
        toggle.tap()
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    func test01ReadDefaultMonitorAX() throws {
        let app = try existingApp()
        try ensureToolbarVisible(app)
        let chooser = try unique(app.buttons.matching(identifier: "macDisplayChooser"))
        let value = try XCTUnwrap(chooser.value as? String, "기본 모니터 AX 값 미노출")
        XCTAssertFalse(value.isEmpty)
        let data = try JSONSerialization.data(withJSONObject: [
            "identifier": chooser.identifier, "label": chooser.label, "value": value,
            "meaning": "현재 AX 관측값. 기본 모니터 일치 판정은 별도 원본 대조가 필요합니다."
        ], options: [.prettyPrinted, .sortedKeys])
        let ax = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        ax.name = "default-monitor-ax"
        ax.lifetime = .keepAlways
        add(ax)
        capture(app, name: "default-monitor")
    }

    private func tapUnique(_ query: XCUIElementQuery) throws {
        try tapChecked(unique(query))
    }

    private func tapChecked(_ element: XCUIElement) throws {
        guard element.isHittable, element.isEnabled else {
            throw NSError(domain: "ConnectionUI", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "정확한 native AX 요소가 조작 가능하지 않습니다."])
        }
        element.tap()
    }

    private func menuAction(_ app: XCUIApplication, label: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ AND (elementType == %d OR elementType == %d)", label,
            Int(XCUIElement.ElementType.button.rawValue), Int(XCUIElement.ElementType.menuItem.rawValue)))
    }

    func test02OpenNativeAudioChooserOnly() throws {
        let app = try existingApp()
        try openAudioChooser(app)
    }

    private func openAudioChooser(_ app: XCUIApplication) throws {
        let audio = app.menuBars.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "오디오"))
        let count = audio.count
        guard count <= 1 else { throw NSError(domain: "ConnectionUI", code: 11) }
        let nativeAudio = count == 1 ? audio.element(boundBy: 0) : nil
        if let nativeAudio, nativeAudio.isHittable {
            try tapChecked(nativeAudio)
            capture(app, name: "native-audio-menu")
            try tapUnique(menuAction(app, label: "입력·출력 선택…"))
        } else {
            try ensureToolbarVisible(app)
            try tapUnique(app.buttons.matching(identifier: "workspaceOverflow"))
            capture(app, name: "workspace-native-menu")
            try tapUnique(menuAction(app, label: "설정"))
            capture(app, name: "host-settings-panel")
            try tapUnique(app.buttons.matching(NSPredicate(
                format: "identifier == %@ AND label == %@", "openAudioRoutes", "오디오 입력·출력 선택…")))
        }
        XCTAssertTrue(app.navigationBars["오디오 입력·출력"].waitForExistence(timeout: 5))
        capture(app, name: "audio-input-output-chooser")
    }

    private func captureMediaState(_ app: XCUIApplication, name: String) {
        capture(app, name: name)
        let ax = XCTAttachment(string: app.debugDescription)
        ax.name = name + "-native-ax"
        ax.lifetime = .keepAlways
        add(ax)
    }

    private func requireAudioChooser(_ app: XCUIApplication) throws {
        let chooser = try unique(app.navigationBars.matching(identifier: "오디오 입력·출력"))
        guard chooser.isHittable else { throw NSError(domain: "ConnectionUI", code: 7) }
    }

    func test03EnableIPadFullDuplex() async throws {
        let app = try existingMediaApp()
        if !app.navigationBars["오디오 입력·출력"].exists {
            try openAudioChooser(app)
        }
        try requireAudioChooser(app)
        captureMediaState(app, name: "before-enable-full-duplex")
        let fullDuplex = try unique(app.buttons.matching(identifier: "useIPadFullDuplex"))
        guard fullDuplex.isHittable, fullDuplex.isEnabled else {
            throw NSError(domain: "ConnectionUI", code: 8,
                          userInfo: [NSLocalizedDescriptionKey: "full-duplex 버튼이 비활성 또는 미노출입니다."])
        }
        fullDuplex.tap()
        captureMediaState(app, name: "after-enable-full-duplex")
        try await Task.sleep(nanoseconds: 10_000_000_000)
        captureMediaState(app, name: "ten-seconds-after-enable-full-duplex")
    }

    func test04DisableIPadAudio() async throws {
        let app = try existingMediaApp()
        if !app.navigationBars["오디오 입력·출력"].exists {
            try openAudioChooser(app)
        }
        try requireAudioChooser(app)
        try tapUnique(app.buttons.matching(NSPredicate(
            format: "identifier == %@ AND label == %@", "stopIPadAudio", "iPad 입출력 중지")))
        captureMediaState(app, name: "after-explicit-stop-ipad-audio")
        try await Task.sleep(nanoseconds: 10_000_000_000)
        captureMediaState(app, name: "ten-seconds-after-explicit-stop-ipad-audio")
    }

    func test05ReadMonitorMenuAX() throws {
        let app = try existingApp()
        let navigation = app.navigationBars.matching(identifier: "오디오 입력·출력")
        let count = navigation.count
        guard count <= 1 else { throw NSError(domain: "ConnectionUI", code: 12) }
        if count == 1 {
            let bar = navigation.element(boundBy: 0)
            guard bar.isHittable else { throw NSError(domain: "ConnectionUI", code: 13) }
            try tapUnique(bar.buttons.matching(NSPredicate(format: "label == %@", "닫기")))
            guard bar.waitForNonExistence(timeout: 5) else {
                throw NSError(domain: "ConnectionUI", code: 14)
            }
        }
        try ensureToolbarVisible(app)
        let chooser = try unique(app.buttons.matching(identifier: "macDisplayChooser"))
        guard chooser.label == "Mac 모니터 선택" else {
            throw NSError(domain: "ConnectionUI", code: 15,
                          userInfo: [NSLocalizedDescriptionKey: "소스 전환 없이 열 수 있는 모니터 선택 버튼 미확인"])
        }
        let value = try XCTUnwrap(chooser.value as? String, "현재 모니터 AX 값 미노출")
        let chooserID = chooser.identifier
        try tapChecked(chooser)
        let menu = try unique(app.scrollViews.containing(.staticText, identifier: "Mac 모니터 선택"))
        guard menu.isHittable else { throw NSError(domain: "ConnectionUI", code: 16) }
        let choices = menu.buttons.allElementsBoundByIndex
        guard choices.count <= 64 else { throw NSError(domain: "ConnectionUI", code: 17) }
        let rows: [[String: Any]] = choices.map { item in
            ["identifier": item.identifier, "label": item.label,
             "value": item.value as? String ?? "", "enabled": item.isEnabled]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "chooserIdentifier": chooserID, "currentMonitorAXValue": value,
            "menuIdentifier": menu.identifier, "menuItems": rows,
            "numericDisplayID": NSNull(),
            "numericDisplayIDObservation": "제품 소스는 display.id를 AX에 별도 노출하지 않습니다. 이름을 ID로 해석하지 않습니다."
        ], options: [.prettyPrinted, .sortedKeys])
        let ax = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        ax.name = "monitor-menu-native-ax-values"
        ax.lifetime = .keepAlways
        add(ax)
        captureMediaState(app, name: "monitor-menu-observation")
        XCTAssertFalse(choices.isEmpty, "모니터 메뉴 항목 미노출. 실제 sourceID 검증으로 수용하지 않습니다.")
    }

    private enum ReadOnlyCallTarget: String {
        case native = "Mac 순정 Codex 음성"
        case dots = "ChatGPT Dots"

        var start: String { self == .native ? "음성 대화 시작" : "ChatGPT Dots 통화 시작" }
        var stop: String { self == .native ? "음성 대화 종료" : "ChatGPT Dots 통화 종료" }
        var statuses: [String] {
            if self == .native {
                return ["이 Mac 연결은 순정 Codex 음성 대화 제어를 지원하지 않습니다."]
            }
            return ["이 Mac 연결은 ChatGPT Dots 통화 제어를 지원하지 않습니다.",
                    "통화와 음성 입출력 상태는 각각 확인합니다."]
        }
    }

    private func callTargetPicker(_ app: XCUIApplication) throws -> XCUIElement {
        let picker = try unique(app.descendants(matching: .any).matching(identifier: "iPadCallTarget"))
        guard [.button, .popUpButton].contains(picker.elementType), picker.isEnabled, picker.isHittable else {
            throw NSError(domain: "ConnectionUI", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "정상 통화 대상 Picker의 native AX 형식·활성 상태 미확인"])
        }
        return picker
    }

    private func selectedCallTarget(_ picker: XCUIElement) throws -> ReadOnlyCallTarget {
        let value = picker.value as? String
        for target in [ReadOnlyCallTarget.native, .dots] {
            if value == target.rawValue ||
                ((value == nil || value == "") && picker.label == "통화 대상, " + target.rawValue) {
                return target
            }
        }
        throw NSError(domain: "ConnectionUI", code: 21,
                      userInfo: [NSLocalizedDescriptionKey: "현재 통화 대상 AX 값 미확인. 추정 선택하지 않습니다."])
    }

    private func observeReadOnlyCall(_ app: XCUIApplication, target: ReadOnlyCallTarget,
                                     name: String) throws {
        captureMediaState(app, name: name)
        let picker = try callTargetPicker(app)
        let start = try unique(app.buttons.matching(identifier: "iPadProviderCallStart"))
        let stop = try unique(app.buttons.matching(identifier: "iPadProviderCallStop"))
        let status = try unique(app.staticTexts.matching(identifier: "iPadProviderCallStatus"))
        guard try selectedCallTarget(picker) == target,
              start.label == target.start, stop.label == target.stop,
              !start.isEnabled, !stop.isEnabled,
              target.statuses.contains(status.label),
              app.buttons.matching(identifier: "iPadProviderCallCheckPrevious").count == 0,
              app.staticTexts.matching(identifier: "iPadProviderCallHistoricalResult").count == 0 else {
            throw NSError(domain: "ConnectionUI", code: 22,
                          userInfo: [NSLocalizedDescriptionKey:
                            "미지원 전용 전제와 AX가 다릅니다. 지원 광고·이전 요청·활성 버튼·대상 불일치 시 중지합니다."])
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "target": target.rawValue, "pickerIdentifier": picker.identifier,
            "pickerLabel": picker.label, "pickerValue": picker.value as? String ?? "",
            "startLabel": start.label, "startEnabled": start.isEnabled,
            "stopLabel": stop.label, "stopEnabled": stop.isEnabled,
            "status": status.label,
            "scope": "정상 Picker와 모델의 표시 바인딩 관측. Host 버전·인증·fresh OFF는 부모 metadata 전제."
        ], options: [.prettyPrinted, .sortedKeys])
        let ax = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        ax.name = name + "-values"
        ax.lifetime = .keepAlways
        add(ax)
    }

    private func selectReadOnlyCallTarget(_ app: XCUIApplication, from: ReadOnlyCallTarget,
                                          to: ReadOnlyCallTarget) throws {
        let picker = try callTargetPicker(app)
        guard try selectedCallTarget(picker) == from else {
            throw NSError(domain: "ConnectionUI", code: 23,
                          userInfo: [NSLocalizedDescriptionKey: "선택 직전 통화 대상이 바뀌었습니다."])
        }
        try tapChecked(picker)
        captureMediaState(app, name: "native06-target-menu-" + to.rawValue)
        let popup = try unique(app.collectionViews
            .containing(.button, identifier: ReadOnlyCallTarget.native.rawValue)
            .containing(.button, identifier: ReadOnlyCallTarget.dots.rawValue)
            .containing(.button, identifier: "Grok Bot"))
        let actions = popup.cells.children(matching: .button)
        let rows = actions.allElementsBoundByIndex
        let selected = rows.filter(\.isSelected)
        let action = try unique(actions.matching(NSPredicate(format: "label == %@", to.rawValue)))
        guard popup.isHittable, popup.cells.count == 3, popup.buttons.count == 3,
              rows.map(\.label) == [ReadOnlyCallTarget.native.rawValue, ReadOnlyCallTarget.dots.rawValue, "Grok Bot"],
              rows.allSatisfy({ $0.identifier.isEmpty }),
              selected.count == 1, selected[0].label == from.rawValue, !action.isSelected,
              action.frame.width > 0, action.frame.height > 0,
              popup.frame.contains(action.frame), app.frame.contains(action.frame) else {
            throw NSError(domain: "ConnectionUI", code: 26,
                          userInfo: [NSLocalizedDescriptionKey: "실제 통화 대상 popup의 직접 Cell/Button·체크·프레임 전제가 다릅니다."])
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "popupFrame": String(describing: popup.frame), "popupHittable": popup.isHittable,
            "from": from.rawValue, "to": to.rawValue,
            "actions": rows.map { item in
                ["label": item.label, "identifier": item.identifier,
                 "frame": String(describing: item.frame), "hittable": item.isHittable,
                 "enabled": item.isEnabled, "selected": item.isSelected] as [String: Any]
            }
        ], options: [.prettyPrinted, .sortedKeys])
        let ax = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        ax.name = "native06-popup-action-" + to.rawValue
        ax.lifetime = .keepAlways
        add(ax)
        try tapChecked(action)
        guard !popup.exists else {
            captureMediaState(app, name: "native06-popup-action-not-dismissed")
            throw NSError(domain: "ConnectionUI", code: 27,
                          userInfo: [NSLocalizedDescriptionKey: "popup action을 한 번 탭했으나 메뉴가 남았습니다. 재탭하지 않습니다."])
        }
        guard try selectedCallTarget(callTargetPicker(app)) == to else {
            throw NSError(domain: "ConnectionUI", code: 28,
                          userInfo: [NSLocalizedDescriptionKey: "popup이 닫혔으나 모델의 통화 대상 반영은 미확인입니다."])
        }
    }

    private func restoreNativeCallAndClose(_ app: XCUIApplication) throws {
        captureMediaState(app, name: "native06-before-restore")
        let current = try selectedCallTarget(callTargetPicker(app))
        if current == .dots {
            try observeReadOnlyCall(app, target: .dots, name: "native06-restore-guard")
            try selectReadOnlyCallTarget(app, from: .dots, to: .native)
        }
        try observeReadOnlyCall(app, target: .native, name: "native06-restored")
        let bar = try unique(app.navigationBars.matching(identifier: "오디오 입력·출력"))
        try tapUnique(bar.buttons.matching(NSPredicate(format: "label == %@", "닫기")))
        guard bar.waitForNonExistence(timeout: 5) else {
            throw NSError(domain: "ConnectionUI", code: 24,
                          userInfo: [NSLocalizedDescriptionKey: "native 값 복원 후 오디오창 닫힘 미확인"])
        }
        captureMediaState(app, name: "native06-closed")
    }

    func test06ReadNativeDotsUnsupportedChooserAX() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["CCR_CONNECTION_UI_MEDIA_APPROVED"] == "0" else {
            throw XCTSkip("06은 media 승인값이 정확히 0일 때만 실행합니다.")
        }
        let app = try existingApp()
        if !app.navigationBars["오디오 입력·출력"].exists {
            try openAudioChooser(app)
        }
        try requireAudioChooser(app)
        try observeReadOnlyCall(app, target: .native, name: "native06-initial-unsupported")
        do {
            try selectReadOnlyCallTarget(app, from: .native, to: .dots)
            try observeReadOnlyCall(app, target: .dots, name: "native06-dots-binding")
        } catch {
            let observationError = error
            captureMediaState(app, name: "native06-observation-failed")
            do {
                try restoreNativeCallAndClose(app)
            } catch {
                throw NSError(domain: "ConnectionUI", code: 25,
                              userInfo: [NSLocalizedDescriptionKey:
                                "관측 실패: \(observationError). 안전한 복원·닫기도 미확인: \(error). 추가 조작하지 않습니다."])
            }
            throw observationError
        }
        try restoreNativeCallAndClose(app)
    }

    func test07RecoverOpenDotsPopupToNative() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["CCR_CONNECTION_UI_RECOVERY_APPROVED"] == "1",
              ProcessInfo.processInfo.environment["CCR_CONNECTION_UI_MEDIA_APPROVED"] == "0" else {
            throw XCTSkip("07은 별도 복구 승인1·media0과 부모의 fresh OFF 확인 후에만 실행합니다.")
        }
        let app = try existingApp()
        captureMediaState(app, name: "recover07-current-open-popup")
        let popups = app.collectionViews
            .containing(.button, identifier: ReadOnlyCallTarget.native.rawValue)
            .containing(.button, identifier: ReadOnlyCallTarget.dots.rawValue)
            .containing(.button, identifier: "Grok Bot")
        let bars = app.navigationBars.matching(identifier: "오디오 입력·출력")
        let pickers = app.buttons.matching(identifier: "iPadCallTarget")
        let starts = app.buttons.matching(identifier: "iPadProviderCallStart")
        let stops = app.buttons.matching(identifier: "iPadProviderCallStop")
        let statuses = app.staticTexts.matching(identifier: "iPadProviderCallStatus")
        guard popups.count == 1, bars.count == 1, pickers.count == 1,
              starts.count == 1, stops.count == 1, statuses.count == 1,
              app.buttons.matching(identifier: "iPadProviderCallCheckPrevious").count == 0,
              app.staticTexts.matching(identifier: "iPadProviderCallHistoricalResult").count == 0 else {
            throw NSError(domain: "ConnectionUI", code: 40,
                          userInfo: [NSLocalizedDescriptionKey: "복구 대상의 현재 상태가 다릅니다. popup을 다시 열지 않고 중지합니다."])
        }
        let popup = popups.element(boundBy: 0)
        let picker = pickers.element(boundBy: 0)
        let start = starts.element(boundBy: 0)
        let stop = stops.element(boundBy: 0)
        let status = statuses.element(boundBy: 0)
        let actions = popup.cells.children(matching: .button)
        let rows = actions.allElementsBoundByIndex
        let selected = rows.filter(\.isSelected)
        let nativeActions = actions.matching(NSPredicate(format: "label == %@", ReadOnlyCallTarget.native.rawValue))
        guard popup.isHittable, popup.cells.count == 3, popup.buttons.count == 3,
              rows.map(\.label) == [ReadOnlyCallTarget.native.rawValue, ReadOnlyCallTarget.dots.rawValue, "Grok Bot"],
              rows.allSatisfy({ $0.identifier.isEmpty }), nativeActions.count == 1,
              selected.count == 1, selected[0].label == ReadOnlyCallTarget.dots.rawValue,
              picker.isEnabled, try selectedCallTarget(picker) == .dots,
              start.label == ReadOnlyCallTarget.dots.start, stop.label == ReadOnlyCallTarget.dots.stop,
              !start.isEnabled, !stop.isEnabled, ReadOnlyCallTarget.dots.statuses.contains(status.label) else {
            throw NSError(domain: "ConnectionUI", code: 41,
                          userInfo: [NSLocalizedDescriptionKey: "정확한 세 action·Dots 체크·기존 대상·시작/종료 비활성 전제가 아닙니다. 조작하지 않습니다."])
        }
        let action = nativeActions.element(boundBy: 0)
        guard !action.isSelected, action.frame.width > 0, action.frame.height > 0,
              popup.frame.contains(action.frame), app.frame.contains(action.frame) else {
            throw NSError(domain: "ConnectionUI", code: 42,
                          userInfo: [NSLocalizedDescriptionKey: "복구 native action의 선택·frame 전제가 다릅니다."])
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "popupFrame": String(describing: popup.frame), "pickerLabel": picker.label,
            "pickerHittable": picker.isHittable, "startEnabled": start.isEnabled,
            "stopEnabled": stop.isEnabled, "status": status.label,
            "nativeActionFrame": String(describing: action.frame),
            "nativeActionHittable": action.isHittable, "nativeActionEnabled": action.isEnabled,
            "selected": selected[0].label,
            "operation": "이미 열린 popup의 native action 1회 선택 후 복원·닫기만 확인"
        ], options: [.prettyPrinted, .sortedKeys])
        let ax = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        ax.name = "recover07-before-native-action-values"
        ax.lifetime = .keepAlways
        add(ax)
        try tapChecked(action)
        captureMediaState(app, name: "recover07-after-native-action")
        guard !popup.exists else {
            throw NSError(domain: "ConnectionUI", code: 43,
                          userInfo: [NSLocalizedDescriptionKey: "native action 1회 후에도 popup이 남았습니다. 재탭하지 않습니다."])
        }
        try observeReadOnlyCall(app, target: .native, name: "recover07-restored-native")
        let bar = try unique(app.navigationBars.matching(identifier: "오디오 입력·출력"))
        try tapUnique(bar.buttons.matching(NSPredicate(format: "label == %@", "닫기")))
        guard bar.waitForNonExistence(timeout: 5) else {
            throw NSError(domain: "ConnectionUI", code: 44,
                          userInfo: [NSLocalizedDescriptionKey: "복구 뒤 오디오창 닫힘 미확인"])
        }
        captureMediaState(app, name: "recover07-closed")
    }

    private func openSimpleCall(_ app: XCUIApplication) throws {
        if app.navigationBars["통화"].exists { return }
        let audio = app.menuBars.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "오디오"))
        guard audio.count <= 1 else { throw NSError(domain: "ConnectionUI", code: 50) }
        if audio.count == 1, audio.element(boundBy: 0).isHittable {
            try tapChecked(audio.element(boundBy: 0))
            try tapUnique(menuAction(app, label: "입력·출력 선택…"))
        } else {
            try ensureToolbarVisible(app)
            try tapUnique(app.buttons.matching(identifier: "workspaceOverflow"))
            try tapUnique(menuAction(app, label: "설정"))
            try tapUnique(app.buttons.matching(NSPredicate(
                format: "identifier == %@ AND label == %@", "openAudioRoutes", "통화·마이크·스피커")))
        }
        let bar = try unique(app.navigationBars.matching(identifier: "통화"))
        guard bar.isHittable else { throw NSError(domain: "ConnectionUI", code: 51) }
    }

    private func simpleCallControls(_ app: XCUIApplication, name: String) throws
        -> (microphone: XCUIElement, speaker: XCUIElement) {
        captureMediaState(app, name: name)
        let bar = try unique(app.navigationBars.matching(identifier: "통화"))
        guard bar.isHittable, app.navigationBars["기기"].exists == false,
              app.buttons.matching(identifier: "iPadProviderCallCancelPreparation").count == 0 else {
            throw NSError(domain: "ConnectionUI", code: 52,
                          userInfo: [NSLocalizedDescriptionKey: "통화 메인 화면이 아니거나 준비 중입니다."])
        }
        let call = try unique(app.buttons.matching(NSPredicate(
            format: "identifier IN %@", ["iPadProviderCallStart", "iPadProviderCallStop"])))
        guard call.isHittable,
              call.label == (call.identifier == "iPadProviderCallStart" ? "통화 시작" : "통화 종료") else {
            throw NSError(domain: "ConnectionUI", code: 53)
        }
        let microphone = try unique(app.switches.matching(identifier: "iPadCallMicrophone"))
        let speaker = try unique(app.switches.matching(identifier: "iPadCallSpeaker"))
        let devices = try unique(app.buttons.matching(identifier: "iPadCallDevices"))
        guard microphone.label == "마이크 사용", speaker.label == "스피커 사용", devices.label == "기기",
              microphone.isHittable, speaker.isHittable, devices.isHittable,
              ["0", "1"].contains(microphone.value as? String ?? ""),
              ["0", "1"].contains(speaker.value as? String ?? "") else {
            throw NSError(domain: "ConnectionUI", code: 54,
                          userInfo: [NSLocalizedDescriptionKey: "정확한 통화 toggle·기기 AX 또는 0/1 값 미확인"])
        }
        let internalIDs = ["audioRouteInput", "audioRouteOutput", "applyAudioRoutes", "applyMacAudioRoutes",
                           "useIPadFullDuplex", "stopIPadAudio", "iPadCallTarget", "macAudioInput", "macAudioOutput"]
        guard app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier IN %@", internalIDs)).count == 0,
              app.descendants(matching: .any).matching(NSPredicate(
                format: "label MATCHES %@", "(?i).*(grant|packet|blackhole|동의 적용|Mac 수신 상태 확인).*")).count == 0 else {
            throw NSError(domain: "ConnectionUI", code: 55,
                          userInfo: [NSLocalizedDescriptionKey: "통화 메인에 내부 적용·grant·packet 또는 기기 설정이 노출됐습니다."])
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "controls": [call, microphone, speaker, devices].map { item in
                ["identifier": item.identifier, "label": item.label, "value": item.value as? String ?? "",
                 "enabled": item.isEnabled, "hittable": item.isHittable] as [String: Any]
            },
            "scope": "제품 소스7c2fd685의 간단한 통화 AX 관측. 버튼을 누르지 않으며 실제 미디어 수용은 별도입니다."
        ], options: [.prettyPrinted, .sortedKeys])
        let ax = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        ax.name = name + "-values"
        ax.lifetime = .keepAlways
        add(ax)
        return (microphone, speaker)
    }

    func test08ReadSimpleCallAXAndDeviceSheet() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["CCR_CONNECTION_UI_MEDIA_APPROVED"] == "0" else {
            throw XCTSkip("08은 media0과 부모의 actual88·fresh OFF 확인 후에만 실행합니다.")
        }
        let app = try existingApp()
        try openSimpleCall(app)
        _ = try simpleCallControls(app, name: "simple08-main")
        try tapUnique(app.buttons.matching(NSPredicate(
            format: "identifier == %@ AND label == %@", "iPadCallDevices", "기기")))
        captureMediaState(app, name: "simple08-device-sheet")
        let sheetBar = try unique(app.navigationBars.matching(identifier: "기기"))
        guard sheetBar.isHittable else { throw NSError(domain: "ConnectionUI", code: 57) }
        try tapUnique(sheetBar.buttons.matching(NSPredicate(format: "label == %@", "완료")))
        guard sheetBar.waitForNonExistence(timeout: 5) else {
            throw NSError(domain: "ConnectionUI", code: 58,
                          userInfo: [NSLocalizedDescriptionKey: "기기 sheet 닫힘 미확인. 재탭하지 않습니다."])
        }
        _ = try simpleCallControls(app, name: "simple08-device-sheet-closed")
    }

    func test09SetSimpleCallMediaToggles() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard environment["CCR_CONNECTION_UI_SIMPLE_MEDIA_APPROVED"] == "1",
              let action = environment["CCR_CONNECTION_UI_SIMPLE_MEDIA_ACTION"], ["ON", "OFF"].contains(action) else {
            throw XCTSkip("09는 별도 simple media 승인1과 부모의 명시적 ON 또는 OFF 선택이 필요합니다.")
        }
        let app = try existingMediaApp()
        try openSimpleCall(app)
        defer { captureMediaState(app, name: "simple09-final-observation") }
        let controls = try simpleCallControls(app, name: "simple09-before-" + action)
        let target = action == "ON" ? "1" : "0"
        guard controls.microphone.isEnabled, controls.speaker.isEnabled,
              action == "OFF" || (controls.microphone.value as? String == "0" && controls.speaker.value as? String == "0") else {
            throw NSError(domain: "ConnectionUI", code: 59,
                          userInfo: [NSLocalizedDescriptionKey: "부모가 승인한 ON/OFF의 초기 toggle 값 또는 활성 상태와 다릅니다."])
        }
        for control in [controls.microphone, controls.speaker] {
            let toggle = try unique(app.switches.matching(identifier: control.identifier))
            guard let current = toggle.value as? String, ["0", "1"].contains(current),
                  toggle.isEnabled, toggle.isHittable, action == "OFF" || current == "0" else {
                throw NSError(domain: "ConnectionUI", code: 60,
                              userInfo: [NSLocalizedDescriptionKey: "toggle의 현재 0/1 값 또는 활성 상태 미확인. 조작하지 않습니다."])
            }
            if current != target {
                try tapChecked(toggle)
                captureMediaState(app, name: "simple09-after-" + toggle.identifier + "-" + action)
            }
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate(
                format: "value == %@ AND enabled == true AND hittable == true", target), object: toggle)
            guard await XCTWaiter.fulfillment(of: [settled], timeout: 10) == .completed else {
                throw NSError(domain: "ConnectionUI", code: 61,
                              userInfo: [NSLocalizedDescriptionKey: "toggle 반영·활성 복귀 미확인. 재탭·자동 원복하지 않습니다."])
            }
        }
        try await Task.sleep(nanoseconds: 10_000_000_000)
        let observed = try simpleCallControls(app, name: "simple09-ten-seconds-after-" + action)
        guard observed.microphone.isEnabled, observed.speaker.isEnabled else {
            throw NSError(domain: "ConnectionUI", code: 62,
                          userInfo: [NSLocalizedDescriptionKey: "최종 toggle 활성 상태 미확인"])
        }
        XCTAssertEqual(observed.microphone.value as? String, target)
        XCTAssertEqual(observed.speaker.value as? String, target)
    }
}
