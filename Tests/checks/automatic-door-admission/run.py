import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
host = root / 'Sources/SillHost'
files = [host / name for name in ['Door.swift', 'AutomaticDevicePrincipal.swift', 'AutomaticSessionAuthorization.swift']]
files += [here / 'Main.swift', Path(__file__)]
before = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
text = files[0].read_text()
start = text.index('private func automaticResolved(')
opening = text.index('{', start)
end, depth = opening + 1, 1
while depth:
    depth += (text[end] == '{') - (text[end] == '}'); end += 1
method = text[start:end].replace('private func', 'func', 1)
with tempfile.TemporaryDirectory(prefix='automatic-door-') as temporary:
    scratch = Path(temporary)
    fixture = scratch / 'Main.swift'
    fixture.write_text((here / 'Main.swift').read_text().replace('    // METHOD', method))
    binary = scratch / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(scratch / 'cache'),
        str(files[1]), str(files[2]), str(fixture), '-o', str(binary)], check=True, timeout=180)
    subprocess.run([str(binary)], check=True, timeout=30)
assert all(hashlib.sha256((root / name).read_bytes()).hexdigest() == digest for name, digest in before.items())
print(json.dumps({'passed': True, 'sourceHashes': before, 'sourceUnchanged': True, 'scratchRemoved': not scratch.exists(),
                  'physicalActions': 0}))
