import Foundation
@MainActor final class NoteWorkspaceHarness {
    let store:CanvasStore, relay:CanvasRelay
    var relayAddress="http://192.168.88.88:4242",relayToken="own-fixture-token-012345678901"
    var noteConflict:CanvasRelay.NoteConflict?,noteConflictLocal:NoteConflictLocalState?,noteConflictChoice:NoteConflictLocalChoice?,noteConflictArchive:NoteConflictLocalState?
    var noteConflictBusy=false,noteConflictMessage="",noteConflictGeneration:UInt64=0
    init(_ store:CanvasStore,_ relay:CanvasRelay) {self.store=store;self.relay=relay}
    // EXACT_MEMBERS
    func read(refresh:Bool=false)async {await readNoteConflict(refresh:refresh)}
    func resolve(_ decision:CanvasRelay.ConflictDecision)async {await resolveNoteConflict(decision)}
}
