"""Extract actual native adapter and modal methods; no compiler is invoked here."""
import hashlib
from pathlib import Path


def block(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


def fixture(root):
    here = root / 'Tests/checks/vision-audio-routing'
    client = (root / 'iOSClient/StreamClient.swift').read_text()
    view = (root / 'visionOSClient/SillVisionApp.swift').read_text()
    lease = (root / 'visionOSClient/VisionCableBootstrap.swift').read_text()
    input_source = (root / 'visionOSClient/VisionInputSession.swift').read_text()
    fields = client[client.index('    private var visionMacAudioConnectionEpoch'):client.index('    let visionAudioOwnerID')]
    adapter = block(client, 'extension StreamClient {\n    func updateVisionMacAudioRoutes(')
    pieces = {'fields': fields, 'adapter': adapter, 'lease': block(lease, 'struct VisionWindowLease:')}
    before = 'authorize: { [weak self] scope in self?.visionMacAudioScopeIsCurrent(scope) == true })'
    assert fields.count(before) == 1
    emitted_fields = fields.replace(before, 'authorize: { [weak self] scope in self?.visionMacAudioScopeIsCurrent(scope) == true }, clock: { NativeClock.now })')
    markers = ['private var audioControlsAllowed:', 'private var inputAllowed:', 'private var macAudioModalShown:',
               'private func openMacAudioChooser()', 'private func updateInputAdmission()', 'private func withWindowOwnership(']
    pieces.update({marker: block(view, marker) for marker in markers})
    pieces['inputAdmission'] = block(input_source, 'var allowed = false')
    standins = (here / 'Standins.swift').read_text()
    for sentinel, value in [('PRODUCTION_LEASE', pieces['lease']), ('PRODUCTION_FIELDS', emitted_fields),
                            ('PRODUCTION_ADAPTER', adapter), ('PRODUCTION_INPUT_ADMISSION', pieces['inputAdmission']),
                            ('PRODUCTION_MODAL_METHODS', '\n'.join(pieces[marker] for marker in markers))]:
        assert standins.count('// ' + sentinel) == 1
        standins = standins.replace('// ' + sentinel, value)
    manifest = {name: hashlib.sha256(text.encode()).hexdigest() for name, text in pieces.items()}
    manifest['emittedFieldsSHA256'] = hashlib.sha256(emitted_fields.encode()).hexdigest()
    return standins, manifest
