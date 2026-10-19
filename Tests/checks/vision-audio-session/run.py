import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys

MUTANTS = [
    ('supersession', [('if error is GraphWait, playbackIsSuperseded() {', 'if false {')], 'normal format replacement does not quarantine lease'),
    ('invalidation', [('if transitioning { quarantine(reason); return }\n        transitioning = true', 'if transitioning { quarantine(reason); return }')], 'invalidation callback cannot replace a resource before old stop finishes'),
    ('generation', [('&& (generation == nil || state.generation == generation)', '&& true')], 'previous graph stays silent after new commit'),
    ('quarantine', [('guard state.problem == nil, state.reserved[role] == nil,', 'guard state.reserved[role] == nil,')], 'configure quarantine refuses same-owner capture reservation'),
    ('permission', [('guard !transitioning, permitted(), driver.recordPermissionGranted,', 'guard !transitioning, permitted(),')], 'permission refusal cannot configure or start hardware'),
    ('permission-recheck', [('try driver.start(playback: output, capture: input)\n            try validateRoles()', 'try driver.start(playback: output, capture: input)')], 'permission revoked during start prevents commit'),
    ('stop-gate', [('state.revoked.insert(claim.role)\n            state.committed.removeValue(forKey: claim.role)', '_ = claim')], 'stop revokes input before hardware cleanup'),
]

def main():
    root, output = [Path(x).resolve() for x in sys.argv[1:3]]
    if output == root or root in output.parents:
        raise RuntimeError('isolated output required')
    output.mkdir(exist_ok=True, parents=True)
    record = {'scope': 'actual hardware coordinator and actual player with inert injected graph; software PCM only; no engine/session/device/permission/route I/O', 'commands': [], 'mutants': [], 'exitCode': 2}
    base = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(output/'cache')]
    def run(command, label):
        child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
        try:
            log, _ = child.communicate(timeout=90)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGTERM)
            try: log, _ = child.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                log, _ = child.communicate(timeout=5)
        (output/(label+'.log')).write_text(log)
        record['commands'].append({'label': label, 'exitCode': child.returncode, 'reaped': child.poll() is not None})
        return child.returncode, log
    def require(command, label):
        code, log = run(command, label)
        if code: raise RuntimeError(label+'\n'+log[-6000:])
        return log
    protocol = [root/'Sources/StreamProtocol'/n for n in ['AudioPacket.swift','StreamMessage.swift','AudioRouting.swift','Switcher.swift', 'Sentry.swift', 'TestDestinations.swift','AudioPrivacy.swift']]
    client_source = (root/'iOSClient/StreamClient.swift').read_text()
    begin = client_source.index('    func receiveVisionAudioCatalogBarrier(')
    end = client_source.index('    func receiveVisionAudioCatalogAcknowledgement(', begin)
    barrier_source = client_source[begin:end]
    barrier = output/'CatalogBarrier.swift'
    barrier.write_text('import Foundation\nimport StreamProtocol\nextension StreamClient {\n' + barrier_source + '}\n')
    record['catalogBarrierSHA256'] = hashlib.sha256(barrier_source.encode()).hexdigest()
    sources = [root/'visionOSClient'/n for n in ['VisionAudioBuffer.swift','VisionAudioHardware.swift','VisionAudioPlayer.swift']]
    main = root/'Tests/checks/vision-audio-session/main.swift'
    try:
        require(base+['-parse-as-library','-whole-module-optimization','-emit-module','-emit-object','-module-name','StreamProtocol']+list(map(str,protocol))+['-emit-module-path',str(output/'StreamProtocol.swiftmodule'),'-o',str(output/'StreamProtocol.o')], 'protocol-compile')
        def compile_run(paths, label, scenario=None):
            exe = output/label
            require(base+['-I',str(output)]+list(map(str,paths))+[str(barrier),str(main),str(output/'StreamProtocol.o'),'-o',str(exe)], label+'-compile')
            return run([str(exe)]+([scenario] if scenario else []), label+'-runtime')
        code, log = compile_run(sources, 'baseline')
        if code: raise RuntimeError('baseline runtime\n'+log)
        record['assertions'] = int(re.search(r'^RESULT_ASSERTIONS (\d+)$',log,re.M)[1])
        original = sources[1].read_text()
        for name, edits, witness in MUTANTS:
            variant = output/('mutant-'+name)
            variant.mkdir()
            mutated = original
            for old, new in edits:
                if mutated.count(old) != 1: raise RuntimeError('mutation anchor '+name)
                mutated = mutated.replace(old,new,1)
            path = variant/'VisionAudioHardware.swift'
            path.write_text(mutated)
            entry = {'name':name,'witness':witness,'compiled':False,'caught':False}
            record['mutants'].append(entry)
            scenario = {'supersession':'review','invalidation':'review','generation':'hardware','stop-gate':'hardware','quarantine':'failure','permission':'hardware','permission-recheck':'failure'}[name]
            entry['scenario'] = scenario
            code, log = compile_run([sources[0],path,sources[2]],'mutant-'+name+'-run',scenario)
            entry.update(compiled=True,exitCode=code,failures=re.findall(r'^FAIL (.*)$',log,re.M))
            entry['caught'] = code == 1 and witness in entry['failures']
        regression = [
            ('buffer', [root/'visionOSClient/VisionAudioBuffer.swift',root/'Tests/checks/vision-audio-player/main.swift']),
            ('consent', [root/'visionOSClient/VisionAudioState.swift',root/'Tests/checks/vision-audio-consent/main.swift']),
        ]
        route = root/'visionOSClient/VisionAudioRoute.swift'
        adapted = output/'VisionAudioRoute.swift'
        adapted.write_text(route.read_text().replace('import Network\n','').replace('import StreamProtocol\n',''))
        record['routeFixture'] = {'originalSHA256': hashlib.sha256(route.read_bytes()).hexdigest(), 'emittedSHA256': hashlib.sha256(adapted.read_bytes()).hexdigest(), 'substitution':'imports removed; existing identity-only Network/source fixtures, methods unchanged'}
        regression.append(('controller',[root/'visionOSClient/VisionAudioState.swift',root/'visionOSClient/VisionAudioController.swift',adapted,root/'Tests/checks/vision-audio-consent/adapter/main.swift']))
        record['regression'] = {}
        for name, paths in regression:
            exe = output/name
            require(base+list(map(str,paths))+['-o',str(exe)], name+'-compile')
            log = require([str(exe)],name+'-runtime')
            record['regression'][name] = log.strip().splitlines()[-1]
        record['exitCode'] = 0 if all(e['caught'] for e in record['mutants']) else 1
    except Exception as error:
        record['error'] = str(error)
    (output/'result.json').write_text(json.dumps(record,indent=2)+'\n')
    print('SUITE_RESULT '+json.dumps(record),flush=True)
    return record['exitCode']

if __name__ == '__main__': sys.exit(main())
