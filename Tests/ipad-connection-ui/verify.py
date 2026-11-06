"""기기 없이 실행하는 후보 범위·행동·설치 계약 검사."""
import hashlib
import json
import plistlib
from pathlib import Path
import xml.etree.ElementTree as ET

if 'FILES' not in globals():
    root = Path(__file__).resolve().parent
    FILES = {str(p.relative_to(root)): p.read_text() for p in root.rglob('*')
             if p.is_file() and p.suffix in {'.swift', '.py', '.pbxproj', '.xcscheme'}}
candidate_swift = FILES['ConnectionUITests.swift']
full_swift, simple88 = candidate_swift.split('\n    private func openSimpleCall(', 1)
full_swift = full_swift.rstrip() + '\n}\n'
simple88 = 'private func openSimpleCall(' + simple88
assert hashlib.sha256(full_swift.encode()).hexdigest() == 'dc34eaa80c5360b967b4165436ffdeeef72e0dcc6982a47ad9fd99746626b7c9'
previous_swift = full_swift.split('\n    func test07RecoverOpenDotsPopupToNative()', 1)[0].rstrip() + '\n}\n'
assert hashlib.sha256(previous_swift.encode()).hexdigest() == 'bc0907aa6b8712d4cd5fad50add94a784c5617681fe086c44e757ad32d41b2b8'
swift, native06 = full_swift.split('\n    private enum ReadOnlyCallTarget:', 1)
swift = swift.rstrip() + '\n}\n'
assert hashlib.sha256(swift.encode()).hexdigest() == 'd2282679266e9ed82c5da456d48e0484e0453062454828a5ffeebab71e3650e2'
assert swift.count('.tap()') == 3
assert swift.count('fullDuplex.tap()') == 1
assert 'guard fullDuplex.isHittable, fullDuplex.isEnabled' in swift
assert swift.count('try tapUnique(') == 6
assert 'guard element.isHittable, element.isEnabled' in swift
assert 'if let nativeAudio, nativeAudio.isHittable' in swift
assert 'identifier: "workspaceOverflow"' in swift
assert 'menuAction(app, label: "설정")' in swift
assert '"openAudioRoutes", "오디오 입력·출력 선택…"' in swift
assert swift.count('toggle.tap()') == 1
assert swift.count('try ensureToolbarVisible(app)') == 3
assert 'identifier: "iPadToolbarToggle"' in swift
assert 'label == "상단 메뉴 표시", toggle.isHittable, toggle.isEnabled' in swift
assert '상단 메뉴 숨기기' in swift
unique_helper = swift.split('private func unique(', 1)[1].split('private func ensureToolbarVisible', 1)[0]
assert 'var count = query.count' in unique_helper
assert 'if count == 0 {' in unique_helper
assert unique_helper.count('query.count') == 2
assert unique_helper.count('waitForExistence') == 1
assert 'guard count == 1' in unique_helper
reveal = swift.split('private func ensureToolbarVisible(', 1)[1].split('private func capture(', 1)[0]
assert 'capture(' not in reveal and 'waitFor' not in reveal and 'macDisplayChooser' not in reveal
assert reveal.index('guard count <= 1') < reveal.index('toggle.tap()')
opening = swift.split('private func openAudioChooser(', 1)[1].split('private func captureMediaState(', 1)[0]
assert opening.index('let count = audio.count') < opening.index('try ensureToolbarVisible(app)')
assert opening.index('guard count <= 1') < opening.index('try tapChecked(nativeAudio)')
critical = opening.split('try ensureToolbarVisible(app)', 1)[1].split('workspace-native-menu', 1)[0]
assert 'try tapUnique(app.buttons.matching(identifier: "workspaceOverflow"))' in critical
assert critical.count('capture(') == 1 and 'before-native-menu' not in opening
assert swift.count('.activate()') == 1
assert 'func test01ReadDefaultMonitorAX()' in swift
assert 'func test02OpenNativeAudioChooserOnly()' in swift
assert swift.count('func test') == 5
assert 'func test03EnableIPadFullDuplex() async throws' in swift
assert 'func test04DisableIPadAudio() async throws' in swift
for token in ('.launch(', '.terminate(', 'launchArguments', 'launchEnvironment',
              'coordinate(', 'typeText(', 'press(', 'swipe', 'adjust(', 'springboard'):
    assert token not in candidate_swift, token
assert 'CCR_CONNECTION_UI_APPROVED' in swift
import re
audio_gate = re.search(
    r'guard ProcessInfo.processInfo.environment\["CCR_CONNECTION_UI_AUDIO_OFF_VERIFIED"\] == "1" else \{\s*throw XCTSkip\([^\n]+\)\s*\}', swift)
