"""실제 chooser 동작 본문으로 취소/실패 뒤 선택을 검사한다. SDK/UI/Host 실행 없음."""
from pathlib import Path
import hashlib
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
view = root / 'iOSClient/IPadAudioRouteChooser.swift'
policy = root / 'iOSClient/IPadAudioRoutePolicy.swift'
inputs = [view, policy, Path(__file__)]
before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}


def block(source, signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


current = view.read_text()
types = '\n'.join(block(policy.read_text(), signature) for signature in ['    enum Input:', '    enum Output:', '    struct Selection:'])
methods = '\n'.join(block(current, '    private func ' + name + '(').replace('private func ', 'func ', 1)
                    for name in ['startCall', 'applySelection', 'cancelOperation'])
mutants = []
for name in ['startCall', 'cancelOperation']:
    method = block(current, '    private func ' + name + '(')
    resync = next(line for line in method.splitlines(keepends=True) if line.strip() == 'selection = client.audioRouteSelection')
    assert method.count(resync) == 1
    mutants.append(method.replace(resync, '', 1).replace('private func ' + name, 'func mutant' + name[0].upper() + name[1:], 1))


def setter(direction):
    start = current.index('Toggle(isOn: Binding(get: { selection.' + direction + ' != .off }, set: {')
    start = current.index('\n', start) + 1
    return current[start:current.index('\n                    }))', start)].replace('$0', 'enabled')


fixture = r'''
struct UUID: Equatable {
    private static var sequence = 0
    let value: Int
    init() { Self.sequence += 1; value = Self.sequence }
}
enum IPadAudioRoutePolicy {
POLICY_TYPES
    typealias Context = Int
    struct Authorization { let context: Context }
}
enum IPadCallTarget { case nativeCodex }
enum FixtureFailure: Error { case failed }
extension Error { var localizedDescription: String { "검사 오류" } }

@MainActor final class StreamClient {
    var audioRouteSelection = IPadAudioRoutePolicy.Selection()
    var audioRouteContext: Int? = 1
    var audioRouteAuthorization: IPadAudioRoutePolicy.Authorization?
    var iPadProviderCanPrepareCall = true
    var failPreparation = false
    var preparation: CheckedContinuation<Void, Error>?
    var microphoneRequests = 0
    var selectionGeneration = UUID()
    func acknowledgeAudioRoutes(identity: Int?, context: Int?) {}
    func select(_ chosen: IPadAudioRoutePolicy.Selection) {
        if chosen.input != .off && audioRouteSelection.input == .off { microphoneRequests += 1 }
        audioRouteSelection = chosen
        selectionGeneration = UUID()
    }
    func cancelDesiredAudioRequest() { select(.init()) }
    func applyAudioRoutes(_ chosen: IPadAudioRoutePolicy.Selection, context: Int?) async throws { select(chosen) }
    func prepareAndStartIPadProviderCall(_ chosen: IPadAudioRoutePolicy.Selection, context: Int?, target: IPadCallTarget) async throws {
        select(chosen)
        if failPreparation { cancelDesiredAudioRequest(); throw FixtureFailure.failed }
        try await withCheckedThrowingContinuation { preparation = $0 }
    }
    func finishOldPreparation() {
        let old = preparation; preparation = nil
        old?.resume(throwing: FixtureFailure.failed)
    }
}

@MainActor final class ChooserHarness {
    let client: StreamClient
    let callTarget = IPadCallTarget.nativeCodex
    var selection = IPadAudioRoutePolicy.Selection()
    var selectionEdited = false
    var context: Int? = 1
    var acknowledgedMac: Int?
    var problem: String?
    var operation: Task<Void, Never>?
    var operationID: UUID?
    var preparingCall = false
    var preparingCraft = false
    var busy: Bool { operationID != nil }
    init(_ client: StreamClient) { self.client = client }
CURRENT_METHODS
MUTANT_METHODS
    func speaker(_ enabled: Bool) {
SPEAKER_SETTER
    }
    func microphone(_ enabled: Bool) {
MICROPHONE_SETTER
    }
}

@main struct SelectionChecks {
    @MainActor static var checks = 0
    @MainActor static func check(_ value: Bool, _ label: String) {
        checks += 1; precondition(value, label)
    }
    @MainActor static func waitForPreparation(_ client: StreamClient) async {
        for _ in 0..<1000 where client.preparation == nil { await Task.yield() }
        check(client.preparation != nil, "start reaches asynchronous preparation")
    }
    @MainActor static func main() async {
        for mutant in [true, false] {
            let client = StreamClient(), chooser = ChooserHarness(client)
            chooser.startCall()
            let original = chooser.operation!
            await waitForPreparation(client)
            let requests = client.microphoneRequests
            if mutant { chooser.mutantCancelOperation(stopPreparingAudio: true) }
            else { chooser.cancelOperation(stopPreparingAudio: true) }
            check(client.audioRouteSelection == .init(), "cancel stops actual input and output")
            check((chooser.selection == .init()) == !mutant, "missing cancel resync reproduces stale selection")
            chooser.speaker(false)
            await chooser.operation!.value
            client.finishOldPreparation()
            await original.value
            check(client.microphoneRequests == requests + (mutant ? 1 : 0),
                  "speaker OFF reopens cancelled microphone only without resync")
        }
        for mutant in [true, false] {
            let client = StreamClient(), chooser = ChooserHarness(client)
            client.failPreparation = true
            if mutant { chooser.mutantStartCall() } else { chooser.startCall() }
            await chooser.operation!.value
            let requests = client.microphoneRequests
            check(client.audioRouteSelection == .init() && chooser.problem != nil, "actual preparation failure remains visible")
            check((chooser.selection == .init()) == !mutant, "missing failure resync reproduces stale selection")
            chooser.speaker(false)
            await chooser.operation!.value
            check(client.microphoneRequests == requests + (mutant ? 1 : 0),
                  "speaker OFF after failure cannot reactivate fixed microphone")
        }
        let client = StreamClient(), chooser = ChooserHarness(client)
        chooser.startCall()
        let original = chooser.operation!
        await waitForPreparation(client)
        chooser.cancelOperation(stopPreparingAudio: true)
        chooser.microphone(true)
        await chooser.operation!.value
        let generation = client.selectionGeneration
        client.finishOldPreparation()
        await original.value
        check(chooser.selection == client.audioRouteSelection && chooser.selection.input == .iPadMicrophone && chooser.selection.output == .off,
              "late old failure preserves explicit new microphone selection")
        check(client.selectionGeneration == generation && chooser.problem == nil,
              "late cancelled task changes neither new generation nor error state")
        print("PASS \(checks) actual chooser action/selection checks including resync mutation detection; Git/UI/Host/device/audio effects0")
    }
}
'''
fixture = (fixture.replace('POLICY_TYPES', types).replace('CURRENT_METHODS', methods)
           .replace('MUTANT_METHODS', '\n'.join(mutants)).replace('SPEAKER_SETTER', setter('output'))
           .replace('MICROPHONE_SETTER', setter('input')))
with tempfile.TemporaryDirectory(prefix='ipad-chooser-selection-') as temporary:
    out = Path(temporary)
    source = out / 'Checks.swift'
    source.write_text(fixture)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                    str(source), '-o', str(out / 'check')], check=True, cwd=root, timeout=90)
    subprocess.run([str(out / 'check')], check=True, cwd=root, timeout=20)
assert before == {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
print('SOURCE_UNCHANGED=true; SCRATCH_REMOVED=' + str(not out.exists()).lower())
