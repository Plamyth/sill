from pathlib import Path
import hashlib
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
source = root / 'Sources/SillHost/HostProcessOutputSilence.swift'
test = Path(__file__).with_name('Main.swift')
inputs = [source, test, Path(__file__).resolve()]
before = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
with tempfile.TemporaryDirectory(prefix='host-process-output-check-') as directory:
    out = Path(directory)
    command = ['xcrun', 'swiftc', '-warnings-as-errors', '-parse-as-library', '-target', 'arm64-apple-macos14.0',
               '-module-cache-path', str(out / 'cache'), str(source), str(test), '-o', str(out / 'checks')]
    subprocess.run(command, check=True)
    subprocess.run([str(out / 'checks')], check=True)
assert before == {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
print('SOURCE_UNCHANGED=true; SCRATCH_REMOVED=' + str(not out.exists()).lower())
