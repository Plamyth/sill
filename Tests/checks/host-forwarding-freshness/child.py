"""Inert, guarded-envelope stdio peer. No sockets, audio, keys, or apps."""
import json
import os
from pathlib import Path
import sys
import time
import uuid

control, events = map(Path, sys.argv[1:])
boot = str(uuid.uuid4())
controller = None
sequence = 0
revision = 0

def event(**values):
    with events.open('a') as stream:
        stream.write(json.dumps(dict(ns=time.monotonic_ns(), **values)) + '\n')

for line in sys.stdin:
    request = json.loads(line)
    assert set(request) == {'schemaVersion', 'controllerBootId', 'sequence', 'requestId', 'method', 'payload'}
    sequence += 1
    assert request['schemaVersion'] == 1 and request['sequence'] == str(sequence)
    assert controller is None or controller == request['controllerBootId']
    controller = request['controllerBootId']
    method, payload = request['method'], request['payload']
    options = json.loads(control.read_text())
    event(event='request', method=method, sequence=sequence)
    if method not in ['bootstrap', 'inspectRuntime']:
        time.sleep(options.get('delayMs', 0) / 1000)
    revision += 1
    snapshot = dict(schemaVersion=1, revision=str(revision), intent=None, binding=None)
    if method == 'bootstrap':
        result = dict(participantId='s23.audio.relay', capabilities=['quiesce-v1', 'inspect-v1', 'runtime-v1', 'forwarding-v1'])
    elif method == 'inspectRuntime':
        result = dict(runtimeVersion=1, serverListening=True, address='127.0.0.1', port=0,
                      python='inert-python', router='inert-router', pythonArguments=['-I', '-B'])
    elif method in ['forwardingConfigure', 'forwardingSnapshot']:
        result = snapshot
    elif method == 'forwardingBootstrap':
        assert set(payload) == {'pairedDeviceId', 'pairingGeneration'}
        credential = dict(pairedDeviceId=payload['pairedDeviceId'], pairingGeneration=payload['pairingGeneration'], credential='a' * 43)
        if options.get('wrongDevice'):
            credential['pairedDeviceId'] = 'cd' * 32
        if options.get('rotateCredential'):
            credential['credential'] = 'b' * 43
        result = dict(credential=credential, ownCursor=dict(intentRevision='0', bindingRevision='0'), snapshot=snapshot)
    elif method == 'forwardingEvidence':
        assert set(payload) == {'pairedDeviceId', 'pairingGeneration', 'connectionId', 'operation'}
        assert payload['operation'] in ['attach', 'renew', 'detach']
        result = snapshot
    elif method == 'hold':
        result = 1
    else:
        raise AssertionError(method)
    reply = dict(schemaVersion=1, controllerBootId=controller, sequence=request['sequence'], requestId=request['requestId'],
                 relayBootId=boot, processId=os.getpid(), result=result)
    encoded = json.dumps(reply).encode() + b'\n'
    split = options.get('splitMs', 0)
    if split:
        os.write(1, encoded[:1])
        event(event='firstChunkWritten', method=method)
        time.sleep(split / 1000)
        os.write(1, encoded[1:])
    else:
        os.write(1, encoded)
    event(event='newlineWritten', method=method)
