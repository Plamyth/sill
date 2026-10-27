"""실제 iOS SDK로 연결 정책·connector를 typecheck하고 전체 변경 consumer를 parse한다."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'Tests/checks/reconnect-glue'))
from extract import block

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], env=env, text=True).strip()
wire = sorted((ROOT / 'Sources/StreamProtocol').glob('*.swift'))
consumers = [ROOT / 'iOSClient' / (n + '.swift') for n in ['DiscoveryPolicy', 'RemoteDialPolicy', 'SavedMacs', 'RemoteConnector']]
parse = [ROOT / 'iOSClient' / (n + '.swift') for n in ['StreamClient', 'StreamClient+Remote', 'StreamClient+Home']]
home = (ROOT / 'iOSClient/StreamClient+Home.swift').read_text()
adapter = out / 'DeviceTLS.swift'
adapter.write_text('import Foundation\nimport Network\nimport Security\nimport StreamProtocol\n' + block(home, 'enum DeviceTLS {'))
hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in wire + consumers + parse}
flags = ['xcrun', 'swiftc', '-swift-version', '5', '-sdk', sdk, '-target', 'arm64-apple-ios17.0', '-module-cache-path', str(out / 'cache')]
commands = [flags + ['-parse-as-library', '-emit-module', '-module-name', 'StreamProtocol', *map(str, wire), '-emit-module-path', str(out / 'StreamProtocol.swiftmodule')],
            flags + ['-typecheck', '-I', str(out), *map(str, consumers), str(adapter)],
            flags + ['-parse', *map(str, parse)]]
codes = []
with (out / 'sdk.log').open('wb') as log:
    for command in commands:
        result = subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
        codes.append(result.returncode)
        if result.returncode:
            break
record = dict(exitCodes=codes, sdk=sdk, sourceSHA256=hashes,
              sourceUnchanged=all(hashlib.sha256((ROOT / n).read_bytes()).hexdigest() == h for n, h in hashes.items()),
              scope='실제 iOS SDK 정책/RemoteConnector/DeviceTLS typecheck, StreamClient와 확장 전체 parse. 앱 link/실행/설치는 제외.',
              hostExecution=0, deviceExecution=0, keyAccess=0, installation=0)
(out / 'sdk.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({k: v for k, v in record.items() if k != 'sourceSHA256'}, ensure_ascii=False))
sys.exit(0 if codes == [0, 0, 0] and record['sourceUnchanged'] else 1)
