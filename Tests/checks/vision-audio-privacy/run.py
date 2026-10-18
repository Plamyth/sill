"""Pure intent and shared authority models plus actual extracted store with inert audio clients. No capture, device, engine, network, or OS permission effects."""
from pathlib import Path
import json
import hashlib
import subprocess
import sys

root, output = [Path(value).resolve() for value in sys.argv[1:3]]
if output == root or root in output.parents:
    raise RuntimeError('isolated output required')
output.mkdir(parents=True, exist_ok=True)
exe = output / 'vision-audio-privacy'
command = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(output / 'cache'),
           str(root / 'visionOSClient/VisionRemoteAudioIntent.swift'),
           str(root / 'visionOSClient/VisionRemoteAudioAuthority.swift'),
           str(root / 'Tests/checks/vision-audio-privacy/authority.swift'),
           str(root / 'Tests/checks/vision-audio-privacy/main.swift'), '-o', str(exe)]
source = (root / 'visionOSClient/VisionRemoteAudioAuthority.swift').read_text()
store = source[source.index('final class VisionRemoteAudioStore {'):source.rindex('\n#endif')]
(output / 'Store.swift').write_text('import Foundation\n' + store)
(output / 'main.swift').write_bytes((root / 'Tests/checks/vision-audio-privacy/adapter-main.swift').read_bytes())
adapter = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(output / 'cache'),
           str(root / 'visionOSClient/VisionRemoteAudioIntent.swift'),
           str(root / 'visionOSClient/VisionRemoteAudioAuthority.swift'), str(output / 'Store.swift'),
           str(root / 'Tests/checks/vision-audio-privacy/adapter.swift'), str(output / 'main.swift'),
           '-o', str(output / 'adapter')]
result = {'scope': __doc__, 'commands': [], 'exitCode': 1,
          'storeSHA256': hashlib.sha256(store.encode()).hexdigest(),
          'adapterBoundary': 'Actual shared store copied verbatim. Inert StreamClient, player, microphone and hardware cleanup readback; no native graph, transport, OS permission or UI acceptance.'}
for label, args in [('compile', command), ('policy', [str(exe)]),
                    ('adapter-compile', adapter), ('adapter', [str(output / 'adapter')])]:
    run = subprocess.run(args, capture_output=True, text=True, timeout=90)
    (output / (label + '.log')).write_text(run.stdout + run.stderr)
    result['commands'].append({'label': label, 'exitCode': run.returncode})
    if run.returncode:
        break
else:
    result['exitCode'] = 0
(output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result))
sys.exit(result['exitCode'])