assert audio_gate is not None
assert audio_gate.end() < swift.index('return try activateExistingApp()')
read_helper = swift.split('private func existingApp()', 1)[1].split('private func existingMediaApp()', 1)[0]
media_helper = swift.split('private func existingMediaApp()', 1)[1].split('private func activateExistingApp()', 1)[0]
assert 'CCR_CONNECTION_UI_APPROVED' in read_helper and 'CCR_CONNECTION_UI_AUDIO_OFF_VERIFIED' in read_helper
assert 'CCR_CONNECTION_UI_MEDIA_APPROVED' not in read_helper
assert 'guard ProcessInfo.processInfo.environment["CCR_CONNECTION_UI_MEDIA_APPROVED"] == "1" else' in media_helper
assert 'throw XCTSkip(' in media_helper
assert 'CCR_CONNECTION_UI_AUDIO_OFF_VERIFIED' not in media_helper
assert swift.count('return try activateExistingApp()') == 2
assert swift.count('try existingApp()') == 3 and swift.count('try existingMediaApp()') == 2
assert 'XCTAttachment(string: app.debugDescription)' in swift
assert 'Task.sleep(nanoseconds: 10_000_000_000)' in swift
assert 'identifier: "useIPadFullDuplex"' in swift
enable = swift.split('func test03EnableIPadFullDuplex()', 1)[1].split('func test04DisableIPadAudio()', 1)[0]
disable = swift.split('func test04DisableIPadAudio()', 1)[1].split('func test05ReadMonitorMenuAX()', 1)[0]
assert 'if !app.navigationBars["오디오 입력·출력"].exists' in enable
assert enable.count('fullDuplex.tap()') == 1
assert enable.index('fullDuplex.tap()') < enable.index('Task.sleep(') < enable.index('ten-seconds-after-enable-full-duplex')
assert '"stopIPadAudio", "iPad 입출력 중지"' in disable
assert disable.count('try tapUnique(') == 1
assert 'try existingMediaApp()' in disable
assert 'if !app.navigationBars["오디오 입력·출력"].exists' in disable
assert disable.index('try openAudioChooser(app)') < disable.index('try requireAudioChooser(app)') < disable.index('try tapUnique(')
assert disable.index('try tapUnique(') < disable.index('after-explicit-stop-ipad-audio') < disable.index('Task.sleep(') < disable.index('ten-seconds-after-explicit-stop-ipad-audio')
assert 'selectOff' not in swift
for forbidden in ('audioRouteInput', 'audioRouteOutput', 'applyAudioRoutes', 'swipe'):
    assert forbidden not in disable
assert swift.count('Task.sleep(nanoseconds: 10_000_000_000)') == 2
monitor = swift.split('func test05ReadMonitorMenuAX()', 1)[1]
assert monitor.count('try existingApp()') == 1 and 'existingMediaApp' not in monitor
assert 'bar.buttons.matching(NSPredicate(format: "label == %@", "닫기"))' in monitor
assert 'guard count <= 1' in monitor
assert monitor.index('guard chooser.label == "Mac 모니터 선택"') < monitor.index('try tapChecked(chooser)')
assert monitor.count('try tapUnique(') == 1 and monitor.count('try tapChecked(') == 1
assert 'app.scrollViews.containing(.staticText, identifier: "Mac 모니터 선택")' in monitor
assert '"numericDisplayID": NSNull()' in monitor
assert 'choices.map' in monitor
assert 'item.tap' not in monitor
assert '.runningBackgroundSuspended' in swift
assert 'app.menuBars.descendants' in swift
assert 'identifier: "macDisplayChooser"' in swift
assert '입력·출력 선택…' in swift
project = FILES['ConnectionUI.xcodeproj/project.pbxproj']
assert project.count('isa = PBXNativeTarget;') == 1
assert 'com.apple.product-type.application' not in project
assert 'dependencies = ();' in project
assert 'TEST_TARGET_NAME' not in project
assert '../../../' not in project
scheme = ET.fromstring(FILES['ConnectionUI.xcodeproj/xcshareddata/xcschemes/ConnectionUI.xcscheme'])
assert len(scheme.findall('.//BuildActionEntry')) == 1
assert not scheme.findall('.//LaunchAction')
namespace = {'__name__': 'contract_check'}
exec(compile(FILES['prepare_destination.py'], 'prepare_destination.py', 'exec'), namespace)
seed = {'__xctestrun_metadata__': {'FormatVersion': 1}, 'ConnectionUITests': {
    'TestHostBundleIdentifier': 'com.ambrion.rea.appaudit.UITests.xctrunner',
    'UseUITargetAppProvidedByTests': True, 'IsUITestBundle': True,
    'IsXCTRunnerHostedTestBundle': True,
    'TestBundlePath': '__TESTHOST__/PlugIns/ConnectionUITests.xctest',
    'TestHostPath': 'runner.app', 'UITargetAppPath': 'FORBIDDEN.app',
    'DependentProductPaths': ['FORBIDDEN.app'],
    'BlueprintName': 'ConnectionUITests', 'ProductModuleName': 'ConnectionUITests',
    'TestingEnvironmentVariables': {},
    'EnvironmentVariables': {'CCR_CONNECTION_UI_APPROVED': '1',
                             'CCR_CONNECTION_UI_AUDIO_OFF_VERIFIED': '1',
                             'CCR_CONNECTION_UI_MEDIA_APPROVED': '1',
                             'CCR_CONNECTION_UI_SIMPLE_MEDIA_APPROVED': '1',
                             'CCR_CONNECTION_UI_SIMPLE_MEDIA_ACTION': 'ON'}}}
