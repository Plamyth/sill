from pathlib import Path
import hashlib
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
source = root / 'Sources/SillHost/ProviderCallSocket.swift'
checks = Path(__file__).with_name('WaitChecks.swift')
before = hashlib.sha256(source.read_bytes()).hexdigest()
text = source.read_text()
start = text.index('    private static func wait(')
end = text.index('    private static func write(', start)
body = text[start:end].replace('private static func wait(', 'static func wait(', 1)
with tempfile.TemporaryDirectory(prefix='provider-socket-wait-') as directory:
    scratch = Path(directory)
    (scratch / 'ProductionWait.swift').write_text('import Foundation\nimport Darwin\nenum ProductionWait {\n' + body + '}\n')
    binary = scratch / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(scratch / 'ProductionWait.swift'),
                    str(checks), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
assert hashlib.sha256(source.read_bytes()).hexdigest() == before
print('productionWaitSHA256=' + hashlib.sha256(body.encode()).hexdigest())
print('SOURCE_UNCHANGED=true; SCRATCH_REMOVED=' + str(not scratch.exists()).lower())
