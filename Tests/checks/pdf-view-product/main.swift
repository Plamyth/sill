import Foundation
import PDFKit
import AppKit
func pagesPDF(_ pages: [(String,String)], outlineObjects: [String] = []) -> Data {
    var objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Count \(pages.count) /Kids [\(pages.indices.map { "\(4+$0*2) 0 R" }.joined(separator:" "))] >>", "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    for (index,item) in pages.enumerated() {
        let stream = "BT /F1 16 Tf 60 700 Td (Core) Tj 0 -40 Td (\(item.0)) Tj 0 -40 Td (Core) Tj ET"
        objects.append("<< /Type /Page /Parent 2 0 R \(item.1.hasPrefix("/MediaBox") ? "" : "/MediaBox [0 0 612 792]") \(item.1) /Resources << /Font << /F1 3 0 R >> >> /Contents \(5+index*2) 0 R >>")
        objects.append("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")
    }
    if !outlineObjects.isEmpty {
        objects[0] = "<< /Type /Catalog /Pages 2 0 R /Outlines \(objects.count + 1) 0 R >>"
        objects.append(contentsOf:outlineObjects)
    }
    var data = Data("%PDF-1.4\n".utf8), offsets = [Int]()
    for (index,object) in objects.enumerated() { offsets.append(data.count); data.append(Data("\(index+1) 0 obj\n\(object)\nendobj\n".utf8)) }
    let start = data.count
    data.append(Data("xref\n0 \(objects.count+1)\n0000000000 65535 f \n".utf8))
    for offset in offsets { data.append(Data(String(format:"%010d 00000 n \n",offset).utf8)) }
    data.append(Data("trailer\n<< /Size \(objects.count+1) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n".utf8))
    return data
}



