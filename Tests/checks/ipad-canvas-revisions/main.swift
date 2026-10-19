import Foundation

func decoded(_ change: AgentRevision) throws -> AgentRevision {
    try JSONDecoder().decode(AgentRevision.self,from:JSONEncoder().encode(change))
}

func refuses(_ change: AgentRevision, in original: CanvasScene, basedOn sent: CanvasScene? = nil,
             _ message: String) throws {
    var scene = original
    let incoming = try decoded(change)
    precondition(!scene.apply(incoming,basedOn:sent),message)
    precondition(scene == original,"Refusal must preserve the entire scene: \(message)")
}

var scene = CanvasScene()
scene.revision = 3
let annotation = CanvasAnnotation(id:UUID(),nodeId:nil,text:"제안",author:"agent")
let proposal = CanvasNode(id:UUID(),kind:.note,
    frame:CanvasRect(x:10,y:20,width:260,height:120),text:"확인할 내용",
    confidence:.proposal,sourceStrokeIds:[])
let change = AgentRevision(sceneId:scene.id,baseRevision:3,
    annotations:[annotation],proposedNodes:[proposal])

let legacyWire = try JSONSerialization.jsonObject(with:JSONEncoder().encode(change)) as! [String:Any]
precondition(legacyWire["proposedLinks"] == nil, "Legacy JSON must omit unset proposedLinks")
let legacyChange = try decoded(change)
precondition(legacyChange.proposedLinks == nil, "Legacy JSON without links must decode")
precondition(scene.apply(legacyChange))
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

var linkedScene = CanvasScene()
let firstNode = CanvasNode(id:UUID(),kind:.note,
    frame:CanvasRect(x:10,y:20,width:100,height:80),text:"근거",
    confidence:.proposal,sourceStrokeIds:[])
let secondNode = CanvasNode(id:UUID(),kind:.box,
    frame:CanvasRect(x:200,y:20,width:100,height:80),text:"정리",
    confidence:.proposal,sourceStrokeIds:[])
let relation = CanvasLink(id:UUID(),from:firstNode.id,to:secondNode.id,label:"참고")
let nodesRevision = AgentRevision(sceneId:linkedScene.id,baseRevision:linkedScene.revision,
    annotations:[],proposedNodes:[firstNode,secondNode])
var wire = try JSONSerialization.jsonObject(with:JSONEncoder().encode(nodesRevision)) as! [String:Any]
wire["proposedLinks"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode([relation]))
let fromRelay = try JSONDecoder().decode(AgentRevision.self,from:JSONSerialization.data(withJSONObject:wire))
precondition(linkedScene.apply(fromRelay), "Valid JSON graph revision should apply")
guard linkedScene.nodes == [firstNode,secondNode], linkedScene.links == [relation] else {
    fputs("FAIL revision JSON graph expected nodes=2 links=1; got nodes=\(linkedScene.nodes.count) links=\(linkedScene.links.count)\n",stderr)
    exit(1)
}
print("PASS revision JSON graph nodes=2 links=1")

precondition(fromRelay.proposedLinks == [relation], "JSON decoding must preserve proposed links")
let linkedBase = linkedScene
precondition(linkedScene.apply(fromRelay) && linkedScene == linkedBase,
    "Identical decoded graph replay must not change the scene or revision")

var conflictingGraph = fromRelay
conflictingGraph.proposedLinks = [CanvasLink(id:relation.id,from:relation.from,to:relation.to,label:"다른 관계")]
try refuses(conflictingGraph,in:linkedBase,"Replayed link labels must match")
conflictingGraph.proposedLinks = [CanvasLink(id:relation.id,from:relation.to,to:relation.from,label:relation.label)]
try refuses(conflictingGraph,in:linkedBase,"Replayed link endpoints must match")
conflictingGraph = fromRelay
conflictingGraph.proposedNodes[0].text = "다른 내용"
try refuses(conflictingGraph,in:linkedBase,"Replayed node content must match even when links match")

let reverseLink = CanvasLink(id:UUID(),from:secondNode.id,to:firstNode.id,label:"돌아가기")
let linksOnly = AgentRevision(sceneId:linkedBase.id,baseRevision:linkedBase.revision,
    annotations:[],proposedNodes:[],proposedLinks:[reverseLink])
let decodedLinksOnly = try decoded(linksOnly)
precondition(linkedScene.apply(decodedLinksOnly), "Link-only JSON revisions must apply")
precondition(linkedScene.nodes == linkedBase.nodes && linkedScene.annotations == linkedBase.annotations &&
    linkedScene.links == [relation,reverseLink] && linkedScene.revision == linkedBase.revision + 1)
let linkedAgain = linkedScene
precondition(linkedScene.apply(decodedLinksOnly) && linkedScene == linkedAgain,
    "Link-only replay must be an exact no-op")
var conflictingLink = linksOnly
conflictingLink.proposedLinks = [CanvasLink(id:reverseLink.id,from:reverseLink.from,to:reverseLink.to,label:"변경")]
try refuses(conflictingLink,in:linkedAgain,"Link-only conflicting replay must be refused")

var thirdNode = proposal
thirdNode.id = UUID()
let bridgeLink = CanvasLink(id:UUID(),from:firstNode.id,to:thirdNode.id,label:"추가")
let linkedAnnotation = CanvasAnnotation(id:UUID(),nodeId:thirdNode.id,text:"확인",author:"agent")
let addition = AgentRevision(sceneId:linkedBase.id,baseRevision:linkedBase.revision,
    annotations:[linkedAnnotation],proposedNodes:[thirdNode],proposedLinks:[bridgeLink])
