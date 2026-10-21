import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

here = Path(__file__).resolve().parent
root = here.parents[2]
production = root / 'Sources/SillHost/HostSentryPlatform.swift'
inputs = [production, here / 'Main.swift', Path(__file__).resolve()]
before = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
source = production.read_text()
start = source.index('let timer = Timer(timeInterval: 0.5, repeats: true)')
end = source.index('\n        self.timer = timer', start)
callback = source[start:end]
def block(marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}'); end += 1
    return source[start:end].replace('private func', 'func', 1)
methods = '\n'.join(block(marker) for marker in ['private func invalidate(', 'private func environmentChanged(', 'private func requestRecovery('])
with tempfile.TemporaryDirectory(prefix='sentry-timer-') as temporary:
    out = Path(temporary)
    fixture = out / 'Main.swift'
    fixture.write_text((here / 'Main.swift').read_text().replace('// TIMER', callback).replace('// METHODS', methods))
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(out / 'cache'), str(fixture), '-o', str(out / 'checks')], check=True, timeout=120)
    subprocess.run([str(out / 'checks')], check=True, timeout=30)
assert all(hashlib.sha256((root / n).read_bytes()).hexdigest() == v for n, v in before.items())
print(json.dumps({'sourceHashes': before, 'sourceUnchanged': True, 'scratchRemoved': not out.exists(), 'actualMediaOrDeviceActions': 0}))
