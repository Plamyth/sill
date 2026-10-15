# CanvasBridge source port

Source project is `/Users/ambrion/Documents/ChatGPT/BT_CCR(아이패드 앱)` at commit `dc42618c933d9b4f093905d04bdfc4f8d9a8d771`.
All nine production Swift files below are copied byte for byte. Existing type names, persistence names, and the `com.ambrion.canvasbridge.relay` Keychain service name are preserved.

The integration owner needs all nine files in the iOS app target:

- `CanvasModel.swift` defines scene, packet, receipt, voice, and outbox data.
- `CanvasRelay.swift` provides relay requests and connection storage access.
- `CanvasStore.swift` manages canvas state, persistence, and packet submission state.
- `CanvasWorkspace.swift` provides the workspace view and send flow.
- `ControlRoomProjection.swift` defines projection data, navigation, and layout.
- `ControlRoomViews.swift` provides native Control Room and voice views.
- `PencilCanvas.swift` provides the PencilKit view and gestures.
- `SceneFile.swift` provides scene document import and export.
- `SceneRenderer.swift` renders scene images.

`CanvasBridgeApp.swift` is excluded. Sill retains its app entry point. The parent integration owns UI wiring, project references, and platform configuration. This commit adds source files only. It includes no relay credential files or Keychain contents.

`CanvasWorkspace` currently includes the native 3×3 Control Room and only sends with an active voice session. The integration owner must address both behaviors before acceptance. This port preserves them.

Verification compares each copied file with the pinned source Git blob and worktree using SHA-256 and byte equality. No build, installation, pairing, push, or browser launch was performed.
