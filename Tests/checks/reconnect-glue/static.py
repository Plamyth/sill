import hashlib
import json
from pathlib import Path
import subprocess

from extract import ROOT, block
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from swift_platform import select_platform

base = '62bc4c5884bf54f4eb729b71e082d0fa8d7d8609'
stream = (ROOT / 'iOSClient/StreamClient.swift').read_text()
remote = (ROOT / 'iOSClient/StreamClient+Remote.swift').read_text()
old = subprocess.check_output(['git', '--no-lazy-fetch', 'show', base + ':iOSClient/StreamClient.swift'], cwd=ROOT, text=True)
results = {}
def check(name, value):
    results[name] = bool(value)
    assert value, name

baseline = 'f331d8d307fb301e1c0f2bfd71e4a83a76d62dbc'
reference = subprocess.check_output(['git', '--no-lazy-fetch', 'show', baseline + ':iOSClient/StreamClient.swift'], cwd=ROOT, text=True)
check('reconnect files exactly native integration parent', all((ROOT / path).read_bytes() == subprocess.check_output(['git', '--no-lazy-fetch', 'show', baseline + ':' + path], cwd=ROOT) for path in ['iOSClient/DiscoveryPolicy.swift', 'iOSClient/StreamClient+Remote.swift']))
check('reconnect glue bodies exactly native integration parent', all(block(stream, marker) == block(reference, marker) for marker in ['struct Reconnect {', 'func scheduleReconnectRetry(', 'func startBrowsing()', 'private func wentToBackground()', 'private func cameForward()']))
native = select_platform(stream, vision=True)
check('native lifecycle explicit active gate', 'didBecomeActiveNotification' in native and 'willResignActiveNotification' in native and 'cameForward()' in native and 'wentToBackground()' in native)
check('native initial active state', '#if os(visionOS)\n    private(set) var appInForeground = UIApplication.shared.applicationState == .active' in stream)
glue = block(remote, 'func reconnectIfListed()')
check('global gate precedes row and remote dispatch', glue.index('guard appInForeground') < glue.index('guard connection') < glue.index('dialSaved(id, why: .automatic)'))
check('one-shot entry has no recursive poll', block(stream, 'func scheduleReconnectRetry()') == 'func scheduleReconnectRetry() {\n        reconnectIfListed()\n    }' and 'retryReconnect(chain:' not in stream)
check('noAutoDesktop and native input ACK preserved', all(line in stream for line in old.splitlines() if 'noAutoDesktop' in line or 'visionInputFence' in line))
check('window-list delivery and input fence unchanged', block(stream, 'private func deliver(') == block(reference, 'private func deliver('))
check('no upstream clipboard dependency', 'Clipboard' not in stream and 'Clipboard' not in remote)
print(json.dumps({'checks': results, 'count': len(results), 'scope': 'Static constraints supplement extracted Swift execution.'}, indent=2))
