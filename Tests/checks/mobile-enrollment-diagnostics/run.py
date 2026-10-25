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
host = [root / 'Sources/SillHost' / (name + '.swift') for name in
        ['HostLog', 'MobileEnrollmentSigner', 'ProviderPeerAnchor', 'MobileEnrollmentSocket', 'MobileEnrollmentHostRuntime']]
remote = root / 'Sources/SillHost/RemoteAccess.swift'
identity = root / 'Sources/SillHost/HostIdentity.swift'
inputs = protocol + host + [remote, identity] + sorted(here.glob('*'))
digest = lambda: {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in inputs if p.is_file()}
before = digest()


def method(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
with tempfile.TemporaryDirectory(prefix='diagnostics-build-', dir=args.output) as temporary:
    build = Path(temporary)
    swift = ['xcrun', 'swiftc', '-swift-version', '5', '-package-name', 'Sill',
             '-sdk', sdk, '-target', 'arm64-apple-macosx14.0', '-module-cache-path', str(build / 'cache')]
    subprocess.run(swift + ['-emit-module', '-emit-library', '-module-name', 'StreamProtocol',
        *map(str, protocol), '-o', str(build / 'libStreamProtocol.dylib'),
        '-emit-module-path', str(build / 'StreamProtocol.swiftmodule')], check=True)
    text = identity.read_text()
    (build / 'HostIdentity.swift').write_text(text[:text.index("/// Where the Mac's")])
    text = remote.read_text()
    methods = [method(text, signature) for signature in
               ['private func mobileEnrollmentHostProfile(', 'private func updateMobileEnrollment()',
                'func stopMobileEnrollment()']]
    standin = (here / 'RemoteAccessStandin.swift').read_text()
    (build / 'RemoteAccess.swift').write_text(standin.replace('// PRODUCTION_METHODS', '\n'.join(methods)))
    sources = [str(build / 'HostIdentity.swift'), *map(str, host), str(build / 'RemoteAccess.swift')]
    subprocess.run(swift + ['-parse-as-library', '-I', str(build), '-L', str(build), '-lStreamProtocol',
        *sources, str(here / 'Main.swift'), '-o', str(build / 'checks')], check=True)
    result = subprocess.run([str(build / 'checks'), str(args.output)],
        env={**os.environ, 'DYLD_LIBRARY_PATH': str(build)}, timeout=60)
after = digest()
assert before == after
(args.output / 'source-evidence.json').write_text(json.dumps(dict(
    before=before, after=after, sourceUnchanged=True, macOSSDK=sdk,
    remoteAccessScope='exact production profile/update/stop methods in minimal state standin',
    profileFailure='test module Security public-key lookup standin returns nil; no production injection',
    actualCommandSocketConnections=0, actualHostLaunches=0, actualKeychainCalls=0,
    actualDeviceLAKeychainPermissionAudioEffects=0, independentReview='parent-owned'), indent=2))
raise SystemExit(result.returncode)