result = namespace['prepare'](seed)['ConnectionUITests']
assert result['UseDestinationArtifacts'] is True
assert result['UseUITargetAppProvidedByTests'] is True
assert result['UITargetAppBundleIdentifier'] == 'com.ambrion.sillcanvas.ipad'
assert result['EnvironmentVariables'] == {
    'CCR_CONNECTION_UI_APPROVED': '0',
    'CCR_CONNECTION_UI_AUDIO_OFF_VERIFIED': '0',
    'CCR_CONNECTION_UI_MEDIA_APPROVED': '0',
}
assert result['OnlyTestIdentifiers'] == ['ConnectionUITests/test01ReadDefaultMonitorAX',
                                         'ConnectionUITests/test02OpenNativeAudioChooserOnly']
for key in ('TestHostPath', 'TestBundlePath', 'UITargetAppPath', 'DependentProductPaths',
            'UITargetAppCommandLineArguments', 'UITargetAppEnvironmentVariables'):
    assert key not in result
assert plistlib.loads(plistlib.dumps(result)) == result
monitor_contract = namespace['prepare'](seed, test05_only=True)['ConnectionUITests']
assert monitor_contract['OnlyTestIdentifiers'] == ['ConnectionUITests/test05ReadMonitorMenuAX']
assert monitor_contract['EnvironmentVariables'] == result['EnvironmentVariables']
assert monitor_contract['UseDestinationArtifacts'] is True
native_contract = namespace['prepare'](seed, test06_only=True)['ConnectionUITests']
assert native_contract['OnlyTestIdentifiers'] == ['ConnectionUITests/test06ReadNativeDotsUnsupportedChooserAX']
assert {k: v for k, v in native_contract.items() if k != 'OnlyTestIdentifiers'} == {
    k: v for k, v in result.items() if k != 'OnlyTestIdentifiers'}
try:
    namespace['prepare'](seed, test05_only=True, test06_only=True)
except ValueError:
    pass
else:
    raise AssertionError('mixed 05/06 selection accepted')
assert 'add_mutually_exclusive_group()' in FILES['prepare_destination.py']
recovery_contract = namespace['prepare'](seed, recover07_only=True)['ConnectionUITests']
assert recovery_contract['OnlyTestIdentifiers'] == ['ConnectionUITests/test07RecoverOpenDotsPopupToNative']
assert recovery_contract['EnvironmentVariables'] == dict(result['EnvironmentVariables'], CCR_CONNECTION_UI_RECOVERY_APPROVED='0')
assert {k: v for k, v in recovery_contract.items() if k not in ('OnlyTestIdentifiers', 'EnvironmentVariables')} == {
    k: v for k, v in result.items() if k not in ('OnlyTestIdentifiers', 'EnvironmentVariables')}
for modes in ({'test05_only': True, 'recover07_only': True},
              {'test06_only': True, 'recover07_only': True}):
    try:
        namespace['prepare'](seed, **modes)
    except ValueError:
        pass
    else:
        raise AssertionError('mixed recovery selection accepted')
assert full_swift.count('func test') == 7
assert full_swift.count('.tap()') == swift.count('.tap()')
assert full_swift.count('.activate()') == 1
for forbidden in ('existingMediaApp', '.tap()', 'Task.sleep', 'performIPadProviderCall',
                  'selectIPadProviderCallTarget', 'audioRouteInput', 'audioRouteOutput',
                  'applyAudioRoutes', 'applyMacAudioRoutes', 'stopIPadAudio',
                  'useIPadFullDuplex', 'fetchMacAudioRoutes', 'macDisplayChooser',
                  'WindowList', 'nativeSupported', 'providerCallKinds'):
    assert forbidden not in native06, forbidden
test06 = native06.split('func test06ReadNativeDotsUnsupportedChooserAX()', 1)[1].split('func test07', 1)[0]
assert test06.index('environment["CCR_CONNECTION_UI_MEDIA_APPROVED"] == "0"') < test06.index('try existingApp()')
assert 'throw XCTSkip(' in test06
assert test06.count('try existingApp()') == 1
assert test06.index('target: .native, name: "native06-initial-unsupported"') < test06.index('from: .native, to: .dots')
assert test06.index('from: .native, to: .dots') < test06.index('target: .dots, name: "native06-dots-binding"')
assert test06.count('try restoreNativeCallAndClose(app)') == 2
assert 'throw observationError' in test06
picker_check = native06.split('private func callTargetPicker(', 1)[1].split('private func selectedCallTarget(', 1)[0]
assert 'identifier: "iPadCallTarget"' in picker_check
assert '[.button, .popUpButton].contains(picker.elementType), picker.isEnabled, picker.isHittable' in picker_check
observation = native06.split('private func observeReadOnlyCall(', 1)[1].split('private func selectReadOnlyCallTarget(', 1)[0]
for expected in ('!start.isEnabled, !stop.isEnabled', 'target.statuses.contains(status.label)',
                 'start.label == target.start, stop.label == target.stop',
                 'try selectedCallTarget(picker) == target',
                 'identifier: "iPadProviderCallCheckPrevious").count == 0',
                 'identifier: "iPadProviderCallHistoricalResult").count == 0'):
    assert expected in observation, expected
