import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]


def block(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


def fixture():
    stream = (ROOT / 'iOSClient/StreamClient.swift').read_text()
    remote = (ROOT / 'iOSClient/StreamClient+Remote.swift').read_text()
    pieces = {}
    for marker in ['struct Reconnect {', 'func scheduleReconnectRetry(', 'private func retryReconnect(']:
        if marker in stream:
            pieces[marker] = block(stream, marker)
    pieces['reconnectIfListed'] = block(remote, '@discardableResult\n    func reconnectIfListed()')
    marker = 'if !connected, goodbye == nil, reconnect != nil, let s, !s.route.isRemote'
    if marker in remote:
        pieces['sessionEndedRowFailure'] = 'func finishRowFailure() {\nlet goodbye: Int? = nil\nlet s = session\n' + block(remote, marker) + '\n}'
    marker = 'DispatchQueue.main.asyncAfter(deadline: .now() + Self.reconnectDialWait)'
    pieces['dialTimeout'] = 'func armTimeout(_ c: NWConnection, name: String) {\n' + block(stream, marker) + '\n}'
    start = stream.index('    func startBrowsing()')
    end = stream.index('    /// A browser\'s results changed', start)
    pieces['browserGlue'] = stream[start:end]
    if 'private enum BrowserKind:' in stream:
        start = stream.index('    private enum BrowserKind:')
        end = stream.index('    /// Launch,', start)
        pieces['browserState'] = stream[start:end]
    else:
        pieces['browserState'] = 'var appInForeground = true\n'
    pieces['networkBrowser'] = 'private var networkBrowser: NWBrowser?\nprivate var nearbyBrowser: NWBrowser?\nprivate var networkResults: [NWBrowser.Result] = []\nprivate var nearbyResults: [NWBrowser.Result] = []\n'
    state = (Path(__file__).parent / 'Standins.swift').read_text()
    tests = (Path(__file__).parent / 'scenarios.swift').read_text()
    body = '\n'.join(pieces.values())
    lifecycle = '''
    func background() {
        wentToBackground()
    }
    func foreground() { cameForward() }
    ''' if 'private func wentToBackground()' in stream else '''
    func background() { appInForeground = false }
    func foreground() { appInForeground = true }
    '''
    main = state.rsplit('\n}', 1)[0] + '\n' + body + lifecycle + '\n}\n' + tests
    sha = lambda b: hashlib.sha256(b).hexdigest()
    receipts = {name: sha(value.encode()) for name, value in pieces.items()}
    policy = (ROOT / 'iOSClient/DiscoveryPolicy.swift').read_text()
    files = {'main.swift': main, 'DiscoveryPolicy.swift': policy}
    if 'static func redialRow' in policy:
        upstream = subprocess.check_output(['git', 'show', '03ca390b3ce7fcd05d81794b396e20d02ea56258:Tests/checks/policy/sleep.swift'], cwd=ROOT, text=True)
        selected = upstream[:upstream.index('    // MARK: The Desktop after a stop')]
        files['sleep.swift'] = selected + '}\n'
        receipts['upstreamSleepSelected'] = sha(selected.encode())
        receipts['upstreamSleepFull'] = sha(upstream.encode())
    return files, receipts


if __name__ == '__main__':
    import sys
    files, receipts = fixture()
    destination = Path(sys.argv[1])
    destination.mkdir(parents=True, exist_ok=True)
    for name, text in files.items():
        (destination / name).write_text(text)
    (destination / 'extraction.json').write_text(json.dumps(receipts, indent=2) + '\n')
