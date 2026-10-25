import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
args.output.mkdir(parents=True, exist_ok=True)
protocol = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
host = [root / 'Sources/SillHost' / (n + '.swift') for n in
        ['HostLog', 'MobileEnrollmentSigner', 'ProviderPeerAnchor', 'MobileEnrollmentSocket', 'MobileEnrollmentHostRuntime']]
inputs = protocol + host + [root / 'Sources/SillHost/HostIdentity.swift'] + sorted(here.glob('*'))
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
before = {str(p.relative_to(root)): sha(p) for p in inputs if p.is_file()}
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
with tempfile.TemporaryDirectory(prefix='build-', dir=args.output) as temporary:
    build = Path(temporary)
    swift = ['xcrun', 'swiftc', '-swift-version', '5', '-package-name', 'Sill',
             '-sdk', sdk, '-target', 'arm64-apple-macosx14.0', '-module-cache-path', str(build / 'cache')]
    subprocess.run(swift + ['-emit-module', '-emit-library', '-module-name', 'StreamProtocol',
        *map(str, protocol), '-o', str(build / 'libStreamProtocol.dylib'),
        '-emit-module-path', str(build / 'StreamProtocol.swiftmodule')], check=True)
    identity = (root / 'Sources/SillHost/HostIdentity.swift').read_text()
    prefix = identity[:identity.index("/// Where the Mac's")]
    (build / 'HostIdentity.swift').write_text(prefix)
    sources = [str(build / 'HostIdentity.swift'), *map(str, host)]
    subprocess.run(swift + ['-typecheck', '-I', str(build), *sources], check=True)
    subprocess.run(swift + ['-parse-as-library', '-I', str(build), '-L', str(build), '-lStreamProtocol',
        *sources, str(here / 'Main.swift'), '-o', str(build / 'checks')], check=True)
    subprocess.run([str(build / 'checks'), str(args.output)],
        env={**os.environ, 'DYLD_LIBRARY_PATH': str(build)}, check=True, timeout=60)
    subprocess.run(['node', str(here / 'node-compat.js'), str(args.output)], check=True, timeout=10)
after = {str(p.relative_to(root)): sha(p) for p in inputs if p.is_file()}
assert before == after
(args.output / 'source-evidence.json').write_text(json.dumps(dict(
    before=before, after=after, sourceUnchanged=True, macOSSDK=sdk,
    hostIdentityScope='exact production prefix through immutable HostIdentity, excluding all IdentityStore backends',
    actualCommandSocketConnections=0, actualHostLaunches=0, actualDeviceLAKeychainPermissionAudioEffects=0,
    productionRegistryWiring=False, productionLifecycleWiring=False, independentReview='parent-owned'), indent=2))
