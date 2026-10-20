var checks = 0
func check(_ condition: Bool, _ label: String) {
    precondition(condition, label)
    checks += 1
}
func rejects(_ label: String, _ operation: () throws -> Void) {
    do { try operation(); preconditionFailure(label) }
    catch { checks += 1 }
}
let files = FileManager.default
let home = URL(fileURLWithPath:ProcessInfo.processInfo.environment["CCR_CHECK_HOME"]!,isDirectory:true)
let support = files.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!
check(support.path.hasPrefix(home.path + "/"), "Foundation sandbox HOME must stay in this worktree")
let mode = ProcessInfo.processInfo.environment["CCR_CHECK_MODE"]!
let identity = UUID(uuidString:"12345678-1234-4234-8234-123456789abc")!
let commit = String(repeating:"a",count:40), tree = String(repeating:"b",count:40)
let address = "http://192.168.45.4:8791", token = String(repeating:"t",count:24)
let legacyFiles = CanvasRuntime.StateFile.allCases.map { support.appendingPathComponent($0.rawValue) }
let originalBytes = try legacyFiles.map { try Data(contentsOf:$0) }
let documents = files.urls(for:.documentDirectory,in:.userDomainMask).first!
let importFile = documents.appendingPathComponent("canvas-relay.json")
let importBytes = try Data(contentsOf:importFile)

