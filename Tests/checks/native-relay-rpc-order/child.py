import json
import os
import sys
import time
import uuid

mode, log_path = sys.argv[1:]
boot = str(uuid.uuid4())
configuration = None
controller = None
sequence = 0
binding = None
prepared_receipt = None
bootstrap_count = 0
previous_bootstrap_reply = None
bootstrap_intent_id = str(uuid.uuid4())
bootstrap_intent_generation = str(uuid.uuid4())
bootstrap_binding_epoch = str(uuid.uuid4())
bootstrap_transport_id = str(uuid.uuid4())
bootstrap_operation_id = str(uuid.uuid4())

def snapshot():
    return dict(schemaVersion=1, revision='1', intent=None, binding=None)

def receipt(request):
    return dict(schemaVersion=1, operationId=request['operationId'], privacyGeneration=request['privacyGeneration'],
                registryRevision=request['registryRevision'], participantId='s23.audio.relay', bootId=boot,
                state='quiescent', facts={key: True for key in ['admissionFenced', 'startsSettled', 'mediaDetached',
                   'callbacksDrained', 'buffersEmpty', 'workersExited']}, reason=None)

def forwarding_bootstrap(payload):
    assert set(payload) == {'pairedDeviceId', 'pairingGeneration'}
    own = dict(intentRevision='7', bindingRevision='11')
    state = dict(schemaVersion=1, revision='9', intent=None, binding=None)
    credential = dict(pairedDeviceId=payload['pairedDeviceId'], pairingGeneration=payload['pairingGeneration'], credential='a' * 43)
    result = dict(credential=credential, ownCursor=own, snapshot=state)
    scenario = mode.removeprefix('bootstrap-')
    if scenario == 'empty':
        own.update(intentRevision='0', bindingRevision='0')
    if scenario == 'max-cursor':
        own.update(intentRevision='18446744073709551615', bindingRevision='18446744073709551615')
    if scenario in ['own-off', 'own-off-binding', 'other-off', 'other-active', 'refused', 'cursor-mismatch'] or scenario.startswith('bad-snapshot-'):
        other = scenario in ['other-off', 'other-active', 'refused']
        active = scenario == 'other-active'
        owner = 'cd' * 32 if other else payload['pairedDeviceId']
        state['intent'] = dict(pairedDeviceId=owner, intentId=bootstrap_intent_id, intentRevision='99' if other else '7',
            intentGeneration=bootstrap_intent_generation, inputDesired=active, outputDesired=active,
            sentryDesired=True, localMutedDesired=True)
        if scenario in ['own-off-binding', 'other-active', 'refused'] or scenario.startswith('bad-snapshot-'):
            assert configuration is not None
            state['binding'] = dict(pairedDeviceId=owner, intentGeneration=bootstrap_intent_generation,
                bindingEpoch=bootstrap_binding_epoch, transportId=bootstrap_transport_id, transportKind='native',
                operationId=bootstrap_operation_id, phase='active' if active else 'off', configuration=configuration)
    if scenario == 'refused':
        return dict(state='refused', code='remembered_device_superseded', snapshot=state)
    if scenario == 'credential-id': credential['pairedDeviceId'] = 'cd' * 32
    elif scenario == 'credential-generation': credential['pairingGeneration'] = str(uuid.uuid4())
    elif scenario == 'cursor-mismatch': own['intentRevision'] = '6'
    elif scenario.startswith('missing-'): result.pop(scenario.removeprefix('missing-'))
    elif scenario == 'extra': result['appKey'] = 'caller-claim-must-be-rejected'
    elif scenario.startswith('credential-missing-'): credential.pop(scenario.removeprefix('credential-missing-'))
    elif scenario == 'credential-extra': credential['role'] = 'audioOwner'
    elif scenario == 'credential-invalid': credential['credential'] = 'invalid'
    elif scenario.startswith('cursor-missing-'): own.pop(scenario.removeprefix('cursor-missing-'))
    elif scenario == 'cursor-extra': own['otherDevice'] = dict(intentRevision='99', bindingRevision='101')
    elif scenario.startswith('cursor-invalid-'):
        field, invalid = scenario.removeprefix('cursor-invalid-').split('-', 1)
        own[field] = dict(number=1, boolean=True, fraction=1.5, null=None, object={}, array=[], empty='',
            negative='-1', plus='+1', leading='01', overflow='18446744073709551616',
            whitespace=' 1', exponent='1e2', decimal='1.0')[invalid]
    elif scenario.startswith('bad-snapshot-'):
        invalid = scenario.removeprefix('bad-snapshot-')
        if invalid.startswith('missing-'): state.pop(invalid.removeprefix('missing-'))
        elif invalid == 'extra': state['unexpected'] = True
        elif invalid == 'schema': state['schemaVersion'] = 2
        elif invalid == 'revision': state['revision'] = '01'
        elif invalid == 'intent-revision': state['intent']['intentRevision'] = '0'
        elif invalid == 'intent-protection': state['intent']['localMutedDesired'] = False
        elif invalid == 'binding-owner': state['binding']['pairedDeviceId'] = 'cd' * 32
        elif invalid == 'binding-generation': state['binding']['intentGeneration'] = str(uuid.uuid4())
        elif invalid == 'binding-active-off': state['binding']['phase'] = 'active'
        elif invalid == 'binding-without-intent': state['intent'] = None
        elif invalid == 'binding-configuration': state['binding']['configuration'] = {}
        else: raise AssertionError(invalid)
    return result

