import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def block(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def main():
    root, output = [Path(p).resolve() for p in sys.argv[1:3]]
    output.mkdir(parents=True, exist_ok=False)
    path = root / 'visionOSClient/SillVisionApp.swift'
    source = path.read_text()
    input_source = (root / 'visionOSClient/VisionInputSession.swift').read_text()
    members = '\n'.join(block(source, marker) for marker in (
        'private var inputAllowed:', 'private var audioControlsAllowed:',
        'private var macAudioModalShown:', 'private func updateInputAdmission()'))
    callbacks = {}
    for state in ('recoveryShown', 'changingSource'):
        marker = '.onChange(of: ' + state + ')'
        callback = block(source, marker) if marker in source else ''
        callbacks[state] = callback
        body = callback.split(' in ', 1)[1].rsplit('}', 1)[0] if callback else ''
        members += '\nmutating func changed_' + state + '() {' + body + '}\n'
    allowed = block(input_source, 'var allowed = false')
    swift = r'''
import Foundation

enum ScenePhase { case active, inactive, background }
enum CaptureSource { case none, desktop, window }
struct Selection { var inputBlocked = false }
final class Client {
    var connected = true
    var active = CaptureSource.desktop
    var visionDisplaySelection = Selection()
    var visionAudioIntentModal = false
}
struct Transition { var isPending = false }
final class Session {
    var owner = 1
    var refreshes = 0
    func owns(_ lease: Int) -> Bool { owner == lease }
    func refresh() { refreshes += 1 }
}
final class Input {
    var releases = 0
    func releaseAll() { releases += 1 }
    __ALLOWED__
}
struct Workspace {
    let session = Session()
    let lease = 1
    let input = Input()
    var client = Client()
    var phase = ScenePhase.active
    var transitions = Transition()
    var inputSuspended = false
    var draftShown = false
    var testDestinationsShown = false
    var audioOfferShown = false
    var macAudioShown = false
    var macAudioOfferShown = false
    var displayChooserShown = false
    var recoveryShown = false
    var changingSource = false
    var controlEventsShown = false
    __MEMBERS__
    var admitsInput: Bool { inputAllowed }
    var admitsAudio: Bool { audioControlsAllowed }
    mutating func update() { updateInputAdmission() }
}
var failures = 0
var assertions = 0
func check(_ actual: Bool, _ expected: Bool, _ label: String) {
    assertions += 1
    if actual != expected {
        failures += 1
        print("FAIL \(label): expected \(expected), got \(actual)")
    }
}
func verify(_ workspace: inout Workspace, _ label: String, _ expected: (Bool, Bool, Bool)) {
    check(workspace.admitsInput, expected.0, label + " inputAllowed")
    check(workspace.admitsAudio, expected.1, label + " audioControlsAllowed")
    workspace.update()
    check(workspace.input.allowed, expected.0, label + " published input")
    check(workspace.client.visionAudioIntentModal, expected.2, label + " audio intent modal")
}
var normal = Workspace()
verify(&normal, "normal without input mode", (true, true, false))
normal.client.active = .window
verify(&normal, "window without input mode", (true, true, false))

var status = Workspace()
status.update()
status.controlEventsShown = true
verify(&status, "work status preserves audio intent", (false, false, false))
check(status.input.releases == 1, true, "work status releases remote input")
status.controlEventsShown = false
verify(&status, "work status dismissed", (true, true, false))

for modal in [\Workspace.recoveryShown, \Workspace.changingSource] {
    let name = modal == \Workspace.recoveryShown ? "recovery" : "source confirmation"
    var workspace = Workspace()
    workspace.update()
    workspace[keyPath: modal] = true
    verify(&workspace, name, (false, false, true))
    check(workspace.input.releases == 1, true, name + " releases existing input through allowed setter")
    workspace[keyPath: modal] = false
    verify(&workspace, name + " dismissed", (true, true, false))

    var disconnected = Workspace()
    disconnected.client.connected = false
    disconnected.update()
    disconnected[keyPath: modal] = true
    if modal == \Workspace.recoveryShown { disconnected.changed_recoveryShown() }
    else { disconnected.changed_changingSource() }
    check(disconnected.client.visionAudioIntentModal, true, name + " onChange publishes while input already false")
    disconnected.client.connected = true
    verify(&disconnected, name + " reconnect behind modal", (false, false, true))
    disconnected.client.connected = false
    disconnected.update()
    disconnected[keyPath: modal] = false
    if modal == \Workspace.recoveryShown { disconnected.changed_recoveryShown() }
    else { disconnected.changed_changingSource() }
    check(disconnected.client.visionAudioIntentModal, false, name + " onChange clears while input remains false")
    disconnected.client.connected = true
    verify(&disconnected, name + " reconnect after dismiss", (true, true, false))
}

let guards: [(String, (inout Workspace) -> Void, (Bool, Bool, Bool))] = [
    ("inactive", { $0.phase = .inactive }, (false, false, false)),
    ("background", { $0.phase = .background }, (false, false, false)),
    ("disconnected", { $0.client.connected = false }, (false, false, false)),
    ("no source", { $0.client.active = .none }, (false, true, false)),
    ("pending transition", { $0.transitions.isPending = true }, (false, false, true)),
    ("input suspended", { $0.inputSuspended = true }, (false, false, true)),
    ("draft", { $0.draftShown = true }, (false, false, true)),
    ("test destinations", { $0.testDestinationsShown = true }, (false, true, true)),
    ("audio offer", { $0.audioOfferShown = true }, (false, true, false)),
    ("Mac audio chooser", { $0.macAudioShown = true }, (false, true, true)),
    ("Mac audio offer", { $0.macAudioOfferShown = true }, (false, true, true)),
    ("display blocked", { $0.client.visionDisplaySelection.inputBlocked = true }, (false, false, false)),
    ("display chooser", { $0.displayChooserShown = true }, (false, false, true)),
]
for (label, arrange, expected) in guards {
    var workspace = Workspace()
    arrange(&workspace)
    verify(&workspace, label, expected)
}
var overlap = Workspace()
overlap.recoveryShown = true
overlap.changingSource = true
verify(&overlap, "both modals", (false, false, true))
overlap.recoveryShown = false
verify(&overlap, "source confirmation survives recovery dismiss", (false, false, true))
overlap.draftShown = true
overlap.changingSource = false
verify(&overlap, "draft survives source confirmation dismiss", (false, false, true))
overlap.draftShown = false
verify(&overlap, "all dismissed", (true, true, false))

var stale = Workspace()
stale.session.owner = 2
stale.input.allowed = true
stale.recoveryShown = true
stale.changingSource = true
stale.changed_recoveryShown()
stale.changed_changingSource()
stale.update()
check(stale.admitsAudio, false, "stale owner cannot start audio")
check(stale.input.allowed, true, "stale owner cannot mutate shared input")
check(stale.input.releases == 0, true, "stale owner cannot release shared input")
check(stale.client.visionAudioIntentModal, false, "stale owner cannot publish modal")
check(stale.session.refreshes == 0, true, "stale owner cannot refresh")
print("RESULT_ASSERTIONS \(assertions) FAILURES \(failures)")
exit(failures == 0 ? 0 : 1)
'''.replace('__ALLOWED__', allowed).replace('__MEMBERS__', members)
    generated = output / 'main.swift'
    generated.write_text(swift)
    compiler = subprocess.check_output(['/usr/bin/xcrun', '--find', 'swiftc'], text=True).strip()
    sdk = subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    command = [compiler, '-sdk', sdk,
               '-target', 'arm64-apple-macosx14.0', '-swift-version', '5',
               '-module-cache-path', str(output / 'cache'), str(generated), '-o', str(output / 'checks')]
    record = {'scope': 'Actual workspace admission members and modal callback bodies with typed inert standins; no SwiftUI scheduling or hardware proof',
              'sourceSHA256': hashlib.sha256(source.encode()).hexdigest(),
              'inputSourceSHA256': hashlib.sha256(input_source.encode()).hexdigest(),
              'extractedSHA256': hashlib.sha256((members + allowed).encode()).hexdigest(),
              'callbacksPresent': {key: bool(value) for key, value in callbacks.items()}, 'commands': []}
    with tempfile.TemporaryDirectory(prefix='vma-', dir='/tmp') as temporary:
        environment = dict(os.environ, TMPDIR=temporary)
        for label, arguments in [('compile', command), ('runtime', [str(output / 'checks')])]:
            result = subprocess.run(arguments, capture_output=True, text=True, env=environment, timeout=90)
            log = result.stdout + result.stderr
            (output / (label + '.log')).write_text(log)
            record['commands'].append({'label': label, 'argv': arguments, 'exitCode': result.returncode})
            print(log, end='')
            record['exitCode'] = result.returncode
            if result.returncode:
                break
    record['sourceUnchanged'] = path.read_text() == source
    if not record['sourceUnchanged']:
        record['exitCode'] = 2
    (output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record))
    return record['exitCode']


if __name__ == '__main__':
    sys.exit(main())