assert observation.index('captureMediaState(') < observation.index('let picker =')
assert 'return ["이 Mac 연결은 순정 Codex 음성 대화 제어를 지원하지 않습니다."]' in native06
selection06 = native06.split('private func selectReadOnlyCallTarget(', 1)[1].split('private func restoreNativeCallAndClose(', 1)[0]
assert selection06.index('guard try selectedCallTarget(picker) == from') < selection06.index('try tapChecked(picker)')
assert selection06.count('try tapChecked(') == 2 and selection06.count('try tapUnique(') == 0
assert 'menuAction(' not in selection06
for expected in ('app.collectionViews',
                 '.containing(.button, identifier: ReadOnlyCallTarget.native.rawValue)',
                 '.containing(.button, identifier: ReadOnlyCallTarget.dots.rawValue)',
                 '.containing(.button, identifier: "Grok Bot")',
                 'popup.cells.children(matching: .button)',
                 'let action = try unique(actions.matching(NSPredicate(format: "label == %@", to.rawValue)))',
                 'popup.isHittable, popup.cells.count == 3, popup.buttons.count == 3',
                 'rows.allSatisfy({ $0.identifier.isEmpty })',
                 'selected.count == 1, selected[0].label == from.rawValue, !action.isSelected',
                 'popup.frame.contains(action.frame), app.frame.contains(action.frame)',
                 '"hittable": item.isHittable', '"selected": item.isSelected',
                 'guard !popup.exists else',
                 'guard try selectedCallTarget(callTargetPicker(app)) == to else'):
    assert expected in selection06, expected
assert selection06.index('popup.frame.contains(action.frame)') < selection06.index('try tapChecked(action)')
assert selection06.index('try tapChecked(action)') < selection06.index('guard !popup.exists else')
assert selection06.index('guard !popup.exists else') < selection06.index('guard try selectedCallTarget(callTargetPicker(app)) == to')
for forbidden in ('waitFor', 'sleep', 'while ', 'for ', 'continue', 'retry', '651', '829'):
    assert forbidden not in selection06, forbidden
recovery07 = full_swift.split('func test07RecoverOpenDotsPopupToNative()', 1)[1]
assert recovery07.index('environment["CCR_CONNECTION_UI_RECOVERY_APPROVED"] == "1"') < recovery07.index('try existingApp()')
assert recovery07.index('environment["CCR_CONNECTION_UI_MEDIA_APPROVED"] == "0"') < recovery07.index('try existingApp()')
assert recovery07.count('try existingApp()') == 1
assert recovery07.count('try tapChecked(action)') == 1
assert recovery07.count('try tapUnique(') == 1
for forbidden in ('tapChecked(picker)', 'callTargetPicker(', 'selectReadOnlyCallTarget(',
                  'restoreNativeCallAndClose(', 'openAudioChooser(', 'ensureToolbarVisible(',
                  'requireAudioChooser(', 'menuAction(', 'target: .dots', 'catch', 'while ',
                  'sleep', 'coordinate', 'swipe', 'typeText', 'press('):
    assert forbidden not in recovery07, forbidden
for expected in ('popups.count == 1, bars.count == 1, pickers.count == 1',
                 'starts.count == 1, stops.count == 1, statuses.count == 1',
                 'popup.cells.children(matching: .button)',
                 'popup.isHittable, popup.cells.count == 3, popup.buttons.count == 3',
                 'rows.allSatisfy({ $0.identifier.isEmpty }), nativeActions.count == 1',
                 'selected.count == 1, selected[0].label == ReadOnlyCallTarget.dots.rawValue',
                 'picker.isEnabled, try selectedCallTarget(picker) == .dots',
                 '!start.isEnabled, !stop.isEnabled',
                 'ReadOnlyCallTarget.dots.statuses.contains(status.label)',
                 'popup.frame.contains(action.frame), app.frame.contains(action.frame)',
                 'guard !popup.exists else',
                 'try observeReadOnlyCall(app, target: .native, name: "recover07-restored-native")',
                 'bar.buttons.matching(NSPredicate(format: "label == %@", "닫기"))'):
    assert expected in recovery07, expected
