# CanvasBridge source port

Source project is `/Users/ambrion/Documents/ChatGPT/BT_CCR(아이패드 앱)` at commit `dc42618c933d9b4f093905d04bdfc4f8d9a8d771`.
The initial port copied all nine production Swift files byte for byte. Existing type names, persistence names, and the `com.ambrion.canvasbridge.relay` Keychain service name are preserved.

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

`CanvasBridgeApp.swift` is excluded. Sill retains its app entry point. The initial port commit added source files only and included no relay credential files or Keychain contents.

The Sill integration opens `CanvasWorkspace` as a full-screen Pencil canvas. The Mac's existing 3×3 Control Room remains a video stream; this app does not rebuild it as native cards. The canvas reads the Mac's current 3×3 projection and lets the user select an exact Codex card when voice is off. The new relay send path is coded to steer an active target turn or start an idle selected chat; it does not queue new packets. Legacy queue receipts remain readable.

The separate `com.ambrion.sillcanvas.ipad` bundle was signed, installed, and launched on the physical iPad. The user verified live Pencil ink, the recipient list and selected card title, Mac video, and touch control. The relay token moved from a one-time app document into the app's Keychain and the document was removed. Exact-chat image delivery is still unverified: the running Codex desktop app does not expose the shared control socket the relay requires. The Mac Sill host, Sunshine, and Moonlight remain installed and unchanged.
