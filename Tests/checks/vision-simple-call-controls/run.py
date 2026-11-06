"""Vision 통화 UI 구조와 순수 표시 상태 검사. 앱·기기·미디어 실행 없음."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
view = (root / 'visionOSClient/SillVisionApp.swift').read_text()
panels = sum(view.count('                ' + name + '(') for name in
             ['VisionAudioControls', 'VisionMicrophoneControls', 'VisionCallControls'])
checks = {
    'one integrated audio control surface': panels == 1 and 'private struct VisionCallControls:' in view,
    'no automatic media or device offers': all(name not in view for name in
        ['audioOfferShown', 'audioOfferScope', 'macAudioOfferShown', 'offerMacAudioChooser']),
    'native call is the main path without provider picker': '통화 제어 대상' not in view and 'VisionCallTarget.allCases' not in view,
    'device chooser is still explicitly reachable': 'openMacAudioChooser' in view and 'VisionMacAudioChooser(' in view,
    'input ownership and existing media intent remain': 'withWindowOwnership' in view and
        'setVisionAudioDesired' in view and 'direction: .microphone' in view and 'direction: .playback' in view,
}
for name, passed in checks.items():
    print(('PASS ' if passed else 'FAIL ') + name, flush=True)
if not all(checks.values()):
    raise SystemExit(f'Audio control panels observed={panels}; expected one unified surface without automatic offers')

if '--static-only' not in sys.argv:
    subprocess.run(['python3', '-B', str(root / 'Tests/checks/vision-provider-call/run.py')], check=True)
