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

def snapshot():
    return dict(schemaVersion=1, revision='1', intent=None, binding=None)

def receipt(request):
    return dict(schemaVersion=1, operationId=request['operationId'], privacyGeneration=request['privacyGeneration'],
                registryRevision=request['registryRevision'], participantId='s23.audio.relay', bootId=boot,
                state='quiescent', facts={key: True for key in ['admissionFenced', 'startsSettled', 'mediaDetached',
                   'callbacksDrained', 'buffersEmpty', 'workersExited']}, reason=None)

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
    elif method == 'forwardingSnapshot':
        intent_generation, epoch = str(uuid.uuid4()), str(uuid.uuid4())
        binding = binding or dict(pairedDeviceId='ab' * 32, intentGeneration=intent_generation, bindingEpoch=epoch,
                       transportId=str(uuid.uuid4()), transportKind='native', operationId=str(uuid.uuid4()),
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
        if mode.startswith('receipt-'):
            field = mode[len('receipt-'):]
            if field == 'state': result[field] = 'blocked'
            elif field == 'facts': result[field]['workersExited'] = False
            elif field == 'schemaVersion': result[field] = 2
            elif field == 'registryRevision': result[field] = '999'
            elif field == 'participantId': result[field] = 'native.sill'
            else: result[field] = str(uuid.uuid4())
    elif method == 'fenceAndQuiesce':
        result = receipt(payload)
    elif method == 'inspect':
        result = None
    else:
        if method.startswith('hold'): time.sleep(0.2)
        result = 1
    reply = dict(schemaVersion=1, controllerBootId=controller, sequence=req['sequence'],
                 requestId=req['requestId'], relayBootId=boot, processId=os.getpid(), result=result)
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
