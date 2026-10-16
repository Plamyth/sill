"""Parent-only pure runtime driver. Usage: python3 -B run.py ROOT OUTPUT."""
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


def main():
    root, output = map(lambda p: Path(p).resolve(), sys.argv[1:3])
    if output == root or root in output.parents:
        raise SystemExit('OUTPUT must be isolated from source ROOT')
    output.mkdir(parents=True, exist_ok=True)
    if (output / 'result.json').exists():
        raise SystemExit('Reconcile prior output before reusing it')
    started = time.monotonic()
    files, manifest = fixture(root)
    before = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in root.rglob('*') if p.is_file() and p.suffix in ('.swift', '.py', '.sh')}
    generated = output / 'generated'
    for name, source in files.items():
        path = generated / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source)
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1', TMPDIR=str(output / 'tmp'))
    Path(env['TMPDIR']).mkdir(exist_ok=True)
    cache = output / 'cache'
    cache.mkdir(exist_ok=True)
    base = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(cache)]
    record = {'scope': 'actual source extraction with inert framework and connection adapters; no physical display or decoder proof',
              'extractionSHA256': manifest, 'commands': [], 'mutants': [], 'assertions': 0}

    def run(command, label):
        remaining = 540 - (time.monotonic() - started)
        if remaining <= 0:
            raise TimeoutError('540 second driver budget exhausted')
        child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                 env=env, start_new_session=True)
        try:
            log, _ = child.communicate(timeout=min(120, remaining))
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                log, _ = child.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                log, _ = child.communicate(timeout=5)
            raise TimeoutError(label + ' exceeded its command budget')
        (output / (label + '.log')).write_text(log)
        record['commands'].append({'label': label, 'exitCode': child.returncode, 'pid': child.pid, 'reaped': child.poll() is not None})
        return child.returncode, log

    def module(name, sources):
        return base + ['-parse-as-library', '-emit-module', '-emit-object', '-whole-module-optimization',
                       '-module-name', name] + [str(generated / n) for n in sources] + [
                       '-emit-module-path', str(output / (name + '.swiftmodule')), '-o', str(output / (name + '.o'))]

    protocol = ['Sources/StreamProtocol/' + n + '.swift' for n in
                ['StreamMessage', 'Switcher', 'Input', 'Compatibility', 'Pointer', 'SafeText']]
    sources = ['Client.swift', 'Host.swift', 'Geometry.swift', 'Display.swift', 'Framework.swift', 'Accounting.swift', 'MessageReader.swift', 'ProbeCap.swift',
               'iOSClient/SessionLink.swift', 'iOSClient/KeyChords.swift', 'Sources/SillHost/KeyStrokes.swift', 'Sources/SillHost/SourceInputFence.swift',
               'visionOSClient/VisionPointer.swift', 'visionOSClient/VisionInputSession.swift',
               'visionOSClient/VisionInputDebt.swift', 'visionOSClient/VisionPresentation.swift',
               'visionOSClient/VisionRemoteKey.swift', 'main.swift']
    objects = [str(output / (n + '.o')) for n in ['Network', 'SwiftUI', 'StreamProtocol']]

    def compile_app(paths, executable, label):
        return run(base + ['-package-name', 'sill', '-I', str(output)] + paths + objects + ['-o', str(executable)], label)

    try:
        for name, paths in [('Network', ['Network.swift']), ('SwiftUI', ['SwiftUI.swift']), ('StreamProtocol', protocol)]:
            code, log = run(module(name, paths), 'module-' + name)
            if code: raise RuntimeError('module failed: ' + name + '\n' + log)
        paths = [str(generated / n) for n in sources]
        executable = output / 'epoch'
        code, log = compile_app(paths, executable, 'baseline-compile')
        if code: raise RuntimeError('baseline compilation failed\n' + log)
        code, log = run([str(executable)], 'baseline-runtime')
        match = re.search(r'^RESULT_ASSERTIONS (\d+)$', log, re.M)
        record['assertions'] = int(match[1]) if match else 0
        if code or not match: raise RuntimeError('baseline runtime failed\n' + log)
        for name, path, old, new, witness in MUTANTS:
            source = files[path]
            variant = output / ('mutant-' + name)
            variant.mkdir()
            if name == 'held-host-epoch':
                occurrence = source.rfind(old)
                changed = source[:occurrence] + source[occurrence:].replace(old, new, 1)
                count = int(occurrence >= 0)
            else:
                count = source.count(old)
                changed = source.replace(old, new, 1)
            entry = {'name': name, 'witness': witness, 'anchorMatches': count, 'caught': False}
            record['mutants'].append(entry)
            if count != 1: continue
            mutant_source = variant / Path(path).name
            mutant_source.write_text(changed)
            if path in protocol:
                mutated_protocol = [str(mutant_source) if n == path else str(generated / n) for n in protocol]
                code, log = run(base + ['-parse-as-library', '-emit-module', '-emit-object', '-whole-module-optimization',
                    '-module-name', 'StreamProtocol'] + mutated_protocol + ['-emit-module-path', str(output / 'StreamProtocol.swiftmodule'),
                    '-o', str(output / 'StreamProtocol.o')], name + '-compile-module')
                compile_paths = paths
            else:
                code = 0
                compile_paths = [str(mutant_source) if n == path else str(generated / n) for n in sources]
            if code == 0:
                code, log = compile_app(compile_paths, variant / 'epoch', name + '-compile')
            entry['compileExit'] = code
            if code: entry['diagnostic'] = log[-8000:]
            if code == 0:
                code, log = run([str(variant / 'epoch')], name + '-runtime')
                entry['runtimeExit'] = code
                entry['caught'] = code != 0 and ('FAIL ' + witness) in log
                if not entry['caught']: entry['diagnostic'] = log[-8000:]
            if path in protocol:
                code, log = run(module('StreamProtocol', protocol), name + '-restore-module')
                if code: raise RuntimeError('protocol restore failed\n' + log)
        record['mutationCount'] = len(record['mutants'])
        record['mutationsCaught'] = sum(m['caught'] for m in record['mutants'])
        record['exitCode'] = 0 if record['mutationsCaught'] == len(MUTANTS) else 1
    except Exception as error:
        record['error'] = str(error)
        record['exitCode'] = 2
    finally:
        record['sourceSHA256'] = before
        record['sourceUnchanged'] = all((root / n).exists() and hashlib.sha256((root / n).read_bytes()).hexdigest() == h for n, h in before.items())
        record['seconds'] = time.monotonic() - started
        if not record['sourceUnchanged']: record['exitCode'] = 2
        (output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
        print('RESULT_JSON ' + json.dumps(record), flush=True)
    return record['exitCode']


if __name__ == '__main__':
    sys.exit(main())