def forwarding_request(payload):
    assert set(payload) == {'pairedDeviceId', 'credential', 'intent'}
    intent = payload['intent']
    assert set(intent) == {'schemaVersion', 'pairedDeviceId', 'intentId', 'intentRevision', 'action',
                           'inputDesired', 'outputDesired', 'expectedRevision', 'transportId',
                           'transportKind', 'bindingRevision'}
    assert payload['pairedDeviceId'] == intent['pairedDeviceId'] == 'ab' * 32
    assert payload['credential'] == 'a' * 43
    assert intent['schemaVersion'] == 1 and intent['transportKind'] == 'native'
    assert intent['intentRevision'] == '7' and intent['expectedRevision'] == '9' and intent['bindingRevision'] == '11'
    assert intent['action'] == 'request' and intent['inputDesired'] is True and intent['outputDesired'] is False
    uuid.UUID(intent['intentId'])
    uuid.UUID(intent['transportId'])
    state = dict(schemaVersion=1, revision='12', binding=None, intent=dict(
        pairedDeviceId=intent['pairedDeviceId'], intentId=intent['intentId'], intentRevision=intent['intentRevision'],
        intentGeneration=bootstrap_intent_generation, inputDesired=intent['inputDesired'],
        outputDesired=intent['outputDesired'], sentryDesired=True, localMutedDesired=True))
    if mode == 'request-refused':
        return dict(state='refused', code='stale_revision', snapshot=state)
    return state

