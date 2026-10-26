"""실제 diagnostics 및 network/main Sentry 함수의 결정적 재현. 실기기·미디어·네트워크 실행 없음."""
from pathlib import Path
import os, subprocess, sys
root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
out = Path(sys.argv[1]).resolve(); out.mkdir(parents=True, exist_ok=True)
def block(text, marker):
    start = text.index(marker); opening = text.index('{', start); depth = 1
    for end in range(opening + 1, len(text)):
        depth += (text[end] == '{') - (text[end] == '}')
        if not depth: return text[start:end + 1]
    raise AssertionError(marker)
source = (root/'iOSClient/IPadMicrophoneCapture.swift').read_text().split('final class IPadMicrophoneConversionWorker')[0]
source = source.replace('FileManager.default.urls(for: .applicationSupportDirectory,\n        in: .userDomainMask)[0].appendingPathComponent("CCR Sill/microphone-diagnostics.json")',
    'URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("events.json")')
source += '''
extension IPadMicrophoneDiagnostics {
    func holdWriter(_ entered: DispatchSemaphore, _ release: DispatchSemaphore) {
        writer.async { entered.signal(); release.wait() }
    }
}
'''
(out/'Diagnostics.swift').write_text(source)
stream = (root/'iOSClient/StreamClient.swift').read_text()
sentry = (root/'iOSClient/StreamClient+Sentry.swift').read_text()
handler = stream.split('case .sentryState:')[1].split('case .sentryReturnState:')[0]
receiver = block(sentry, 'func receiveIPadSentry(')
(out/'Sentry.swift').write_text('import Foundation\nextension StreamClient {\n' + receiver +
    '\nfunc deliverSentry(_ header: Header, _ data: Data, from peer: NWConnection) {\n'+handler+'\n}\n}\nlet hasNetworkGuard = '+str('connection === peer' in handler).lower()+'\n')
flags = ['xcrun','swiftc','-swift-version','5','-whole-module-optimization','-parse-as-library','-module-cache-path',str(out/'cache')]
env = dict(os.environ, TMPDIR=str(out)+'/', PYTHONDONTWRITEBYTECODE='1')
failed = False
for key in sys.argv[2:] or ['lifecycle','peer']:
    destination = out/key; destination.mkdir(exist_ok=True)
    args = flags+[str(out/'Diagnostics.swift'),str(here/(key+'.swift'))]
    if key == 'peer': args += [str(out/'Sentry.swift')]
    with (out/(key+'.log')).open('w') as log:
        compiled = subprocess.run(args+['-o',str(out/(key+'-check'))],env=env,stdout=log,stderr=subprocess.STDOUT)
        result = subprocess.run([str(out/(key+'-check')),str(destination)],env=env,stdout=log,stderr=subprocess.STDOUT) if not compiled.returncode else compiled
    print(key, 'exit', result.returncode, flush=True)
    print((out/(key+'.log')).read_text()[-2000:],flush=True)
    failed |= result.returncode != 0
if not failed:
    for marker in ['func tearDown(', 'private func wentToBackground()', 'private func cameForward()']:
        body = block(stream, marker)
        assert 'defer { observeAudioDiagnostics() }' in body, marker
    assert 'hostTimestamp: header.timestamp' in handler and 'shared.received(.sentryState' not in handler
    assert receiver.index('guard let self, self.connection === peer') < receiver.index('shared.received(.sentryState')
    print('PASS post-transition lifecycle observation and guarded Sentry source wiring')
raise SystemExit(int(failed))
