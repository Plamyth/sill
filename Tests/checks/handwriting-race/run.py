#!/usr/bin/env python3
"""Compile the production store with Apple's SDK; no extracted method or model stand-ins."""
import hashlib
import json
import os
import signal
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
output = Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=True)
sources = [root / 'iOSClient/CanvasBridge/CanvasModel.swift',
           root / 'iOSClient/CanvasBridge/CanvasStore.swift',
           Path(__file__).with_name('main.swift')]
hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
tool_env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=tool_env, text=True).strip()
command = ['xcrun', 'swiftc', '-sdk', sdk, '-target', 'arm64e-apple-macos27.0',
           '-swift-version', '5', '-parse-as-library', '-module-cache-path', str(output.parent / 'modules'),
           *map(str, sources), '-Xlinker', '-sectcreate', '-Xlinker', '__TEXT',
           '-Xlinker', '__info_plist', '-Xlinker', str(Path(__file__).with_name('Info.plist')),
           '-o', str(output / 'check')]
def run(command, env, timeout):
    child = subprocess.Popen(command, env=env, text=True, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, start_new_session=True)
    try:
        log, _ = child.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        log, _ = child.communicate()
        print(log, end='')
        raise
    return subprocess.CompletedProcess(command, child.returncode, log)

compile_result = run(command, tool_env, 240)
(output / 'compile.log').write_text(compile_result.stdout)
print(compile_result.stdout, end='')
code = compile_result.returncode
if code == 0:
    home = output / 'home'
    home.mkdir(exist_ok=True)
    env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))
    result = run([str(output / 'check')], env, 90)
    (output / 'runtime.log').write_text(result.stdout)
    print(result.stdout, end='')
    code = result.returncode
(output / 'result.json').write_text(json.dumps({'sourceHashes': hashes, 'sdk': sdk,
    'command': command, 'exitCode': code}, indent=2) + '\n')
sys.exit(code if code >= 0 else 1)
