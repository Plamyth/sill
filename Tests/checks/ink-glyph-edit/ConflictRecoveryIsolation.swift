import Foundation

@main struct ConflictRecoveryIsolation {
    static func main() throws {
        let files=FileManager.default
        let support=files.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!
        let normal=support.appendingPathComponent("CanvasConflictRecovery",isDirectory:true)
        let mode=ProcessInfo.processInfo.environment["RECOVERY_TEST_MODE"]!
        let normalFiles=[support.appendingPathComponent("CanvasScene.json"),support.appendingPathComponent("CanvasOutbox/ledger.json"),
            normal.appendingPathComponent("CanvasConflictChoice.json"),normal.appendingPathComponent("CanvasConflictLocal-11111111-1111-4111-8111-111111111111.json"),
            normal.appendingPathComponent("CanvasConflictAttempt-22222222-2222-4222-8222-222222222222.json")]
        let before=try normalFiles.map {try Data(contentsOf:$0)}
        var checks=0
        func check(_ value:Bool,_ label:String) {precondition(value,label);checks+=1;print("PASS",label)}
        func rejected(_ label:String,_ body:() throws -> Void) {do {try body();preconditionFailure(label)} catch {checks+=1;print("PASS",label)}}
        let valid=["CanvasConflictChoice.json","CanvasConflictLocal-33333333-3333-4333-8333-333333333333.json",
            "CanvasConflictAttempt-44444444-4444-4444-8444-444444444444.json"]
        let bad=["runtime.json","CanvasScene.json","other.json","CanvasConflictChoice2.json","canvasconflictchoice.json",
            "CanvasConflictLocal-invalid.json","CanvasConflictAttempt-.json","CanvasConflictLocal-33333333333343338333333333333333.json",
            "CanvasConflictLocal-AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA.json","CanvasConflictLocal-33333333-3333-4333-8333-333333333333.JSON",
            "../CanvasConflictChoice.json","sub/CanvasConflictChoice.json","/CanvasConflictChoice.json"]
        #if DEBUG
        if mode == "invalid" {
            guard case .invalid = CanvasRuntime.launch else {preconditionFailure("actual invalid launch required")}
            for name in valid {rejected("invalid launch cannot construct recovery path") {_=try CanvasRuntime.conflictRecoveryURL(name)}}
        } else if mode == "normal" {
            guard case .normal = CanvasRuntime.launch else {preconditionFailure("actual normal launch required")}
            for name in valid {check(try CanvasRuntime.conflictRecoveryURL(name)==normal.appendingPathComponent(name),"normal recovery directory only")}
        } else {
            guard case .isolated = CanvasRuntime.launch else {preconditionFailure("actual --ccr-test-runtime launch required")}
            let state=try CanvasRuntime.stateURL(.checkpoint).deletingLastPathComponent()
            let recovery=state.appendingPathComponent("CanvasConflictRecovery",isDirectory:true)
            if mode == "parent-link" {
                for name in valid {
                    let url=recovery.appendingPathComponent(name)
                    rejected("symlink parent blocks helper") {_=try CanvasRuntime.conflictRecoveryURL(name)}
                    rejected("symlink parent blocks native write") {try CanvasLocalFile.write(Data("bad".utf8),to:url)}
                    rejected("symlink parent blocks native read") {_=try CanvasLocalFile.read(url)}
                }
            } else {
                for name in valid {
                    let url=try CanvasRuntime.conflictRecoveryURL(name)
                    check(url==recovery.appendingPathComponent(name),"exact current runtime UUID recovery path")
                    let bytes=Data(("격리 원본 e\u{301} 👩🏽‍💻\r\n"+name).utf8)
                    try CanvasLocalFile.write(bytes,to:url)
                    let read=try CanvasLocalFile.read(url);check(read==bytes,"actual CanvasLocalFile create and reopen permitted recovery file")
                    try CanvasLocalFile.write(bytes+Data("추가".utf8),to:url)
                    let again=try CanvasLocalFile.read(url);check(again==bytes+Data("추가".utf8),"actual atomic update and readback permitted")
                }
                for name in bad {
                    let url=name.hasPrefix("/") ? URL(fileURLWithPath:name):recovery.appendingPathComponent(name)
                    rejected("invalid recovery name helper: "+name) {_=try CanvasRuntime.conflictRecoveryURL(name)}
                    rejected("invalid recovery name direct write: "+name) {try CanvasLocalFile.write(Data([1]),to:url)}
                    rejected("invalid recovery name direct read: "+name) {_=try CanvasLocalFile.read(url)}
                }
                let foreign=support.appendingPathComponent("CCRIntegrationTests/55555555-5555-4555-8555-555555555555/state/CanvasConflictRecovery",isDirectory:true)
                for directory in [normal,state,foreign,state.appendingPathComponent("other"),state.appendingPathComponent("CanvasConflictRecoveryExtra"),recovery.appendingPathComponent("nested")] {
                    for name in valid {
                        let url=directory.appendingPathComponent(name)
                        rejected("outside exact recovery root native write") {try CanvasLocalFile.write(Data([1]),to:url)}
                        rejected("outside exact recovery root native read") {_=try CanvasLocalFile.read(url)}
                    }
                }
                // Existing fixed state files and runtime.json retain their original, current-UUID scope.
                for item in CanvasRuntime.StateFile.allCases {
                    let url=try CanvasRuntime.stateURL(item),bytes=Data(item.rawValue.utf8)
                    try CanvasLocalFile.write(bytes,to:url)
                    let read=try CanvasLocalFile.read(url);check(read==bytes,"existing StateFile path unchanged: "+item.rawValue)
                }
                let runtime=state.appendingPathComponent("runtime.json")
                try CanvasLocalFile.write(Data("receipt fixture".utf8),to:runtime)
                let runtimeBytes=try CanvasLocalFile.read(runtime);check(runtimeBytes==Data("receipt fixture".utf8),"existing runtime.json scope unchanged")
                rejected("normal runtime.json remains forbidden") {try CanvasLocalFile.write(Data([1]),to:support.appendingPathComponent("runtime.json"))}
                rejected("foreign UUID runtime.json remains forbidden") {try CanvasLocalFile.write(Data([1]),to:foreign.deletingLastPathComponent().appendingPathComponent("runtime.json"))}
                for kind in ["symlink","hardlink","directory"] {
                    let name="CanvasConflictLocal-\(UUID().uuidString.lowercased()).json"
                    let url=try CanvasRuntime.conflictRecoveryURL(name)
                    if kind=="symlink" {try files.createSymbolicLink(at:url,withDestinationURL:normalFiles[2])}
                    else if kind=="hardlink" {try files.linkItem(at:normalFiles[2],to:url)}
                    else {try files.createDirectory(at:url,withIntermediateDirectories:false)}
                    rejected("late "+kind+" rejects native read") {_=try CanvasLocalFile.read(url)}
                    rejected("late "+kind+" rejects native write") {try CanvasLocalFile.write(Data([1]),to:url)}
                    rejected("late "+kind+" rejects helper") {_=try CanvasRuntime.conflictRecoveryURL(name)}
                    if kind=="hardlink" {try files.removeItem(at:url)} // only this test-created hardlink; protected source remains.
                }
                let lateURL=try CanvasRuntime.conflictRecoveryURL("CanvasConflictLocal-66666666-6666-4666-8666-666666666666.json")
                try files.moveItem(at:recovery,to:state.appendingPathComponent("owned-recovery-before-link"))
                try files.createSymbolicLink(at:recovery,withDestinationURL:normal)
                rejected("parent replaced after URL creation rejects read") {_=try CanvasLocalFile.read(lateURL)}
                rejected("parent replaced after URL creation rejects write") {try CanvasLocalFile.write(Data([1]),to:lateURL)}
            }
        }
        #else
        for name in valid {check(try CanvasRuntime.conflictRecoveryURL(name)==normal.appendingPathComponent(name),"Release normal recovery directory")}
        #endif
        for name in bad {rejected("helper never permits arbitrary filenames") {_=try CanvasRuntime.conflictRecoveryURL(name)}}
        let after=try normalFiles.map {try Data(contentsOf:$0)}
        check(before==after,"all protected normal scene/outbox and recovery fixture bytes unchanged")
        print("CONFLICT_RECOVERY_ISOLATION_OK",mode,checks,"actualLaunch=true compiledActualProductModel=true")
    }
}
