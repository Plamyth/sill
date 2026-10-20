from pathlib import Path

root = Path(__file__).resolve().parents[3]
host = root / 'Sources/SillHost'

def block(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    end, depth = opening + 1, 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}'); end += 1
    return text[start:end]

fixture = Path(__file__).with_name('Main.swift').read_text()
for name, marker in [('RemoteAccess.swift', 'struct AudioForwardingPairedDevice:'),
                     ('StreamServer.swift', 'struct ForwardingExchange:'),
                     ('StreamCoordinator.swift', '@MainActor\nstruct AudioForwardingConnectionContext'),
                     ('StreamCoordinator.swift', 'private struct ForwardingClient {'),
                     ('StreamCoordinator.swift', 'private func handleForwarding(')]:
    piece = block((host / name).read_text(), marker)
    if piece.startswith('private '): piece = piece[len('private '):]
    fixture = fixture.replace('// ' + marker.replace('\n', ' '), piece)
print(fixture)