assert recovery07.index('!start.isEnabled, !stop.isEnabled') < recovery07.index('try tapChecked(action)')
assert recovery07.index('try tapChecked(action)') < recovery07.index('guard !popup.exists else')
assert recovery07.index('guard !popup.exists else') < recovery07.index('target: .native') < recovery07.index('try tapUnique(')
assert recovery07.count('waitFor') == 1 and 'bar.waitForNonExistence(timeout: 5)' in recovery07
popup_replay = []
if 'ACTUAL_POPUP_AX' in globals():
    titles = ['Mac 순정 Codex 음성', 'ChatGPT Dots', 'Grok Bot']

    def popup_candidates(tree):
        return [view for view in tree.iter('CollectionView')
                if set(titles) <= {button.get('label') for button in view.iter('Button')}]

    for name, saved_ax in ACTUAL_POPUP_AX.items():
        tree = ET.Element('Snapshot')
        stack = [(-1, tree)]
        for line in saved_ax.splitlines():
            match = re.match(r'^(\s*)(?:→)?(\w+)(?: \(\w+\))?, 0x[0-9a-f]+, (.*)$', line)
            if not match:
                continue
            indent, kind, attributes = match.groups()
            while len(indent) <= stack[-1][0]:
                stack.pop()
            node = ET.SubElement(stack[-1][1], kind)
            for key in ('label', 'identifier'):
                value = re.search(key + r": '([^']*)'", attributes)
                node.set(key, value.group(1) if value else '')
            node.set('selected', str(attributes.endswith(', Selected')))
            stack.append((len(indent), node))
        candidates = popup_candidates(tree)
        assert len(candidates) == 1, (name, len(candidates))
        popup = candidates[0]
        rows = popup.findall('./Cell/Button')
        assert [row.get('label') for row in rows] == titles
        assert all(row.get('identifier') == '' for row in rows)
        assert len(list(popup.iter('Button'))) == 3
        assert sum(row.get('selected') == 'True' for row in rows) == 1
        selected_title = next(row.get('label') for row in rows if row.get('selected') == 'True')
        form = next(view for view in tree.iter('CollectionView')
                    if any(x.get('identifier') == 'iPadCallTarget' for x in view.iter('Button')))
        assert form is not popup
        ET.SubElement(form, 'Button', label=titles[0], identifier='iPadCallTarget')
        assert popup_candidates(tree) == [popup]
        tree.append(ET.fromstring(ET.tostring(popup)))
        assert len(popup_candidates(tree)) == 2
        popup_replay.append({'snapshot': name, 'directPopupActions': titles,
                             'backgroundSameNameExcluded': True, 'duplicatePopupRejected': True,
                             'recovery07SelectedTargetPrecondition': selected_title == 'ChatGPT Dots',
                             'actualTapExecuted': False})
restoration = native06.split('private func restoreNativeCallAndClose(', 1)[1].split('func test06', 1)[0]
assert restoration.index('target: .dots, name: "native06-restore-guard"') < restoration.index('from: .dots, to: .native')
assert restoration.index('target: .native, name: "native06-restored"') < restoration.index('bar.buttons.matching')
assert 'bar.waitForNonExistence(timeout: 5)' in restoration
bad = dict(seed, ConnectionUITests=dict(seed['ConnectionUITests'], TestHostBundleIdentifier='other'))
try:
    namespace['prepare'](bad)
except AssertionError:
    pass
else:
    raise AssertionError('runner identity mismatch accepted')

assert candidate_swift.count('func test') == 9
assert candidate_swift.count('.activate()') == 1
assert candidate_swift.count('.tap()') == full_swift.count('.tap()')
for forbidden in ('existingMediaApp', 'performIPadProviderCall', 'selectIPadProviderCallTarget',
                  'try openAudioChooser(', 'try requireAudioChooser(', 'try callTargetPicker(',
                  'tapChecked(call)', 'tapChecked(devices)', 'tapChecked(microphone)', 'tapChecked(speaker)'):
    if forbidden == 'existingMediaApp':
        assert simple88.count('try existingMediaApp()') == 1
    else:
        assert forbidden not in simple88, forbidden
simple_open = simple88.split('private func simpleCallControls(', 1)[0]
assert 'if app.navigationBars["통화"].exists { return }' in simple_open
assert 'menuAction(app, label: "입력·출력 선택…")' in simple_open
assert '"openAudioRoutes", "통화·마이크·스피커"' in simple_open
assert simple_open.count('try tapChecked(') == 1 and simple_open.count('try tapUnique(') == 4
assert 'guard audio.count <= 1' in simple_open
simple_controls = simple88.split('private func simpleCallControls(', 1)[1].split('func test08', 1)[0]
assert 'try tap' not in simple_controls
assert 'captureMediaState(app, name: name)' in simple_controls
call_guard = simple_controls.split('        let callLabels = ', 1)[1].split('        let microphone = ', 1)[0]
call_guard = '        let callLabels = ' + call_guard

def verify_simple_call_guard(body):
    assert hashlib.sha256(body.encode()).hexdigest() == '3a948a48d3723209af18339df150500186dcebf9658a0c3ba9c99e5bc29bd7ba'
    pairs = re.findall(r'"(iPad\w+)": "([^"\n]+)"', body)
    labels = dict(pairs)
    assert len(pairs) == len(labels) == 3
    assert labels == {'iPadProviderCallStart': '통화 시작', 'iPadProviderCallStop': '통화 종료',
                      'iPadConfiguredCraftAction': '음성 대화'}
    assert body.count('try unique(app.buttons.matching(NSPredicate(') == 1
    assert 'format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@", "iPadProviderCall", "iPadConfiguredCraft"' in body
    assert 'guard let expectedLabel = callLabels[call.identifier], call.isHittable,' in body
    assert 'call.label == expectedLabel else {' in body
    assert re.search(r'\b(tap\w*|press\w*|longPress\w*|longpress\w*)\s*\(', body) is None
    return labels

call_labels = verify_simple_call_guard(call_guard)
# 정적 입력 표 대조이며 XCUIElement 실행이나 실제 AX 재생이 아니다.
def call_guard_accepts(records, preparing=False):
    candidates = [(identifier, label, hittable) for identifier, label, hittable in records
                  if identifier.startswith(('iPadProviderCall', 'iPadConfiguredCraft'))]
    if preparing or len(candidates) != 1:
        return False
    identifier, label, hittable = candidates[0]
    return identifier in call_labels and hittable and label == call_labels[identifier]