#if DEBUG
let bundles = URL(fileURLWithPath:ProcessInfo.processInfo.environment["CCR_CHECK_BUNDLES"]!,isDirectory:true)
let receiptBundle = Bundle(url:bundles.appendingPathComponent("valid.bundle"))!
if mode != "isolated" {
    rejects("normal/invalid launch cannot write runtime receipt") { try CanvasRuntime.writeRuntimeReceipt(bundle:receiptBundle) }
}
if ProcessInfo.processInfo.environment["CCR_CHECK_SUITE"] == "1" {
    struct Fixture {
        let support: URL
        let root: URL
        var file: URL { root.appendingPathComponent("context.json") }
        func load(_ args: [String]? = nil, commit: String? = String(repeating:"a",count:40),
                  tree: String? = String(repeating:"b",count:40)) -> CanvasRuntime.LaunchState {
            CanvasRuntime.resolve(arguments:args ?? ["app","--ccr-test-runtime",identity.uuidString],
                applicationSupport:support,sourceCommit:commit,sourceTree:tree)
        }
        func write(_ changes: [String:Any] = [:]) throws {
            var payload: [String:Any] = ["schema":"ccr.ipad-test-context/v1","id":identity.uuidString,
                "commit":String(repeating:"a",count:40),"tree":String(repeating:"b",count:40),
                "relayAddress":address,"token":token]
            payload.merge(changes) { _, new in new }
            try JSONSerialization.data(withJSONObject:payload).write(to:file)
        }
    }
    func fixture() throws -> Fixture {
        let support = home.appendingPathComponent("fixtures/\(UUID().uuidString)/support",isDirectory:true)
        let root = support.appendingPathComponent("CCRIntegrationTests/\(identity.uuidString.lowercased())",isDirectory:true)
        try files.createDirectory(at:root,withIntermediateDirectories:true)
        let fixture = Fixture(support:support,root:root)
        try fixture.write()
        return fixture
    }
    func invalid(_ state: CanvasRuntime.LaunchState, _ label: String) {
        if case .invalid = state { checks += 1 } else { preconditionFailure(label) }
    }
    let base = try fixture()
    if case .normal = base.load(["app"]) { checks += 1 } else { preconditionFailure("no flag") }
    if case .normal = CanvasRuntime.resolve(arguments:["app","--ccr-test-runtime-extra"],
        applicationSupport:nil,sourceCommit:nil,sourceTree:nil) { checks += 1 }
    else { preconditionFailure("only exact flag opts in") }
    for args in [["app","--ccr-test-runtime"], ["app","--ccr-test-runtime",""],
                 ["app","--ccr-test-runtime","../escape"], ["app","--ccr-test-runtime","not-a-uuid"],
                 ["app","--ccr-test-runtime",identity.uuidString.replacingOccurrences(of:"-",with:"")],
                 ["app","--ccr-test-runtime",identity.uuidString,"--ccr-test-runtime",identity.uuidString],
                 ["app","--ccr-test-runtime",identity.uuidString,"--ccr-test-runtime"]] {
        invalid(base.load(args), "invalid launch argument must not fall back")
    }
    invalid(CanvasRuntime.resolve(arguments:["app","--ccr-test-runtime",identity.uuidString],
        applicationSupport:nil,sourceCommit:commit,sourceTree:tree), "missing application support")
    guard case .isolated(let context) = base.load() else { preconditionFailure("valid uppercase UUID") }
    check(context.id == identity && context.commit == commit && context.tree == tree, "immutable source identity")
    check(context.relayAddress == address && context.token == token, "immutable relay connection")
    for file in CanvasRuntime.StateFile.allCases {
        check(try CanvasRuntime.isolatedURL(file,in:context) ==
              base.root.appendingPathComponent("state").appendingPathComponent(file.rawValue), "all isolated paths")
    }
    check(!files.fileExists(atPath:base.root.appendingPathComponent("state").path), "validation does not create state")
    for change: [String:Any] in [["schema":"wrong"], ["id":UUID().uuidString], ["id":3],
        ["commit":String(repeating:"a",count:39)], ["tree":String(repeating:"b",count:41)],
        ["commit":String(repeating:"g",count:40)], ["tree":String(repeating:"c",count:40)],
        ["commit":String(repeating:"A",count:40)], ["token":String(repeating:"t",count:23)],
        ["token":false], ["relayAddress":"http://8.8.8.8:80"]] {
        try base.write(change)
        invalid(base.load(), "bad schema/identity/source/relay/token")
    }
    try base.write()
    invalid(base.load(commit:nil), "missing bundle commit")
    invalid(base.load(tree:nil), "missing bundle tree")
    invalid(base.load(commit:String(repeating:"0",count:40)), "bundle commit mismatch")
    invalid(base.load(tree:String(repeating:"0",count:40)), "bundle tree mismatch")
    for bytes in [Data(), Data("not-json".utf8), Data("[]".utf8), Data("{}".utf8)] {
        try bytes.write(to:base.file)
        invalid(base.load(), "malformed context")
    }
    try base.write()
    var bytes = try Data(contentsOf:base.file)
    bytes.append(Data(repeating:32,count:CanvasRuntime.contextByteLimit - bytes.count))
    try bytes.write(to:base.file)
    guard case .isolated = base.load() else { preconditionFailure("context at byte bound") }
    checks += 1
    bytes.append(32)
    try bytes.write(to:base.file)
    invalid(base.load(), "oversize context")

    for endpoint in ["http://10.0.0.0:1", "http://10.255.255.255:65535", "http://172.16.0.1:80",
                     "http://172.31.255.255:65535", "http://192.168.0.1:8791"] {
        check(CanvasRuntime.privateEndpoint(endpoint), "RFC1918 endpoint accepted")
    }
    for endpoint in ["http://172.15.0.1:80", "http://172.32.0.1:80", "http://192.169.0.1:80",
        "http://127.0.0.1:80", "http://169.254.0.1:80", "http://0.0.0.0:80", "http://8.8.8.8:80",
        "http://localhost:80", "http://private.local:80", "http://[::1]:80", "https://10.0.0.1:80",
        "http://10.0.0.1", "http://10.0.0.1:0", "http://10.0.0.1:65536", "http://10.0.0.1:-1",
        "http://u:p@10.0.0.1:80", "http://@10.0.0.1:80", "http://10.0.0.1:80/",
        "http://10.0.0.1:80/x", "http://10.0.0.1:80?x", "http://10.0.0.1:80#x",
        "http://10.0.0.1:80?", "http://10.0.0.1:80#", "http://10.0.0.1:080",
        "http://010.0.0.1:80", "http://10.0.0.256:80", "http://10.1:80", "http://167772161:80",
        "http://0x0a.0.0.1:80", "http://10.0.0.1:80\n", "http://10.0.0.1%2f:80"] {
        check(!CanvasRuntime.privateEndpoint(endpoint), "unsafe endpoint rejected: \(endpoint)")
    }
    for relative in ["context.json", "state", "state/CanvasScene.json", "state/CanvasOutbox",
                     "state/CanvasOutbox/ledger.json", "state/CanvasBlockEdit",
                     "state/CanvasBlockEdit/recovery.json", "state/CanvasVaultCheckpoint.json"] {
        let value = try fixture()
        let path = value.root.appendingPathComponent(relative)
        try files.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
        if files.fileExists(atPath:path.path) { try files.removeItem(at:path) }
        try files.createSymbolicLink(at:path,withDestinationURL:home.appendingPathComponent("does-not-exist"))
        invalid(value.load(), "dangling symlink rejected: \(relative)")
    }
    for relative in ["CCRIntegrationTests", "CCRIntegrationTests/\(identity.uuidString.lowercased())"] {
        let value = try fixture()
        let path = value.support.appendingPathComponent(relative)
        let target = home.appendingPathComponent("preserved-\(UUID().uuidString)",isDirectory:true)
        try files.moveItem(at:path,to:target)
        try files.createSymbolicLink(at:path,withDestinationURL:target)
        invalid(value.load(), "root symlink rejected")
    }
    let linked = try fixture()
    let alias = home.appendingPathComponent("support-alias")
    try files.createSymbolicLink(at:alias,withDestinationURL:linked.support)
    invalid(CanvasRuntime.resolve(arguments:["app","--ccr-test-runtime",identity.uuidString],
        applicationSupport:alias,sourceCommit:commit,sourceTree:tree), "application support symlink")
    let directoryContext = try fixture()
    try files.removeItem(at:directoryContext.file)
    try files.createDirectory(at:directoryContext.file,withIntermediateDirectories:false)
    invalid(directoryContext.load(), "context must be a regular file")
    let hardLinked = try fixture()
    let preservedContext = home.appendingPathComponent("preserved-context.json")
    try files.moveItem(at:hardLinked.file,to:preservedContext)
    try files.linkItem(at:preservedContext,to:hardLinked.file)
    invalid(hardLinked.load(), "context hardlink cannot alias original data")
    let hardLinkedState = try fixture()
    try files.createDirectory(at:hardLinkedState.root.appendingPathComponent("state"),withIntermediateDirectories:true)
    try files.linkItem(at:legacyFiles[0],to:hardLinkedState.root.appendingPathComponent("state/CanvasScene.json"))
    invalid(hardLinkedState.load(), "state hardlink cannot alias original data")
    try files.removeItem(at:hardLinkedState.root.appendingPathComponent("state/CanvasScene.json"))
}
#endif

