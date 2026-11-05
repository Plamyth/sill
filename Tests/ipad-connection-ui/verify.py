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
assert swift.count('.tap()') == 2
assert swift.count('try tapUnique(') == 5
assert 'guard element.isHittable' in swift
assert 'if audio.count == 1, audio.firstMatch.isHittable' in swift
assert 'identifier: "workspaceOverflow"' in swift
assert 'menuAction(app, label: "설정")' in swift
assert '"openAudioRoutes", "오디오 입력·출력 선택…"' in swift
assert swift.count('toggle.tap()') == 1
assert swift.count('try ensureToolbarVisible(app)') == 2
assert 'identifier: "iPadToolbarToggle"' in swift
assert 'toggle.label == "상단 메뉴 표시", toggle.isHittable' in swift
assert '상단 메뉴 숨기기' in swift
assert 'XCTWaiter.wait(for: [reflected], timeout: 2)' in swift
assert swift.count('.activate()') == 1
assert 'func test01ReadDefaultMonitorAX()' in swift
assert 'func test02OpenNativeAudioChooserOnly()' in swift
assert swift.count('func test') == 2
for token in ('.launch(', '.terminate(', 'launchArguments', 'launchEnvironment',
              'coordinate(', 'typeText(', 'press(', 'swipe', 'adjust(', 'springboard'):
    assert token not in swift, token
assert 'CCR_CONNECTION_UI_APPROVED' in swift
import re
audio_gate = re.search(
    r'guard ProcessInfo.processInfo.environment\["CCR_CONNECTION_UI_AUDIO_OFF_VERIFIED"\] == "1" else \{\s*throw XCTSkip\([^\n]+\)\s*\}', swift)
assert audio_gate is not None
assert audio_gate.end() < swift.index('let app = XCUIApplication(') < swift.index('app.activate()')
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
                             'CCR_CONNECTION_UI_AUDIO_OFF_VERIFIED': '1'}}}
result = namespace['prepare'](seed)['ConnectionUITests']
assert result['UseDestinationArtifacts'] is True
assert result['UseUITargetAppProvidedByTests'] is True
assert result['UITargetAppBundleIdentifier'] == 'com.ambrion.sillcanvas.ipad'
assert result['EnvironmentVariables'] == {
    'CCR_CONNECTION_UI_APPROVED': '0',
    'CCR_CONNECTION_UI_AUDIO_OFF_VERIFIED': '0',
}
for key in ('TestHostPath', 'TestBundlePath', 'UITargetAppPath', 'DependentProductPaths',
            'UITargetAppCommandLineArguments', 'UITargetAppEnvironmentVariables'):
    assert key not in result
assert plistlib.loads(plistlib.dumps(result)) == result
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
