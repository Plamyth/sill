"""Source integration checks only. No Swift compiler, device, network, or audio IO."""
import argparse
import ast
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'Tests/checks'))
from swift_platform import select_platform

BASE = 'e11566df90bca876bd5a0d218647183f943d13e2'


def block(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


def ios(source, debug):
    source = source.replace('os(iOS) || os(visionOS)', '!os(visionOS)')
    return select_platform(source, vision=False, debug=debug).rstrip('\n')


def checks(root, include_baseline=True):
    client = (root / 'iOSClient/StreamClient.swift').read_text()
    view = (root / 'visionOSClient/SillVisionApp.swift').read_text()
    session = (root / 'visionOSClient/VisionAppSession.swift').read_text()
    input_session = (root / 'visionOSClient/VisionInputSession.swift').read_text()
    transport = (root / 'visionOSClient/VisionMacAudioTransport.swift').read_text()
    shared = (root / 'iOSClient/MacAudioRouteTransport.swift').read_text()
    controller = (root / 'visionOSClient/VisionMacAudioController.swift').read_text()
    status = (root / 'visionOSClient/VisionMacAudioStatus.swift').read_text()
    dependency = json.loads((root / 'Tests/checks/vision-audio-routing/dependency.json').read_text())
    generator = (root / 'Scripts/make-vision-project.py').read_text()
    ast.parse(generator)
    project = plistlib.loads((root / 'SillVision.xcodeproj/project.pbxproj').read_bytes())
    objects = list(project['objects'].values())
    refs = [obj['path'] for obj in objects if obj['isa'] == 'PBXFileReference' and obj.get('lastKnownFileType') == 'sourcecode.swift']
    versions = [obj['buildSettings']['CURRENT_PROJECT_VERSION'] for obj in objects if obj['isa'] == 'XCBuildConfiguration' and 'CURRENT_PROJECT_VERSION' in obj['buildSettings']]
    update = block(client, 'func updateVisionMacAudioRoutes(')
    receive = block(client, 'private func receiveVisionMacAudioRoutes(')
    reset = block(client, 'private func resetVisionAudio()')
    background = block(client, 'private func wentToBackground()')
    open_chooser = block(view, 'private func openMacAudioChooser()')
    result = {
        'project references actual shared client path': refs.count('iOSClient/StreamClient.swift') == 1 and not any('Generated/' in path for path in refs),
        'project source files all exist': all((root / path).is_file() for path in refs),
        'candidate version is nine in both configurations': versions == ['9', '9'],
        'source rewriting workaround removed': 'vision_audio_routing_source' not in generator and not (root / 'Scripts/vision_audio_routing_source.py').exists() and not (root / 'visionOSClient/Generated/StreamClient.swift').exists(),
        'session passes current foreground and owner lease': 'client.updateVisionMacAudioRoutes(lease: windowLease, foreground: foreground)' in block(session, 'func refresh()'),
        'route scope independent of video source': all(word not in update for word in ['visionInputBinding', 'videoEpoch', 'active != .none', 'VisionAudioGrant']),
        'current peer checked before receive and after main hop': receive.count('connection === peer') == 2 and 'self.visionMacAudioScopeIsCurrent(scope)' in receive,
        'lifecycle revokes routes on reset and background': 'revokeVisionMacAudioRoutes()' in reset and 'revokeVisionMacAudioRoutes(foreground: false)' in background,
        'native wrapper composes shared exact-peer Submission transport': 'private let shared: MacAudioRouteTransport' in transport and 'onlyOn: peer, submission: submission' in shared and 'link.send(' not in transport,
        'native scope invalidation resets shared queued submissions': 'shared.reset()' in block(transport, 'func bind('),
        'reviewed dependency candidate hashes match receipt': all(hashlib.sha256((root / name).read_bytes()).hexdigest() == entry['candidateSHA256'] for name, entry in dependency['files'].items()),
        'duplicate pure policy removed': not (root / 'visionOSClient/VisionMacAudioModel.swift').exists() and 'var model = MacAudioRouteSession()' in controller,
        'verified identity and TLS peer auth guard reused': all(piece in block(client, 'private var authenticatedVisionMacAudioPeer:') for piece in ['macInfoSaved', 'verified.info.macID == id', 'verified.fingerprint == pin', 'RemoteTLS.peerFingerprint(connection) == pin', 'session.route.isRemote || session.home == .saved(pin: pin)']),
        'trusted context rechecked on requests, receive and first offer': all('authorize(' in block(controller, marker) for marker in ['func refresh()', 'func apply(', 'func receive(', 'func takeOffer()']),
        'native timeout is bounded to eight seconds': 'static let responseTimeout = 8.0' in controller and 'expirePendingIfDue()' in block(controller, 'func receive('),
        'status file uses protected private changed-only writes': all(piece in status for piece in ['guard snapshot != previous', '0o600', 'FileProtectionType.complete', 'values.isExcludedFromBackup = true', 'CCRMacAudioStatus.json']),
        'only user Apply increments the request counter': controller.count('selectionRequestCount += 1') == 1 and 'selectionRequestCount += 1' in block(controller, 'func apply('),
        'status schema has no identifiers or raw endpoint fields': set(re.findall(r'^    let (\w+):', block(status, 'struct VisionMacAudioStatus:'), re.M)) == {'build', 'trustedCurrentPeer', 'owningWindow', 'foreground', 'catalogAvailable', 'catalogValid', 'catalogCount', 'currentInputKnown', 'currentOutputKnown', 'pending', 'outcome', 'selectionRequestCount'},
        'both route modals inhibit existing input admission': 'macAudioShown || macAudioOfferShown' in block(view, 'private var macAudioModalShown:') and '!macAudioModalShown' in block(view, 'private var inputAllowed:'),
        'input admission still reaches existing releaseAll': '.onChange(of: inputAllowed) { _, _ in updateInputAdmission() }' in view and 'input.allowed = inputAllowed' in block(view, 'private func updateInputAdmission()') and 'didSet { if oldValue && !allowed { releaseAll() } }' in input_session,
        'opening chooser clears speaker prompt before admission update': open_chooser.index('audioOfferShown = false') < open_chooser.index('updateInputAdmission()') and 'audioOfferScope = nil' in open_chooser,
        'late speaker confirmation cannot enable during route modal': 'guard audioControlsAllowed, !macAudioModalShown, let scope = audioOfferScope' in view,
        'speaker offer cannot overlap route chooser or offer': '!audioOfferAnswered, !audioOfferShown, !macAudioShown, !macAudioOfferShown' in view,
    }
    if include_baseline:
        baseline = subprocess.check_output(['git', '--no-lazy-fetch', 'show', BASE + ':iOSClient/StreamClient.swift'], cwd=root, text=True)
        result['non-Vision release source unchanged'] = ios(client, False) == ios(baseline, False)
        result['non-Vision debug source unchanged'] = ios(client, True) == ios(baseline, True)
    guard = block(client, 'private var authenticatedVisionMacAudioPeer:')
    body = guard[guard.index('{'):]
    result['auth guard body matches reviewed dependency receipt'] = hashlib.sha256(''.join(body.split()).encode()).hexdigest() == dependency['authGuard']['normalizedGuardSHA256']
    sources = ['iOSClient/StreamClient.swift', 'visionOSClient/SillVisionApp.swift', 'visionOSClient/VisionAppSession.swift', 'visionOSClient/VisionMacAudioTransport.swift', 'visionOSClient/VisionMacAudioController.swift', 'visionOSClient/VisionMacAudioStatus.swift', 'Scripts/make-vision-project.py', 'SillVision.xcodeproj/project.pbxproj']
    return {'scope': 'Static integration constraints only. Swift type checking, actual queued cancellation, native rendering and host effects are unverified.',
            'baseline': BASE, 'checks': result,
            'baselineComparison': 'local Git comparison' if include_baseline else 'not repeated in Git-free runtime input; bind parent local static receipt',
            'pendingIntegration': ['parent execution of shared and native runtime fixtures', 'exact XROS SDK build and independent review'],
            'sourceSHA256': {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in sources}}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path)
    options = parser.parse_args()
    record = checks(ROOT)
    if options.output:
        options.output.parent.mkdir(parents=True, exist_ok=True)
        options.output.write_text(json.dumps(record, indent=2) + '\n')
    for name, passed in record['checks'].items():
        print(('PASS ' if passed else 'FAIL ') + name)
    raise SystemExit(0 if all(record['checks'].values()) else 1)
