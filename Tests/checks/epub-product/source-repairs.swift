import Foundation
import AppKit
import PencilKit

@main struct IndependentEPUBStoreCheck {
 @MainActor static func main() async throws {
  guard case .isolated(let ctx) = CanvasRuntime.launch else { fatalError("isolation required") }
  let out = URL(fileURLWithPath:CommandLine.arguments[1]).resolvingSymlinksInPath()
  let archive = try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))
  let snapshot = try VaultEPUBSnapshot(path:"book.epub",bytes:archive)
  if CommandLine.arguments.contains("--group-paper-reopen") {
   let reopened = CanvasStore(); reopened.enableDocumentChecks()
   let expected = try CanvasDocument.decode(Data(contentsOf:out.appendingPathComponent("composition-expected.json")))
   precondition(reopened.document == expected && reopened.documentFileReady)
   print("PASS composite whole document fresh Store process")
   return
  }
  if CommandLine.arguments.contains("--group-paper-only") {
   try await composition(snapshot:snapshot,out:out,contextID:ctx.id)
   return
  }
  let s = CanvasStore(); s.enableDocumentChecks(); s.setNoteConnection(address:ctx.relayAddress,token:ctx.token)
  let opened = await s.openEPUB("book.epub",load:{ _ in snapshot }); precondition(opened)
  let r = s.epubReader!; try r.openChapter(1)
  r.view.setSelectedRange((r.view.string as NSString).range(of:"문구 😀"))
  let source = try r.prepareExcerpt()
  precondition(s.prepareEPUBExcerpt(source))
  var server: VaultNoteSnapshot?; var creates = 0
  let node = await s.saveEPUBExcerpt(allowCreate:true,create:{ path,text in
   creates += 1; let n = VaultNoteSnapshot(path:path,text:text,sha256:CanvasPacket.sha(Data(text.utf8)),modifiedAt:""); server = n; return n
  },load:{ _ in guard let server else { throw NSError(domain:"CanvasRelay",code:404) }; return server })
  guard let node, let note = server else { fatalError("save did not attach") }
  func row(_ label:String) -> [String:Any] {
   let n = s.scene.nodes.first { $0.id == node }!, ref = n.vaultNote!
   return ["phase":label,"quoteSha256":ref.quoteSha256 as Any? ?? NSNull(),"sourceState":ref.sourceState?.rawValue as Any? ?? NSNull(),"cacheTruncated":ref.cacheTruncated as Any? ?? NSNull(),"fullNoteSHA":ref.sha256,"previewMatchesFullText":n.text.utf8.elementsEqual(note.text.utf8),"sourcePayloadUnchanged":(try? VaultEPUBExcerpt.parse(note.text)) == source]
  }
  var rows = [row("saved")]
  await s.refreshVaultNotes(load:{ _ in note }); rows.append(row("identical-full-GET"))
  await s.refreshVaultNotes(load:{ _ in note }); rows.append(row("second-identical-full-GET"))
  let pdf = VaultPDFExcerpt(schemaVersion:1,excerptID:source.excerptID,pdfPath:"book.pdf",pdfSha256:String(repeating:"b",count:64),pageIndex:0,mediaBox:.init(CGRect(x:0,y:0,width:100,height:100)),cropBox:.init(CGRect(x:0,y:0,width:100,height:100)),rotation:0,selectionRects:[.init(CGRect(x:1,y:1,width:20,height:10))],quote:"원문")
  let mixed = try pdf.markdown() + "\n" + source.markdown()
  var mixedRows = [[String:Any]]()
  for (label,kind) in [("nil-legacy-PDF",nil as VaultPDFCreateRecovery.SourceKind?),("explicit-EPUB",.epub)] {
   let record = VaultPDFCreateRecovery(sceneID:s.scene.id,relayAddress:ctx.relayAddress,path:source.notePath,draft:mixed,submittedText:nil,sourceKind:kind)
   do {
    let bytes = try JSONEncoder().encode(VaultPDFCreateRecoveryFile(record))
    let decoded = try JSONDecoder().decode(VaultPDFCreateRecoveryFile.self,from:bytes).record()
    mixedRows.append(["kind":label,"accepted":decoded != nil,"containsPDF":try VaultPDFExcerpt.parse(mixed) != nil,"containsEPUB":try VaultEPUBExcerpt.parse(mixed) != nil])
   } catch { mixedRows.append(["kind":label,"accepted":false,"error":error.localizedDescription]) }
  }
  var supplemental = [[String:Any]]()
  func extra(_ label:String,_ value:Bool) { precondition(value,label); supplemental.append(["name":label,"passed":value]) }
  extra("same GET preserves current and quote SHA",rows.dropFirst().allSatisfy { $0["sourceState"] as? String == "current" && $0["quoteSha256"] as? String == CanvasPacket.sha(Data(source.quote.utf8)) })
  extra("initial preview truncation flag is explicit",rows[0]["cacheTruncated"] is Bool)
  extra("mixed recovery rejected in both source kinds",mixedRows.allSatisfy { $0["accepted"] as? Bool == false })
  let validEPUB = VaultPDFCreateRecovery(sceneID:s.scene.id,relayAddress:ctx.relayAddress,path:source.notePath,draft:note.text,submittedText:nil,sourceKind:.epub)
  let validPDF = VaultPDFCreateRecovery(sceneID:s.scene.id,relayAddress:ctx.relayAddress,path:source.notePath,draft:try pdf.markdown(),submittedText:nil)
  _ = try validEPUB.validated(); _ = try validPDF.validated()
  extra("single EPUB and legacy PDF remain valid",true)
  for (name,draft,current) in [("mixed adopted note",note.text,mixed),("mixed recovery draft",mixed,note.text)] {
   let recovery = VaultPDFCreateRecovery(sceneID:s.scene.id,relayAddress:ctx.relayAddress,path:source.notePath,draft:draft,submittedText:nil,sourceKind:.epub)
   let adopted = VaultNoteSnapshot(path:note.path,text:current,sha256:CanvasPacket.sha(Data(current.utf8)),modifiedAt:"")
   do { try recovery.requireMatchingEPUBNote(adopted); fatalError("mixed adoption accepted") } catch { extra(name,true) }
  }
  let memoText = note.text + "\n사용자 메모 보완\n"
  let memo = VaultNoteSnapshot(path:note.path,text:memoText,sha256:CanvasPacket.sha(Data(memoText.utf8)),modifiedAt:"")
  await s.refreshVaultNotes(load:{ _ in memo })
  let updated = s.scene.nodes.first { $0.id == node }!
  extra("memo edits keep exact quote and update full note SHA",updated.vaultNote?.quoteSha256 == CanvasPacket.sha(Data(source.quote.utf8)) && updated.vaultNote?.sha256 == memo.sha256 && updated.vaultNote?.sourceState == .changed)
  for (label,text,expected) in [("missing source","일반 텍스트",VaultNoteReference.SourceState.missing),("unsupported source",note.text.replacingOccurrences(of:"ccr-epub-source-v1",with:"ccr-epub-source-v99"),.unsupported),("ambiguous source",mixed,.ambiguous)] {
   let before = s.scene.nodes.first { $0.id == node }!
   let changedNote = VaultNoteSnapshot(path:note.path,text:text,sha256:CanvasPacket.sha(Data(text.utf8)),modifiedAt:"")
   await s.refreshVaultNotes(load:{ _ in changedNote })
   let after = s.scene.nodes.first { $0.id == node }!
   extra(label + " preserves last cache and binding",after.text == before.text && after.vaultNote?.sha256 == before.vaultNote?.sha256 && after.vaultNote?.quoteSha256 == before.vaultNote?.quoteSha256 && after.vaultNote?.sourceState == expected && after.vaultNote?.observedSha256 == changedNote.sha256)
  }
  let result:[String:Any] = ["supplemental":supplemental,"sourceCommit":ctx.commit,"sourceTree":ctx.tree,"rows":rows,"mixedRecovery":mixedRows,"creates":creates,"originalArchiveSHA":CanvasPacket.sha(archive),"expectedQuoteSHA":CanvasPacket.sha(Data(source.quote.utf8)),"actualHTTP":false,"GUI":false,"fullNative54Repeated":false]
  let data = try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]); try data.write(to:out.appendingPathComponent("counterexample-result.json")); print(String(decoding:data,as:UTF8.self))
 }
 @MainActor static func composition(snapshot:VaultEPUBSnapshot,out:URL,contextID:UUID) async throws {
  var checks = [String]()
  func check(_ value:Bool,_ name:String) { precondition(value,name); checks.append(name); print("PASS",name) }
  let book = try VaultEPUBBook(snapshot:snapshot)
  let text = book.chapters[1].paragraphs[0].text
  let source = try VaultEPUBExcerpt.capture(book:book,chapter:1,paragraph:0,range:(text as NSString).range(of:"문구 😀"))
  let markdown = try source.markdown()
  let note = VaultNoteSnapshot(path:source.notePath,text:markdown,sha256:CanvasPacket.sha(Data(markdown.utf8)),modifiedAt:"")
  let reference = try source.reference(note:note,relayAddress:"http://192.168.88.88:4242")
  let drawing = PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.black),path:PKStrokePath(controlPoints:[
   PKStrokePoint(location:.init(x:10,y:20),timeOffset:0,size:.init(width:2,height:2),opacity:1,force:0.7,azimuth:0,altitude:1),
   PKStrokePoint(location:.init(x:50,y:40),timeOffset:0.1,size:.init(width:2,height:2),opacity:1,force:0.9,azimuth:0,altitude:1)
  ],creationDate:Date(timeIntervalSince1970:0)))])
  var scene = CanvasScene();scene.schemaVersion = 3;scene.drawingBase64 = drawing.dataRepresentation().base64EncodedString();scene.strokes = CanvasScene.nativeInkStrokes(drawing)
  let first = UUID(), second = UUID()
  scene.nodes = [.init(id:first,kind:.note,frame:.init(x:40,y:80,width:260,height:120),text:VaultPDFCard.preview(markdown),confidence:.confirmed,sourceStrokeIds:[],vaultNote:reference),
   .init(id:second,kind:.note,frame:.init(x:400,y:80,width:260,height:120),text:"사용자 메모",confidence:.confirmed,sourceStrokeIds:[])]
  let grouped = try CanvasGroup.Draft(scene:scene,memberIDs:[first,second]).applying(to:scene)
  let grid = try CanvasPagePaper.applying(.grid,to:grouped.scene)
  check(grid.nodes.first { $0.id == first }?.vaultNote == reference && grid.drawingBase64 == scene.drawingBase64,"EPUB card group and paper retain native ink and exact quote reference")
  let store = CanvasStore();store.enableDocumentChecks();try store.importSourceBytes(CanvasFileWorkspace.bytes(grid));try store.createDocument()
  let png = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=")!
  store.filePreview = { _ in png }
  let folder = out.appendingPathComponent("composition-selected-files",isDirectory:true);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
  await store.connectDocumentWorkspace(folder)
  let files = CanvasDocumentFiles(folder:folder,requiresScope:false), base = try files.load(store.document.id)
  check(store.documentFileReady && base.document == store.document,"composite document actual Store and whole Files readback match")
  var external = base.document, page = try CanvasPagePaper.applying(.plain,to:external.activePage)
  page.nodes[page.nodes.firstIndex { $0.id == second }!].text = "AI가 보완한 같은 원본 메모"
  try external.replacePage(page,expectedRevision:external.revision)
  _ = try files.save(external,previews:base.previews,expected:base.token)
  store.refreshDocumentWorkspace()
  check(try store.documentFileReady && CanvasPagePaper.pattern(in:store.scene) == .plain && store.scene.nodes.first { $0.id == second }?.text == "AI가 보완한 같은 원본 메모","external paper and card edits return through existing full document CAS")
  check(try CanvasGroup.entries(in:store.scene)[0].memberIDs == [first,second] && store.scene.nodes.first { $0.id == first }?.vaultNote == reference && store.scene.drawingBase64 == scene.drawingBase64,"reverse sync preserves ordered membership source identity and native ink")
  try store.document.bytes().write(to:out.appendingPathComponent("composition-expected.json"))
  let child = Process();child.executableURL = URL(fileURLWithPath:CommandLine.arguments[0]);child.arguments = [out.path,CommandLine.arguments[2],"--group-paper-reopen","--ccr-test-runtime",contextID.uuidString.lowercased()]
  try child.run();child.waitUntilExit();check(child.terminationStatus==0,"fresh Store child restores the exact composite canonical document")
  try JSONSerialization.data(withJSONObject:["checks":checks,"count":checks.count,"childProcesses":1,"actualStoreFiles":true,"previewFixture":true,"HTTP":false,"GUI":false],options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("composition-observations.json"))
 }

}
