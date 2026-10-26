"""합성 메타데이터와 버퍼만 검사하며 기기·엔진·권한·네트워크는 실행하지 않는다."""
from pathlib import Path
import os, subprocess, sys
root = Path(__file__).resolve().parents[3]
out = Path(sys.argv[1]).resolve(); out.mkdir(parents=True, exist_ok=True)
base = root/'.audit/audio-metadata-baseline.swift'
if base.exists(): source = base.read_text()
else: source = subprocess.check_output(['git','show','14e941099ca5d27bb4c1df171849d601a14a1455:iOSClient/IPadMicrophoneCapture.swift'],cwd=root,text=True)
source = source.replace('IPadMicrophoneDiagnostics','BaselineMicrophoneDiagnostics').replace('IPadMicrophoneConversionWorker','BaselineMicrophoneConversionWorker')
(out/'Baseline.swift').write_text(source)
flags = ['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(out/'cache')]
files = [str(root/'iOSClient'/name) for name in ['IPadMicrophonePCM.swift','IPadMicrophoneCapture.swift']]
def run(args): subprocess.run(args,check=True)
run(flags+files+[str(Path(__file__).with_name('main.swift')),'-o',str(out/'metadata')])
run([str(out/'metadata'),str(out)])
run(flags+files+[str(out/'Baseline.swift'),str(Path(__file__).with_name('raw-byte.swift')),'-o',str(out/'bytes')])
run([str(out/'bytes')])

decoder = (root/'iOSClient/RemoteAudioPlayer.swift').read_text().split('private final class RemoteAACDecoder')[1]
(out/'AACImplementation.swift').write_text('import AVFoundation\nimport Foundation\nfinal class RemoteAACDecoder'+decoder)
run(flags+files+[str(out/'AACImplementation.swift'),str(Path(__file__).with_name('decoder.swift')),'-o',str(out/'decoder')])
run([str(out/'decoder'),str(out)])
