import json
import os
import sys
import time
import uuid

boot = str(uuid.uuid4())
for line in sys.stdin:
    req = json.loads(line)
    method = req['method']
    if method == 'bootstrap':
        result = {'participantId': 's23.audio.relay', 'capabilities': ['quiesce-v1', 'inspect-v1']}
    else:
        if method == 'hold':
            time.sleep(0.2)
        result = 1
    reply = dict(schemaVersion=1, controllerBootId=req['controllerBootId'], sequence=req['sequence'],
                 requestId=req['requestId'], relayBootId=boot, processId=os.getpid(), result=result)
    print(json.dumps(reply), flush=True)
