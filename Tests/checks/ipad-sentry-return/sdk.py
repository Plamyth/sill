"""설치 iOS SDK에서 전용 키 API와 실제 consumer를 typecheck한다. 실행·서명은 없다."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
label = sys.argv[1]
out = Path(json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route', 'path',
    'development-archive', '--project', 'BT_CCR-ipad', '--filename', 'sentry-return-consumer-20261025-' + label], text=True))['path'])
out.mkdir(parents=True, exist_ok=True)
assert not (out / (label + '.json')).exists()
sdk = Path(subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True,
    env={'DEVELOPER_DIR': '/Applications/Xcode.app/Contents/Developer', 'PATH': '/usr/bin:/bin'}).strip())
interface = sdk / 'System/Library/Frameworks/CryptoKit.framework/Modules/CryptoKit.swiftmodule/arm64e-apple-ios.swiftinterface'
source = interface.read_text()
assert 'accessControl: Security::SecAccessControl' in source and 'authenticationContext: LocalAuthentication::LAContext?' in source
assert 'init(dataRepresentation: Foundation::Data' in source
paths = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
consumers = [root / 'iOSClient' / name for name in ['IPadSentryControl.swift', 'IPadSentryObservation.swift', 'IPadSentryReturn.swift', 'IPadSentryReturnKeys.swift']]
parse_paths = [root / 'iOSClient' / name for name in ['StreamClient+SentryReturn.swift', 'StreamClient.swift', 'HostSettingsPanel.swift']]
hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths + consumers + parse_paths}
with tempfile.TemporaryDirectory(prefix='sdk-api-', dir=out) as temp:
    temp = Path(temp)
    flags = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-sdk', str(sdk), '-target', 'arm64-apple-ios17.0',
        '-module-cache-path', str(temp / 'cache')]
    commands = [flags + ['-parse-as-library', '-emit-module', '-module-name', 'StreamProtocol', *map(str, paths),
        '-emit-module-path', str(temp / 'StreamProtocol.swiftmodule')],
        flags + ['-typecheck', '-I', str(temp), *map(str, consumers)],
        flags + ['-parse', *map(str, parse_paths)]]
    results = [subprocess.run(command, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        env={'DEVELOPER_DIR': '/Applications/Xcode.app/Contents/Developer', 'PATH': '/usr/bin:/bin'}) for command in commands]
log = b'\n'.join(result.stdout for result in results)
(out / (label + '.log')).write_bytes(log)
record = dict(exitCodes=[r.returncode for r in results], sdk=str(sdk), sdkInterfaceSHA256=hashlib.sha256(interface.read_bytes()).hexdigest(),
    sourceSHA256=hashes, sourceUnchanged=all(hashlib.sha256((root / n).read_bytes()).hexdigest() == h for n, h in hashes.items()),
    realKeyCreation=0, biometricUI=0, fullIOSBuild='parent', scope='실제 iOS SDK 키 adapter/consumer typecheck 및 StreamClient/UI parse. 전체 앱 link·실기기 수용은 별도.')
(out / (label + '.json')).write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
print(log.decode(errors='replace'))
print(json.dumps({k:v for k,v in record.items() if k != 'sourceSHA256'}, ensure_ascii=False))
sys.exit(0 if all(r.returncode == 0 for r in results) and record['sourceUnchanged'] else 1)