call_guard_positive = 0
call_guard_negative = 0
for identifier, label in call_labels.items():
    record = (identifier, label, True)
    assert call_guard_accepts([record])
    call_guard_positive += 1
    for records, preparing in (([], False), ([record, record], False),
                               ([(identifier, '잘못된 라벨', True)], False),
                               ([(identifier, label, False)], False), ([record], True)):
        assert not call_guard_accepts(records, preparing)
        call_guard_negative += 1
craft = ('iPadConfiguredCraftAction', '음성 대화', True)
for records in ([('iPadProviderCallStart', '통화 시작', True), craft],
                [('iPadProviderCallStop', '통화 종료', True), craft],
                [('iPadProviderCallStart', '통화 시작', True), ('iPadProviderCallStop', '통화 종료', True)],
                [('iPadConfiguredCraftActionUnknown', '음성 대화', True)],
                [('iPadProviderCallUnknown', '통화 시작', True)],
                [('iPadUnknownAction', '음성 대화', True)],
                [craft, ('iPadConfiguredCraftActionUnknown', '음성 대화', True)],
                [craft, ('iPadProviderCallCancelPreparation', '준비 취소', True)]):
    assert not call_guard_accepts(records)
    call_guard_negative += 1
call_guard_mutations = 0
for old, new in (('"음성 대화"', '"통화 시작"'),
                 ('call.isHittable,', 'true,'),
                 ('call.label == expectedLabel', 'true'),
                 ('try unique(app.buttons.matching', 'app.buttons.matching'),
                 ('OR identifier BEGINSWITH %@', 'AND identifier BEGINSWITH %@')):
    assert old in call_guard
    try:
        verify_simple_call_guard(call_guard.replace(old, new, 1))
    except AssertionError:
        call_guard_mutations += 1
    else:
        raise AssertionError('unsafe voice guard mutation accepted: ' + new)
for operation in ('call.tap()', 'try tapChecked(call)', 'call.press(forDuration: 1)',
                  'call.longPress()', 'call.longpress()'):
    try:
        verify_simple_call_guard(call_guard + '        ' + operation + '\n')
    except AssertionError:
        call_guard_mutations += 1
    else:
        raise AssertionError('voice action insertion accepted: ' + operation)
for identifier in ('iPadCallMicrophone', 'iPadCallSpeaker'):
    assert f'app.switches.matching(identifier: "{identifier}")' in simple_controls
for expected in ('microphone.label == "마이크 사용", speaker.label == "스피커 사용", devices.label == "기기"',
                 '"iPadProviderCallCancelPreparation").count == 0',
                 '["0", "1"].contains(microphone.value as? String ?? "")',
                 '["0", "1"].contains(speaker.value as? String ?? "")',
                 '"audioRouteInput", "audioRouteOutput", "applyAudioRoutes", "applyMacAudioRoutes"',
                 'grant|packet|blackhole|동의 적용|Mac 수신 상태 확인',
                 '"controls": [call, microphone, speaker, devices].map',
                 'XCTAttachment(data: data, uniformTypeIdentifier: "public.json")'):
    assert expected in simple_controls, expected
simple08 = simple88.split('func test08ReadSimpleCallAXAndDeviceSheet()', 1)[1].split('func test09', 1)[0]
assert simple08.index('environment["CCR_CONNECTION_UI_MEDIA_APPROVED"] == "0"') < simple08.index('try existingApp()')
assert simple08.count('try existingApp()') == 1 and 'existingMediaApp' not in simple08
assert simple08.count('try tapUnique(') == 2 and 'try tapChecked(' not in simple08
assert '"iPadCallDevices", "기기"' in simple08
assert 'app.navigationBars.matching(identifier: "기기")' in simple08
assert 'sheetBar.buttons.matching(NSPredicate(format: "label == %@", "완료"))' in simple08
assert 'sheetBar.waitForNonExistence(timeout: 5)' in simple08
assert 'XCTAssertEqual' not in simple08 and '.value as? String' not in simple08
assert simple08.count('try simpleCallControls(') == 2
simple09 = simple88.split('func test09SetSimpleCallMediaToggles()', 1)[1]
pre09 = candidate_swift.split('    func test09SetSimpleCallMediaToggles()', 1)[0]
assert hashlib.sha256(pre09.encode()).hexdigest() == 'f3cb736d767c067662df73439d9016e557c0da3e99cfcddb57739d0fe39f63fb'
base37_call_guard = '''        let call = try unique(app.buttons.matching(NSPredicate(
            format: "identifier IN %@", ["iPadProviderCallStart", "iPadProviderCallStop"])))
        guard call.isHittable,
              call.label == (call.identifier == "iPadProviderCallStart" ? "통화 시작" : "통화 종료") else {
            throw NSError(domain: "ConnectionUI", code: 53)
        }
'''
assert pre09.count(call_guard) == 1
assert hashlib.sha256(pre09.replace(call_guard, base37_call_guard, 1).encode()).hexdigest() == '880e2dc3c7c4712139912ff1d3aa4fb5463542f544eeb9c6d17c6f45e6676e56'
assert hashlib.sha256(simple09.encode()).hexdigest() == '4fc8ae855bb5669c558717d4bb5e89415c509243517175b4bf32ca57fa14b18d'
assert hashlib.sha256(FILES['prepare_destination.py'].encode()).hexdigest() == '3214435c0f8e284d32758f60e3a542088019f8524c77b716fe6194d457871e45'
for expected in ('environment["CCR_CONNECTION_UI_SIMPLE_MEDIA_APPROVED"] == "1"',
                 'environment["CCR_CONNECTION_UI_SIMPLE_MEDIA_ACTION"]', '["ON", "OFF"].contains(action)'):
    assert simple09.index(expected) < simple09.index('try existingMediaApp()')