for line in sys.stdin:
    req = json.loads(line)
    assert set(req) == {'schemaVersion', 'controllerBootId', 'sequence', 'requestId', 'method', 'payload'}
    sequence += 1
    assert req['sequence'] == str(sequence)
    assert req['schemaVersion'] == 1
    assert controller is None or controller == req['controllerBootId']
    controller = req['controllerBootId']
    with open(log_path, 'a') as log:
        log.write(json.dumps(req) + '\n')
    method, payload = req['method'], req['payload']
    if mode.startswith('bootstrap-'):
        assert method in {'bootstrap', 'inspectRuntime', 'forwardingConfigure', 'forwardingBootstrap',
                          'hold', 'hold-bootstrap-deadline', 'after-bootstrap'}, '관측 중 허용되지 않은 RPC'
    if mode.startswith('request-'):
        assert method in {'bootstrap', 'inspectRuntime', 'forwardingRequest', 'hold', 'after-request'}, '요청 검사 중 허용되지 않은 RPC'
    if method == 'bootstrap':
        result = dict(participantId='s23.audio.relay', capabilities=['quiesce-v1', 'inspect-v1', 'runtime-v1', 'forwarding-v1'])
    elif method == 'inspectRuntime':
        result = dict(runtimeVersion=1, serverListening=True, address='127.0.0.1', port=0,
                      python='inert-python', router='inert-router', pythonArguments=['-I', '-B'])
    elif method == 'forwardingConfigure':
        configuration = payload
        result = snapshot()
    elif method == 'forwardingRegister':
        time.sleep(2.2 if mode == 'queued-over-prepare' else 0.12)
        result = dict(pairedDeviceId=payload['pairedDeviceId'], pairingGeneration=payload['pairingGeneration'], credential='a' * 43)
    elif method == 'forwardingBootstrap':
        bootstrap_count += 1
        if mode == 'bootstrap-delayed': time.sleep(0.2)
        result = forwarding_bootstrap(payload)
    elif method == 'forwardingRequest':
        if mode == 'request-delayed': time.sleep(0.2)
        result = forwarding_request(payload)
    elif method == 'forwardingSnapshot':
        intent_generation, epoch = str(uuid.uuid4()), str(uuid.uuid4())
        binding = binding or dict(pairedDeviceId='ab' * 32, intentGeneration=intent_generation, bindingEpoch=epoch,
                       transportId=str(uuid.uuid4()), transportKind='http' if mode.startswith('http') else 'native', operationId=str(uuid.uuid4()),
                       phase='quiescing', configuration=configuration)
        result = dict(schemaVersion=1, revision='1', binding=binding, intent=dict(pairedDeviceId='ab' * 32,
            intentId=str(uuid.uuid4()), intentRevision='1', intentGeneration=binding['intentGeneration'],
            inputDesired=True, outputDesired=True, sentryDesired=True, localMutedDesired=True))
    elif method == 'forwardingPrepare':
        assert set(payload) == {'intentGeneration', 'bindingEpoch'}
        assert payload['intentGeneration'].lower() == binding['intentGeneration'].lower()
        assert payload['bindingEpoch'].lower() == binding['bindingEpoch'].lower()
        time.sleep(3.2 if mode in ['slow-prepare', 'queued-over-prepare'] else 5.3 if mode == 'over-prepare' else 0)
        request = dict(operationId=binding['operationId'], privacyGeneration=configuration['privacyGeneration'],
                       registryRevision=configuration['registryRevision'])
        result = receipt(request)
        receipt_mode = mode[5:] if mode.startswith('http-') else mode
        if receipt_mode.startswith('receipt-'):
            field = receipt_mode[len('receipt-'):]
            if field == 'state': result[field] = 'blocked'
            elif field == 'facts': result[field]['workersExited'] = False
            elif field == 'schemaVersion': result[field] = 2
            elif field == 'registryRevision': result[field] = '999'
            elif field == 'participantId': result[field] = 'native.sill'
            else: result[field] = str(uuid.uuid4())
        prepared_receipt = result
    elif method == 'fenceAndQuiesce':
        result = receipt(payload)
        if mode.startswith('conflict'):
            result.update(state='blocked', facts={key: None for key in result['facts']}, reason='audio_preparation_conflict')
            field = mode.removeprefix('conflict-')
            if field in ['operationId', 'privacyGeneration', 'bootId']: result[field] = str(uuid.uuid4())
            elif field == 'registryRevision': result[field] = '999'
            elif field == 'schemaVersion': result[field] = 2
            elif field == 'participantId': result[field] = 'native.sill'
            elif field == 'state': result[field] = 'unknown'
            elif field == 'reason': result[field] = 'unknown_conflict'
            elif field == 'facts': result[field]['workersExited'] = True
    elif method == 'inspect':
        result = prepared_receipt if prepared_receipt and payload['operationId'].lower() == prepared_receipt['operationId'].lower() else None
    else:
        if method.startswith('hold'): time.sleep(3.4 if method == 'hold-bootstrap-deadline' else 0.2)
        result = 1
    reply = dict(schemaVersion=1, controllerBootId=controller, sequence=req['sequence'],
                 requestId=req['requestId'], relayBootId=boot, processId=os.getpid(), result=result)
    if method == 'forwardingBootstrap' and mode.startswith('bootstrap-stale-') and bootstrap_count == 2:
        field = mode.removeprefix('bootstrap-stale-')
        reply[field] = previous_bootstrap_reply[field] if field in ['sequence', 'requestId'] else str(uuid.uuid4())
    if method == 'forwardingBootstrap': previous_bootstrap_reply = reply.copy()
    if method == 'bad':
        if mode == 'schemaVersion': reply[mode] = 2
        elif mode == 'sequence': reply[mode] = '999'
        elif mode == 'processId': reply[mode] += 1
        elif mode in ['controllerBootId', 'relayBootId', 'requestId']: reply[mode] = str(uuid.uuid4())
        elif mode == 'unknown': reply['unexpected'] = True
    frame = json.dumps(reply)
    if method == 'bad':
        if mode == 'duplicate': frame = frame[:-1] + ', "requestId": "' + req['requestId'] + '"}'
        elif mode == 'bom': frame = '\ufeff' + frame
        elif mode == 'oversize': frame = ' ' * 16385 + frame
        elif mode == 'double': frame += '\n' + frame
        elif mode == 'invalid': frame = '{bad}'
        elif mode == 'eof': sys.exit(0)
        elif mode == 'blank': frame = ''
    try:
        print(frame, flush=True)
    except BrokenPipeError:
        os._exit(0)
