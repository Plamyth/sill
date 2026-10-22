#!/usr/bin/env python3
import hashlib
import argparse
import json
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[3]
route = json.loads(subprocess.check_output([
    '/Users/ambrion/.local/bin/storage-route', 'path', 'development-archive',
    '--project', 'BT_CCR-ipad'
], text=True))
parser = argparse.ArgumentParser(description='Pencil 교정 순수 모델 검사')
parser.add_argument('--output', type=Path, default=root / '.build/pencil-text-correction-checks')
output = parser.parse_args().output.resolve()
if not output.is_relative_to(Path(route['path']).resolve()):
    raise SystemExit('지정된 외장 출력 경로를 확인하지 못했습니다.')
output.mkdir(parents=True, exist_ok=True)
model = root / 'iOSClient/CanvasBridge/CanvasModel.swift'
correction = root / 'iOSClient/CanvasBridge/PencilTextCorrection.swift'
main = Path(__file__).with_name('main.swift')
inputs = [model, correction, main, Path(__file__), Path(__file__).with_name('README.md')]
def hashes():
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
before = hashes()
source = model.read_text()
start = source.index('func canvasSelectedCharacterRange(')
end = source.index('\nstruct CanvasPoint:', start)
helper = output / 'SelectedCharacterRange.swift'
helper.write_text('import Foundation\n' + source[start:end])
cache = output / 'modules'
temporary = output / 'tmp'
temporary.mkdir(exist_ok=True)
env = dict(os.environ, TMPDIR=str(temporary), CLANG_MODULE_CACHE_PATH=str(cache))
compiler = subprocess.run(['xcrun', 'swiftc', '--version'], env=env, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=True).stdout
command = ['xcrun', 'swiftc', '-swift-version', '5', '-warnings-as-errors',
           '-module-cache-path', str(cache), str(helper), str(correction), str(main),
           '-o', str(output / 'check')]
def run(args, name):
    result = subprocess.run(args, env=env, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=180)
    (output / name).write_text(result.stdout)
    print(result.stdout, end='')
    return result.returncode
code = run(command, 'compile.log')
if code == 0:
    code = run([str(output / 'check')], 'runtime.log')
after = hashes()
unchanged = before == after
if not unchanged:
    code = 1
(output / 'result.json').write_text(json.dumps({
    'compiler': compiler, 'command': command, 'sourceHashes': before,
    'sourceHashesAfter': after, 'sourceUnchanged': unchanged, 'exitCode': code,
    'helperExtractedFromExistingSource': True, 'deviceExecuted': False,
    'independentReview': 'pending-parent-review'
}, ensure_ascii=False, indent=2) + '\n')
raise SystemExit(code)
