"""정확한 Git 서버 소스와 코드 없는 Mach-O object로 검사 입력만 만든다."""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import struct
import subprocess


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--node-repo', type=Path, required=True)
parser.add_argument('--sounddevice', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('packager', root / 'Scripts/package-local-audio-runtime.py')
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


def git(*parts):
    return subprocess.check_output(['git', '-C', str(args.node_repo), *parts])


assert git('rev-parse', packager.NODE_COMMIT + '^{tree}').decode().strip() == packager.NODE_TREE
pins = dict(re.findall(r'"(server/[^\"]+)": "([a-f0-9]{64})"',
                      (root / 'Sources/SillHost/LocalAudioRelayClosure.swift').read_text()))
names = git('ls-tree', '--name-only', packager.NODE_COMMIT, 'server/').decode().splitlines()
assert len(pins) == 24 and set(pins) == {p for p in names if p.endswith(('.js', '.py'))}
files = {name: git('show', packager.NODE_COMMIT + ':' + name) for name in pins}
assert {name: hashlib.sha256(data).hexdigest() for name, data in files.items()} == pins
sounddevice = args.sounddevice.read_bytes()
assert hashlib.sha256(sounddevice).hexdigest() == '6336351c4771da61a3039f0aeb603da4d975d7b4525d56224016389433ccde34'
files['python/lib/python3.13/site-packages/sounddevice.py'] = sounddevice
native = ['node/bin/node', 'python/bin/python3.13', 'python/Python',
          'python/lib/python3.13/site-packages/_cffi_backend.cpython-313-darwin.so',
          'python/lib/python3.13/site-packages/_sounddevice_data/portaudio-binaries/libportaudio.dylib']
for name in native:
    files[name] = struct.pack('<8I', 0xfeedfacf, 0x0100000c, 0, 1, 0, 0, 0, 0)
package = args.output.resolve()
package.mkdir(parents=True, exist_ok=False)
runtime = package / 'runtime'
for name, data in files.items():
    path = runtime / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    path.chmod(0o755 if name in native[:2] else 0o644)
entries, dependencies = [], []
for path in sorted(runtime.rglob('*')):
    name = str(path.relative_to(runtime))
    if path.is_dir():
        path.chmod(0o755)
    entry = dict(path=name, kind='directory' if path.is_dir() else 'file', mode=path.stat().st_mode & 0o7777)
    if path.is_file():
        entry.update(size=path.stat().st_size, sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        dependencies.append(dict(source=name, bundled=[], system=[]))
    entries.append(entry)
manifest = dict(schemaVersion=1, runtimeABI='native-audio-forwarding-stdio-v3',
                nodeSourceCommit=packager.NODE_COMMIT, port=17648, entries=entries, dependencies=dependencies)
(package / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(dict(fixtureOnly=True, nativeObjectsHaveNoCode=True, serverModules=len(pins),
                      nodeSourceCommit=packager.NODE_COMMIT, nodeSourceTree=packager.NODE_TREE,
                      serverStarted=False, audioOpened=False)))
