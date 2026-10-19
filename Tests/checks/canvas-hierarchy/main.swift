import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
}

func node(_ text: String, confidence: CanvasNode.Confidence = .confirmed) -> CanvasNode {
    CanvasNode(id: UUID(), kind: .note, frame: CanvasRect(x: 10, y: 20, width: 260, height: 120),
               text: text, confidence: confidence, sourceStrokeIds: [])
}

func edge(_ parent: UUID, _ child: UUID, kind: CanvasLink.Kind? = .parentChild) -> CanvasLink {
    CanvasLink(id: UUID(), from: parent, to: child, label: "관계 원문", kind: kind)
}

func bytes<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}

func decoded(_ change: AgentRevision) throws -> AgentRevision {
    try JSONDecoder().decode(AgentRevision.self, from: bytes(change))
}

func refuses(_ change: AgentRevision, in original: CanvasScene, basedOn sent: CanvasScene? = nil,
             _ message: String) throws {
    var scene = original
    let incoming = try decoded(change)
    check(!scene.apply(incoming, basedOn: sent), message)
    check(scene == original, "Rejected revision preserves every scene field: \(message)")
    let originalBytes = try bytes(original)
    let resultBytes = try bytes(scene)
    check(resultBytes == originalBytes, "Rejected revision preserves encoded scene: \(message)")
}

let a = node("원본 부모")
let b = node("원본 자식")
let c = node("세 번째")
let d = node("네 번째")
var base = CanvasScene()
base.nodes = [a, b, c, d]
base.drawingBase64 = Data([0, 1, 2, 253, 254, 255]).base64EncodedString()
let stroke = InkStroke(id: UUID(), points: [InkPoint(x: 3, y: 5, pressure: 0.7)],
                       createdAt: Date(timeIntervalSince1970: 123),
                       visibility: .init(kind: .masked, visibleSegments: [
                        .init(lowerBound: 0.1, upperBound: 0.8,
                              worldPoints: [InkPoint(x: 4, y: 6, pressure: 0.6)])]))
base.strokes = [stroke]
base.nodes[0].sourceStrokeIds = [stroke.id]
base.nodes[0].vaultNote = VaultNoteReference(path: "Notes/근거.md", sha256: "original-note-sha",
    relayAddress: "http://127.0.0.1:9999", blockID: "source-block", sourceState: .changed,
    observedSha256: "observed-note-sha", quoteSha256: "quote-sha")
base.annotations = [CanvasAnnotation(id: UUID(), nodeId: a.id, text: "원문 주석", author: "person")]
base.links = [edge(c.id, a.id, kind: nil), edge(a.id, c.id, kind: .general)]
base.revision = 8

let legacy = CanvasLink(id: UUID(), from: a.id, to: b.id, label: "legacy")
let legacyBytes = try bytes(legacy)
let legacyWire = try JSONSerialization.jsonObject(with: legacyBytes) as! [String: Any]
check(legacyWire["kind"] == nil, "Legacy constructors omit kind on the wire")
let legacyDecoded = try JSONDecoder().decode(CanvasLink.self, from: legacyBytes)
check(legacyDecoded == legacy && legacyDecoded.kind == nil, "Old links decode unchanged")
var legacyScene = base
legacyScene.links = [legacy]
let oldSceneBytes = try bytes(legacyScene)
let oldScene = try JSONDecoder().decode(CanvasScene.self, from: oldSceneBytes)
check(oldScene == legacyScene, "Legacy scene JSON roundtrips without a migration")
var nullWire = legacyWire
nullWire["kind"] = NSNull()
let nullBytes = try JSONSerialization.data(withJSONObject: nullWire)
let nullLink = try JSONDecoder().decode(CanvasLink.self, from: nullBytes)
check(nullLink.kind == nil, "An explicit null kind is also an ordinary link")
var unknownWire = legacyWire
unknownWire["kind"] = "unknown-hierarchy"
let unknownBytes = try JSONSerialization.data(withJSONObject: unknownWire)
do {
    _ = try JSONDecoder().decode(CanvasLink.self, from: unknownBytes)
    preconditionFailure("An unknown kind must not silently become an ordinary relationship")
} catch DecodingError.dataCorrupted { checks += 1 }

var tree = base
check(tree.connectAsChild(parent: a.id, child: b.id, label: "親子"), "A semantic parent can attach its child")
check(tree.links.last?.kind == .parentChild && tree.links.last?.from == a.id &&
      tree.links.last?.to == b.id && tree.links.last?.label == "親子", "Parent direction and label are explicit")
