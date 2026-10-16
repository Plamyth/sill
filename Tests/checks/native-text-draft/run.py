"""Parent-only inert Swift runner. Usage: python3 -B run.py ROOT OUTPUT."""
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path
from extract import fixture
from mutants import MUTANTS
from static import contracts


def main():
    root, output = [Path(value).resolve() for value in sys.argv[1:3]]
    if output == root or root in output.parents:
        raise SystemExit('OUTPUT must be outside source ROOT')
    output.mkdir(parents=True, exist_ok=True)
    if (output / 'result.json').exists():
        raise SystemExit('Reconcile prior output before reuse')
    started = time.monotonic()
    record = {'scope': 'production draft, SessionLink and extracted client with inert Network and SwiftUI; no UIKit or host delivery proof',
              'commands': [], 'mutants': [], 'assertions': 0, 'exitCode': 2}
    files, manifest = fixture(root)
    record['extractionSHA256'] = manifest
    generated = output / 'generated'
    for name, text in files.items():
        path = generated / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    originals = {name: hashlib.sha256(text.encode()).hexdigest() for name, text in files.items()}
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1', TMPDIR=str(output / 'tmp'))
    Path(env['TMPDIR']).mkdir(exist_ok=True)
    base = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(output / 'cache')]
    protocol = ['Sources/StreamProtocol/' + name + '.swift' for name in ['Input', 'Switcher', 'StreamMessage', 'Compatibility']]
    sources = ['Client.swift', 'iOSClient/SessionLink.swift', 'iOSClient/KeyChords.swift',
               'Sources/SillHost/KeyStrokes.swift', 'visionOSClient/VisionPointer.swift',
               'visionOSClient/VisionInputSession.swift', 'visionOSClient/VisionInputDebt.swift',
               'visionOSClient/VisionPresentation.swift', 'visionOSClient/VisionRemoteKey.swift',
               'visionOSClient/VisionTextDraft.swift', 'Tests/checks/vision-input-controls/SourceInputFence.swift', 'main.swift']
    objects = [str(output / (name + '.o')) for name in ['Network', 'SwiftUI', 'StreamProtocol']]

    def run(command, label):
        remaining = 720 - (time.monotonic() - started)
        if remaining <= 0:
            raise TimeoutError('720 second driver budget exhausted')
        child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 text=True, env=env, start_new_session=True)
        try:
            log, _ = child.communicate(timeout=min(90, remaining))
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                log, _ = child.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                log, _ = child.communicate(timeout=5)
            (output / (label + '.log')).write_text(log)
            record['commands'].append({'label': label, 'exitCode': child.returncode, 'pid': child.pid, 'reaped': True, 'timeout': True})
            raise TimeoutError(label)
        (output / (label + '.log')).write_text(log)
        record['commands'].append({'label': label, 'exitCode': child.returncode, 'pid': child.pid, 'reaped': child.poll() is not None})
        return child.returncode, log

    def module(name, paths):
        return base + ['-parse-as-library', '-emit-module', '-emit-object', '-whole-module-optimization',
                       '-module-name', name] + [str(generated / path) for path in paths] + [
                       '-emit-module-path', str(output / (name + '.swiftmodule')), '-o', str(output / (name + '.o'))]

    def compile_app(paths, executable, label):
        return run(base + ['-package-name', 'sill', '-I', str(output)] + paths + objects + ['-o', str(executable)], label)

    try:
        record['staticContracts'] = contracts(root)
        for name, paths in [('Network', ['Network.swift']), ('SwiftUI', ['SwiftUI.swift']), ('StreamProtocol', protocol)]:
            code, log = run(module(name, paths), 'module-' + name)
            if code:
                raise RuntimeError('module compilation failed: ' + name + '\n' + log)
        paths = [str(generated / path) for path in sources]
        executable = output / 'native-draft'
        code, log = compile_app(paths, executable, 'baseline-compile')
        if code:
            raise RuntimeError('baseline compilation failed\n' + log)
        code, log = run([str(executable)], 'baseline-runtime')
        count = re.search(r'^RESULT_ASSERTIONS (\d+)$', log, re.M)
        if code or not count:
            raise RuntimeError('baseline runtime failed\n' + log)
        record['assertions'] = int(count[1])
        for name, path, edits, witness in MUTANTS:
            changed = files[path]
            matches = []
            for old, new in edits:
                matches.append(changed.count(old))
                changed = changed.replace(old, new, 1)
            entry = {'name': name, 'witness': witness, 'anchorMatches': matches, 'compiled': False, 'caught': False}
            record['mutants'].append(entry)
            if any(count != 1 for count in matches) or changed == files[path]:
                continue
            variant = output / ('mutant-' + name)
            variant.mkdir()
            mutant_source = variant / Path(path).name
            mutant_source.write_text(changed)
            variant_paths = [str(mutant_source) if source == path else str(generated / source) for source in sources]
            code, log = compile_app(variant_paths, variant / 'run', name + '-compile')
            entry['compileExitCode'] = code
            if code:
                entry['diagnostic'] = log[-8000:]
                continue
            entry['compiled'] = True
            code, log = run([str(variant / 'run')], name + '-runtime')
            failures = re.findall(r'^FAIL (.*)$', log, re.M)
            entry['runtimeExitCode'] = code
            entry['runtimeFailures'] = failures
            entry['caught'] = code == 1 and failures == [witness]
            if not entry['caught']:
                entry['diagnostic'] = log[-8000:]
        record['exitCode'] = 0 if all(entry['compiled'] and entry['caught'] for entry in record['mutants']) else 1
    except Exception as error:
        record['error'] = str(error)
        record['exitCode'] = 2
    finally:
        record['generatedInputsUnchanged'] = all(hashlib.sha256((generated / name).read_bytes()).hexdigest() == digest
                                                  for name, digest in originals.items())
        if not record['generatedInputsUnchanged']:
            record['exitCode'] = 2
        (output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
        print('RESULT_JSON ' + json.dumps(record), flush=True)
    return record['exitCode']


if __name__ == '__main__':
    try:
        code = main()
    except Exception as error:
        print('RESULT_JSON ' + json.dumps({'exitCode': 2, 'error': str(error)[-8000:]}), flush=True)
        code = 2
    sys.exit(code)
