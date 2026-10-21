#!/usr/bin/env python3
"""서비스·네트워크·HAL을 사용하지 않는 stdio 프로세스 경계."""
import json
import os
from pathlib import Path
import sys
import time
import uuid

directory = Path(sys.argv[1])
boot = str(uuid.uuid4())
configuration = None
revision = 0
intent = None
binding = None
connections = {}
credentials = {}
prepared = None
http_started = False


def snapshot():
    return dict(schemaVersion=1, revision=str(revision), intent=intent, binding=binding)


def record(request):
    payload = request['payload']
    event = dict(method=request['method'], at=time.monotonic())
    for key in ('operation', 'pairedDeviceId', 'connectionId', 'bindingEpoch'):
        if key in payload:
            event['connectionID' if key == 'connectionId' else key] = payload[key]
    if request['method'] == 'forwardingRequest':
        event['credentialMatches'] = payload['credential'] == credentials.get(payload['pairedDeviceId'])
    with (directory / 'events.jsonl').open('a') as output:
        output.write(json.dumps(event) + '\n')


def wait_flag(name):
    marker = directory / ('hold-' + name)
    if marker.exists():
        deadline = time.monotonic() + 2
        while not (directory / ('release-' + name)).exists():
            if time.monotonic() >= deadline:
                raise TimeoutError('격리 fixture gate 시간 초과')
            time.sleep(.005)


def receipt():
    return dict(schemaVersion=1, operationId=binding['operationId'],
                privacyGeneration=configuration['privacyGeneration'],
                registryRevision=configuration['registryRevision'], participantId='s23.audio.relay', bootId=boot,
                state='quiescent', facts=dict(admissionFenced=True, startsSettled=True, mediaDetached=True,
                                             callbacksDrained=True, buffersEmpty=True, workersExited=True), reason=None)


for line in sys.stdin:
    request = json.loads(line)
    record(request)
    method, payload = request['method'], request['payload']
    if method == 'bootstrap':
        result = dict(participantId='s23.audio.relay', capabilities=['quiesce-v1', 'inspect-v1', 'runtime-v1', 'forwarding-v1'])
    elif method == 'inspectRuntime':
        result = dict(runtimeVersion=1, serverListening=True, address='127.0.0.1', port=0,
                      python='inert-python', router='inert-router', pythonArguments=['-I', '-B'])
    elif method == 'forwardingConfigure':
        configuration = payload
        binding = None
        revision += 1
        result = snapshot()
    elif method == 'forwardingBootstrap':
        wait_flag('bootstrap')
        credentials.setdefault(payload['pairedDeviceId'], 'R' * 43)
        result = dict(credential=dict(pairedDeviceId=payload['pairedDeviceId'], pairingGeneration=payload['pairingGeneration'],
                                      credential=credentials[payload['pairedDeviceId']]),
                      ownCursor=dict(intentRevision=intent['intentRevision'] if intent and intent['pairedDeviceId'] == payload['pairedDeviceId'] else '0',
                                     bindingRevision='0'), snapshot=snapshot())
    elif method == 'forwardingEvidence':
        if payload['operation'] == 'attach':
            wait_flag('attach')
        key = payload['connectionId']
        if payload['operation'] in ('attach', 'renew'):
            connections[key] = (payload['pairedDeviceId'], time.monotonic())
        elif payload['operation'] == 'detach':
            connections.pop(key, None)
        if binding and not any(value[0] == binding['pairedDeviceId'] for value in connections.values()):
            binding = None
        result = snapshot()
        if payload['operation'] == 'attach' and (directory / 'refuse-attach').exists():
            result = dict(state='refused', code='fixture_attach_refused', snapshot=snapshot())
        if payload['operation'] == 'attach' and (directory / 'mismatched-cursor').exists():
            generation = str(uuid.uuid4())
            intent = dict(pairedDeviceId=payload['pairedDeviceId'], intentId=str(uuid.uuid4()), intentRevision='9',
                          intentGeneration=generation, inputDesired=True, outputDesired=True,
                          sentryDesired=True, localMutedDesired=True)
            result = snapshot()
    elif method == 'forwardingRequest':
        incoming = payload['intent']
        assert payload['credential'] == credentials.get(payload['pairedDeviceId'])
        assert incoming['transportKind'] == 'native'
        generation = str(uuid.uuid4())
        intent = dict(pairedDeviceId=payload['pairedDeviceId'], intentId=incoming['intentId'], intentRevision=incoming['intentRevision'],
                      intentGeneration=generation, inputDesired=incoming['inputDesired'], outputDesired=incoming['outputDesired'],
                      sentryDesired=True, localMutedDesired=True)
        binding = dict(pairedDeviceId=payload['pairedDeviceId'], intentGeneration=generation, bindingEpoch=str(uuid.uuid4()),
                       transportId=incoming['transportId'], transportKind='native', operationId=str(uuid.uuid4()),
                       phase='quiescing', configuration=configuration)
        revision += 1
        result = snapshot()
    elif method == 'forwardingSnapshot':
        wait_flag('snapshot')
        now = time.monotonic()
        connections = {key: value for key, value in connections.items() if now - value[1] < 10}
        if (directory / 'http-pending').exists() and not http_started and binding is None and connections:
            http_started = True
            peer = next(iter(connections.values()))[0]
            generation = str(uuid.uuid4())
            intent = dict(pairedDeviceId=peer, intentId=str(uuid.uuid4()), intentRevision='1', intentGeneration=generation,
                          inputDesired=True, outputDesired=True, sentryDesired=True, localMutedDesired=True)
            binding = dict(pairedDeviceId=peer, intentGeneration=generation, bindingEpoch=str(uuid.uuid4()),
                           transportId=str(uuid.uuid4()), transportKind='http', operationId=str(uuid.uuid4()),
                           phase='quiescing', configuration=configuration)
            revision += 1
        result = snapshot()
    elif method == 'forwardingPrepare':
        assert payload['bindingEpoch'] == binding['bindingEpoch']
        prepared = receipt()
        result = prepared
    elif method == 'inspect':
        result = prepared if prepared and payload['operationId'] == prepared['operationId'] else None
    elif method == 'forwardingCommit':
        wait_flag('commit')
        assert payload['bindingEpoch'] == binding['bindingEpoch']
        assert payload['configuration'] == configuration and len(payload['receipts']) == 2
        assert all(payload['localProtection'].values())
        binding = dict(binding, phase='active' if intent['inputDesired'] or intent['outputDesired'] else 'off')
        revision += 1
        result = snapshot()
    elif method == 'forwardingDisconnect':
        if binding and binding['bindingEpoch'] == payload['bindingEpoch']:
            binding = None
            revision += 1
        result = snapshot()
    else:
        raise AssertionError('허용하지 않은 fixture RPC ' + method)
    response_boot = str(uuid.uuid4()) if method == 'forwardingSnapshot' and (directory / 'wrong-boot').exists() else boot
    response = dict(schemaVersion=1, controllerBootId=request['controllerBootId'], sequence=request['sequence'],
                    requestId=request['requestId'], relayBootId=response_boot, processId=os.getpid(), result=result)
    print(json.dumps(response), flush=True)
