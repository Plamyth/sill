import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
output = Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=False)
scratch = output / 'scratch'
scratch.mkdir()
protocol = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
host = [root / 'Sources/SillHost' / name for name in ['OriginPolicy.swift', 'CableLink.swift', 'AutomaticLocalAccess.swift']]
main = Path(__file__).with_name('Main.swift')
sources = protocol + host + [main, Path(__file__)]
before = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
record = {'sourceHashes': before, 'hardwareOrDeviceActions': 0, 'passed': False, 'commands': []}
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
base = ['xcrun', 'swiftc', '-module-cache-path', str(scratch / 'cache')]
commands = [base + ['-emit-library', '-emit-module', '-module-name', 'StreamProtocol', *map(str, protocol),
                    '-o', str(scratch / 'libStreamProtocol.dylib'), '-emit-module-path', str(scratch / 'StreamProtocol.swiftmodule')],
            base + ['-parse-as-library', '-I', str(scratch), '-L', str(scratch), '-lStreamProtocol',
                    '-Xlinker', '-rpath', '-Xlinker', str(scratch), *map(str, host), str(main), '-o', str(scratch / 'checks')],
            [str(scratch / 'checks')]]
try:
    for index, command in enumerate(commands):
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=180)
        (output / f'{index}.log').write_text(result.stdout + result.stderr)
        record['commands'].append({'exitCode': result.returncode})
        if result.returncode:
            print(result.stdout + result.stderr)
            break
    else:
        record['passed'] = True
finally:
    record['sourceUnchanged'] = all(hashlib.sha256((root / name).read_bytes()).hexdigest() == digest for name, digest in before.items())
    shutil.rmtree(scratch)
    record['outputRemoved'] = not scratch.exists()
    (output / 'result.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({k: v for k, v in record.items() if k != 'sourceHashes'}, ensure_ascii=False))
raise SystemExit(0 if record['passed'] and record['sourceUnchanged'] and record['outputRemoved'] else 1)