let override = home.appendingPathComponent("override/recovery.json")
let legacy = CanvasVaultCheckpoint(sceneID:identity,address:address,sceneSha:"scene",noteSha:"note",pendingSceneSha:nil)
UserDefaults.standard.checkpoint = try JSONEncoder().encode(legacy)
if mode == "normal" {
    for file in CanvasRuntime.StateFile.allCases {
        check(try CanvasRuntime.stateURL(file) == support.appendingPathComponent(file.rawValue), "normal production paths preserved")
    }
    check(try CanvasRuntime.stateURL(.blockRecovery,blockRecoveryOverride:override) == override, "normal injectable recovery preserved")
    try files.removeItem(at:support.appendingPathComponent("CanvasVaultCheckpoint.json"))
    keychainData = try JSONSerialization.data(withJSONObject:["address":address,"token":token])
    _ = CanvasRelay.loadConnection()
    check(keychainCalls > 0, "normal relay uses existing import/keychain path with counted stand-ins")
    check(CheckpointInitialization().vaultSceneID == identity && UserDefaults.standard.reads == 1,
          "normal checkpoint retains existing standard defaults fallback")
    try originalBytes[CanvasRuntime.StateFile.allCases.firstIndex(of:.checkpoint)!]
        .write(to:support.appendingPathComponent("CanvasVaultCheckpoint.json"))
} else {
    #if DEBUG
    if mode == "invalid" {
        guard case .invalid = CanvasRuntime.launch else { preconditionFailure("shared launch must fail closed") }
        for file in CanvasRuntime.StateFile.allCases {
            rejects("invalid state cannot fall back") { _ = try CanvasRuntime.stateURL(file,blockRecoveryOverride:override) }
        }
        rejects("invalid low-level write cannot bypass gate") { try CanvasLocalFile.write(Data(),to:override) }
        rejects("invalid low-level read cannot bypass gate") { _ = try CanvasLocalFile.read(legacyFiles[0]) }
        check(CanvasRelay.loadConnection() == nil, "invalid relay fails before legacy import")
        _ = CheckpointInitialization()
        check(UserDefaults.standard.reads == 0, "invalid checkpoint never reads standard defaults")
        rejects("invalid relay request fails closed") {
            _ = try CanvasRelay(address:address,token:token).checkedRequest("/voice/projection")
        }
    } else {
        guard case .isolated(let context) = CanvasRuntime.launch else { preconditionFailure("shared launch valid") }
        let state = support.appendingPathComponent("CCRIntegrationTests/\(identity.uuidString.lowercased())/state")
        let receiptURL = state.appendingPathComponent("runtime.json")
        check(!files.fileExists(atPath:receiptURL.path), "launch validation alone never writes receipt")
        for variant in ["commit", "tree", "identity", "build", "executable"] {
            let bundle = Bundle(url:bundles.appendingPathComponent(variant + ".bundle"))!
            rejects("receipt rejects unreadable/mismatched Bundle identity or executable") {
                try CanvasRuntime.writeRuntimeReceipt(bundle:bundle)
            }
            check(!files.fileExists(atPath:receiptURL.path), "failed receipt leaves no success file")
        }
        // Synthetic Bundle execution proves the helper only, never an installed app launch.
        try CanvasRuntime.writeRuntimeReceipt(bundle:receiptBundle)
        let receiptBytes = try Data(contentsOf:receiptURL)
        let receipt = try JSONSerialization.jsonObject(with:receiptBytes) as! [String:Any]
        check(Set(receipt.keys) == Set(["schema", "id", "commit", "tree", "bundleID", "build", "storageRoot",
                                      "relayAddress", "executableSHA256", "processID"]), "receipt exact schema fields, no token")
        for (key, value) in ["schema":"ccr.ipad-test-runtime/v1", "id":identity.uuidString.lowercased(),
                            "commit":commit, "tree":tree, "bundleID":"com.ambrion.sillcanvas.ipad.helper",
                            "build":"42", "storageRoot":state.path, "relayAddress":address,
                            "executableSHA256":ProcessInfo.processInfo.environment["CCR_CHECK_EXECUTABLE_SHA256"]!] {
            check(receipt[key] as? String == value, "runtime receipt exact " + key)
        }
        check((receipt["processID"] as? NSNumber)?.int32Value == getpid(), "receipt actual helper processID")
        check(!String(decoding:receiptBytes,as:UTF8.self).contains(token), "receipt never contains relay token")
        let inode = try files.attributesOfItem(atPath:receiptURL.path)[.systemFileNumber] as! NSNumber
        try CanvasRuntime.writeRuntimeReceipt(bundle:receiptBundle)
        check(try files.attributesOfItem(atPath:receiptURL.path)[.systemFileNumber] as? NSNumber != inode,
              "same-context receipt uses atomic replacement")
        check(try JSONSerialization.jsonObject(with:Data(contentsOf:receiptURL)) as? NSDictionary == receipt as NSDictionary,
              "atomic replacement preserves exact receipt values")
        check(try files.contentsOfDirectory(atPath:state.path) == ["runtime.json"], "receipt writes only its own file, no temporary residue")
        let replacedBytes = try Data(contentsOf:receiptURL)
        rejects("Bundle mismatch is rechecked on receipt replacement") {
            try CanvasRuntime.writeRuntimeReceipt(bundle:Bundle(url:bundles.appendingPathComponent("commit.bundle"))!)
        }
        check(try Data(contentsOf:receiptURL) == replacedBytes, "failed recheck preserves existing receipt")
        let otherReceipt = support.appendingPathComponent("CCRIntegrationTests/\(UUID().uuidString.lowercased())/state/runtime.json")
        rejects("receipt cannot write another context") { try CanvasLocalFile.write(receiptBytes,to:otherReceipt) }
        rejects("receipt cannot write into normal support") {
            try CanvasLocalFile.write(receiptBytes,to:support.appendingPathComponent("runtime.json"))
        }
        check(!files.fileExists(atPath:otherReceipt.path), "other context remains untouched")
        try files.removeItem(at:receiptURL)
        try files.createSymbolicLink(at:receiptURL,withDestinationURL:legacyFiles[0])
        rejects("receipt symlink cannot overwrite original state") { try CanvasRuntime.writeRuntimeReceipt(bundle:receiptBundle) }
        try files.removeItem(at:receiptURL)
        try files.linkItem(at:legacyFiles[0],to:receiptURL)
        rejects("receipt hardlink cannot overwrite original state") { try CanvasRuntime.writeRuntimeReceipt(bundle:receiptBundle) }
        try files.removeItem(at:receiptURL)
        for file in CanvasRuntime.StateFile.allCases {
            let url = try CanvasRuntime.stateURL(file,blockRecoveryOverride:override)
            check(url == state.appendingPathComponent(file.rawValue), "all writes ignore recovery override in test mode")
            let bytes = Data(file.rawValue.utf8)
            try CanvasLocalFile.write(bytes,to:url)
            check(try CanvasLocalFile.read(url) == bytes, "isolated atomic write/readback")
        }
        try files.removeItem(at:CanvasRuntime.stateURL(.checkpoint))
        let cold = CheckpointInitialization()
        check(cold.vaultSceneID == nil && UserDefaults.standard.reads == 0, "cold isolated checkpoint excludes standard fallback")
        try CanvasLocalFile.write(JSONEncoder().encode(legacy),to:CanvasRuntime.stateURL(.checkpoint))
        check(CheckpointInitialization().vaultSceneID == identity, "isolated checkpoint restore uses actual initializer")
        let connection = CanvasRelay.loadConnection()
        check(connection?.address == address && connection?.token == token, "isolated relay reads validated connection")
        let relay = CanvasRelay(address:address,token:token)
        let request = try relay.checkedRequest("/voice/projection")
        check(request.url?.absoluteString == address + "/voice/projection", "isolated request stays at test endpoint")
        rejects("changed address cannot escape isolated relay") {
            _ = try CanvasRelay(address:"http://8.8.8.8:80",token:token).checkedRequest("/voice/projection")
        }
        rejects("changed token cannot escape context") {
            _ = try CanvasRelay(address:address,token:"other").checkedRequest("/voice/projection")
        }
        rejects("absolute request cannot override isolated origin") { _ = try relay.checkedRequest("http://8.8.8.8:80/voice/projection") }
        rejects("low-level write outside state refused") { try CanvasLocalFile.write(Data(),to:override) }
        rejects("low-level read outside state refused") { _ = try CanvasLocalFile.read(legacyFiles[0]) }
        // Launch parsing is immutable: later context changes cannot change relay identity or paths.
        try Data("invalid now".utf8).write(to:state.deletingLastPathComponent().appendingPathComponent("context.json"))
        check(CanvasRelay.loadConnection()?.token == context.token, "cached launch context is not reparsed by relay")
        for file in CanvasRuntime.StateFile.allCases {
            let url = try CanvasRuntime.stateURL(file)
            try files.removeItem(at:url)
            try files.createSymbolicLink(at:url,withDestinationURL:support.appendingPathComponent(file.rawValue))
            rejects("late file symlink rejected on every restore/save path") { _ = try CanvasRuntime.stateURL(file) }
            rejects("late symlink rejected by atomic writer") { try CanvasLocalFile.write(Data(),to:url) }
            rejects("late symlink rejected by state reader") { _ = try CanvasLocalFile.read(url) }
            try files.removeItem(at:url)
        }
        let linkedScene = try CanvasRuntime.stateURL(.scene)
        try files.linkItem(at:legacyFiles[0],to:linkedScene)
        rejects("late hardlink cannot be restored") { _ = try CanvasLocalFile.read(linkedScene) }
        rejects("late hardlink cannot be saved") { try CanvasLocalFile.write(Data(),to:linkedScene) }
        try files.removeItem(at:linkedScene)
        for relative in ["CanvasOutbox", "CanvasBlockEdit"] {
            let directory = state.appendingPathComponent(relative)
            try files.removeItem(at:directory)
            try files.createSymbolicLink(at:directory,withDestinationURL:support.appendingPathComponent(relative))
            let file: CanvasRuntime.StateFile = relative == "CanvasOutbox" ? .outbox : .blockRecovery
            rejects("late parent symlink rejected") { _ = try CanvasRuntime.stateURL(file) }
            try files.removeItem(at:directory)
        }
        try files.removeItem(at:state)
        try files.createSymbolicLink(at:state,withDestinationURL:support)
        rejects("late state-root symlink blocks runtime receipt") { try CanvasRuntime.writeRuntimeReceipt(bundle:receiptBundle) }
        for file in CanvasRuntime.StateFile.allCases {
            rejects("late state-root symlink rejected") { _ = try CanvasRuntime.stateURL(file) }
        }
    }
    check(keychainCalls == 0, "requested test path never touches Keychain")
    check(UserDefaults.standard.reads == 0, "requested test path never reads standard defaults")
    #else
    preconditionFailure("Release must ignore every test launch flag")
    #endif
}
check(try legacyFiles.map { try Data(contentsOf:$0) } == originalBytes, "original state unchanged")
check(try Data(contentsOf:importFile) == importBytes, "Documents relay import unchanged")
check(!files.fileExists(atPath:override.path), "test recovery override never written")
#if DEBUG
check(!files.fileExists(atPath:support.appendingPathComponent("runtime.json").path), "no normal runtime receipt written")
#endif
print("PASS \(mode): \(checks) checks; no network, real Keychain, iOS SDK, UI or device used")