var mixedScene = linkedBase
let decodedAddition = try decoded(addition)
precondition(mixedScene.apply(decodedAddition),
    "Links and annotations may reference existing and incoming nodes together")
precondition(mixedScene.nodes == linkedBase.nodes + [thirdNode] &&
    mixedScene.links == linkedBase.links + [bridgeLink] && mixedScene.annotations == [linkedAnnotation] &&
    mixedScene.revision == linkedBase.revision + 1)

let invalidLinks: [(String,[CanvasLink])] = [
    ("Duplicate link IDs",[bridgeLink,bridgeLink]),
    ("Self link",[CanvasLink(id:UUID(),from:thirdNode.id,to:thirdNode.id,label:"")]),
    ("Dangling source",[CanvasLink(id:UUID(),from:UUID(),to:thirdNode.id,label:"")]),
    ("Dangling target",[CanvasLink(id:UUID(),from:thirdNode.id,to:UUID(),label:"")]),
    ("Existing link ID",[relation])
]
for (message,links) in invalidLinks {
    var invalid = addition
    invalid.proposedLinks = links
    try refuses(invalid,in:linkedBase,message)
}
var invalidNodes = addition
invalidNodes.proposedNodes = [thirdNode,thirdNode]
try refuses(invalidNodes,in:linkedBase,"Duplicate node IDs must refuse the whole linked revision")
invalidNodes.proposedNodes = [firstNode]
try refuses(invalidNodes,in:linkedBase,"Existing node IDs must refuse the whole linked revision")
var invalidAnnotations = addition
invalidAnnotations.annotations = [linkedAnnotation,linkedAnnotation]
try refuses(invalidAnnotations,in:linkedBase,"Duplicate annotation IDs must refuse the whole linked revision")
invalidAnnotations.annotations = [linkedAnnotation]
invalidAnnotations.annotations[0].nodeId = UUID()
try refuses(invalidAnnotations,in:linkedBase,"Dangling annotations must not append valid nodes or links")

var vaultInjection = addition
vaultInjection.proposedNodes[0].vaultNote = VaultNoteReference(path:"Notes/injected.md",sha256:"untrusted",
    relayAddress:"http://127.0.0.1:9999")
try refuses(vaultInjection,in:linkedBase,"Agent revisions must not inject vault note references")

var graphSent = linkedBase
graphSent.strokes = [originalStroke]
graphSent.drawingBase64 = "sent graph ink"
var graphWithNewInk = graphSent
graphWithNewInk.strokes.append(laterStroke)
graphWithNewInk.drawingBase64 = "new graph ink"
graphWithNewInk.revision += 1
var inkAndLinks = addition
inkAndLinks.proposedNodes[0].sourceStrokeIds = [originalStroke.id]
try refuses(inkAndLinks,in:graphWithNewInk,"Stale linked revisions require the sent scene")
var mergedGraph = graphWithNewInk
let decodedInkAndLinks = try decoded(inkAndLinks)
precondition(mergedGraph.apply(decodedInkAndLinks,basedOn:graphSent),
    "Append-only ink must coexist with new nodes, annotations, and links")
precondition(mergedGraph.strokes == graphWithNewInk.strokes &&
    mergedGraph.drawingBase64 == graphWithNewInk.drawingBase64 &&
    mergedGraph.nodes == graphSent.nodes + inkAndLinks.proposedNodes &&
    mergedGraph.links == graphSent.links + [bridgeLink] &&
    mergedGraph.annotations == [linkedAnnotation] && mergedGraph.revision == graphWithNewInk.revision + 1)
let mergedGraphSnapshot = mergedGraph
precondition(mergedGraph.apply(decodedInkAndLinks,basedOn:graphSent) && mergedGraph == mergedGraphSnapshot,
    "Identical linked replay must preserve concurrent ink")
var staleLinkOnly = graphWithNewInk
precondition(staleLinkOnly.apply(decodedLinksOnly,basedOn:graphSent),
    "Stale link-only revisions may merge over append-only ink")
precondition(staleLinkOnly.nodes == graphSent.nodes && staleLinkOnly.links == graphSent.links + [reverseLink] &&
    staleLinkOnly.strokes == graphWithNewInk.strokes &&
    staleLinkOnly.drawingBase64 == graphWithNewInk.drawingBase64 &&
    staleLinkOnly.revision == graphWithNewInk.revision + 1)

var concurrentNode = graphWithNewInk
concurrentNode.nodes[0].text = "동시 편집"
try refuses(inkAndLinks,in:concurrentNode,basedOn:graphSent,"Stale links must refuse concurrent node changes")
var concurrentLink = graphWithNewInk
concurrentLink.links[0].label = "동시 관계 편집"
try refuses(inkAndLinks,in:concurrentLink,basedOn:graphSent,"Stale links must refuse concurrent link changes")
var concurrentLinkAddition = graphWithNewInk
concurrentLinkAddition.links.append(reverseLink)
try refuses(inkAndLinks,in:concurrentLinkAddition,basedOn:graphSent,"Stale revisions must refuse new local links")

print("PASS revision JSON legacy, link-only, replay, atomic graph refusal, ink merge, and vault note guard")
