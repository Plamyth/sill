from pathlib import Path
import hashlib
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
sources = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
client = root / 'visionOSClient/VisionProviderCall.swift'
test = Path(__file__).with_name('main.swift')
inputs = sources + [client, test]
before = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
with tempfile.TemporaryDirectory(prefix='vision-provider-call-') as temporary:
    out = Path(temporary)
    swift = ['xcrun', 'swiftc', '-package-name', 'Sill', '-module-cache-path', str(out/'cache')]
    subprocess.run(swift + ['-emit-module', '-emit-library', '-module-name', 'StreamProtocol',
        *map(str, sources), '-o', str(out/'libStreamProtocol.dylib'),
        '-emit-module-path', str(out/'StreamProtocol.swiftmodule')], check=True)
    subprocess.run(swift + ['-I', str(out), '-L', str(out), '-lStreamProtocol', str(client), str(test),
        '-o', str(out/'checks')], check=True)
    subprocess.run([str(out/'checks')], env={**os.environ, 'DYLD_LIBRARY_PATH': str(out)}, check=True)
assert before == {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
print('SOURCE_UNCHANGED=true; SCRATCH_REMOVED=' + str(not out.exists()).lower())
