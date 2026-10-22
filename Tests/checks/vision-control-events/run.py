#!/usr/bin/env python3
"""Compile the production consumer and test only synthetic, in-memory transports."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--full-receipt', action='store_true', help='stdout에 전체 Swift 결과와 영수증을 출력합니다.')
parser.add_argument('--skip-node', action='store_true', help='Node 대조는 부모 정본에서 별도로 수행합니다.')
args = parser.parse_args()
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
BUILD = HERE / '.build'
BUILD.mkdir(exist_ok=True)
files = [ROOT / 'visionOSClient' / (name + '.swift') for name in [
    'ControlEventsModel', 'ControlEventsReducer', 'ControlEventsSSEParser', 'ControlEventsCodec',
    'ControlEventsProjection', 'ControlEventsTransport', 'ControlEventsController', 'VisionControlEnrollment']]
env = dict(os.environ)
xcode = Path('/Applications/Xcode.app/Contents/Developer')
if xcode.is_dir() and not env.get('DEVELOPER_DIR'):
    env['DEVELOPER_DIR'] = str(xcode)
subprocess.run(['/usr/bin/swiftc', '-swift-version', '5', '-module-cache-path', str(BUILD / 'modules'),
                *map(str, files), str(HERE / 'Main.swift'), '-o', str(BUILD / 'checks')], env=env, check=True)
output = subprocess.check_output([str(BUILD / 'checks'), str(HERE)], text=True, env=env)
receipt = json.loads(output)
common = Path('/Users/ambrion/.codex/worktrees/ccr-live-state-20261023/bridge/control-events.js')
node = '''
const fs=require('node:fs');const {reduceEvent}=require(process.argv[1]);
const f=JSON.parse(fs.readFileSync(process.argv[2]));const e=f.events;
let state=null;const result=[];
for(const event of [...e,e[1],f.gap,f.replacement]){const next=reduceEvent(state,event);state=next.state;result.push(next);}
process.stdout.write(JSON.stringify(result));
'''
receipt['nodeSwiftGoldenEqual'] = None
receipt['nodeComparison'] = {'status': 'not-run', 'reason': '정본 Node 모듈 또는 실행기가 없어 부모에서 대조해야 합니다.'}
if not args.skip_node and common.is_file() and shutil.which('node'):
    for fixture, key in [('control-events-v1.json', 'commonGolden'), ('mobile-control-events-v1.json', 'mobileGolden')]:
        result = json.loads(subprocess.check_output(['node', '-e', node, str(common), str(HERE / fixture)], text=True))
        assert result == receipt[key], f'Node/Swift mismatch: {fixture}'
    receipt['nodeSwiftGoldenEqual'] = True
    receipt['nodeComparison'] = {'status': 'passed', 'moduleSHA256': hashlib.sha256(common.read_bytes()).hexdigest()}
elif args.skip_node:
    receipt['nodeComparison']['reason'] = '부모가 정본 Node와 대조하도록 명시적으로 분리했습니다.'
receipt['sourceSHA256'] = {str(file.relative_to(ROOT)): hashlib.sha256(file.read_bytes()).hexdigest() for file in files}
receipt['fixturesSHA256'] = {file.name: hashlib.sha256(file.read_bytes()).hexdigest() for file in HERE.glob('*.json')}
assert receipt['fixturesSHA256']['mobile-control-events-v1.json'] == '60facc67e1435383dfd6ef78cfcf7ea6393529ca1b399742d8f03a8273c350be'
(BUILD / 'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
if args.full_receipt:
    print(json.dumps(receipt, ensure_ascii=False))
else:
    print(json.dumps({'checks': receipt['checks'], 'nodeSwiftGoldenEqual': receipt['nodeSwiftGoldenEqual'],
                      'nodeComparison': receipt['nodeComparison'], 'externalEffects': 0,
                      'receipt': str(BUILD / 'receipt.json')}, ensure_ascii=False))
