from pathlib import Path
import re
import sys

root, output = Path(sys.argv[1]), Path(sys.argv[2])
source = (root / 'Sources/SillHost/StreamServer.swift').read_text()


def body(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:opening], text[opening + 1:end - 1]


receive = source.split('private func receiveLoop(_ client: Client)', 1)[1]
header = receive.split('guard let self else { return }', 1)[1].split(
    'guard let data, let header = StreamMessage.parseHeader(data)', 1)[0]
payload = receive.split(
    'c.receive(minimumIncompleteLength: header.payloadLength, maximumLength: header.payloadLength)', 1
)[1].split(' in\n', 1)[1].split('guard let data else', 1)[0]
helpers = []
for name in ['traceFailure(', 'traceCompletion(']:
    signature, contents = body(source, 'private static func ' + name)
    helpers.append(signature.replace('private static', 'static', 1) + '{' + contents + '}')

direct = []
markers = ['private func tick()', 'func sendReport(_ report: MacPointer)',
           'private static func sayGoodbye(', 'func goodbyeAll(']
for index, marker in enumerate(markers):
    _, function = body(source, marker)
    send = function[function.index('.send(content: data, completion: .contentProcessed'):]
    _, callback = body(send, '.contentProcessed')
    callback = re.sub(r'^\s*(?:\[[^]]*\]\s*)?\w+\s+in', '', callback, count=1)
    direct.append(f'''static func direct{index}(_ closeTrace: PeerCloseTrace, error: NWError?) -> (Int, Int) {{
        let trace: PeerCloseTrace? = closeTrace
        let data = Data(repeating: 0, count: 19)
        let connection = CounterConnection()
        let group = CounterGroup()
        {callback}
        return (connection.cancelled, group.left)
    }}''')

output.write_text('''import Foundation
import Network
final class EntryClient { let closeTrace: PeerCloseTrace; init(_ trace: PeerCloseTrace) { closeTrace = trace } }
final class CounterConnection { var cancelled = 0; func cancel() { cancelled += 1 } }
final class CounterGroup { var left = 0; func leave() { left += 1 } }
enum EntryHarness {
''' + '\n'.join(helpers) + '''
static func header(_ client: EntryClient, data: Data?, error: NWError?) {
''' + header + '''
}
static func payload(_ client: EntryClient, data: Data?, header: StreamHeader, error: NWError?) {
''' + payload + '\n}\n' + '\n'.join(direct) + '\n}\n')
