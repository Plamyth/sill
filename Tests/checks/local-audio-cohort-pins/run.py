import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import re
import subprocess
import tempfile


parser = argparse.ArgumentParser(description='실행 불가능한 fixture로 오디오 closure 핀과 거절 경계를 검사한다.')
parser.add_argument('--fixture', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[3]
package = args.fixture.resolve(strict=True)
output = args.output.resolve(strict=True)
manifest_path = package / 'manifest.json'
original = manifest_path.read_bytes()
manifest = json.loads(original)
fixture_modes = {e['path']: (package / 'runtime' / e['path']).stat().st_mode & 0o7777
                 for e in manifest['entries']}
for entry in manifest['entries']:
    (package / 'runtime' / entry['path']).chmod(entry['mode'])
host = root / 'Sources/SillHost'
paths = [host / name for name in ['LocalAudioRelayLaunch.swift', 'LocalAudioRelayClosure.swift',
                                 'LocalAudioRelayMachO.swift']]
packager = root / 'Scripts/package-local-audio-runtime.py'
before = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths + [packager]}
spec = importlib.util.spec_from_file_location('packager', packager)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
expected = dict(re.findall(r'"(server/[^\"]+)": "([a-f0-9]{64})"', paths[1].read_text()))
assert len(expected) == 24
assert manifest['nodeSourceCommit'] == module.NODE_COMMIT == 'd0df44d788574ee5393d846f03aeadffc1eee318'
assert module.NODE_TREE == '63ceb6b15d785b31b8b05c74a61b640a706dbaa6'
assert {e['path']: e['sha256'] for e in manifest['entries']
        if e['kind'] == 'file' and e['path'].startswith('server/')} == expected
source = paths[0].read_text().split('\nstruct LocalAudioRelayInvocation {', 1)[0]
source += '''
@main struct Check {
    static func main() {
        do {
            let inventory = try LocalAudioRelayInventory.capture(package: URL(fileURLWithPath: CommandLine.arguments[1]))
            try LocalAudioRelayClosure.validate(inventory)
            try inventory.recheck()
            print("accepted")
        } catch { print("rejected: \\(error)") }
    }
}
'''
checks = []
with tempfile.TemporaryDirectory(prefix='cohort-pins-', dir=output) as temporary:
    scratch = Path(temporary)
    fixture = scratch / 'Inventory.swift'
    fixture.write_text(source)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(scratch / 'cache'),
                    str(fixture), str(paths[1]), str(paths[2]), '-o', str(scratch / 'check')], check=True)

    def check(name, accepted):
        swift = subprocess.check_output([str(scratch / 'check'), str(package)], text=True).strip()
        if accepted:
            assert swift == 'accepted', (name, swift)
        else:
            assert swift.startswith('rejected: '), (name, swift)
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                module.verify(package)
            python = True
        except AssertionError:
            python = False
        assert python == accepted, (name, python)
        checks.append(name)

    try:
        check('exact-24-module-cohort', True)
        for name in sorted(expected):
            path = package / 'runtime' / name
            data = path.read_bytes()
            try:
                path.write_bytes(data + b'\n')
                changed = json.loads(original)
                entry = next(e for e in changed['entries'] if e['path'] == name)
                entry.update(size=path.stat().st_size, sha256=hashlib.sha256(path.read_bytes()).hexdigest())
                manifest_path.write_text(json.dumps(changed))
                check('wrong-hash:' + name, False)
            finally:
                path.write_bytes(data)
                manifest_path.write_bytes(original)
            try:
                path.unlink()
                changed = json.loads(original)
                changed['entries'] = [e for e in changed['entries'] if e['path'] != name]
                changed['dependencies'] = [e for e in changed['dependencies'] if e['source'] != name]
                manifest_path.write_text(json.dumps(changed))
                check('missing:' + name, False)
            finally:
                path.write_bytes(data)
                path.chmod(0o644)
                manifest_path.write_bytes(original)
        extra = package / 'runtime/server/unexpected.js'
        try:
            extra.write_bytes(b'inert\n')
            extra.chmod(0o644)
            check('undeclared-extra-module', False)
            changed = json.loads(original)
            changed['entries'].append(dict(path='server/unexpected.js', kind='file', mode=0o644,
                                          size=extra.stat().st_size, sha256=hashlib.sha256(extra.read_bytes()).hexdigest()))
            changed['dependencies'].append(dict(source='server/unexpected.js', bundled=[], system=[]))
            manifest_path.write_text(json.dumps(changed))
            check('declared-extra-module', False)
        finally:
            extra.unlink()
            manifest_path.write_bytes(original)
        try:
            changed = json.loads(original)
            changed['nodeSourceCommit'] = '0bec7a9970b0bd4e15390012b8ade02ed54605c2'
            manifest_path.write_text(json.dumps(changed))
            check('stale-node-pin', False)
        finally:
            manifest_path.write_bytes(original)
        check('restored-exact-cohort', True)
    finally:
        manifest_path.write_bytes(original)
assert before == {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths + [packager]}
result = dict(passed=True, checks=checks, checksPerValidator=len(checks), validators=['Swift', 'Python'],
              fixtureModesRestored=sum(fixture_modes[e['path']] != e['mode'] for e in manifest['entries']),
              nodeSourceCommit=module.NODE_COMMIT, nodeSourceTree=module.NODE_TREE, sourceHashes=before,
              sourceUnchanged=True, scratchRemoved=not scratch.exists(), fixtureOnly=True,
              fullPackageCreated=False, serverStarted=False, audioOpened=False, installed=False)
(output / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(result, ensure_ascii=False))
