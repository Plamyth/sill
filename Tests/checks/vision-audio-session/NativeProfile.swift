import Foundation

final class AVAudioSession {
    enum Category { case ambient, playback, playAndRecord }
    enum Mode { case `default`, spokenAudio }
    struct CategoryOptions: OptionSet {
        let rawValue: Int
        static let mixWithOthers = Self(rawValue: 0x1)
        static let duckOthers = Self(rawValue: 0x2)
        static let allowBluetoothHFP = Self(rawValue: 0x4)
        static let allowBluetoothA2DP = Self(rawValue: 0x20)
    }
    struct SetActiveOptions: OptionSet {
        let rawValue: Int
        static let notifyOthersOnDeactivation = Self(rawValue: 0x1)
    }
    static let inert = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { inert }
    var category = Category.ambient
    var mode = Mode.spokenAudio
    var categoryOptions: CategoryOptions = [.duckOthers]
    var events: [String] = []
    var activations: [(Bool, SetActiveOptions)] = []
    func setCategory(_ category: Category, mode: Mode, options: CategoryOptions) throws {
        self.category = category
        self.mode = mode
        categoryOptions = options
        events.append("category")
    }
    func setActive(_ active: Bool, options: SetActiveOptions = []) throws {
        activations.append((active, options))
        events.append(active ? "activate" : "deactivate")
    }
}

@main
struct NativeProfileChecks {
    static func main() throws {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ name: String) {
            checks += 1
            if !value { failures += 1; print("FAIL \(name)") }
        }
        let session = AVAudioSession.inert
        let driver = VisionAudioNativeGraph()
        check(!driver.categoryStillMatches(), "unconfigured native profile has no expected category")
        try driver.deactivate()
        check(session.events.isEmpty, "unconfigured cleanup does not change session")
        for profile in [VisionAudioProfile.playback, .microphone, .playback, .microphone] {
            try driver.configure(profile)
            check(session.category == (profile == .microphone ? .playAndRecord : .playback), "native profile applies requested category")
            check(session.mode == .default, "native profile retains default mode")
            check(session.categoryOptions.contains(.mixWithOthers), "native profile retains mixing")
            if profile == .microphone {
                print("MICROPHONE_OPTIONS \(session.categoryOptions.rawValue)")
                check(session.categoryOptions.contains(.allowBluetoothHFP), "microphone offers OS-exposed Bluetooth HFP input")
                check(session.categoryOptions.contains(.allowBluetoothA2DP), "microphone offers OS-exposed Bluetooth A2DP output")
                check(session.categoryOptions == [.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP], "microphone applies only mix and both Bluetooth options")
            } else {
                check(session.categoryOptions == [.mixWithOthers], "playback-only options remain unchanged")
            }
            check(driver.categoryStillMatches(), "expected options match applied native session")
            let applied = session.categoryOptions
            session.categoryOptions.formSymmetricDifference(.allowBluetoothHFP)
            check(!driver.categoryStillMatches(), "option-only route category drift invalidates expectation")
            session.categoryOptions = applied
            session.mode = .spokenAudio
            check(!driver.categoryStillMatches(), "mode drift invalidates expectation")
            session.mode = .default
            session.category = .ambient
            check(!driver.categoryStillMatches(), "category drift invalidates expectation")
            session.category = profile == .microphone ? .playAndRecord : .playback
            check(driver.categoryStillMatches(), "unchanged category notification matches expected profile")
        }
        check(session.activations.count == 4 && session.activations.allSatisfy { $0.0 && $0.1.isEmpty }, "configure activates only after applying profile")
        try driver.deactivate()
        check(session.category == .ambient && session.mode == .spokenAudio && session.categoryOptions == [.duckOthers], "deactivate restores original category mode and options across rebuilds")
        check(session.events.suffix(2) == ["deactivate", "category"], "deactivate precedes previous session restoration")
        check(session.activations.last?.0 == false && session.activations.last?.1 == .notifyOthersOnDeactivation, "deactivate notifies other sessions")
        check(driver.categoryStillMatches(), "restored previous session matches expected settings")
        let events = session.events
        try driver.deactivate()
        check(session.events == events, "cleanup clears previous session exactly once")
        session.category = .playback
        session.mode = .default
        session.categoryOptions = [.mixWithOthers, .allowBluetoothA2DP]
        try driver.configure(.microphone)
        try driver.deactivate()
        check(session.category == .playback && session.mode == .default && session.categoryOptions == [.mixWithOthers, .allowBluetoothA2DP], "new lifecycle restores its own previous session options")
        print("RESULT_ASSERTIONS \(checks)")
        print("RESULT_FAILURES \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
