"""Parent-only driver: python3 -B run.py ROOT OUTPUT. Never run on a product host."""
import hashlib
import json
import os
import platform
import re
import signal
import subprocess
import sys
import time
from pathlib import Path
from extract import fixture
from mutants import MUTANTS


def main():
    root, output = (Path(p).resolve() for p in sys.argv[1:3])
    receiver_only = sys.argv[3:] == ['--receiver-only']
    if sys.argv[3:] and not receiver_only:
        raise SystemExit('Unknown check selection')
    if output == root or root in output.parents:
        raise SystemExit('OUTPUT must be outside ROOT')
    output.mkdir(parents=True, exist_ok=True)
    if (output / 'result.json').exists():
        raise SystemExit('Reconcile the previous result before reusing OUTPUT')
    started = time.monotonic()
    record = {'scope': 'actual receiver, wire, owned-block HAL sink with inert unit/object seams, extracted authenticated dispatch; no native IO or call proof',
              'commands': [], 'mutants': [], 'assertions': 0, 'exitCode': 2}
    if receiver_only:
        record['scope'] = 'actual receiver, wire, owned-block HAL sink and cleanup entry; inert seams only; excludes server/catalog/owner integration'
    source_hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for folder in ['Sources', 'Tests/checks/microphone-uplink']
                     for p in (root / folder).rglob('*') if p.is_file()}
    if not receiver_only:
        name = 'Tests/checks/host-voice-protection/FakeHAL.swift'
        source_hashes[name] = hashlib.sha256((root / name).read_bytes()).hexdigest()
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1', TMPDIR=str(output / 'tmp'))
    Path(env['TMPDIR']).mkdir(exist_ok=True)
    generated = output / 'generated'
    cache = output / 'cache'
    cache.mkdir(exist_ok=True)
    base = ['/usr/bin/xcrun', 'swiftc', '-target', platform.machine() + '-apple-macosx14.0', '-swift-version', '5', '-package-name', 'sill', '-module-cache-path', str(cache)]

    def run(command, label):
        remaining = 660 - (time.monotonic() - started)
        if remaining <= 0:
            raise TimeoutError('660 second budget exhausted')
        child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 text=True, env=env, start_new_session=True)
        timed_out = False
        try:
            log, _ = child.communicate(timeout=min(90, remaining))
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(child.pid, signal.SIGTERM)
            try:
                log, _ = child.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                log, _ = child.communicate(timeout=5)
        (output / (label + '.log')).write_text(log)
        record['commands'].append({'label': label, 'argv': command, 'exitCode': child.returncode,
                                   'pid': child.pid, 'reaped': child.poll() is not None, 'timedOut': timed_out})
        if timed_out:
            raise TimeoutError(label + ': diagnostics saved before teardown')
        return child.returncode, log

    def compile_module(name, paths, label):
        return run(base + ['-parse-as-library', '-emit-module', '-emit-object', '-whole-module-optimization', '-module-name', name]
                   + paths + ['-emit-module-path', str(output / (name + '.swiftmodule')), '-o', str(output / (name + '.o'))], label)

    try:
        files, manifest = fixture(root, receiver_only=receiver_only)
        mutants = [m for m in MUTANTS if not receiver_only or (m[1] in files and m[4] in files['Main.swift'])]
        record['extractionSHA256'] = manifest
        for name, source in files.items():
            path = generated / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source)
        protocol = [name for name in files if name.startswith('Sources/StreamProtocol/')]
        app = [name for name in files if name not in protocol and name != 'Network.swift']
        objects = [str(output / (name + '.o')) for name in ['Network', 'StreamProtocol']]
        for name, sources in [('Network', ['Network.swift']), ('StreamProtocol', protocol)]:
            code, log = compile_module(name, [str(generated / n) for n in sources], 'module-' + name)
            if code:
                raise RuntimeError(name + ' failed\n' + log)

        def compile_app(replacement=None, executable=None, label='baseline-compile'):
            paths = [str(replacement[1]) if replacement and n == replacement[0] else str(generated / n) for n in app]
            return run(base + ['-parse-as-library', '-I', str(output)] + paths + objects + ['-o', str(executable)], label)

        executable = output / 'check'
        code, log = compile_app(executable=executable)
        if code:
            raise RuntimeError('baseline compile failed\n' + log)
        code, log = run([str(executable)], 'baseline-runtime')
        match = re.search(r'^RESULT_ASSERTIONS (\d+)$', log, re.M)
        if code or not match:
            raise RuntimeError('baseline runtime failed\n' + log)
        record['assertions'] = int(match[1])
        for name, target, old, new, witness in mutants:
            entry = {'name': name, 'witness': witness, 'anchorMatches': files[target].count(old), 'caught': False}
            record['mutants'].append(entry)
            expected_matches = 2 if name == 'pair' else 1
            entry['expectedAnchorMatches'] = expected_matches
            if entry['anchorMatches'] != expected_matches:
                continue
            mutated = files[target].replace(old, new, expected_matches)
            if name == 'pair':
                # Pairing is now checked in both lane bodies and the shared route gate.
                auth = 'return AudioRoutingPolicy.authorized(encrypted: route?.encrypted == true, paired: paired,'
                entry['routeAuthAnchorMatches'] = mutated.count(auth)
                if entry['routeAuthAnchorMatches'] != 1:
                    continue
                mutated = mutated.replace(auth, auth.replace('paired: paired', 'paired: true'), 1)
            variant = output / ('mutant-' + name)
            variant.mkdir()
            path = variant / Path(target).name
            path.write_text(mutated)
            if target in protocol:
                code, log = compile_module('StreamProtocol', [str(path) if n == target else str(generated / n) for n in protocol], name + '-module')
            else:
                code = 0
            if code == 0:
                code, log = compile_app((target, path), variant / 'check', name + '-compile')
            entry['compileExit'] = code
            if code == 0:
                code, log = run([str(variant / 'check')], name + '-runtime')
                entry['runtimeExit'] = code
                entry['caught'] = code != 0 and ('FAIL ' + witness) in log
            if not entry['caught']:
                entry['diagnostic'] = log[-12000:]
            if target in protocol:
                code, log = compile_module('StreamProtocol', [str(generated / n) for n in protocol], name + '-restore')
                if code:
                    raise RuntimeError('protocol restore failed\n' + log)
        record['mutationCount'] = len(mutants)
        record['mutationsCaught'] = sum(m['caught'] for m in record['mutants'])
        record['exitCode'] = 0 if record['mutationsCaught'] == len(mutants) else 1
    except Exception as error:
        record['error'] = str(error)
    finally:
        record['sourceSHA256'] = source_hashes
        record['sourceUnchanged'] = all((root / name).is_file() and hashlib.sha256((root / name).read_bytes()).hexdigest() == digest
                                        for name, digest in source_hashes.items())
        if not record['sourceUnchanged']:
            record['exitCode'] = 2
        record['seconds'] = time.monotonic() - started
        (output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
        print('RESULT_JSON ' + json.dumps(record), flush=True)
    return record['exitCode']


if __name__ == '__main__':
    sys.exit(main())
