import subprocess
import sys
from pathlib import Path

runner = Path(__file__).resolve().parents[1] / 'sentry-targeted-input/run.py'
raise SystemExit(subprocess.call([sys.executable, '-B', str(runner), '--suite', 'input', *sys.argv[1:]]))
