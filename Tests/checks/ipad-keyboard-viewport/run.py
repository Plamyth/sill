"""Independent Mini RAM geometry model, not SwiftUI keyboard runtime or physical acceptance."""
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys

here = Path(__file__).resolve().parent
root = here.parents[2]
out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
if (out / 'result.json').exists(): raise SystemExit('receipt exists; reconcile before retry')
sha = lambda data: hashlib.sha256(data).hexdigest()
def block(source, marker):
    start = source.index(marker)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
paths = [root / 'iOSClient' / name for name in ['StreamScreen.swift', 'InputOverlay.swift',
    'HEVCDisplayView.swift', 'PortraitStreamScreen.swift', 'DuoPosture.swift', 'DuoPostureReader.swift',
    'PhonePortraitLayout.swift']]
paths += [here / name for name in ['main.swift', 'run.py', 'remote.py']]
original = {str(path.relative_to(root)): sha(path.read_bytes()) for path in paths}
screen, overlay, display, portrait = [path.read_text() for path in paths[:4]]
screen_body = block(screen[screen.index('struct StreamScreen: View'):], 'var body: some View {')
geometry = block(screen_body, 'GeometryReader { geo in')
outer = screen_body.replace(geometry, '')
background = block(outer, '.background {')
region = [line.strip() for line in outer.replace(background, '').splitlines()
          if line.strip().startswith('.ignoresSafeArea(')]
assert len(region) == 1
fixture = (here / 'main.swift').read_text().replace('// PRODUCTION_TYPES', block(screen, 'enum DuoLayout {') + '\n' + block(screen, 'struct BarMetrics {'))
fixture = fixture.replace('// PRODUCTION_PORTRAIT', paths[4].read_text() + '\n' + paths[6].read_text()
    + '\n' + block(portrait, 'struct PortraitMetrics {')
    + '\n' + block(paths[5].read_text(), 'extension PortraitMetrics {'))
layout = screen[screen.index('        GeometryReader { geo in'):screen.index('            let layout: TourLayout')]
fixture = fixture.replace('// PRODUCTION_LAYOUT', '\n'.join(line.strip() for line in layout.splitlines()
    if line.strip().startswith(('let layoutSize = ', 'let duo = '))))
assert '.onChange(of: duo.isPortrait' in screen
fixture = fixture.replace('/*PRODUCTION_SAFE_AREA*/', region[0])
fixture = fixture.replace('// PRODUCTION_VIDEO_RECT', block(display, 'static func videoRect('))
fixture = fixture.replace('// PRODUCTION_NORMALIZED', block(overlay, 'private func normalized('))
assert 'HEVCDisplayView.videoRect(in: bounds, videoSize: videoSize)' in overlay
for source in [screen, portrait]:
    assert 'StreamView(client: client)' in source and 'InputOverlay(videoSize: client.videoSize,' in source
    assert '.onGeometryChange(for: CGSize.self, of: { $0.size }, action:' in source
assert 'width: Double(panelSize.width)' in screen and 'height: Double(panelSize.height)' in screen
payload = json.dumps({'source': base64.b64encode(fixture.encode()).decode(), 'sha256': sha(fixture.encode())}).encode()
command = ['/Users/ambrion/.local/bin/mini', 'heavy', '--cwd', '/private/tmp', '--', 'python3', '-B', '-c', (here / 'remote.py').read_text()]
child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
log, _ = child.communicate(payload, timeout=230)
(out / 'run.log').write_bytes(log)
lines = log.decode(errors='replace').splitlines()
records = [line[len('RESULT_JSON '):] for line in lines if line.startswith('RESULT_JSON ')]
record = {'scope': __doc__, 'inputSHA256': sha(payload), 'sourceSHA256': original,
    'sourceUnchanged': all(sha((root / path).read_bytes()) == digest for path, digest in original.items()),
    'senderReceiverMatch': ('INPUT_SHA256 ' + sha(payload)) in lines, 'exitCode': child.returncode,
    'transportReaped': child.poll() is not None, 'region': region[0], 'remote': json.loads(records[-1]) if records else None}
(out / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
if record['remote']:
    print(record['remote'].get('compileLog', '')[-5000:])
    print(record['remote'].get('runtimeLog', '')[-5000:])
    print(json.dumps({key: record['remote'].get(key) for key in ['childrenReaped', 'outputRemoved', 'sourceRemoved', 'detachCode', 'error']}))
else: print(log.decode(errors='replace')[-5000:])
print(json.dumps({key: record[key] for key in ['inputSHA256', 'sourceUnchanged', 'senderReceiverMatch', 'exitCode']}))
sys.exit(child.returncode if records and record['sourceUnchanged'] and record['senderReceiverMatch'] else 2)
