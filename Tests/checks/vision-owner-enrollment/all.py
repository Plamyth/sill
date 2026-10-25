import concurrent.futures
from pathlib import Path
import subprocess
import sys
ROOT = Path(__file__).resolve().parents[3]
commands = [
    ['python3', 'Tests/checks/vision-owner-enrollment/static.py'],
    ['python3', 'iOSClient/Tests/owner-enrollment/run.py'],
    ['python3', 'Tests/checks/vision-owner-enrollment/run.py'],
    ['python3', 'Tests/checks/vision-control-events/run.py', '--skip-node'],
    ['python3', 'Tests/checks/vision-owner-bootstrap/run.py'],
    ['python3', 'Tests/checks/owner-bootstrap-provision/run.py'],
]
def run(command):
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=600)
    return command, result.returncode, result.stdout + result.stderr
with concurrent.futures.ThreadPoolExecutor(max_workers=len(commands)) as pool:
    results = list(pool.map(run, commands))
for command, code, log in results:
    print('검사', command, '종료', code)
    print(log)
raise SystemExit(1 if any(result[1] for result in results) else 0)
