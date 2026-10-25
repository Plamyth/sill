"""Mini ephemeral 내부에서만 production Admission/HostSentry의 inert 검사를 실행한다."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
suites = sys.argv[1:] or ['manual', 'control', 'selection', 'sentry']
inputs = sorted((root / 'Sources/StreamProtocol').glob('*.swift')) + [
    root / 'Sources/SillHost/SentryAdmission.swift', root / 'Sources/SillHost/HostSentry.swift']
hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
code = 0
with tempfile.TemporaryDirectory(prefix='manual-sentry-inert-') as temporary:
    out = Path(temporary)
    compiler = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
    flags = [compiler, '-swift-version', '5', '-parse-as-library', '-whole-module-optimization',
             '-package-name', 'sill', '-module-cache-path', str(out / 'cache')]
    protocol = list(map(str, sorted((root / 'Sources/StreamProtocol').glob('*.swift'))))
    subprocess.run(flags + ['-emit-module', '-emit-object', '-module-name', 'StreamProtocol'] + protocol +
                   ['-emit-module-path', str(out / 'StreamProtocol.swiftmodule'), '-o', str(out / 'StreamProtocol.o')], check=True)
    for suite in suites:
        main = {'manual': 'manual-sentry-admission/Main.swift', 'control': 'sentry-control-v2/Main.swift',
                'selection': 'source-selection-admission/main.swift', 'sentry': 'sentry/Main.swift'}[suite]
        binary = out / suite
        subprocess.run(flags + ['-I', str(out)] + list(map(str, inputs[-2:])) +
                       [str(root / 'Tests/checks' / main), str(out / 'StreamProtocol.o'), '-o', str(binary)], check=True)
        result = subprocess.run([str(binary), str(out)], timeout=60)
        print('SUITE_RESULT ' + json.dumps({'suite': suite, 'exitCode': result.returncode}), flush=True)
        code = max(code, result.returncode if result.returncode >= 0 else 128 - result.returncode)
unchanged = all(hashlib.sha256((root / name).read_bytes()).hexdigest() == digest for name, digest in hashes.items())
print('INERT_RESULT ' + json.dumps({'sourceSHA256': hashes, 'sourceUnchanged': unchanged,
    'temporaryFilesRemoved': not out.exists(), 'Host': 0, 'HAL': 0, 'UI': 0, 'devices': 0,
    'audio': 0, 'apps': 0, 'fullRelease': 0, 'Node': 0, 'Java': 0}), flush=True)
sys.exit(code if unchanged else 2)
