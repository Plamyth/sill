"""생산 Swift 소비자를 공개 fixture·메모리 I/O로만 실행한다. 키·네트워크·앱을 열지 않는다."""
import hashlib
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
FIXTURES = {
    'device-enrollment-golden-v2.json': '12c3fdf84163ed9407f5b82bb10c96baa3fda387b93870f5fe49023d3bdef059',
    'device-enrollment-readback-golden.json': '2b7064d3a2fd50e1f79b4dfdc5744aee1caf1b911e63a4599b287daf168b695a',
}
for name, digest in FIXTURES.items():
    assert hashlib.sha256((HERE / 'fixtures' / name).read_bytes()).hexdigest() == digest, name

with tempfile.TemporaryDirectory(prefix='build-', dir=HERE) as directory:
    out = Path(directory)
    cache = out / 'cache'
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(cache))
    common = ['swiftc', '-module-cache-path', str(cache)]
    protocol = ['RemoteIdentity.swift', 'AudioRouting.swift', 'StreamMessage.swift', 'OwnerMacBootstrap.swift', 'AddressParser.swift']
    subprocess.run(common + ['-emit-library', '-emit-module', '-module-name', 'StreamProtocol',
        *[str(ROOT / 'Sources/StreamProtocol' / name) for name in protocol],
        '-o', str(out / 'libStreamProtocol.dylib')], check=True, env=env, timeout=120)
    sources = ['IPadEnrollmentJSON.swift', 'IPadEnrollmentProtocol.swift', 'IPadDeviceEnrollment.swift']
    runtime = (ROOT / 'iOSClient/StreamClient+OwnerEnrollment.swift').read_text().replace('#if os(iOS)', '#if true')
    runtime = runtime.replace('import Network\n', '').replace('import Security\n', '')
    clock = 'now: { Int64(Date().timeIntervalSince1970 * 1000) }'
    assert runtime.count(clock) == 1
    runtime = runtime.replace(clock, 'now: { runtimeMemory!.now }')
    (out / 'runtime-extension.swift').write_text(runtime)
    fixture = json.loads((HERE / 'fixtures/device-enrollment-readback-golden.json').read_text())
    envelope = fixture['enrollRequest']['ownerReceipt']
    payload = json.loads(base64.urlsafe_b64decode(envelope['payload'] + '==='))
    profile = {'schema': 'ccr.owner-mac-bootstrap/v1', 'macID': payload['macID'], 'fingerprint': payload['macFingerprint'],
        'addresses': ['100.100.100.100'], 'remotePort': 52342}
    profile_path = out / 'synthetic-owner-profile.json'
    profile_path.write_text(json.dumps(profile))
    subprocess.run(common + ['-I', str(out), '-L', str(out), '-lStreamProtocol', '-Xlinker', '-rpath', '-Xlinker', str(out),
        *[str(ROOT / 'iOSClient' / name) for name in sources], str(HERE / 'main.swift'), str(HERE / 'runtime.swift'),
        str(HERE / 'signed-payload.swift'), str(HERE / 'renewal.swift'),
        str(out / 'runtime-extension.swift'), '-o', str(out / 'checks')],
        check=True, env=env, timeout=120)
    subprocess.run([str(out / 'checks'), str(HERE / 'fixtures'), str(profile_path)], check=True, timeout=30)
    transport = (ROOT / 'iOSClient/IPadEnrollmentTransport.swift').read_text()
    exchange = transport[transport.index('final class IPadOwnerReceiptExchange'):].rsplit('\n#endif', 1)[0]
    bootstrap = (ROOT / 'iOSClient/OwnerBootstrapState.swift').read_text()
    permit = bootstrap[bootstrap.index('final class OwnerBootstrapSendPermit'):]
    store = (ROOT / 'iOSClient/IPadEnrollmentStore.swift').read_text().replace('#if os(iOS)', '#if true')
    for original, replacement in [('SecItemCopyMatching(', 'memoryCopyMatching('), ('SecItemAdd(', 'memoryAdd('), ('SecItemUpdate(', 'memoryUpdate(')]:
        store = store.replace(original, replacement)
    (out / 'main.swift').write_text((HERE / 'adapters.swift').read_text() + '\n' + permit + '\n' + exchange + '\n' + store)
    subprocess.run(common + ['-I', str(out), '-L', str(out), '-lStreamProtocol', '-Xlinker', '-rpath', '-Xlinker', str(out),
        str(ROOT / 'iOSClient/IPadEnrollmentJSON.swift'), str(ROOT / 'iOSClient/IPadEnrollmentProtocol.swift'),
        str(out / 'main.swift'), '-o', str(out / 'adapter-checks')], check=True, env=env, timeout=120)
    subprocess.run([str(out / 'adapter-checks')], check=True, timeout=30)
