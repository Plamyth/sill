import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
package = Path(sys.argv[1]).resolve(strict=True)
output = Path(sys.argv[2]).resolve(strict=True)
host = root / 'Sources/SillHost'
paths = [host / name for name in ['LocalAudioRelayLaunch.swift', 'LocalAudioRelayClosure.swift', 'LocalAudioRelayMachO.swift']]
before = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
source = paths[0].read_text().split('\nstruct LocalAudioRelayInvocation {', 1)[0]
source += '''
@main struct Check {
    static func main() throws {
        let inventory = try LocalAudioRelayInventory.capture(package: URL(fileURLWithPath: CommandLine.arguments[1]))
        try LocalAudioRelayClosure.validate(inventory)
        try inventory.recheck()
        print("실제 패키지 inventory·Mach-O·의존성·소스 핀 검증 통과: \\(inventory.manifest.entries.count)개 항목")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='package-validation-', dir=output) as temporary:
    scratch = Path(temporary)
    fixture = scratch / 'Inventory.swift'
    fixture.write_text(source)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(scratch / 'cache'),
        str(fixture), str(paths[1]), str(paths[2]), '-o', str(scratch / 'check')], check=True)
    subprocess.run([str(scratch / 'check'), str(package)], check=True)
assert before == {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
print(json.dumps({'passed': True, 'sourceHashes': before, 'sourceUnchanged': True,
                  'manifestSHA256': hashlib.sha256((package / 'manifest.json').read_bytes()).hexdigest(),
                  'serverStarted': False, 'audioOpened': False, 'scratchRemoved': not scratch.exists()}))
