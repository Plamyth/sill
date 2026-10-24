def bind_client(client, root, block, ios=True):
    source = (root / 'iOSClient/StreamClient.swift').read_text()
    viewport = (root / 'iOSClient/StreamClient+Viewport.swift').read_text()
    markers = [
        'private struct PendingExtendedDesktop', 'var extendedDesktopRequestPending:',
        'private var extendedDesktopCandidate:', 'var canSelectIPadExtendedDesktop:',
        'private var extendedDesktopRequestReady:', 'func selectIPadExtendedDesktop(',
        'private final class ExtendedDesktopAdmission', 'private func extendedDesktopBinding(',
        'private func expireExtendedDesktopRequest(', 'private func cancelExtendedDesktopRequest(',
        'private func observeExtendedDesktopCatalog(', 'private func finishExtendedDesktopSelection(',
    ]
    members = '\n'.join(block(source, marker) for marker in markers).replace('private ', '')
    fields = '\n'.join(line.strip().replace('@Published private(set) ', '').replace('@Published private ', '')
                       for line in source.splitlines() if any(marker in line for marker in [
                           'var extendedDesktopControl:', 'var extendedDesktopProblem:', 'var pendingExtendedDesktop:']))
    members += '\n' + fields + '\n    let extendedDesktopAdmission = ExtendedDesktopAdmission()\n' + '''
    var lastViewport: Viewport?
    let localCursorState = LocalCursorState()
    var microphoneChanges = 0
    func microphoneSourceWillChange() { microphoneChanges += 1 }
    func send(_ kind: StreamMessageKind, payload: Data) { send(kind, payload) }
    '''
    members += '\n' + '\n'.join(block(viewport, marker).replace('private ', '') for marker in [
        'func sendViewport(', 'func forgetViewport(', 'func setLocalCursor('])
    members += '\n' + next(line.strip().replace('private ', '') for line in viewport.splitlines()
                             if 'private static let localCursorDebounce' in line)
    import re
    for field in ['connected', 'displays', 'supportsDisplaySelection', 'displayInventoryID',
                  'displayCatalogPeer', 'sessionHost', 'explicitSourceIntent', 'session', 'savedMacs']:
        declaration = re.search(r'(?m)^.*\bvar ' + field + r'(?=[: =]).*$', source).group()
        observer = block(source, declaration.strip())
        assert 'refreshExtendedDesktopAdmission()' in observer, field
        observer = observer[observer.index('{'):].replace('; ownerEnrollmentTrustChanged()', '')
        if field not in ['supportsDisplaySelection', 'displayCatalogPeer']:
            client, count = re.subn(r'(?m)^([ \t]*var ' + field + r'(?=[: =]).*)$',
                lambda match: match[1] + ' ' + observer, client)
            assert count == 1, (field, count)
    at = client.rfind('\n}')
    shared = '\n'.join(block(source, name).replace('@Published private(set) ', '').replace('private ', '') for name in [
        '@Published private(set) var supportsDisplaySelection', 'private var displayCatalogPeer:'])
    shared += '\nvar activeDisplayID: UInt32?\n'
    refresh = block(source, 'private func refreshExtendedDesktopAdmission(').replace('private ', '')
    client = client[:at] + '\n' + shared + '#if os(iOS)\n' + members + '\n#endif\n' + refresh + '\n' + client[at:]
    start = source.index('                self.supportsDisplaySelection = list.displaySelection == 1')
    end = source.index('                #if DEBUG', start)
    updates = source[start:end].replace('self.', '')
    updates += '        displaySelectionReady = list.displaySelection == 1 && list.displayInventoryID != nil\n'
    updates += '        #if os(iOS)\n        observeExtendedDesktopCatalog(list, peer: peer)\n        #endif\n'
    start = client.index('        automaticDisplaySelection = list.automaticDisplaySelection',
                         client.index('func prepareAutomaticTicketCatalog('))
    end = client.index('\n    }', start)
    client = client[:start] + updates + client[end:]
    return client.replace('#if os(iOS)', '#if true') if ios else client


def protocol_inputs(root, block):
    viewport = (root / 'Sources/StreamProtocol/Viewport.swift').read_text()
    screen = (root / 'iOSClient/StreamScreen.swift').read_text()
    client_viewport = (root / 'iOSClient/StreamClient+Viewport.swift').read_text()
    return {
        'Viewport.swift': 'import Foundation\n' + block(viewport, 'public struct Viewport:'),
        'ExtendedDisplaySelection.swift': 'import Foundation\n' + block(screen, 'enum IPadExtendedDisplaySelection {'),
        'LocalCursorState.swift': 'import Foundation\n' + block(client_viewport, 'private final class LocalCursorState').replace('private ', ''),
    }
