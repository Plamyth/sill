"""빌드된 runner의 xctestrun만 변환합니다. 설치·실행은 수행하지 않습니다."""
import argparse
import plistlib
from pathlib import Path


def prepare(source, test05_only=False):
    assert source['__xctestrun_metadata__']['FormatVersion'] == 1
    assert set(source) == {'ConnectionUITests', '__xctestrun_metadata__'}
    original = source['ConnectionUITests']
    assert original['TestHostBundleIdentifier'] == 'com.ambrion.rea.appaudit.UITests.xctrunner'
    assert original['UseUITargetAppProvidedByTests'] is True
    assert original['IsUITestBundle'] is True
    assert original['TestBundlePath'] == '__TESTHOST__/PlugIns/ConnectionUITests.xctest'
    target = {key: original[key] for key in (
        'BlueprintName', 'ProductModuleName', 'IsUITestBundle',
        'IsXCTRunnerHostedTestBundle', 'TestHostBundleIdentifier',
        'UseUITargetAppProvidedByTests', 'TestingEnvironmentVariables')}
    target.update({
        'UseDestinationArtifacts': True,
        'TestBundleDestinationRelativePath': '__TESTHOST__/PlugIns/ConnectionUITests.xctest',
        'UITargetAppBundleIdentifier': 'com.ambrion.sillcanvas.ipad',
        'EnvironmentVariables': {
            'CCR_CONNECTION_UI_APPROVED': '0',
            'CCR_CONNECTION_UI_AUDIO_OFF_VERIFIED': '0',
            'CCR_CONNECTION_UI_MEDIA_APPROVED': '0',
        },
        'OnlyTestIdentifiers': [
            'ConnectionUITests/test01ReadDefaultMonitorAX',
            'ConnectionUITests/test02OpenNativeAudioChooserOnly'],
        'SystemAttachmentLifetime': 'deleteOnSuccess',
        'UserAttachmentLifetime': 'keepAlways',
        'PreferredScreenCaptureFormat': 'screenshots',
        'TestTimeoutsEnabled': True,
        'DefaultTestExecutionTimeAllowance': 60,
        'MaximumTestExecutionTimeAllowance': 90,
        'ParallelizationEnabled': False,
    })
    if test05_only:
        target['OnlyTestIdentifiers'] = ['ConnectionUITests/test05ReadMonitorMenuAX']
    return {'ConnectionUITests': target,
            '__xctestrun_metadata__': source['__xctestrun_metadata__']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('generated', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--test05-only', action='store_true')
    args = parser.parse_args()
    data = prepare(plistlib.loads(args.generated.read_bytes()), test05_only=args.test05_only)
    with args.output.open('xb') as output:
        plistlib.dump(data, output, sort_keys=True)
    assert plistlib.loads(args.output.read_bytes()) == data
    print(args.output)
