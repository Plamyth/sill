"""Parent-only inert participant suite. Usage: python3 -B run.py ROOT OUTPUT."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root, output = [Path(value).resolve() for value in sys.argv[1:3]]
if output == root or root in output.parents or (output.exists() and (not output.is_dir() or any(output.iterdir()))):
    raise SystemExit('OUTPUT must be an empty parent-owned isolated directory outside ROOT')
here = root / 'Tests/checks/local-audio-participants'
record = {'scope': 'Actual native Codable, registry, Host request, startup and extracted coordinator with injected HAL/transport; no OS auth, HAL, network, installed app or device acceptance',
          'commands': [], 'exitCode': 2}
output.mkdir(parents=True, exist_ok=True)
package = output / 'package'
try:
    subprocess.run([sys.executable, '-B', str(root / 'Tests/checks/host-audio-privacy/emit.py'), '--output', str(package)], check=True, timeout=20)
    target = package / 'Sources/HostPrivacyChecks'
    (target / 'ParticipantChecks.swift').write_bytes((here / 'ParticipantChecks.swift').read_bytes())
    main = target / 'Main.swift'
    text = main.read_text()
    anchor = '    @MainActor static func main() async {'
    assert text.count(anchor) == 1
    text = text.replace(anchor, anchor + '''
        do { if try participantInterop() { return } }
        catch { fputs("Participant interop rejected: \\(error)\\n", stderr); exit(1) }
        await participantChecks()
''')
    main.write_text(text)
    manifest = {str(path.relative_to(package)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in package.rglob('*') if path.is_file()}
    record['inputsSHA256'] = manifest
    for name in ['tmp', 'module-cache', 'clang-cache', 'spm-cache', 'spm-config', 'spm-security']:
        (output / name).mkdir(exist_ok=True)
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1', TMPDIR=str(output / 'tmp'),
               SWIFTPM_MODULECACHE_OVERRIDE=str(output / 'module-cache'), CLANG_MODULE_CACHE_PATH=str(output / 'clang-cache'))
    command = ['/usr/bin/xcrun', 'swift', 'run', '--package-path', str(package),
               '--scratch-path', str(output / 'swiftpm'), '--cache-path', str(output / 'spm-cache'),
               '--config-path', str(output / 'spm-config'), '--security-path', str(output / 'spm-security'),
               '--manifest-cache', 'local', '--disable-dependency-cache', '--disable-netrc', '--disable-keychain',
               '--jobs', '1', 'HostPrivacyChecks']
    try:
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=240, env=env)
        log, code = result.stdout, result.returncode
    except subprocess.TimeoutExpired as error:
        log, code = error.stdout or b'', 124
    (output / 'checks.log').write_bytes(log)
    sys.stdout.buffer.write(log)
    record['commands'].append({'command': command, 'exitCode': code})
    record['sourceUnchanged'] = all(hashlib.sha256((package / name).read_bytes()).hexdigest() == sha for name, sha in manifest.items())
    record['passedAssertions'] = sum(line.startswith(b'PASS ') for line in log.splitlines())
    record['completed'] = b'Host audio privacy: all injected checks passed; no native hardware calls' in log
    record['fixtureExecutable'] = str(output / 'swiftpm/debug/HostPrivacyChecks')
    record['fixtureCommands'] = ['--emit-request REQUEST_JSON S23_BOOT_UUID', '--read-receipt REQUEST_JSON RECEIPT_JSON']
    record['exitCode'] = 0 if code == 0 and record['completed'] and record['sourceUnchanged'] else code or 2
except Exception as error:
    record['error'] = str(error)
(output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
print('SUITE_RESULT ' + json.dumps(record, sort_keys=True), flush=True)
raise SystemExit(record['exitCode'])
