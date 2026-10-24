"""Mini의 격리 사본에서 정책 반례와 실제 SDK 컴파일을 확인한다."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

here = Path(__file__).resolve().parent
repo = here.parents[2]
source = repo / 'Sources/ProviderPeerVerifier/PeerAnchor.swift'
original = source.read_text()
assert original.count('import Security\n') == 1
assert original.count('getsockopt(') == 2
with tempfile.TemporaryDirectory(prefix='core-peer-') as temporary:
    out = Path(temporary)
    transformed = out / 'PeerAnchor.swift'
    transformed.write_text(original.replace('import Security\n', '').replace('getsockopt(', 'fixtureGetSockOpt('))
    subprocess.run(['xcrun', 'swiftc', str(transformed), str(here / 'FixtureSecurity.swift'),
        str(here / 'Checks.swift'), '-module-cache-path', str(out / 'cache'), '-o', str(out / 'checks')],
        check=True, timeout=180)
    subprocess.run([str(out / 'checks')], check=True, timeout=20)
    helper = out / 'custom-policy-verifier'
    subprocess.run(['xcrun', 'swiftc', str(source),
        str(here.parent / 'provider-peer-anchor/fixture-verifier.swift'),
        '-module-cache-path', str(out / 'cache'), '-o', str(helper)], check=True, timeout=90)
    binary = out / 'native-checks'
    subprocess.run(['xcrun', 'swiftc', str(source), str(here / 'NativeChecks.swift'),
        '-module-cache-path', str(out / 'cache'), '-o', str(binary)], check=True, timeout=90)
    subprocess.run([str(binary)], check=True, timeout=20)
    assert source.read_text() == original
print(json.dumps({'productionSHA256': hashlib.sha256(source.read_bytes()).hexdigest(),
    'customPolicyAPICompiled': True, 'productionSourceUnchanged': True,
    'scratchRemoved': not out.exists(), 'fullGitSourceGuardAccepted': False,
    'actualAppsPorts17648_17649VoiceHALKeysUIEffects': 0}), flush=True)