check(tree.revision == base.revision + 1, "A successful hierarchy command advances revision once")
check(tree.connectAsChild(parent: b.id, child: c.id), "A child can have children")
check(tree.connectAsChild(parent: a.id, child: d.id), "A parent can have multiple children")
check(tree.nodes == base.nodes && tree.strokes == base.strokes && tree.drawingBase64 == base.drawingBase64 &&
      tree.annotations == base.annotations && Array(tree.links.prefix(base.links.count)) == base.links,
      "Hierarchy commands retain source nodes, links, note references, annotations, and raw ink")

for (parent, child, name) in [
    (a.id, a.id, "self edge"), (UUID(), b.id, "missing parent"),
    (a.id, UUID(), "missing child"), (a.id, b.id, "duplicate hierarchy edge"),
    (d.id, b.id, "second parent"), (c.id, a.id, "cycle through ancestors")
] {
    var rejected = tree
    check(!rejected.connectAsChild(parent: parent, child: child), "Local command rejects \(name)")
    check(rejected == tree, "Local rejection is atomic for \(name)")
}
var general = tree
check(general.connect(c.id, to: a.id), "General links can close a hierarchy path into a graph cycle")
check(general.connect(a.id, to: b.id), "General links can share hierarchy endpoints")
check(general.connect(a.id, to: b.id), "Ordinary repeated relationships keep their existing behavior")
check(general.links.suffix(3).allSatisfy { $0.kind == nil }, "Existing connect remains an ordinary relationship")
var forest = base
check(forest.connectAsChild(parent: b.id, child: c.id), "A disconnected tree is valid")
check(forest.connectAsChild(parent: a.id, child: b.id), "Attaching an existing subtree is valid")
let treeBytes = try bytes(general)
let restoredTree = try JSONDecoder().decode(CanvasScene.self, from: treeBytes)
check(restoredTree == general, "Mixed hierarchy and ordinary scene JSON roundtrips exactly")
check(restoredTree.schemaVersion == 1, "Hierarchy keeps the existing scene schema version")

let proposal = node("잉크에서 제안한 자식", confidence: .proposal)
var sourcedProposal = proposal
sourcedProposal.sourceStrokeIds = [stroke.id]
let annotation = CanvasAnnotation(id: UUID(), nodeId: proposal.id, text: "검토 필요", author: "agent")
let incoming = [edge(b.id, proposal.id), edge(a.id, b.id), edge(proposal.id, c.id),
                edge(c.id, a.id, kind: .general), edge(b.id, a.id, kind: nil)]
let change = AgentRevision(sceneId: base.id, baseRevision: base.revision,
    annotations: [annotation], proposedNodes: [sourcedProposal], proposedLinks: incoming)
let wireChange = try decoded(change)
check(wireChange.proposedLinks == incoming, "Agent JSON preserves link kinds, IDs, directions, and labels")
var applied = base
check(applied.apply(wireChange), "An unordered hierarchy batch can refer to existing and proposed nodes")
check(applied.nodes == base.nodes + [sourcedProposal] && applied.links == base.links + incoming &&
      applied.annotations == base.annotations + [annotation] && applied.revision == base.revision + 1,
      "Agent hierarchy batch appends the exact objects and advances once")
check(applied.strokes == base.strokes && applied.drawingBase64 == base.drawingBase64,
      "Agent hierarchy batch preserves all raw drawing data")
let appliedSnapshot = applied
check(applied.apply(wireChange) && applied == appliedSnapshot, "Exact hierarchy response replay is a no-op")
var altered = change
altered.proposedLinks?[0].kind = .general
try refuses(altered, in: applied, "Replay cannot change hierarchy semantics")
altered = change
altered.proposedLinks?[0].label = "changed"
try refuses(altered, in: applied, "Replay cannot change a hierarchy label")

var existing = base
check(existing.connectAsChild(parent: a.id, child: b.id), "Seed the existing hierarchy")
let duplicate = edge(c.id, d.id)
let reusedID = CanvasLink(id: existing.links[0].id, from: c.id, to: d.id, label: "", kind: .parentChild)
let invalidBatches: [(String, [CanvasLink])] = [
    ("self edge", [edge(c.id, c.id)]),
    ("missing parent", [edge(UUID(), c.id)]),
    ("missing child", [edge(c.id, UUID())]),
    ("duplicate existing hierarchy with a new link ID", [edge(a.id, b.id)]),
    ("second existing parent", [edge(d.id, b.id)]),
    ("cycle across existing links", [edge(b.id, a.id)]),
    ("disconnected cycle wholly in a batch", [edge(c.id, d.id), edge(d.id, c.id)]),
    ("long cycle across a batch and an existing link", [edge(b.id, c.id), edge(c.id, d.id), edge(d.id, a.id)]),
    ("two incoming parents", [edge(b.id, d.id), edge(c.id, d.id)]),
    ("duplicate incoming endpoints with different IDs", [duplicate, edge(c.id, d.id)]),
    ("duplicate incoming link IDs", [duplicate, duplicate]),
    ("existing ordinary link ID reused for hierarchy", [reusedID])
]
for (name, links) in invalidBatches {
    var invalid = change
    invalid.baseRevision = existing.revision
    invalid.proposedLinks = [edge(a.id, proposal.id)] + links
    try refuses(invalid, in: existing, "Whole mixed revision rejects \(name)")
    invalid.proposedLinks = Array(links.reversed()) + [edge(a.id, proposal.id)]
    try refuses(invalid, in: existing, "Reversing the batch still rejects \(name)")
}
var injection = change
injection.proposedNodes[0].vaultNote = base.nodes[0].vaultNote
try refuses(injection, in: base, "A hierarchy proposal cannot inject a vault reference")
injection = change
injection.proposedNodes[0].sourceStrokeIds = [UUID()]
try refuses(injection, in: base, "A hierarchy proposal must cite known source ink")