assert 'throw XCTSkip(' in simple09
assert 'existingApp()' not in simple09 and simple09.count('try existingMediaApp()') == 1
assert simple09.count('try tapChecked(') == 1 and 'try tapUnique(' not in simple09
assert 'let target = action == "ON" ? "1" : "0"' in simple09

def verify_simple09_cleanup(body):
    preflight = ('guard controls.microphone.isEnabled, controls.speaker.isEnabled,\n'
                 '              action == "OFF" || (controls.microphone.value as? String == "0" && controls.speaker.value as? String == "0") else {')
    loop = 'for control in [controls.microphone, controls.speaker] {'
    lookup = 'let toggle = try unique(app.switches.matching(identifier: control.identifier))'
    selection = 'let selected = try mediaToggle(toggle, name: "simple09-before-tap")'
    current_guard = ('guard let current = toggle.value as? String, ["0", "1"].contains(current),\n'
                     '                  current == selected.value, toggle.isEnabled, toggle.isHittable, action == "OFF" || current == "0" else {')
    tap = ('if current != target {\n'
           '                try tapChecked(selected.element)\n'
           '                captureMediaState(app, name: "simple09-after-" + toggle.identifier + "-" + action)\n'
           '            }')
    final_guard = 'guard observed.microphone.isEnabled, observed.speaker.isEnabled else {'
    helper = body.split('func mediaToggle(', 1)[1].split('        let controls =', 1)[0]
    child_lookup = 'let children = row.descendants(matching: .switch)'
    child_count = 'let count = children.count'
    count_guard = 'guard count <= 1 else {'
    leaf_selection = 'let leaf = count == 1 ? children.element(boundBy: 0) : row'
    value_guard = ('guard let current = row.value as? String, ["0", "1"].contains(current),\n'
                   '                  let leafValue = leaf.value as? String, ["0", "1"].contains(leafValue),\n'
                   '                  current == leafValue, row.isEnabled, row.isHittable, leaf.isEnabled, leaf.isHittable else {')
    for expected in (child_lookup, child_count, count_guard, leaf_selection, value_guard,
                     '"parent": snapshot(row), "childCount": count',
                     '"children": children.allElementsBoundByIndex.map { snapshot($0) }',
                     '"selectedTarget": count == 0 ? "row" : (count == 1 ? "child" : "none")',
                     '"value": element.value ?? NSNull()',
                     '"enabled": element.isEnabled, "hittable": element.isHittable',
                     '"frame": String(describing: element.frame)',
                     'ax.name = name + "-" + row.identifier + "-" + action + "-tap-target"',
                     'ax.lifetime = .keepAlways', 'return (leaf, current)'):
        assert expected in helper, expected
    assert helper.index(child_lookup) < helper.index(child_count) < helper.index('add(ax)') < helper.index(count_guard)
    assert helper.index(count_guard) < helper.index(leaf_selection) < helper.index(value_guard) < helper.index('return (leaf, current)')
    assert 'tap' not in helper.replace('-tap-target', '')
    assert helper.count('children.count') == 1 and 'firstMatch' not in helper
    for expected in (preflight, loop, lookup, selection, current_guard, tap, final_guard):
        assert expected in body, expected
    for direction in ('microphone', 'speaker'):
        initial = f'_ = try mediaToggle(controls.{direction}, name: "simple09-initial")'
        assert initial in body, initial
        assert body.index(initial) < body.index(preflight)
        final = f'let final{direction.capitalize()} = try mediaToggle(observed.{direction}, name: "simple09-final")'
        assert final in body, final
        assert body.index('Task.sleep(') < body.index(final) < body.index(final_guard)
        assert f'XCTAssertEqual(final{direction.capitalize()}.value, target)' in body
    assert body.index(preflight) < body.index(loop) < body.index(lookup) < body.index(selection) < body.index(current_guard) < body.index(tap)
    assert body.index(tap) < body.index('let settled =') < body.index('Task.sleep(') < body.index(final_guard)
    assert 'target), object: toggle)' in body and 'target), object: selected.element)' in body
    wait = 'let result = await XCTWaiter.fulfillment(of: [settled, leafSettled], timeout: 10)'
    after = '_ = try mediaToggle(toggle, name: "simple09-settled")'
    assert wait in body and after in body
    assert body.index(wait) < body.index(after) < body.index('guard result == .completed else {') < body.index('Task.sleep(')
    assert body.count('try tapChecked(') == 1 and body.count('for ') == 1
    assert re.search(r'\b(continue|catch|while)\b', body) is None
    for forbidden in ('let initial =', 'else {\n                try tap', '.tap()'):
        assert forbidden not in body, forbidden

