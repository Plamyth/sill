import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
player = (ROOT / 'visionOSClient/VisionAudioPlayer.swift').read_text()
buffer = (ROOT / 'visionOSClient/VisionAudioBuffer.swift').read_text()
def block(text, declaration):
    start = text.index(declaration)
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

checks = {}
for declaration in ('func begin(', 'func stop(', 'func arm('):
    body = block(player, declaration)
    checks[declaration + ' has no audio API access'] = all(name not in body for name in ('AVAudioSession', 'AVAudioEngine', '.start(', '.setActive('))
render = block(player, 'try output.start(')
checks['render uses nonblocking lock'] = 'withLockIfAvailable' in render and '.withLock {' not in render
checks['no growing sample array'] = 'removeFirst' not in player + buffer and 'samples.append' not in player + buffer
checks['native begin requires process lease'] = 'lease.withLock' in block(player, 'func begin(')
checks['cleanup requires exact owner'] = '$0.owner == ticket.epoch' in block(player, 'func close(')
checks['no microphone or route control'] = all(word not in player for word in ('duckOthers', 'voiceChat', 'setPreferredInput', 'overrideOutputAudioPort', 'setPreferredSampleRate', 'addObserver'))
checks['shared wire declaration not copied'] = 'enum AudioPacket' not in player + buffer
checks['pure checks exclude native adapter compilation'] = "str(package/'visionOSClient/VisionAudioPlayer.swift')" not in (HERE / 'mini.py').read_text()
changed = subprocess.check_output(['git', 'diff', '--name-only', '8ef216d'], cwd=ROOT, text=True).splitlines()
untracked = subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard'], cwd=ROOT, text=True).splitlines()
allowed = lambda name: name in ('visionOSClient/VisionAudioPlayer.swift', 'visionOSClient/VisionAudioBuffer.swift', 'docs/vision-audio-player.md') or name.startswith('Tests/checks/vision-audio-player/')
checks['only allowed writes'] = all(allowed(name) for name in changed + untracked)

peer = '/Users/ambrion/Documents/ChatGPT/BT_CCR-Sill-iPad'
commit = '89f955072e520b6b0aaa00b1e19c26afc3d9fdb3'
path = 'iOSClient/RemoteAudioPlayer.swift'
source = subprocess.check_output(['git', 'show', commit + ':' + path], cwd=peer)
source_decoder = block(source.decode(), 'private final class RemoteAACDecoder')
provenance = {'peerCommit': commit, 'peerPath': path,
              'peerBlob': subprocess.check_output(['git', 'rev-parse', commit + ':' + path], cwd=peer, text=True).strip(),
              'sourceSHA256': hashlib.sha256(source).hexdigest(),
              'originalDecoderSHA256': hashlib.sha256(source_decoder.encode()).hexdigest(),
              'adaptedDecoderSHA256': hashlib.sha256(block(player, 'private final class VisionAACDecoder').encode()).hexdigest(),
              'componentSHA256': {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in ('visionOSClient/VisionAudioBuffer.swift', 'visionOSClient/VisionAudioPlayer.swift')},
              'source': 'Read-only git show of committed bytes. No peer test acceptance.'}
checks['source blob matches specified peer'] = provenance['peerBlob'] == 'ffdbfc457feb82e94bfbdffc79006de5a99049a7'
(HERE / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
(HERE / 'static.json').write_text(json.dumps(checks, indent=2) + '\n')
for name, passed in checks.items():
    print(('PASS ' if passed else 'FAIL ') + name)
raise SystemExit(0 if all(checks.values()) else 1)
