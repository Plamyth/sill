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
swift = FILES['ConnectionUITests.swift']
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
    assert token not in swift, token
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
                             'CCR_CONNECTION_UI_MEDIA_APPROVED': '1'}}}
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
bad = dict(seed, ConnectionUITests=dict(seed['ConnectionUITests'], TestHostBundleIdentifier='other'))
try:
    namespace['prepare'](bad)
except AssertionError:
    pass
else:
    raise AssertionError('runner identity mismatch accepted')
print(json.dumps({'staticAccepted': True, 'deviceExecuted': False,
                  'sha256': {k: hashlib.sha256(v.encode()).hexdigest()
                             for k, v in sorted(FILES.items())}}, sort_keys=True))
