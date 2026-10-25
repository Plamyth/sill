"""생성기가 두 Vision 대상의 인증 소스와 운영 대상 리소스 단계를 보존하는지 확인한다."""
import contextlib
import io
import plistlib
from pathlib import Path
import tempfile
ROOT=Path(__file__).resolve().parents[3]
script=ROOT/'Scripts/make-vision-project.py'
source=script.read_text()
anchor='ROOT = Path(__file__).resolve().parent.parent'
assert source.count(anchor)==1
with tempfile.TemporaryDirectory(prefix='vision-project-') as folder:
    with contextlib.redirect_stdout(io.StringIO()):
        exec(compile(source.replace(anchor, 'ROOT = Path('+repr(folder)+')'),str(script),'exec'),{'__file__':str(script)})
    generated=Path(folder)/'SillVision.xcodeproj/project.pbxproj'
    assert generated.read_bytes()==(ROOT/'SillVision.xcodeproj/project.pbxproj').read_bytes()
    objects=plistlib.loads(generated.read_bytes())['objects']
    targets={v['name']:v for v in objects.values() if v.get('isa')=='PBXNativeTarget'}
    needed={'iOSClient/OwnerBootstrapState.swift','iOSClient/OwnerBootstrapExchange.swift','visionOSClient/StreamClient+VisionOwnerBootstrap.swift'}
    needed.update('iOSClient/'+name+'.swift' for name in ['IPadDeviceEnrollment','IPadEnrollmentJSON','IPadEnrollmentProtocol','IPadEnrollmentStore','IPadEnrollmentTransport','StreamClient+OwnerEnrollment'])
    for name in ['SillVision','SillVisionReleaseTest']:
        target=targets[name]
        phases=[objects[key] for key in target['buildPhases']]
        sources=next(p for p in phases if p['isa']=='PBXSourcesBuildPhase')
        paths={objects[objects[key]['fileRef']]['path'] for key in sources['files']}
        assert needed<=paths
        owner=[p for p in phases if p.get('name')=='소유 Mac 공개 연결 설정']
        assert len(owner)==(1 if name=='SillVision' else 0)
        for key in objects[target['buildConfigurationList']]['buildConfigurations']:
            assert objects[key]['buildSettings']['ENABLE_USER_SCRIPT_SANDBOXING']=='YES'
print('PASS 7 generated Vision project and resource isolation checks')
