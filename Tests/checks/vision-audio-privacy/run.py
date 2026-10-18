"""Pure intent model only. No capture, device, engine, network, or OS permission effects."""
from pathlib import Path
import json
import subprocess
import sys

root, output = [Path(value).resolve() for value in sys.argv[1:3]]
if output == root or root in output.parents:
    raise RuntimeError('isolated output required')
output.mkdir(parents=True, exist_ok=True)
exe = output / 'vision-audio-privacy'
command = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(output / 'cache'),
           str(root / 'visionOSClient/VisionRemoteAudioIntent.swift'),
           str(root / 'Tests/checks/vision-audio-privacy/main.swift'), '-o', str(exe)]
result = {'scope': __doc__, 'commands': [], 'exitCode': 1}
for label, args in [('compile', command), ('policy', [str(exe)])]:
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
