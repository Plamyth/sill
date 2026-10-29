import Foundation
import AppKit
import PencilKit

@main struct IndependentEPUBStoreCheck {
 @MainActor static func main() async throws {
  guard case .isolated(let ctx) = CanvasRuntime.launch else { fatalError("isolation required") }
  let out = URL(fileURLWithPath:CommandLine.arguments[1])
  let archive = try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))
  let snapshot = try VaultEPUBSnapshot(path:"book.epub",bytes:archive)
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
}
