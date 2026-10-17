"""Opt-in native AU format check; never allocates or starts audio hardware."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile

here = Path(__file__).resolve().parent
root = here.parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--device-uid', help='explicit virtual device UID, e.g. BlackHole2ch_UID')
parser.add_argument('--emit-only', type=Path, help='write standalone Swift source without compiling or accessing audio')
args = parser.parse_args()
if not args.emit_only and not args.device_uid:
    parser.error('--device-uid is required for native execution')
path = root / 'Sources/SillHost/HALMicrophoneSink.swift'
original = path.read_bytes()
text = original.decode()
start = text.index('protocol HALMicrophoneOutputUnit:')
end = text.index('struct HALMicrophoneOperations:')
source = ('import Foundation\nimport AudioToolbox\nimport AVFAudio\nimport CoreAudio\n\n'
          + text[start:end] + (here / 'main.swift').read_text())
print('productionSHA256=' + hashlib.sha256(original).hexdigest(), flush=True)
if args.emit_only:
    args.emit_only.write_text(source)
else:
    with tempfile.TemporaryDirectory(prefix='ccr-hal-format-') as directory:
        swift = Path(directory) / 'main.swift'
        binary = Path(directory) / 'check'
        swift.write_text(source)
        subprocess.run(['swiftc', '-O', str(swift), '-o', str(binary)], check=True, timeout=120)
        subprocess.run([str(binary), args.device_uid], check=True, timeout=30)
    if path.read_bytes() != original:
        raise SystemExit('production source changed during native check')
