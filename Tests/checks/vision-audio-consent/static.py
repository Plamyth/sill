import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
texts = {name: (root / name).read_text() for name in [
    'visionOSClient/VisionAudioPlayer.swift', 'visionOSClient/VisionAudioController.swift',
    'visionOSClient/SillVisionApp.swift', 'iOSClient/StreamClient.swift',
]}
player = texts['visionOSClient/VisionAudioPlayer.swift']
client = texts['iOSClient/StreamClient.swift']
controller = texts['visionOSClient/VisionAudioController.swift']
view = texts['visionOSClient/SillVisionApp.swift']

def block(text, start):
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

locks = []
offset = 0
while True:
    start = player.find('state.withLock {', offset)
    if start < 0:
        break
    locks.append(block(player, start))
    offset = start + 1

checks = {
    'native framework startup is outside state locks': all(
        all(word not in body for word in ['output.start(', 'setActive(', 'engine.start(']) for body in locks),
    'render never waits for playback state lock': 'renderState.withLockIfAvailable' in player,
    'framework startup rechecks current grant': player.count('guard permitted()') >= 3,
    'stop never starts or constructs audio engine': all(word not in block(player, player.index('func stop()'))
                                                      for word in ['AVAudioEngine', 'AVAudioSession', '.start(']),
    'own category changes do not recursively stop activation': '.categoryChange { return }' in controller,
    'Enable send body remains under consent lock': 'body()' in block(controller, controller.index('storage.withLock { state in', controller.index('func sendIfPermitted'))),
    'captured positive send checks scope inside grant fence': 'self.visionAudio.sendIfPermitted(control)' in client and 'self.visionAudioRoute.scope(for: expected) == control.grant.scope' in client,
    'audio request bypasses handover-held SessionLink': 'expected.send(content: bytes' in block(client, client.index('private func sendVisionAudio')),
    'actual originating connection enters asynchronous handler': 'handle(header, data, from: c)' in client and client.count('let from: NWConnection? = peer') == 5,
    'replayed move messages retain origin': 'for m in kept { self.deliver(m.header, m.payload, from: c) }' in client,
    'handover revokes even while connected stays true': 'resetVisionAudio()' in block(client, client.index('private func finishMove')),
    'application background revokes audio': 'visionAudio.setForeground(false)' in block(client, client.index('private func wentToBackground')),
    'native stop is a sibling of disabled input controls': 'controls\n                VisionAudioControls' in view,
    'Stop remains actionable while Enable is inhibited': '.disabled(!running && (!audio.presentation.canEnable || !allowStart))' in view,
    'source transition revokes before input fence': block(view, view.index('private func requestTransition')).index('visionAudio.stop()') < block(view, view.index('private func requestTransition')).index('transitions.request(action)'),
    'no native microphone or device route override': not any(word in player + controller for word in ['requestRecordPermission', 'duckOthers', 'voiceChat', 'overrideOutputAudioPort', 'setPreferredInput']),
}
manifest = json.loads((root / 'docs/vision-audio-component-source.json').read_text())
checks['four common component hashes still match owner snapshot'] = all(
    hashlib.sha256((root / name).read_bytes()).hexdigest() == entry['sha256']
    for name, entry in manifest['files'].items())
record = {'scope': 'Static source constraints, not runtime audio, host fence, or device acceptance',
          'checks': checks, 'count': len(checks),
          'sourceSHA256': {name: hashlib.sha256(text.encode()).hexdigest() for name, text in texts.items()}}
(here / 'receipts/static.json').write_text(json.dumps(record, indent=2) + '\n')
for name, passed in checks.items():
    print(('PASS ' if passed else 'FAIL ') + name)
raise SystemExit(0 if all(checks.values()) else 1)
