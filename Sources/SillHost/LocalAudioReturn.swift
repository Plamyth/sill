import Foundation
import LocalAuthentication

struct LocalAudioState: Codable, Equatable {
    struct Device: Codable, Equatable {
        let uid: String
        let inputChannels: Int
        let outputChannels: Int
        let inputMuted: Bool?
        let outputMuted: Bool?
    }
    let version: Int
    let inputUID: String
    let outputUID: String
    let systemOutputUID: String
    let devices: [Device]

    init(_ snapshot: PrivacyAudioSnapshot) throws {
        func uid(_ id: UInt32) throws -> String {
            guard let device = snapshot.devices.first(where: { $0.id == id }) else { throw PrivacyAudioFailure.readback }
            return device.uid
        }
        version = 1
        inputUID = try uid(snapshot.input)
        outputUID = try uid(snapshot.output)
        systemOutputUID = try uid(snapshot.systemOutput)
        devices = snapshot.devices.map { Device(uid: $0.uid, inputChannels: $0.inputChannels,
            outputChannels: $0.outputChannels, inputMuted: $0.inputMuted, outputMuted: $0.outputMuted) }
    }

    func matches(_ snapshot: PrivacyAudioSnapshot) -> Bool {
        guard version == 1, let current = try? LocalAudioState(snapshot) else { return false }
        return current.inputUID == inputUID && current.outputUID == outputUID && current.systemOutputUID == systemOutputUID &&
            devices.allSatisfy { saved in current.devices.contains(saved) }
    }
}

@MainActor
final class LocalAudioAuthentication {
    private var context: LAContext?
    private var completion: CheckedContinuation<Bool, Never>?
    private var expiry: Task<Void, Never>?

    func cancel() { finish(false) }

    func evaluate() async -> Bool {
        guard completion == nil else { return false }
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        self.context = context
        return await withCheckedContinuation { continuation in
            completion = continuation
            expiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(45))
                if !Task.isCancelled { self?.finish(false) }
            }
            context.evaluatePolicy(.deviceOwnerAuthentication,
                localizedReason: "Mac의 로컬 마이크와 스피커로 복귀") { [weak self, weak context] accepted, _ in
                Task { @MainActor in
                    guard let self, let context, self.context === context else { return }
                    self.finish(accepted)
                }
            }
        }
    }

    private func finish(_ accepted: Bool) {
        let continuation = completion
        completion = nil
        let old = context
        context = nil
        expiry?.cancel(); expiry = nil
        old?.invalidate()
        continuation?.resume(returning: accepted)
    }
}
