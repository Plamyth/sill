import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
route = json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route', 'path',
    'development-archive', '--project', 'CCR-native-relay-rpc-order-20261021']))
out = Path(route['path'])
staging = out / 'input'
names = ['Sources/SillHost/LocalAudioRelay.swift', 'Sources/SillHost/LocalAudioParticipants.swift',
         'Sources/SillHost/AudioForwardingContract.swift', 'Sources/SillHost/RemoteAccess.swift']
names += [str(p.relative_to(root)) for p in sorted((root / 'Tests/checks/native-relay-rpc-order').iterdir()) if p.is_file()]
before = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in names}
for name in names:
    target = staging / name
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(root / name, target)
log_path = out / (sys.argv[1] if len(sys.argv) > 1 else 'verification.log')
with log_path.open('w') as log:
    completed = subprocess.run(['/Users/ambrion/.local/bin/mini-ephemeral-source', 'run', '--source', str(staging),
        '--owner', '01a13005-ff61-7780-b0e8-6dc171de1c9d', '--job', 'native-relay-rpc-order-20261021',
        '--', '/usr/bin/python3', 'Tests/checks/native-relay-rpc-order/run.py', '.', *sys.argv[2:]], stdout=log, stderr=subprocess.STDOUT)
after = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in names}
receipt = dict(exitCode=completed.returncode, originalSourceUnchanged=before == after, sourceHashes=before, log=str(log_path))
(out / (log_path.stem + '-source.json')).write_text(json.dumps(receipt, indent=2) + '\n')
print(log_path.read_text()[-16000:])
sys.exit(0 if completed.returncode == 0 and before == after else 1)
