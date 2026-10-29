#!/usr/bin/env python3
"""Run extracted click state with a deterministic clock, without creating CGEvents."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--mutants', action='store_true')
parser.add_argument('--sdk', action='store_true')
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
inputs = [ROOT / 'Sources/SillHost/InputInjector.swift', ROOT / 'Sources/SillHost/KeyStrokes.swift',
          HERE / 'main.swift', Path(__file__).resolve()]


def hashes():
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}


def block(text, marker):
    start = text.index(marker)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


before = hashes()
injector = inputs[0].read_text()
constants = '\n'.join(re.findall(r'^    private static let multiClick(?:Interval|Slop):[^\n]+', injector, re.M))
assert constants.count('private static let') == 2
state = block(injector, 'private struct ButtonState {')
begin = block(injector, 'private func beginClick(')
assert begin.count('CFAbsoluteTimeGetCurrent()') == 1
begin = begin.replace('CFAbsoluteTimeGetCurrent()', 'clock()')
alias = re.search(r'package typealias Device = [^\n]+', inputs[1].read_text()).group().removeprefix('package ')
template = (HERE / 'main.swift').read_text()


def fixture(method):
    return template.replace('__DEVICE_TYPEALIAS__', alias).replace(
        '__PRODUCTION_CLICK_STATE__', constants + '\n' + state + '\n' + method)


record = {'scope': '생산 ButtonState·beginClick 추출과 결정적 clock, 실제 CGEvent 생성·게시 없음',
          'sourceSHA256': before, 'commands': [], 'variants': [], 'actualHostUIHALOrMediaActions': 0}


def command(name, argv):
    result = subprocess.run(argv, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
    (out / (name + '.log')).write_text(result.stdout)
    record['commands'].append({'name': name, 'argv': list(map(str, argv)), 'exitCode': result.returncode})
    print(result.stdout, end='', flush=True)
    return result


compiler = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
record['compiler'] = subprocess.check_output([compiler, '--version'], text=True).strip()
record['SDK'] = sdk
flags = [compiler, '-swift-version', '5', '-parse-as-library', '-sdk', sdk,
         '-target', 'arm64-apple-macosx14.0', '-module-cache-path', str(out / 'cache')]


def run_variant(name, source):
    path = out / (name + '.swift')
    path.write_text(source)
    assert 'CGEvent' not in source.replace('CGEvent/Host/UI/HAL actions=0', '')
    compiled = command(name + '-compile', flags + [str(path), '-o', str(out / name)])
    ran = command(name + '-run', [str(out / name)]) if compiled.returncode == 0 else None
    result = {'name': name, 'fixtureSHA256': hashlib.sha256(source.encode()).hexdigest(),
              'compileExit': compiled.returncode, 'runExit': ran.returncode if ran else None,
              'output': ran.stdout if ran else compiled.stdout}
    record['variants'].append(result)
    return result


normal = run_variant('production', fixture(begin))
code = normal['compileExit'] or normal['runExit']
if code == 0 and args.mutants:
    condition = 'state.lastDownDevice == device && '
    assert begin.count(condition) == 1, 'mutant requires the exact device continuity condition'
    mutant = run_variant('remove-device-comparison', fixture(begin.replace(condition, '', 1)))
    record['mutantKilled'] = mutant['compileExit'] == 0 and mutant['runExit'] == 1 and 'FAIL B expected1 actual2' in mutant['output']
    if not record['mutantKilled']:
        code = 2
if code == 0 and args.sdk:
    protocol = sorted((ROOT / 'Sources/StreamProtocol').glob('*.swift'))
    support_paths = [ROOT / 'Sources/SillHost' / (name + '.swift') for name in ['KeyStrokes', 'GestureChords']]
    record['SDKInputSHA256'] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                               for p in [*protocol, *support_paths, inputs[0]]}
    module = command('protocol-sdk', flags + ['-emit-module', '-module-name', 'StreamProtocol', '-package-name', 'Sill',
        *map(str, protocol), '-emit-module-path', str(out / 'StreamProtocol.swiftmodule')])
    code = module.returncode
    if code == 0:
        support = out / 'SDKSupport.swift'
        support.write_text('''import Foundation
import CoreGraphics
enum HostSentryPlatform {
    static let remoteEventTag: Int64 = 0x435352
    static func stampEventSource(_ event: CGEvent, source: CGEventSource?, tag: Int64) -> Bool { false }
}
final class PointerWatch { func sillMoved(to point: CGPoint) {}; func sillMoved() {} }
final class Stats { static let shared = Stats(); func bump(_ name: String) {} }
''')
        checked = command('injector-sdk', flags + ['-package-name', 'Sill', '-I', str(out), '-typecheck',
            str(inputs[0]), *map(str, support_paths), str(support)])
        code = checked.returncode
    record['SDKSourceUnchanged'] = all(hashlib.sha256((ROOT / p).read_bytes()).hexdigest() == digest
                                     for p, digest in record['SDKInputSHA256'].items())
    if not record['SDKSourceUnchanged']:
        code = 2
record['sourceUnchanged'] = before == hashes()
record['sourceSHA256After'] = hashes()
record['exitCode'] = code if record['sourceUnchanged'] else 2
(out / 'result.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
print('POINTER_CLICK_RESULT ' + json.dumps(record, ensure_ascii=False), flush=True)
sys.exit(record['exitCode'])