var generalBatch = base
let ordinaryLinks = [edge(a.id, b.id, kind: nil), edge(b.id, c.id, kind: .general),
                     edge(c.id, a.id, kind: nil), edge(d.id, b.id, kind: .general)]
let ordinary = AgentRevision(sceneId: base.id, baseRevision: base.revision,
    annotations: [], proposedNodes: [], proposedLinks: ordinaryLinks)
let decodedOrdinary = try decoded(ordinary)
check(generalBatch.apply(decodedOrdinary), "Ordinary agent links permit cycles and multiple incoming relationships")
check(generalBatch.links == base.links + ordinaryLinks, "Ordinary agent links retain their exact source IDs")
var linkOnly = base
let onlyLinks = AgentRevision(sceneId: base.id, baseRevision: base.revision,
    annotations: [], proposedNodes: [], proposedLinks: [edge(a.id, b.id)])
let decodedOnlyLinks = try decoded(onlyLinks)
check(linkOnly.apply(decodedOnlyLinks), "Hierarchy-only revisions do not require proposed nodes")

let laterStroke = InkStroke(id: UUID(), points: [InkPoint(x: 8, y: 9, pressure: 1)],
                            createdAt: Date(timeIntervalSince1970: 456))
var later = base
later.strokes.append(laterStroke)
later.drawingBase64 = Data([7, 8, 9, 0, 255]).base64EncodedString()
later.revision += 1
try refuses(change, in: later, "Stale hierarchy revisions require the sent snapshot")
var merged = later
check(merged.apply(wireChange, basedOn: base), "A hierarchy batch can merge over append-only ink")
check(merged.strokes == later.strokes && merged.drawingBase64 == later.drawingBase64 &&
      merged.nodes == base.nodes + [sourcedProposal] && merged.links == base.links + incoming &&
      merged.revision == later.revision + 1, "Hierarchy merge preserves concurrent ink and exact source records")
let mergedSnapshot = merged
check(merged.apply(wireChange, basedOn: base) && merged == mergedSnapshot, "Merged hierarchy replay remains a no-op")
var invalidStale = change
invalidStale.proposedLinks = [edge(a.id, proposal.id), edge(proposal.id, a.id)]
try refuses(invalidStale, in: later, basedOn: base, "Stale cyclic batch is still atomic")
invalidStale = change
invalidStale.proposedNodes[0].sourceStrokeIds = [laterStroke.id]
try refuses(invalidStale, in: later, basedOn: base, "A stale hierarchy cannot cite ink absent from the sent snapshot")
var concurrent = later
concurrent.links[0].kind = .general
try refuses(change, in: concurrent, basedOn: base, "Concurrent link changes prevent an unseen stale hierarchy merge")

let session = VoiceSession(threadId: UUID(), sessionId: "offline-fixture", observedAt: "2026-10-20T00:00:00Z")
let packet = try CanvasPacket(scene: merged, imagePNG: Data([137, 80, 78, 71, 13, 10, 26, 10]), session: session)
let packetScene = try packet.frozenScene()
check(packetScene == merged, "Existing scene JSON packet transport preserves mixed hierarchy, source links, notes, and ink")
let frozenBytes = Data(base64Encoded: packet.sceneJSONBase64)!
check(CanvasPacket.sha(frozenBytes) == packet.sceneSha256, "Scene packet hash covers the hierarchy JSON")
check(packetScene.nodes[0].vaultNote == base.nodes[0].vaultNote &&
      packetScene.nodes[0].sourceStrokeIds == [stroke.id] && packetScene.strokes == later.strokes,
      "Transport retains note block identity, observed hashes, source stroke IDs, and masked stroke data")

print("PASS canvas hierarchy: \(checks) assertions, legacy JSON, local constraints, agent batch atomicity, replay, source preservation, packet roundtrip")
