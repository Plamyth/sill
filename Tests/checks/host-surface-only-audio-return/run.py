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
        ['HostAudioPrivacyModel', 'LocalAudioParticipants', 'HostSentry', 'SentryAdmission']]
local = root / 'Sources/SillHost/LocalAudioReturn.swift'
inputs = protocol + host + [local, here / 'Main.swift', Path(__file__).resolve()]
digest = lambda: {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
before = digest()
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
with tempfile.TemporaryDirectory(prefix='surface-return-build-', dir=args.output) as temporary:
    build = Path(temporary)
    swift = ['xcrun', 'swiftc', '-swift-version', '5', '-package-name', 'Sill',
             '-sdk', sdk, '-target', 'arm64-apple-macosx14.0', '-module-cache-path', str(build / 'cache')]
    subprocess.run(swift + ['-parse-as-library', '-whole-module-optimization', '-emit-module', '-emit-object',
        '-module-name', 'StreamProtocol', *map(str, protocol), '-o', str(build / 'StreamProtocol.o'),
        '-emit-module-path', str(build / 'StreamProtocol.swiftmodule')], check=True)
    text = local.read_text()
    text = text[:text.index('@MainActor\nfinal class LocalAudioAuthentication')]
    text = text.replace('import LocalAuthentication\n', '').replace('import LocalAuthenticationEmbeddedUI\n', '')
    (build / 'LocalAudioReturn.swift').write_text(text)
    subprocess.run(swift + ['-parse-as-library', '-I', str(build), *map(str, host),
        str(build / 'LocalAudioReturn.swift'), str(here / 'Main.swift'), str(build / 'StreamProtocol.o'),
        '-o', str(build / 'checks')], check=True)
    result = subprocess.run([str(build / 'checks'), str(args.output)], timeout=90)
after = digest()
assert before == after
(args.output / 'source-evidence.json').write_text(json.dumps(dict(
    before=before, after=after, sourceUnchanged=True, macOSSDK=sdk,
    modelAndSentry='exact production sources; immutable NativeAudioStartup and LocalAudioState prefix',
    authentication='injected per-request acceptance; real LocalAuthentication excluded',
    actualHALWrites=0, actualAuthUIHostDeviceAudioActions=0, independentReview='parent-owned'), indent=2))
raise SystemExit(result.returncode)
