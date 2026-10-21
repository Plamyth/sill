import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

here = Path(__file__).resolve().parent
root = here.parents[2]
production = root / 'Sources/SillMenuBar/AppModel.swift'
inputs = [production, here / 'Main.swift', Path(__file__).resolve()]
before = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}

def block(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}'); end += 1
    return text[start:end].replace('private func', 'func', 1)

source = production.read_text()
methods = [block(source, marker) for marker in ['func requestLocalAudioReturn(', 'private func recordLocalAudioReturn(']]
with tempfile.TemporaryDirectory(prefix='local-return-request-') as temporary:
    out = Path(temporary)
    fixture = out / 'Main.swift'
    fixture.write_text((here / 'Main.swift').read_text().replace('// METHODS', '\n'.join(methods)))
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(out / 'cache'),
                    str(fixture), '-o', str(out / 'checks')], check=True, timeout=120)
    subprocess.run([str(out / 'checks')], check=True, timeout=30)
assert all(hashlib.sha256((root / name).read_bytes()).hexdigest() == value for name, value in before.items())
print(json.dumps({'sourceHashes': before, 'sourceUnchanged': True, 'scratchRemoved': not out.exists(), 'actualMediaOrDeviceActions': 0}))
