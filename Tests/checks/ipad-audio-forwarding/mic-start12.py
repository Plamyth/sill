"""실제 타이머와 추출 어댑터. 공통 lease 시계는 고정해 독립된 mic/playback 기한만 검사한다."""
from pathlib import Path
import subprocess,tempfile

root=Path(__file__).resolve().parents[3]
here=Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='mic-start12-') as folder:
    out=Path(folder).resolve()
    subprocess.run(['sh',str(here/'run.sh'),str(out)],check=True,cwd=root)
    subprocess.run(['python3','-B',str(here/'adapter.py'),str(out)],check=True)
    for mode in ['microphone-timers-legacy','microphone-timers']:
        subprocess.run(['python3','-B',str(here/'adapter.py'),str(out),str(here/'mic-start12.swift'),mode],check=True)
    subprocess.run(['xcrun','swiftc','-module-cache-path',str(out/'cache'),'-I',str(out),'-L',str(out),'-lStreamProtocol',
                    '-Xlinker','-rpath','-Xlinker',str(out),str(root/'iOSClient/IPadMicrophonePolicy.swift'),
                    str(root/'Tests/checks/ipad-microphone-control/main.swift'),'-o',str(out/'mic-policy')],check=True)
    subprocess.run([str(out/'mic-policy')],check=True)
print('scratchRemoved='+str(not out.exists()).lower())
