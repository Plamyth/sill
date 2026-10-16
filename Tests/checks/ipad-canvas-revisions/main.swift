import Foundation

var scene = CanvasScene()
scene.revision = 3
let annotation = CanvasAnnotation(id:UUID(),nodeId:nil,text:"제안",author:"agent")
let proposal = CanvasNode(id:UUID(),kind:.note,
    frame:CanvasRect(x:10,y:20,width:260,height:120),text:"확인할 내용",
    confidence:.proposal,sourceStrokeIds:[])
let change = AgentRevision(sceneId:scene.id,baseRevision:3,
    annotations:[annotation],proposedNodes:[proposal])

precondition(scene.apply(change))
precondition(scene.revision == 4 && scene.annotations == [annotation] && scene.nodes == [proposal])
let applied = scene
precondition(scene.apply(change))
precondition(scene == applied, "Repeated revision must not append a second copy")

var altered = change
altered.annotations[0].text = "다른 내용"
precondition(!scene.apply(altered), "Conflicting content with the same ID must be refused")
precondition(scene == applied)

var stale = change
stale.annotations = [CanvasAnnotation(id:UUID(),nodeId:nil,text:"늦은 제안",author:"agent")]
stale.proposedNodes = []
precondition(!scene.apply(stale), "Unseen stale content must not overwrite later edits")
precondition(scene == applied)

var duplicate = AgentRevision(sceneId:scene.id,baseRevision:scene.revision,
    annotations:[annotation,annotation],proposedNodes:[])
precondition(!scene.apply(duplicate), "Duplicate annotation IDs must be refused")
duplicate.annotations = [annotation]
precondition(!scene.apply(duplicate), "An existing annotation ID must not be appended")
precondition(scene == applied)

var sent = CanvasScene()
sent.revision = 7
sent.drawingBase64 = "sent ink"
let originalStroke = InkStroke(id:UUID(),points:[InkPoint(x:1,y:2,pressure:0.5)],createdAt:Date(timeIntervalSince1970:1))
let laterStroke = InkStroke(id:UUID(),points:[InkPoint(x:3,y:4,pressure:0.7)],createdAt:Date(timeIntervalSince1970:2))
sent.strokes = [originalStroke]
var later = sent
later.strokes.append(laterStroke)
later.drawingBase64 = "ink with another stroke"
later.revision += 1
let inkProposal = CanvasNode(id:UUID(),kind:.box,
    frame:CanvasRect(x:1,y:2,width:260,height:120),text:"첫 획에 대한 제안",
    confidence:.proposal,sourceStrokeIds:[originalStroke.id])
let inkChange = AgentRevision(sceneId:sent.id,baseRevision:sent.revision,
    annotations:[],proposedNodes:[inkProposal])

precondition(!later.apply(inkChange), "A stale revision needs the sent scene")
precondition(later.apply(inkChange,basedOn:sent), "New ink can coexist with a proposal for sent ink")
precondition(later.strokes == [originalStroke,laterStroke] && later.drawingBase64 == "ink with another stroke")
let merged = later
precondition(later.apply(inkChange,basedOn:sent) && later == merged,
    "Fetching the same proposal again must preserve the new ink")

var changedInk = sent
changedInk.strokes = [InkStroke(id:originalStroke.id,points:[InkPoint(x:9,y:2,pressure:0.5)],
    createdAt:originalStroke.createdAt),laterStroke]
changedInk.revision += 1
precondition(!changedInk.apply(inkChange,basedOn:sent), "Changing sent ink is not append-only")

var changedGraph = sent
_ = changedGraph.addNode(kind:.note,at:CanvasPoint(x:50,y:60))
changedGraph.strokes.append(laterStroke)
precondition(!changedGraph.apply(inkChange,basedOn:sent), "Concurrent node changes need review")

var unknownSource = inkChange
unknownSource.proposedNodes[0].sourceStrokeIds = [UUID()]
var laterUnknown = sent
laterUnknown.strokes.append(laterStroke)
laterUnknown.revision += 1
precondition(!laterUnknown.apply(unknownSource,basedOn:sent), "Proposals must cite sent stroke IDs")

print("PASS agent revision repeat, conflicts, and append-only ink merge")
