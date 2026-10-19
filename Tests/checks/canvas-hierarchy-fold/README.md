# Canvas hierarchy folding

`CanvasNode.isCollapsed` is an optional JSON boolean. Missing, null, and false mean expanded.
The scene schema remains version 1. The existing JSON, autosave, import, agent packet, and
Obsidian scene synchronization carry the flag and every hidden object.

`CanvasScene.visibility` derives visible node, link, and attached annotation IDs.
Only `parentChild` relationships hide descendants. Every link kind needs two visible endpoints.
An expanded ancestor respects each descendant's own collapsed flag. Raw PencilKit drawing,
source strokes, source references, node text, relationships, and annotations remain intact.

Malformed legacy hierarchy links are considered in ascending link UUID order, accepting only
edges permitted by the existing hierarchy validator. Cycles, missing endpoints, self edges,
and extra parents stay in JSON but cannot make visibility traversal loop or hide every cycle root.
This projection does not repair or delete stored links. General links never create hierarchy.

The tools menu and inspector offer **하위 요소 접기** and **하위 요소 펼치기**.
Their labels have a minimum 44 point target and Korean accessibility state and hint.
Folding clears pending links. Scene updates clear hidden selections and open hidden proposals.

Run with an external path returned by `storage-route path development-archive --project BT_CCR-ipad-hierarchyfold`:

```sh
python3 Tests/checks/canvas-hierarchy-fold/run.py /absolute/verified/archive/run
```

The runner executes complete production model and store code with isolated application support.
It also runs existing hierarchy and revision suites and typechecks the complete CanvasBridge
source set with the iOS SDK. A Catalyst command line probe attempts actual `SceneRenderer` PNG
comparisons without launching an app or operating a device. Its compile and runtime outcomes
are recorded separately. UIKit PNG assertions are also compiled against the iOS SDK.
The receipt records commands, results, compiler, base, head, and source hashes before and after.
This does not certify installed iPad UI, touch target measurements, live vault synchronization,
independent review, or functional parity with MyScript or MarginNote.
