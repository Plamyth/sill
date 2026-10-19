# Canvas parent and child contract

`CanvasLink.kind == .parentChild` means `from` is the parent and `to` is the child.
A missing, null, or explicit `general` kind is an ordinary relationship.
Existing `connect(_:to:label:)` calls remain ordinary links.
Call `connectAsChild(parent:child:label:)` to create a semantic child relationship.
It returns `false` without changing any scene field for a missing endpoint, self edge,
duplicate hierarchy relationship, second parent, or hierarchy cycle.

Agent revisions use the same validation over existing and proposed hierarchy links before
appending nodes, annotations, or links. Batch order does not bypass the constraints.
General relationships allow cycles and multiple incoming relationships.
Existing replay and append-only ink reconciliation rules still apply.
Codable retains the existing scene schema and JSON transport. No hierarchy query cache is added.

Run from the worktree with a verified external output directory supplied by `storage-route`:

```sh
python3 Tests/checks/canvas-hierarchy/run.py /absolute/verified/development-archive/output
```

The runner compiles the complete production model and runs the dedicated hierarchy checks
and the existing `ipad-canvas-revisions` checks. It saves compiler output, runtime output,
compiler version, commands, and source SHA-256 hashes before and after the checks.
The local macOS Apple SDK is required. This is model validation only.
It does not launch an app, access a live vault, contact a relay, or operate a device.
UI wiring, iPad acceptance, and independent review belong to the parent task.
