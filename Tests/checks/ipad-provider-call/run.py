"""기기·Host·오디오 변경 없이 순수 모델과 실제 어댑터 본문을 검사한다."""
from pathlib import Path
import hashlib
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
protocol = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
inputs = protocol + sorted((root / 'iOSClient').glob('*.swift')) + sorted(Path(__file__).parent.glob('*'))
inputs = [p for p in inputs if p.is_file()]
hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}

def run(args):
    subprocess.run(list(map(str, args)), check=True, cwd=root, timeout=240)

with tempfile.TemporaryDirectory(prefix='ipad-provider-call-', dir=root) as temporary:
    out = Path(temporary)
    flags = ['-module-cache-path', out / 'cache']
    run(['xcrun', 'swiftc', *flags, '-emit-library', '-emit-module', '-module-name', 'StreamProtocol',
         *protocol, '-o', out / 'libStreamProtocol.dylib', '-emit-module-path', out / 'StreamProtocol.swiftmodule'])
    link = ['-I', out, '-L', out, '-lStreamProtocol', '-Xlinker', '-rpath', '-Xlinker', out]
    run(['xcrun', 'swiftc', *flags, *link, root / 'iOSClient/IPadProviderCall.swift',
         Path(__file__).with_name('main.swift'), '-o', out / 'model'])
    run([out / 'model', Path(__file__).with_name('vectors.json')])
    run(['xcrun', 'swiftc', *flags, *link, root / 'iOSClient/IPadDesiredAudio.swift',
         root / 'iOSClient/IPadAudioForwarding.swift', root / 'Tests/checks/ipad-audio-forwarding/main.swift', '-o', out / 'forwarding'])
    run([out / 'forwarding'])
    run(['python3', '-B', root / 'Tests/checks/ipad-audio-forwarding/adapter.py', out])
    run(['python3', '-B', root / 'Tests/checks/ipad-audio-forwarding/adapter.py', out,
         Path(__file__).with_name('adapter-main.swift')])
    run(['python3', '-B', root / 'Tests/checks/ipad-audio-admission/run.py', out])
assert hashes == {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
print('SOURCE_UNCHANGED=true; SCRATCH_REMOVED=' + str(not out.exists()).lower())