@MainActor final class OwnVault {
 let process = Process(), input = Pipe(), output = Pipe()
 var operations: [String] = []
 init() throws {
  let env=ProcessInfo.processInfo.environment
  process.executableURL=URL(fileURLWithPath:env["PDF_VIEW_NODE"]!)
  process.arguments=[env["PDF_VIEW_BACKEND"]!];process.standardInput=input;process.standardOutput=output;process.standardError=FileHandle.standardError
  try process.run()
 }
 func close() { try? input.fileHandleForWriting.close();process.waitUntilExit();precondition(process.terminationStatus == 0) }
 private func response(_ op: String,_ args: [String:Any]) throws -> Data {
  operations.append(op);var row=args;row["operation"]=op
  var bytes=try JSONSerialization.data(withJSONObject:row);bytes.append(10);try input.fileHandleForWriting.write(contentsOf:bytes)
  var line=Data()
  while let part=try output.fileHandleForReading.read(upToCount:1),!part.isEmpty { if part[0]==10 {break};line.append(part) }
  let answer=try JSONSerialization.jsonObject(with:line) as! [String:Any]
  guard answer["ok"] as? Bool == true else {
   let status=answer["status"] as? Int ?? 500
   let held=answer["reconciliationRequired"] as? Bool == true || answer["code"] as? String == "note_reconciliation_required"
   throw NSError(domain:"CanvasRelay",code:status,userInfo:[NSLocalizedDescriptionKey:answer["message"] as? String ?? "own fixture",VaultSaveConflict.errorKey:held ? VaultSaveConflict.reconciliationRequired.rawValue : VaultSaveConflict.unclassified.rawValue])
  }
  return line
 }
 func call(_ op: String,_ args: [String:Any]) throws -> Data {
  let answer=try JSONSerialization.jsonObject(with:response(op,args)) as! [String:Any]
  return try JSONSerialization.data(withJSONObject:answer["value"]!)
 }
 private struct Response<Value: Decodable>: Decodable { let value: Value }
 // Decode the original response directly: JSONSerialization's value roundtrip strips a leading text BOM.
 func pdf(_ path:String) async throws -> VaultPDFSnapshot {try JSONDecoder().decode(Response<VaultPDFSnapshot>.self,from:response("readPDF",["path":path])).value}
 func note(_ path:String) async throws -> VaultNoteSnapshot {try JSONDecoder().decode(Response<VaultNoteSnapshot>.self,from:response("readNote",["path":path])).value}
 func save(_ path:String,_ base:String?,_ text:String) async throws -> VaultNoteSnapshot {
  try JSONDecoder().decode(Response<VaultNoteSnapshot>.self,from:response("saveNote",["path":path,"baseSha256":base as Any? ?? NSNull(),"text":text])).value
 }
 func compare(_ path:String) async throws -> CanvasRelay.NoteConflict {try JSONDecoder().decode(CanvasRelay.NoteConflict.self,from:call("compare",["path":path])).validated(path:path)}
 func resolve(_ c:CanvasRelay.NoteConflict,_ d:CanvasRelay.ConflictDecision) async throws -> VaultNoteSnapshot {
  let expected=try JSONSerialization.jsonObject(with:JSONEncoder().encode(c.expected))
  _ = try call("resolve",["path":c.path,"request":["recoveryID":c.recoveryID.uuidString.lowercased(),"expected":expected,"decision":d.rawValue]])
  return try await note(c.path)
 }
}
@main struct PDFProductChecks {
 static var assertions:[String]=[]
 static func check(_ yes:Bool,_ name:String){precondition(yes,name);assertions.append(name);print("PASS",name)}
 @MainActor static func main() async throws {
  setbuf(stdout,nil)
  guard case .isolated(let context)=CanvasRuntime.launch else {fatalError("isolated only")}
  let out=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true).resolvingSymlinksInPath(),vault=try OwnVault();defer{vault.close()}
  func newStore()->CanvasStore {let s=CanvasStore();s.enableDocumentChecks();s.setNoteConnection(address:context.relayAddress,token:context.token);return s}
  let path="문서/원본.pdf"
  if CommandLine.arguments.contains("--reopen") {
   let s=newStore()
   let expected=try JSONDecoder().decode(VaultPDFViewState.self,from:Data(contentsOf:out.appendingPathComponent("expected.json")))
   let opened=await s.openPDFView(path,loadPDF:vault.pdf,loadNote:vault.note)
   check(opened && s.pdfViewReader?.viewState == expected,"fresh process reopens actual sidecar and ordered PDF crop")
   if CommandLine.arguments.contains("--pending") {
    check(s.hasPendingPDFView && s.pdfExcerptRecovery?.viewRecovery?.submitted != nil,"fresh process retains complete submitted and draft intent")
    check(!s.canTransitionDocument,"fresh process blocks document/page replacement on hidden PDF intent")
   } else {check(!s.hasPendingPDFView,"fresh process clean state has no extra recovery intent")}
   return
  }
  func reopen(_ state:VaultPDFViewState,pending:Bool=false)throws {
   try JSONEncoder().encode(state).write(to:out.appendingPathComponent("expected.json"))
   let p=Process();p.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);p.arguments=[out.path,"--ccr-test-runtime",context.id.uuidString.lowercased(),"--reopen"]+(pending ? ["--pending"]:[])
   try p.run();p.waitUntilExit();check(p.terminationStatus==0,"separate Store process \(pending ? "pending":"clean")")
  }
  let pdf=pagesPDF([("ONE",""),("TWO",""),("THREE","")])
  _ = try vault.call("writePDF",["path":path,"base64":pdf.base64EncodedString()])
  let snapshot=try await vault.pdf(path),native=try VaultPDFReader(snapshot:snapshot)
  native.view.frame=CGRect(x:0,y:0,width:640,height:900)
  let page=native.view.document!.page(at:0)!
  native.view.setCurrentSelection(page.selection(for:(page.string! as NSString).range(of:"Core")),animate:false)
  let source=try native.excerpt(),s=newStore()
  check(s.preparePDFExcerpt(source),"actual Store prepares original PDF excerpt")
  let id=await s.savePDFExcerpt(allowCreate:true,create:{try await vault.save($0,nil,$1)},load:vault.note)
  check(id != nil,"actual Obsidian note Files PUT/GET attaches original source card")
  let sourceNote=try await vault.note(source.notePath),sourceCard=s.scene.nodes.first{$0.id==id}!
  let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
  let sourceJSON=try encoder.encode(source),sceneBefore=s.scene
  check(s.closeVaultEditor(),"source note editor closes without draft loss")
  try s.createDocument()
  let files=out.appendingPathComponent("selected-files",isDirectory:true);try FileManager.default.createDirectory(at:files,withIntermediateDirectories:true)
  // Existing native complete Document Files persists original PDF card and all source bytes.
  let png=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAX+XDSwAAAABJRU5ErkJggg==")!
  s.filePreview={_ in png};await s.connectDocumentWorkspace(files)
  print("FILES",s.status,s.fileWorkspaceStatus,s.documentFileReady,s.documentBusy)
  check(s.documentFileReady,"canonical Document original is bound to actual whole Files generation")
  let originalDocument=try s.document.bytes()
  let opened=await s.openPDFView(path,source:source,loadPDF:vault.pdf,loadNote:vault.note)
  check(opened,"only actual sidecar404 permits first PDF view state")
  var reader=s.pdfViewReader!
  try reader.moveDisplayPage(from:1,to:2)
  try reader.setCrop(.init(x:0.1,y:0.1,width:0.8,height:0.8),physicalPageNumber:2)
  let savedState=reader.viewState
  try reader.undoViewState()
  check(s.preservePDFViewDraft(reader) && reader.viewState != savedState,"native metadata Undo updates durable local draft without changing source")
  try reader.redoViewState()
  check(s.preservePDFViewDraft(reader) && reader.viewState == savedState,"native metadata Redo restores exact pending order and crop")
  check(s.preservePDFViewDraft(reader) && s.hasPendingPDFView,"order and crop persist complete durable local draft")
  check(!s.canTransitionDocument,"pending view state participates in whole document recovery barrier")
  let request=try reader.prepareViewStateSave(base:s.pdfViewBase)
  await s.savePDFView(request,reader:reader,save:vault.save,load:vault.note)
  print("SAVE",s.vaultStatus)
  check(!s.hasPendingPDFView && !reader.hasViewEdits,"Store PUT plus full GET confirms exact request and clears only matching intent")
  check(try s.document.bytes()==originalDocument && s.scene==sceneBefore,"view save leaves canonical Document scene and original source untouched")
  try reopen(savedState)
  check(s.closePDFView(),"close clean reader without extra intent")
  let reopened=newStore();check(reopened.documentFileReady,"new Store reopens actual selected Files generation")
  check(await reopened.openPDFView(path,source:source,loadPDF:vault.pdf,loadNote:vault.note),"new Store reconstructs Reader from full sidecar")
  reader=reopened.pdfViewReader!
  try reader.returnToSource(source)
  check(reader.pageNumber==1 && reader.displayPageNumber==2 && reader.view.currentSelection?.string==source.quote,"original anchor returns through reordered and cropped native PDF")
  var external=savedState;external.displayOrder=[3,1,2];external.crops[0] = .init(x:0.2,y:0,width:0.8,height:1)
  _ = try vault.call("external",["path":external.notePath,"text":try external.markdown()])
  await reopened.reloadPDFView(reader:reader,load:vault.note)
  check(reader.viewState==external && !reader.hasViewEdits,"actual external Markdown edit reverse-receives order and crop")
  try reader.setCrop(.init(x:0,y:0,width:0.75,height:1),physicalPageNumber:3)
  let dirty=reader.viewState;check(reopened.preservePDFViewDraft(reader),"new local crop is durably retained")
  await reopened.reloadPDFView(reader:reader,load:vault.note)
  check(reader.viewState==dirty && reopened.hasPendingPDFView,"external reload refuses dirty view without erasing local intent")
  let lost=try reader.prepareViewStateSave(base:reopened.pdfViewBase)
  var puts=0
  await reopened.savePDFView(lost,reader:reader,save:{p,b,t in puts+=1;_ = try await vault.save(p,b,t);throw URLError(.networkConnectionLost)},load:vault.note)
  check(puts==1 && reopened.pdfExcerptRecovery?.saveConflict == .acknowledgementLost && reopened.pdfExcerptRecovery?.viewRecovery?.submitted==lost,"lost response preserves immutable request and sends exactly once")
  try reopen(dirty,pending:true)
  let restored=newStore();check(await restored.openPDFView(path,source:source,loadPDF:vault.pdf,loadNote:vault.note),"restart uses retained base and draft instead of rebasing onto newer remote")
  reader=restored.pdfViewReader!
  await restored.reloadPDFView(reader:reader,load:vault.note)
  check(!restored.hasPendingPDFView && !reader.hasViewEdits,"explicit read confirms unknown result without another PUT")
  try reader.setCrop(.init(x:0,y:0.2,width:1,height:0.8),physicalPageNumber:1)
  check(restored.preservePDFViewDraft(reader),"next intent durably prepared")
  let conflictRequest=try reader.prepareViewStateSave(base:restored.pdfViewBase)
  var displaced=dirty;displaced.displayOrder=[1,3,2]
  await restored.savePDFView(conflictRequest,reader:reader,save:{p,b,t in
   try JSONDecoder().decode(VaultNoteSnapshot.self,from:vault.call("conflictingSave",["path":p,"baseSha256":b as Any? ?? NSNull(),"text":t,"external":try displaced.markdown()]))
  },load:vault.note)
  check(restored.pdfExcerptRecovery?.saveConflict == .reconciliationRequired && !restored.pdfViewCanPersist,"actual atomic-exchange conflict becomes explicit held barrier")
  let intent=restored.pdfExcerptRecovery!
  await restored.reloadPDFView(reader:reader,load:vault.note)
  check(restored.pdfExcerptRecovery==intent && reader.viewState==conflictRequest.state,"held read cannot auto-acknowledge or erase submitted/local bytes")
  try reopen(conflictRequest.state,pending:true)
  await restored.comparePDFViewConflict(reader:reader,load:vault.compare)
  check(restored.pdfViewChoice?.original==intent && restored.noteReconciliationHeld,"actual server conflict candidates and full local original survive durable comparison")
  let choice=restored.pdfViewChoice!
  check(choice.conflict.materials.base?.sha256==CanvasPacket.sha(Data(lost.markdown.utf8)),"server retains correct base material independently")
  // Pick current external candidate; prior full draft/proposal is preserved in the resolved local choice.
  await restored.resolvePDFViewConflict(.keepCurrent,reader:reader,resolve:vault.resolve)
  print("RESOLVE",restored.vaultStatus)
  check(!restored.hasPendingPDFView && restored.pdfViewChoice?.phase == .resolved && !restored.noteReconciliationHeld,"explicit actual note recovery PUT and GET close only this intent")
  check(restored.pdfViewReader?.viewState==displaced,"resolved external order and crop are installed as new Reader")
  check(restored.pdfViewChoice?.original==intent,"resolution retains old base/draft/submitted in immutable recovery payload")
  try reopen(displaced)
  // A later edit arriving during PUT stays dirty against the newly confirmed base.
  reader=restored.pdfViewReader!
  try reader.setCrop(.init(x:0,y:0,width:0.8,height:1),physicalPageNumber:1)
  let first=try reader.prepareViewStateSave(base:restored.pdfViewBase)
  await restored.savePDFView(first,reader:reader,save:{p,b,t in
   let response=try await vault.save(p,b,t)
   try reader.setCrop(.init(x:0.1,y:0,width:0.9,height:1),physicalPageNumber:3)
   check(restored.preservePDFViewDraft(reader),"new input during PUT persists beside immutable submitted request")
   return response
  },load:vault.note)
  check(reader.hasViewEdits && restored.hasPendingPDFView && restored.pdfExcerptRecovery?.viewRecovery?.submitted == nil,"late successful callback advances base without overwriting newer crop")
  let newer=try reader.prepareViewStateSave(base:restored.pdfViewBase)
  await restored.savePDFView(newer,reader:reader,save:vault.save,load:vault.note)
  check(!restored.hasPendingPDFView,"explicit save of later crop confirms new base")
  let beforeBad=reader.viewState
  let unsupported=await restored.openPDFView(path,loadPDF:vault.pdf,loadNote:{p in .init(path:p,text:"unsupported PDF state",sha256:CanvasPacket.sha(Data("unsupported PDF state".utf8)),modifiedAt:"")})
  check(!unsupported && restored.pdfViewReader === reader && reader.viewState==beforeBad,"unsupported sidecar preserves existing Reader and source instead of default fallback")
  let denied=await restored.openPDFView(path,loadPDF:vault.pdf,loadNote:{_ in throw NSError(domain:"CanvasRelay",code:403)})
  check(!denied && restored.pdfViewReader === reader,"permission error does not become missing sidecar or a new default")
  let documentBeforeLate=try restored.document.bytes()
  let late=await restored.openPDFView(path,loadPDF:{p in
   restored.setNoteConnection(address:"http://192.168.88.88:4243",token:context.token)
   return try await vault.pdf(p)
  },loadNote:vault.note)
  let documentAfterLate=try restored.document.bytes()
  check(!late && restored.pdfViewReader == nil && documentAfterLate==documentBeforeLate,"late callback after connection retirement never installs PDF state")
  restored.setNoteConnection(address:context.relayAddress,token:context.token)
  var fail=false
  let failing=CanvasStore(pdfExcerptRecoveryWrite:{data,url in if fail {throw CocoaError(.fileWriteNoPermission)};try CanvasLocalFile.write(data,to:url)})
  failing.enableDocumentChecks();failing.setNoteConnection(address:context.relayAddress,token:context.token)
  check(await failing.openPDFView(path,source:source,loadPDF:vault.pdf,loadNote:vault.note),"IO boundary opens existing Reader before injected failure")
  let failedReader=failing.pdfViewReader!;try failedReader.setCrop(.init(x:0,y:0,width:0.9,height:1),physicalPageNumber:2)
  fail=true
  check(!failing.preservePDFViewDraft(failedReader) && !failing.closePDFView() && failing.pdfViewReader === failedReader,"local intent write failure keeps same Reader and complete unsaved input")
  check(!failing.canApplyReconciledCanvas && !failing.canTransitionDocument,"unwritten metadata draft blocks original replacement before UI change callback")
  failing.setNoteConnection(address:"http://192.168.88.88:4243",token:context.token)
  check(failing.pdfViewReader === failedReader && !failing.pdfViewCanPersist,"connection retirement on IO failure retains Reader while blocking old-provider actions")
  failing.setNoteConnection(address:context.relayAddress,token:context.token)
  fail=false;check(failing.preservePDFViewDraft(failedReader),"retry local durability only after actual write failure is removed")
  let repair=try failedReader.prepareViewStateSave(base:failing.pdfViewBase)
  await failing.savePDFView(repair,reader:failedReader,save:vault.save,load:vault.note)
  check(!failing.hasPendingPDFView,"explicit metadata save closes recovered local IO boundary")
  try reopen(failedReader.viewState)
  let casReader=failing.pdfViewReader!
  try casReader.setCrop(.init(x:0.1,y:0,width:0.9,height:1),physicalPageNumber:2)
  check(failing.preservePDFViewDraft(casReader),"ordinary CAS local draft persists before external write")
  let cas=try casReader.prepareViewStateSave(base:failing.pdfViewBase)
  var remote=casReader.viewState;remote.displayOrder=[2,3,1]
  _ = try vault.call("external",["path":remote.notePath,"text":try remote.markdown()])
  await failing.savePDFView(cas,reader:casReader,save:vault.save,load:vault.note)
  check(failing.pdfExcerptRecovery?.saveConflict == .unclassified && !failing.pdfViewCanPersist,"ordinary unclassified409 is held rather than silently retried or checkpointed")
  let casIntent=failing.pdfExcerptRecovery!
  await failing.comparePDFViewConflict(reader:casReader,load:vault.compare,loadCurrent:vault.note)
  let remoteText=try remote.markdown()
  check(failing.pdfViewLocalChoice?.original == casIntent && failing.pdfViewLocalChoice?.current.text == remoteText,"explicit404 conflict journal plus complete non-held GET stages a local comparison")
  var raced=remote;raced.crops[2] = .init(x:0,y:0,width:1,height:0.9)
  _ = try vault.call("external",["path":remote.notePath,"text":try raced.markdown()])
  let putsBeforeChoice=vault.operations.filter{$0=="saveNote"}.count
  await failing.adoptPDFViewCurrent(reader:casReader,load:vault.note)
  check(failing.pdfExcerptRecovery == casIntent && failing.pdfViewLocalChoice?.closed == false && failing.pdfViewReader === casReader,"comparison-to-choice external race preserves intent and rejects stale current candidate")
  await failing.comparePDFViewConflict(reader:casReader,load:vault.compare,loadCurrent:vault.note)
  await failing.adoptPDFViewCurrent(reader:casReader,load:vault.note)
  check(!failing.hasPendingPDFView && failing.pdfViewReader?.viewState == raced && failing.pdfViewLocalChoice?.phase == .resolved,"explicit current choice resolves ordinary CAS refusal without a server recovery journal")
  check(vault.operations.filter{$0=="saveNote"}.count == putsBeforeChoice,"ordinary CAS reconciliation performs no retry or original overwrite")
  check(failing.pdfViewLocalChoice?.original == casIntent,"ordinary current choice preserves complete former base draft and submitted request")
  try failing.archiveCompletedPDFViewChoiceForNoteEditor()
  // Existing file/cache tasks can briefly own the shared transition gate after a new Store restore.
  for _ in 0..<200 where !failing.canTransitionDocument { await Task.yield() }
  check(failing.canTransitionDocument,"closed PDF comparison archives do not block a later document transition")
  try reopen(raced)
  var failAfter=true
  let post=CanvasStore(pdfExcerptRecoveryWrite:{data,url in try CanvasLocalFile.write(data,to:url);if failAfter {throw CocoaError(.fileWriteUnknown)}})
  post.enableDocumentChecks();post.setNoteConnection(address:context.relayAddress,token:context.token)
  check(await post.openPDFView(path,source:source,loadPDF:vault.pdf,loadNote:vault.note),"post-write failure fixture reuses exact original Files document")
  let postReader=post.pdfViewReader!;try postReader.setCrop(.init(x:0,y:0,width:1,height:0.85),physicalPageNumber:1)
  check(!post.preservePDFViewDraft(postReader),"write-then-error keeps unknown local intent instead of claiming success")
  let attempted=try JSONDecoder().decode(VaultPDFCreateRecoveryFile.self,from:CanvasLocalFile.read(CanvasRuntime.stateURL(.pdfExcerptRecovery))).record()!
  failAfter=false
  check(post.preservePDFViewDraft(postReader) && post.pdfExcerptRecovery?.viewRecovery?.id==attempted.viewRecovery?.id,"local unknown-write retry reuses preserved operation ID")
  let postRequest=try postReader.prepareViewStateSave(base:post.pdfViewBase)
  await post.savePDFView(postRequest,reader:postReader,save:vault.save,load:vault.note)
  check(!post.hasPendingPDFView,"explicit save closes write-then-error without duplicate operation")
  let finalPDF=try await vault.pdf(path),finalNote=try await vault.note(source.notePath)
  let finalExcerpt=try VaultPDFExcerpt.parse(finalNote.text)!
  check(finalPDF.sha256==snapshot.sha256 && finalNote.sha256==sourceNote.sha256 && sourceCard.vaultNote?.sha256==sourceNote.sha256 && CanvasPacket.sha(Data(finalExcerpt.quote.utf8))==CanvasPacket.sha(Data(source.quote.utf8)),"PDF/source-note/quote three SHA remain unchanged")
  check(try encoder.encode(source)==sourceJSON && failing.scene.nodes.first{$0.id==id}==sourceCard,"physical page range boxes rotation and original source card remain byte exact")
  check(NSApplication.shared.windows.isEmpty,"native PDFKit checks created no visible Window")
  try JSONSerialization.data(withJSONObject:["assertions":assertions,"count":assertions.count,"operations":vault.operations,"PDFSHA":snapshot.sha256,"sourceMarkdownSHA":sourceNote.sha256,"quoteSHA":CanvasPacket.sha(Data(source.quote.utf8))],options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("observations.json"))
 }
}
