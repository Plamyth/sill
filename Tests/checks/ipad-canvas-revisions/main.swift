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

print("PASS agent revision apply, repeat, conflict, stale, and annotation ID checks")
