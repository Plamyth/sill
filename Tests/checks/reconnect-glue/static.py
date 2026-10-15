import hashlib
import json
from pathlib import Path
import subprocess

from extract import ROOT, block

base = '62bc4c5884bf54f4eb729b71e082d0fa8d7d8609'
stream = (ROOT / 'iOSClient/StreamClient.swift').read_text()
remote = (ROOT / 'iOSClient/StreamClient+Remote.swift').read_text()
old = subprocess.check_output(['git', 'show', base + ':iOSClient/StreamClient.swift'], cwd=ROOT, text=True)
results = {}
def check(name, value):
    results[name] = bool(value)
    assert value, name

allowed = {'iOSClient/StreamClient.swift', 'iOSClient/StreamClient+Remote.swift', 'iOSClient/DiscoveryPolicy.swift', 'docs/vision-reconnect.md'}
changed = subprocess.check_output(['git', 'diff', '--name-only', base], cwd=ROOT, text=True).splitlines()
check('owned files only', all(n in allowed or n.startswith('Tests/checks/reconnect-glue/') for n in changed))
native = stream[stream.index('        #if os(visionOS)\n        NotificationCenter'):stream.index('        #else\n        NotificationCenter')]
check('native lifecycle explicit active gate', 'didBecomeActiveNotification' in native and 'willResignActiveNotification' in native and 'cameForward()' in native and 'wentToBackground()' in native)
check('native initial active state', '#if os(visionOS)\n    private(set) var appInForeground = UIApplication.shared.applicationState == .active' in stream)
glue = block(remote, 'func reconnectIfListed()')
check('global gate precedes row and remote dispatch', glue.index('guard appInForeground') < glue.index('guard connection') < glue.index('dialSaved(id, why: .automatic)'))
check('one-shot entry has no recursive poll', block(stream, 'func scheduleReconnectRetry()') == 'func scheduleReconnectRetry() {\n        reconnectIfListed()\n    }' and 'retryReconnect(chain:' not in stream)
check('noAutoDesktop and native input ACK preserved', all(line in stream for line in old.splitlines() if 'noAutoDesktop' in line or 'visionInputFence' in line))
check('window-list delivery and input fence unchanged', block(stream, 'private func deliver(') == block(old, 'private func deliver('))
check('no upstream clipboard dependency', 'Clipboard' not in stream and 'Clipboard' not in remote)
print(json.dumps({'checks': results, 'count': len(results), 'scope': 'Static constraints supplement extracted Swift execution.'}, indent=2))