verify_simple09_cleanup(simple09)
for old, new in (
        ('action == "OFF" || (controls.microphone.value', 'action == "ON" || (controls.microphone.value'),
        ('["0", "1"].contains(current)', '["0", "1", "unknown"].contains(current)'),
        ('toggle.isEnabled, toggle.isHittable,', 'toggle.isHittable,'),
        ('try unique(app.switches.matching(identifier: control.identifier))', 'control'),
        ('guard count <= 1 else {', 'guard count <= 2 else {'),
        ('row.descendants(matching: .switch)', 'app.switches'),
        ('count == 1 ? children.element(boundBy: 0) : row', 'row'),
        ('count == 1 ? children.element(boundBy: 0) : row', 'count > 0 ? children.element(boundBy: 0) : row'),
        ('current == leafValue, ', ''),
        ('let current = row.value as? String,', 'case let current = row.value as? String ?? "0",'),
        ('let leafValue = leaf.value as? String,', 'case let leafValue = leaf.value as? String ?? "0",'),
        ('["0", "1"].contains(leafValue)', '["0", "1", "unknown"].contains(leafValue)'),
        ('row.isEnabled, ', ''),
        ('row.isHittable, ', ''),
        ('leaf.isEnabled, ', ''),
        ('leaf.isHittable else {', 'true else {'),
        ('current == selected.value, ', ''),
        ('"parent": snapshot(row)', '"parent": [:]'),
        ('"children": children.allElementsBoundByIndex.map { snapshot($0) }', '"children": []'),
        ('_ = try mediaToggle(controls.speaker, name: "simple09-initial")', ''),
        ('of: [settled, leafSettled]', 'of: [settled]'),
        ('_ = try mediaToggle(toggle, name: "simple09-settled")', ''),
        ('XCTAssertEqual(finalSpeaker.value, target)', ''),
        ('if current != target {', 'if true {'),
        ('if current != target {', 'if current == target {'),
        ('try tapChecked(selected.element)', 'try tapChecked(toggle)'),
        ('try tapChecked(selected.element)', 'try tapChecked(selected.element)\n                try tapChecked(selected.element)'),
        ('guard observed.microphone.isEnabled, observed.speaker.isEnabled else {', 'guard true else {')):
    assert old in simple09
    try:
        verify_simple09_cleanup(simple09.replace(old, new, 1))
    except AssertionError:
        pass
    else:
        raise AssertionError(f'unsafe test09 body accepted: {new}')
assert 'defer { captureMediaState(app, name: "simple09-final-observation") }' in simple09
assert 'await XCTWaiter.fulfillment(of: [settled, leafSettled], timeout: 10)' in simple09
assert 'value == %@ AND enabled == true AND hittable == true' in simple09
assert simple09.index('try tapChecked(selected.element)') < simple09.index('XCTWaiter.fulfillment(') < simple09.index('Task.sleep(')
assert 'XCTAssertEqual(observed.microphone.value as? String, target)' in simple09
assert 'XCTAssertEqual(observed.speaker.value as? String, target)' in simple09
assert 'iPadProviderCall' not in simple09 and 'iPadCallDevices' not in simple09
assert simple09.count('try openSimpleCall(app)') == 1

simple08_contract = namespace['prepare'](seed, test08_only=True)['ConnectionUITests']
assert simple08_contract['OnlyTestIdentifiers'] == ['ConnectionUITests/test08ReadSimpleCallAXAndDeviceSheet']
assert {k: v for k, v in simple08_contract.items() if k != 'OnlyTestIdentifiers'} == {
    k: v for k, v in result.items() if k != 'OnlyTestIdentifiers'}
simple09_contract = namespace['prepare'](seed, test09_media_only=True)['ConnectionUITests']
assert simple09_contract['OnlyTestIdentifiers'] == ['ConnectionUITests/test09SetSimpleCallMediaToggles']
assert simple09_contract['EnvironmentVariables'] == dict(result['EnvironmentVariables'],
    CCR_CONNECTION_UI_SIMPLE_MEDIA_APPROVED='0', CCR_CONNECTION_UI_SIMPLE_MEDIA_ACTION='')
assert {k: v for k, v in simple09_contract.items() if k not in ('OnlyTestIdentifiers', 'EnvironmentVariables')} == {
    k: v for k, v in result.items() if k not in ('OnlyTestIdentifiers', 'EnvironmentVariables')}
from itertools import combinations
for first, second in combinations(('test05_only', 'test06_only', 'recover07_only', 'test08_only', 'test09_media_only'), 2):
    try:
        namespace['prepare'](seed, **{first: True, second: True})
    except ValueError:
        pass
    else:
        raise AssertionError(f'mixed selection accepted: {first}, {second}')
for mode in ('--test08-only', '--test09-media-only'):
    assert f"selection.add_argument('{mode}', action='store_true')" in FILES['prepare_destination.py']
assert plistlib.loads(plistlib.dumps(simple09_contract)) == simple09_contract
print(json.dumps({'staticAccepted': True, 'deviceExecuted': False, 'popupReplay': popup_replay,
                  'callGuardStatic': {'positive': call_guard_positive, 'negative': call_guard_negative,
                                      'sourceMutationsRejected': call_guard_mutations},
                  'sha256': {k: hashlib.sha256(v.encode()).hexdigest()
                             for k, v in sorted(FILES.items())}}, sort_keys=True))
