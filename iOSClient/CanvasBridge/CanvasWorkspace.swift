import PencilKit
import SwiftUI

private struct CanvasVaultCheckpoint: Codable {
    let sceneID: UUID
    let address: String
    let sceneSha: String?
    let noteSha: String?
    let pendingSceneSha: String?
}

struct CanvasWorkspace: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = CanvasStore()
    @StateObject private var dictation = CanvasDictation()
    @State private var relayAddress = "http://192.168.45.4:8791"
    @State private var relayToken = ""
    @State private var connectionOpen = false
    @State private var exportOpen = false
    @State private var importOpen = false
    @State private var inspectorOpen = false
    @State private var dictationOpen = false
    @State private var vaultOpen = false
    @State private var vaultDirectory = ""
    @State private var vaultEntries: [CanvasRelay.VaultEntry] = []
    @State private var vaultStatus = ""
    @State private var vaultDiscardOpen = false
    @State private var syncedSceneSha: String?
    @State private var canvasNoteSha: String?
    @State private var pendingSceneSha: String?
    @State private var canvasVaultBlocked = false
    @State private var canvasSyncBusy = false
    @State private var canvasVaultEnabled = true
    @State private var vaultSceneID: UUID?
    @State private var vaultSyncAddress: String?
    @State private var readProjection: ControlRoomProjection?
    @State private var projectionMessage: String?
    @State private var expandedCard: ControlRoomCardReference?
    @State private var pipPlacement = VoicePIPPlacement()
    @State private var pipDragOrigin: CGPoint?

    init() {
        if let connection = CanvasRelay.loadConnection() {
            _relayAddress = State(initialValue:connection.address)
            _relayToken = State(initialValue:connection.token)
            let data = try? Data(contentsOf:Self.canvasVaultCheckpointURL())
            if let data = data ?? UserDefaults.standard.data(forKey:"canvasVaultCheckpoint"),
               let checkpoint = try? JSONDecoder().decode(CanvasVaultCheckpoint.self,from:data),
               checkpoint.address == connection.address {
                _vaultSceneID = State(initialValue:checkpoint.sceneID)
                _vaultSyncAddress = State(initialValue:checkpoint.address)
                _syncedSceneSha = State(initialValue:checkpoint.sceneSha)
                _canvasNoteSha = State(initialValue:checkpoint.noteSha)
                _pendingSceneSha = State(initialValue:checkpoint.pendingSceneSha)
            }
        }
    }

    private var relay: CanvasRelay { CanvasRelay(address:relayAddress,token:relayToken) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar.zIndex(1)
            GeometryReader { geometry in
                ZStack(alignment:.topLeading) {
                    canvas
                    if geometry.size.width >= 100 && geometry.size.height >= 100 {
                        voicePIP(in:geometry.size)
                    }
                }
                .coordinateSpace(name:"voicePIPContainer")
                .clipped()
                .onChange(of:geometry.size) { _,_ in pipDragOrigin = nil }
            }
            Text(store.status)
                .font(.footnote).frame(maxWidth:.infinity,alignment:.leading)
                .padding(10).background(Color(uiColor:.secondarySystemBackground))
            if let receipt = store.packet, receipt.state == .rejected {
                Text("최근 전송 거부 · \(receipt.reason ?? "현재 대화에 전달되지 않았습니다.")")
                    .font(.footnote).foregroundStyle(.red)
                    .frame(maxWidth:.infinity,alignment:.leading)
                    .padding(.horizontal,10).padding(.bottom,10)
                    .accessibilityIdentifier("canvasSendRejected")
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onDisappear { dictation.cancel(); store.saveNow() }
        .onChange(of:scenePhase) { _,phase in
            if phase != .active {
                store.saveNow()
                dictation.cancel()
            }
            else { Task { await checkConnection() } }
        }
        .onChange(of:relayAddress) { _,_ in store.setNoteConnection(address:relayAddress,token:relayToken) }
        .onChange(of:relayToken) { _,_ in store.setNoteConnection(address:relayAddress,token:relayToken) }
        .task {
            store.setNoteConnection(address:relayAddress,token:relayToken)
            await checkConnection()
        }
        .task(id:"\(store.scene.id.uuidString):\(relayAddress):\(relayToken):\(canvasVaultEnabled)") {
            guard !relayToken.isEmpty else { return }
            do { try await Task.sleep(for:.milliseconds(700)) } catch { return }
            while !Task.isCancelled {
                if canvasVaultEnabled && (!store.scene.strokes.isEmpty || !store.scene.nodes.isEmpty ||
                    !store.scene.links.isEmpty) {
                    await refreshCanvasFromVault()
                    await synchronizeCanvasToVault()
                }
                let connection = relay
                await store.refreshVaultNotes(load:connection.vaultNote)
                do { try await Task.sleep(for:.seconds(2)) } catch { return }
            }
        }
        .task(id:ProjectionConnection(address:relayAddress,token:relayToken,active:scenePhase == .active)) {
            readProjection = nil
            guard scenePhase == .active, !relayToken.isEmpty else {
                projectionMessage = "Mac 연결 필요"
                return
            }
            let connection = relay
            while !Task.isCancelled {
                do {
                    let next = try await connection.controlRoomProjection()
                    guard !Task.isCancelled else { return }
                    guard next.isFresh() else { throw CanvasSendError.unavailable }
                    readProjection = next
                    projectionMessage = nil
                    store.displayedVoice = next.observedSession()
                } catch {
                    guard !Task.isCancelled else { return }
                    readProjection = nil
                    projectionMessage = "읽기 projection 확인 실패 · 연결에서 주소와 상태를 확인하세요."
                }
                do { try await Task.sleep(for:.seconds(10)) }
                catch { return }
            }
        }
        .sheet(isPresented:$connectionOpen) { connectionSheet }
        .sheet(isPresented:$inspectorOpen) {
            NavigationStack {
                ScrollView { inspector }
                    .navigationTitle("구조 데이터")
                    .toolbar { ToolbarItem(placement:.confirmationAction) {
                        Button("닫기") { inspectorOpen = false }
                    }}
            }
        }
        .sheet(isPresented:$dictationOpen,onDismiss:{ dictation.cancel() }) {
            dictationSheet
        }
        .sheet(isPresented:$vaultOpen) { vaultSheet }
        .sheet(item:$expandedCard) { reference in
            ControlRoomCardDetail(reference:reference,projection:readProjection,message:projectionMessage)
        }
        .sheet(item:Binding(get: { store.proposedNode.map(IdentifiedUUID.init) },
                            set: { store.proposedNode = $0?.id })) { _ in proposalSheet }
        .fileExporter(isPresented:$exportOpen,
                      document:SceneFile(scene:store.scene),contentType:.json,
                      defaultFilename:"canvas-\(store.scene.id.uuidString)") { result in
            if case .failure(let error) = result { store.status = error.localizedDescription }
        }
        .fileImporter(isPresented:$importOpen,allowedContentTypes:[.json]) { result in
            do {
                let url = try result.get()
                guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
                defer { url.stopAccessingSecurityScopedResource() }
                let imported = try JSONDecoder().decode(CanvasScene.self,from:Data(contentsOf:url))
                try store.importScene(imported)
            } catch { store.status = "가져오기 실패: \(error.localizedDescription)" }
        }
        .task(id:store.packet?.packetId) {
            guard let packet = store.packet else { return }
            for _ in 0..<90 {
                if Task.isCancelled { return }
                if let change = try? await relay.revision(for:packet.packetId) {
                    store.applyAgentRevision(change)
                    return
                }
                try? await Task.sleep(for:.seconds(2))
            }
        }
    }

    private var toolbar: some View {
        ViewThatFits(in:.horizontal) {
            HStack(spacing:8) {
                ForEach(CanvasMode.allCases,id:\.self) { mode in
                    Button(mode.rawValue) { store.mode = mode }
                        .buttonStyle(.borderedProminent)
                        .tint(store.mode == mode ? .blue : .gray)
                }
                CanvasInkHistoryButtons(history: store.inkHistory)
                toolsMenu
                inboxLabel
                sendButton
            }.fixedSize(horizontal:true,vertical:false)
            HStack(spacing:8) {
                toolsMenu
                CanvasInkHistoryButtons(history: store.inkHistory).labelStyle(.iconOnly)
                inboxLabel
                Spacer(minLength:0)
                sendButton.labelStyle(.iconOnly)
            }
        }
        .padding(10)
        .background(Color(uiColor:.secondarySystemBackground))
    }

    private var toolsMenu: some View {
        Menu("도구",systemImage:"slider.horizontal.3") {
            Picker("그리기 도구",selection:$store.mode) {
                ForEach(CanvasMode.allCases,id:\.self) { Text($0.rawValue).tag($0) }
            }
            Picker("지우기 방식", selection: $store.eraserStyle) {
                ForEach(CanvasEraserStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Button("상자") { store.addNode(.box) }
            Button("메모") { store.addNode(.note) }
            Button("글자 인식") { Task { await store.proposeHandwriting() } }
            Button("음성 설명",systemImage:"mic") { dictationOpen = true }
            Button("화살표") { store.beginLink() }.disabled(store.selectedNode == nil)
            Button("구조 데이터",systemImage:"sidebar.right") { inspectorOpen = true }
            Button("Obsidian 노트",systemImage:"doc.text") {
                vaultOpen = true
                Task { await loadVaultEntries() }
            }
            Button("연결",systemImage:"network") { connectionOpen = true }
            Button("가져오기") { importOpen = true }
            Button("내보내기") { exportOpen = true }
        }
    }

    private var sendButton: some View {
        Button("그림 수신함으로 보내기",systemImage:"paperplane.fill") {
            Task { await send() }
        }.buttonStyle(.borderedProminent).disabled(store.sendBusy)
    }

    private var inboxLabel: some View {
        Label("고정 그림 수신함",systemImage:"tray.full")
            .font(.subheadline)
            .accessibilityIdentifier("canvasInboxLabel")
    }

    private var vaultSheet: some View {
        NavigationStack {
            VStack(spacing:0) {
                if let note = store.vaultNote {
                    Text(note.path).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal)
                    VaultMarkdownEditor(text:$store.vaultDraft,selection:$store.vaultSelection)
                        .frame(minHeight:150)
                        .disabled(store.vaultLoading)
                        .accessibilityIdentifier("obsidianMarkdownEditor")
                    VStack(alignment:.leading,spacing:6) {
                        if let id = store.vaultLinkedBlockID {
                            Text("연결 블록 ^\(id)").font(.caption).textSelection(.enabled)
                        }
                        Text(store.vaultExcerptMessage).font(.footnote)
                        Button { Task { await excerptVaultBlock() } } label: {
                            Text("선택 문단 발췌").frame(maxWidth:.infinity,minHeight:44)
                        }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.vaultSelectedBlock == nil)
                            .accessibilityHint("선택한 일반 문단을 고유한 원본 표식으로 연결합니다.")
                        Button {
                            if store.attachOpenedVaultNote() != nil, store.closeVaultEditor() { vaultOpen = false }
                        } label: {
                            Text("전체 노트 연결").frame(maxWidth:.infinity,minHeight:44)
                        }.disabled(!store.vaultCanAttach)
                        if store.vaultBlocked && !store.vaultDirty {
                            Button { Task { await openVaultNote(note.path) } } label: {
                                Text("원본 다시 읽기").frame(maxWidth:.infinity,minHeight:44)
                            }
                        }
                        if store.vaultDirty {
                            Button(role:.destructive) { vaultDiscardOpen = true } label: {
                                Text("입력 버리고 닫기").frame(maxWidth:.infinity,minHeight:44)
                            }.disabled(store.vaultSaving)
                        }
                    }.padding(.horizontal)
                } else if store.vaultLoading {
                    ProgressView("원본 노트를 읽는 중입니다.")
                } else {
                    List(vaultEntries) { entry in
                        Button {
                            if entry.kind == "directory" {
                                vaultDirectory = entry.path
                                Task { await loadVaultEntries() }
                            } else { Task { await openVaultNote(entry.path) } }
                        } label: {
                            Label(entry.name,systemImage:entry.kind == "directory" ? "folder" : "doc.text")
                        }
                    }
                }
                Text(store.vaultStatus.isEmpty ? vaultStatus : store.vaultStatus)
                    .font(.footnote).frame(maxWidth:.infinity,alignment:.leading).padding(10)
            }
            .navigationTitle(store.vaultNote == nil ? "Obsidian 노트" : "노트 편집")
            .toolbar {
                ToolbarItem(placement:.topBarLeading) {
                    if store.vaultNote != nil {
                        Button("목록") { _ = store.closeVaultEditor() }.frame(minWidth:44,minHeight:44)
                    } else if !vaultDirectory.isEmpty {
                        Button("상위 폴더") {
                            vaultDirectory = vaultDirectory.split(separator:"/").dropLast().joined(separator:"/")
                            Task { await loadVaultEntries() }
                        }
                    }
                }
                ToolbarItemGroup(placement:.topBarTrailing) {
                    if store.vaultNote != nil {
                        Button("저장") { Task { await saveVaultNote() } }
                            .frame(minWidth:44,minHeight:44).disabled(!store.vaultCanSave)
                    } else {
                        Button("새로고침",systemImage:"arrow.clockwise") { Task { await loadVaultEntries() } }
                            .disabled(store.vaultLoading)
                    }
                }
                ToolbarItem(placement:.confirmationAction) {
                    Button("닫기") {
                        if store.closeVaultEditor() { vaultOpen = false }
                    }.frame(minWidth:44,minHeight:44)
                }
            }
            .interactiveDismissDisabled(store.vaultDirty || store.vaultSaving)
            .alert("저장하지 않은 입력을 버릴까요?",isPresented:$vaultDiscardOpen) {
                Button("입력 버리고 닫기",role:.destructive) {
                    if store.closeVaultEditor(discard:true) { vaultOpen = false }
                }
                Button("계속 편집",role:.cancel) {}
            } message: {
                Text("현재 입력만 버립니다. Obsidian 원본은 변경하지 않습니다.")
            }
        }
    }

    private func loadVaultEntries() async {
        let directory = vaultDirectory, address = relayAddress, token = relayToken
        do {
            let entries = try await relay.vaultEntries(in:directory)
            guard !Task.isCancelled, vaultDirectory == directory,
                  relayAddress == address, relayToken == token else { return }
            vaultEntries = entries
            vaultStatus = "Mac Obsidian 보관함 · \(entries.count)개 항목"
        } catch { vaultStatus = "노트 목록을 읽지 못했습니다: \(error.localizedDescription)" }
    }

    private func openVaultNote(_ path: String, nodeID: UUID? = nil) async {
        store.setNoteConnection(address:relayAddress,token:relayToken)
        let connection = relay
        await store.openVaultNote(path,nodeID:nodeID,load:connection.vaultNote)
    }

    private func saveVaultNote() async {
        store.setNoteConnection(address:relayAddress,token:relayToken)
        let connection = relay
        await store.saveVaultNote { path, sha, text in
            try await connection.saveVaultNote(at:path,baseSha256:sha,text:text)
        }
    }

    private func excerptVaultBlock() async {
        store.setNoteConnection(address:relayAddress,token:relayToken)
        let connection = relay
        let id = await store.excerptSelectedVaultBlock(save: { path,sha,text in
            try await connection.saveVaultNote(at:path,baseSha256:sha,text:text)
        },load:connection.vaultNote)
        if id != nil && !store.vaultDirty && store.closeVaultEditor() { vaultOpen = false }
    }

    private func sceneBytes() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(store.scene)
    }

    private static func canvasVaultCheckpointURL() throws -> URL {
        guard let directory = FileManager.default.urls(for:.applicationSupportDirectory,
                                                       in:.userDomainMask).first else {
            throw CanvasSendError.outboxUnavailable
        }
        return directory.appendingPathComponent("CanvasVaultCheckpoint.json")
    }

    private func saveCanvasVaultCheckpoint() throws {
        guard (syncedSceneSha != nil && canvasNoteSha != nil) || pendingSceneSha != nil else {
            throw CanvasSendError.outboxUnavailable
        }
        let data = try JSONEncoder().encode(CanvasVaultCheckpoint(
            sceneID:store.scene.id,address:relayAddress,sceneSha:syncedSceneSha,
            noteSha:canvasNoteSha,pendingSceneSha:pendingSceneSha))
        try CanvasLocalFile.write(data,to:Self.canvasVaultCheckpointURL())
    }

    private func remoteCanvasIsPrefix(_ remote: CanvasRelay.VaultCanvas,
                                      of local: CanvasScene, drawing: PKDrawing) -> Bool {
        guard let bytes = Data(base64Encoded:remote.sceneJSONBase64),
              let prior = try? JSONDecoder().decode(CanvasScene.self,from:bytes),
              let priorDrawingData = Data(base64Encoded:prior.drawingBase64),
              let priorDrawing = try? PKDrawing(data:priorDrawingData),
              prior.id == local.id, prior.schemaVersion == local.schemaVersion,
              prior.width == local.width, prior.height == local.height,
              prior.revision < local.revision,
              prior.strokes.count < local.strokes.count,
              priorDrawing.strokes.count == prior.strokes.count,
              drawing.strokes.count == local.strokes.count,
              Array(local.strokes.prefix(prior.strokes.count)) == prior.strokes,
              prior.nodes == local.nodes, prior.links == local.links,
              prior.annotations == local.annotations,
              drawing.strokes.count >= priorDrawing.strokes.count else { return false }
        return zip(drawing.strokes,priorDrawing.strokes).allSatisfy { current, saved in
            guard current.id == saved.id, current.randomSeed == saved.randomSeed,
                  current.renderGroupID == saved.renderGroupID,
                  current.renderState == nil, saved.renderState == nil,
                  current.ink.inkType == saved.ink.inkType,
                  current.ink.color.isEqual(saved.ink.color),
                  current.transform == saved.transform,
                  current.mask == nil, saved.mask == nil,
                  current.path.creationDate == saved.path.creationDate,
                  current.path.count == saved.path.count else { return false }
            return zip(current.path,saved.path).allSatisfy { a,b in
                a.location == b.location && a.timeOffset == b.timeOffset &&
                a.size == b.size && a.opacity == b.opacity &&
                a.force == b.force && a.azimuth == b.azimuth &&
                a.altitude == b.altitude && a.secondaryScale == b.secondaryScale &&
                a.threshold == b.threshold && a.lateralJitter == b.lateralJitter
            }
        }
    }

    private func synchronizeCanvasToVault() async {
        guard !canvasSyncBusy, !Task.isCancelled else { return }
        if vaultSceneID != store.scene.id || vaultSyncAddress != relayAddress {
            vaultSceneID = store.scene.id
            vaultSyncAddress = relayAddress
            syncedSceneSha = nil
            canvasNoteSha = nil
            pendingSceneSha = nil
            canvasVaultBlocked = false
        }
        guard !canvasVaultBlocked else { return }
        canvasSyncBusy = true
        defer { canvasSyncBusy = false }
        let scene = store.scene
        let connection = relay
        let address = relayAddress
        let token = relayToken
        func current() -> Bool {
            !Task.isCancelled && canvasVaultEnabled && !canvasVaultBlocked &&
                store.scene.id == scene.id && relayAddress == address && relayToken == token &&
                vaultSceneID == scene.id && vaultSyncAddress == address
        }
        do {
            let drawing = store.drawing
            let localSha = CanvasPacket.sha(try sceneBytes())
            let remote = try await connection.vaultCanvas(id:scene.id)
            guard current() else { return }
            if let remote {
                if syncedSceneSha == nil {
                    guard remote.sceneSha256 == localSha ||
                          remote.sceneSha256 == pendingSceneSha else {
                        canvasVaultBlocked = true
                        store.status = "Obsidian 그림과 iPad 원본이 다릅니다. 자동 덮어쓰기를 중단했습니다."
                        return
                    }
                    syncedSceneSha = remote.sceneSha256
                    canvasNoteSha = remote.noteSha256
                    pendingSceneSha = nil
                    try saveCanvasVaultCheckpoint()
                }
                if remote.noteSha256 != canvasNoteSha || remote.sceneSha256 != syncedSceneSha {
                    guard remote.sceneSha256 == localSha ||
                          remote.sceneSha256 == pendingSceneSha ||
                          remoteCanvasIsPrefix(remote,of:scene,drawing:drawing) else {
                        canvasVaultBlocked = true
                        store.status = "Obsidian 그림이 다른 곳에서 수정됐습니다. iPad 원본을 보존했습니다."
                        return
                    }
                    syncedSceneSha = remote.sceneSha256
                    canvasNoteSha = remote.noteSha256
                    pendingSceneSha = nil
                    try saveCanvasVaultCheckpoint()
                }
            } else if canvasNoteSha != nil {
                canvasVaultBlocked = true
                store.status = "Obsidian 그림 파일이 없어졌습니다. 자동 재생성을 중단했습니다."
                return
            }
            guard localSha != syncedSceneSha else { return }
            let baseSha = canvasNoteSha
            guard let image = await SceneRenderer.png(scene:scene), current(),
                  canvasNoteSha == baseSha else { return }
            pendingSceneSha = localSha
            try saveCanvasVaultCheckpoint()
            let saved = try await connection.saveVaultCanvas(scene:scene,imagePNG:image,
                                                             baseSha256:baseSha)
            guard current(), canvasNoteSha == baseSha else { return }
            syncedSceneSha = saved.sceneSha256
            canvasNoteSha = saved.noteSha256
            pendingSceneSha = nil
            try saveCanvasVaultCheckpoint()
            store.status = "Pencil 그림과 구조 데이터가 Obsidian에 저장됐습니다."
        } catch {
            guard current() else { return }
            store.status = "Obsidian 그림 동기화 대기: \(error.localizedDescription)"
        }
    }

    private func refreshCanvasFromVault() async {
        guard !canvasVaultBlocked, !canvasSyncBusy, let syncedSceneSha, let canvasNoteSha,
              vaultSceneID == store.scene.id, vaultSyncAddress == relayAddress else { return }
        do {
            guard let remote = try await relay.vaultCanvas(id:store.scene.id),
                  remote.noteSha256 != canvasNoteSha else { return }
            let localSha = CanvasPacket.sha(try sceneBytes())
            if remote.sceneSha256 == localSha || remote.sceneSha256 == pendingSceneSha {
                self.syncedSceneSha = remote.sceneSha256
                self.canvasNoteSha = remote.noteSha256
                pendingSceneSha = nil
                try saveCanvasVaultCheckpoint()
                return
            }
            if localSha != syncedSceneSha,
               remoteCanvasIsPrefix(remote,of:store.scene,drawing:store.drawing) {
                self.syncedSceneSha = remote.sceneSha256
                self.canvasNoteSha = remote.noteSha256
                try saveCanvasVaultCheckpoint()
                return
            }
            guard localSha == syncedSceneSha, remote.sceneSha256 != syncedSceneSha,
                  let bytes = Data(base64Encoded:remote.sceneJSONBase64) else {
                canvasVaultBlocked = true
                store.status = "Obsidian에서 그림이 바뀌었습니다. iPad 원본을 보존했습니다."
                return
            }
            let imported = try JSONDecoder().decode(CanvasScene.self,from:bytes)
            try store.importScene(imported)
            store.saveNow()
            self.syncedSceneSha = remote.sceneSha256
            self.canvasNoteSha = remote.noteSha256
            pendingSceneSha = nil
            try saveCanvasVaultCheckpoint()
            store.status = "Obsidian 그림의 최신 내용을 iPad에 반영했습니다."
        } catch {
            store.status = "Obsidian 그림 변경 확인 대기: \(error.localizedDescription)"
        }
    }

    private func voicePIP(in size: CGSize) -> some View {
        let origin = pipPlacement.origin(in:size)
        let cardSize = VoicePIPPlacement.cardSize(in:size)
        let drag = DragGesture(minimumDistance:8,coordinateSpace:.named("voicePIPContainer"))
            .onChanged { value in
                if pipDragOrigin == nil { pipDragOrigin = origin }
                pipPlacement.move(from:pipDragOrigin ?? origin,by:value.translation,in:size)
            }
            .onEnded { _ in pipDragOrigin = nil }
        return CurrentVoicePIP(projection:readProjection,message:projectionMessage,
                               expand:{
                                   if let card = readProjection?.availableVoiceCard {
                                       expandedCard = .voice(threadId:card.id)
                                   }
                               },drag:AnyGesture(drag))
            .frame(width:cardSize.width,height:cardSize.height)
            .contentShape(RoundedRectangle(cornerRadius:16))
            .offset(x:origin.x,y:origin.y)
    }

    private var canvas: some View {
        GeometryReader { _ in
            ZStack(alignment:.topLeading) {
                Color(uiColor:CanvasPalette.background)
                PencilCanvas(store:store)
                if store.scene.drawingBase64.isEmpty {
                    ForEach(store.scene.strokes) { stroke in strokeView(stroke) }
                }
                ForEach(store.scene.links) { link in linkView(link) }
                ForEach(store.scene.nodes) { node in nodeView(node) }
                ForEach(store.scene.annotations) { note in annotationView(note) }
            }
            .frame(width:store.scene.width,height:store.scene.height)
            .scaleEffect(store.zoom,anchor:.topLeading)
            .offset(store.pan)
        }
        .clipped()
        .contentShape(Rectangle())
        .background(Color(uiColor:.secondarySystemBackground))
    }

    private func strokeView(_ stroke: InkStroke) -> some View {
        Path { path in
            for points in stroke.visiblePointSegments {
                guard let first = points.first else { continue }
                path.move(to:CGPoint(x:first.x,y:first.y))
                for point in points.dropFirst() {
                    path.addLine(to:CGPoint(x:point.x,y:point.y))
                }
            }
        }
        .stroke(Color(uiColor:CanvasPalette.ink),
                style:StrokeStyle(lineWidth:4,lineCap:.round,lineJoin:.round))
        .allowsHitTesting(false)
    }

    private func linkView(_ link: CanvasLink) -> some View {
        Path { path in
            guard let from = store.scene.nodes.first(where:{$0.id == link.from})?.frame.center,
                  let to = store.scene.nodes.first(where:{$0.id == link.to})?.frame.center else { return }
            path.move(to:CGPoint(x:from.x,y:from.y))
            path.addLine(to:CGPoint(x:to.x,y:to.y))
            let angle = atan2(to.y-from.y,to.x-from.x)
            for sign in [-1.0,1.0] {
                path.move(to:CGPoint(x:to.x,y:to.y))
                path.addLine(to:CGPoint(x:to.x-20*cos(angle+sign*0.45),
                                        y:to.y-20*sin(angle+sign*0.45)))
            }
        }
        .stroke(Color(uiColor:CanvasPalette.link),
                style:StrokeStyle(lineWidth:3,lineCap:.round))
        .allowsHitTesting(false)
    }

    private func nodeView(_ node: CanvasNode) -> some View {
        NodeTile(node:node,store:store)
            .position(x:node.frame.center.x,y:node.frame.center.y)
            .allowsHitTesting(store.mode == .select)
    }

    private func annotationView(_ note: CanvasAnnotation) -> some View {
        Group {
            if let node = store.scene.nodes.first(where:{$0.id == note.nodeId}) {
                Text(note.text).font(.callout).foregroundStyle(.black).padding(8)
                    .background(.yellow.opacity(0.9),in:RoundedRectangle(cornerRadius:8))
                    .position(x:node.frame.x+150,y:node.frame.y+node.frame.height+42)
            }
        }.allowsHitTesting(false)
    }

    private var inspector: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("구조 데이터").font(.headline)
            Text("획 \(store.scene.strokes.count) · 요소 \(store.scene.nodes.count) · 연결 \(store.scene.links.count)")
            Text("장면 \(store.scene.id.uuidString.prefix(8)) · 수정 \(store.scene.revision)")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if let id = store.selectedNode,
               let node = store.scene.nodes.first(where:{$0.id == id}) {
                Text(node.kind == .box ? "선택한 상자" : "선택한 메모")
                Text(node.confidence == .proposal ? "확인 전 제안" : "확정된 요소")
                    .foregroundStyle(node.confidence == .proposal ? .orange : .green)
                TextField("내용",text:Binding(get:{node.text},set:{ _ in }))
                    .disabled(true)
                Text("출처 획 \(node.sourceStrokeIds.count)개")
                if let reference = node.vaultNote {
                    Text(reference.cacheTruncated == true ? "원본 일부 미리보기 · \(reference.path)" :
                        "저장된 원본의 표시 캐시 · \(reference.path)").font(.caption)
                    if let id = reference.blockID { Text("블록 ^\(id)").font(.caption).textSelection(.enabled) }
                    Text(reference.sourceStateLabel).font(.caption)
                    Button("원본 노트 편집") {
                        inspectorOpen = false
                        Task {
                            await openVaultNote(reference.path,nodeID:id)
                            vaultOpen = true
                        }
                    }.frame(minHeight:44)
                } else {
                    Button("내용 수정") {
                        store.proposedNode = id
                        store.proposalText = node.text
                    }
                }
            } else {
                Text("요소를 탭하면 텍스트와 출처를 볼 수 있습니다.").foregroundStyle(.secondary)
            }
            Divider()
            Text("에이전트 주석 \(store.scene.annotations.count)개")
            ForEach(store.scene.annotations) { note in
                Text("\(note.author): \(note.text)").font(.caption)
            }
            if let voice = store.displayedVoice {
                Text("현재 음성 대화 \(voice.threadId.uuidString)").font(.caption)
                Text("세션 \(voice.sessionId)").font(.caption)
            } else {
                Text("열린 음성 세션 미확인").font(.caption)
            }
            if let pending = store.outbox.unresolved {
                Text("미확인 패킷 \(pending.id.uuidString.prefix(8))").font(.caption)
                Button("접수 영수증 확인") { Task { await reconcile(pending) } }
                    .disabled(store.sendBusy)
            }
            if let packet = store.packet {
                Text("전송 \(packet.packetId.uuidString.prefix(8))")
                    .font(.caption)
                Text(packet.state.rawValue).font(.caption).foregroundStyle(.secondary)
                Button("주석 다시 확인") { Task { await refreshRevision() } }
            }
        }
        .padding(16).frame(maxWidth:.infinity,alignment:.topLeading)
        .background(Color(uiColor:.secondarySystemBackground))
    }

    private var proposalSheet: some View {
        NavigationStack {
            Form {
                Text("에이전트나 글자 인식의 제안입니다. 원본 획을 지우지 않고 내용만 수정합니다.")
                TextField("내용 확인",text:$store.proposalText,axis:.vertical)
            }
            .navigationTitle("구조 요소 확인")
            .toolbar {
                ToolbarItem(placement:.confirmationAction) {
                    Button("확정") { store.confirmProposal() }
                }
                ToolbarItem(placement:.cancellationAction) {
                    Button("나중에") { store.proposedNode = nil }
                }
            }
        }
    }

    private var dictationSheet: some View {
        NavigationStack {
            Form {
                Text("iPad 마이크로 설명을 받아씁니다. 문구를 확인해 캔버스에 저장하기 전까지 그림이나 대화로 전송되지 않습니다.")
                    .font(.footnote)
                Text(dictation.status).font(.footnote).foregroundStyle(.secondary)
                TextEditor(text:$dictation.draft)
                    .frame(minHeight:150)
                    .accessibilityIdentifier("canvasDictationDraft")
                Button(dictation.isListening ? "받아쓰기 멈추기" : "받아쓰기 시작하기",
                       systemImage:dictation.isListening ? "stop.fill" : "mic.fill") {
                    if dictation.isListening { dictation.stop() }
                    else { Task { await dictation.start() } }
                }
                .disabled(dictation.isStarting || dictation.isFinalizing)
            }
            .navigationTitle("음성 설명")
            .toolbar {
                ToolbarItem(placement:.cancellationAction) {
                    Button("취소") { dictation.cancel(); dictationOpen = false }
                }
                ToolbarItem(placement:.confirmationAction) {
                    Button("캔버스에 저장") {
                        dictation.stop()
                        store.addSpokenNote(dictation.draft)
                        dictationOpen = false
                    }
                    .disabled(dictation.isStarting || dictation.isListening || dictation.isFinalizing ||
                              dictation.draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var connectionSheet: some View {
        NavigationStack {
            Form {
                TextField("Mac 수신 주소",text:$relayAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("일회용 연결 토큰",text:$relayToken)
                Text("그림은 Mac의 고정 수신함으로 보냅니다. 음성 대화가 없어도 같은 곳에서 받습니다. 접수 결과가 불명확하면 같은 패킷의 영수증만 조회합니다.")
            }
            .navigationTitle("Mac 연결")
            .toolbar { ToolbarItem(placement:.confirmationAction) {
                Button("닫기") { connectionOpen = false }
            }}
        }
    }

    @MainActor
    private func send() async {
        guard !store.sendBusy else { return }
        store.sendBusy = true
        defer { store.sendBusy = false }
        let frozen = store.scene
        let connection = relay
        let address = relayAddress
        do {
            if let pending = try store.unresolvedPacket() {
                await reconcile(pending)
                return
            }
            guard let image = await SceneRenderer.png(scene:frozen) else {
                throw CanvasSendError.invalidPacket
            }
            let target = try await connection.inboxTarget()
            let session = try target.session()
            let targetMode = target.targetMode
            if let existing = try store.existingPacket(for:frozen,session:session) {
                await reconcile(existing)
                return
            }
            let readiness = try await connection.deliveryReadiness(threadId:session.threadId,
                targetMode:targetMode)
            guard readiness.available else {
                store.status = "전송 대기 · 고정 수신 대화 연결 미준비. 그림은 캔버스에 남아 있습니다."
                return
            }
            let packet = try store.preparePacket(scene:frozen,imagePNG:image,session:session,
                targetMode:targetMode,relayAddress:address)
            try store.beginSubmission(packet.packetId)
            do {
                try store.acceptReceipt(await connection.send(packet))
            } catch {
                if let entry = store.outbox.entries.first(where: { $0.id == packet.packetId }) {
                    await reconcile(entry)
                }
            }
        } catch { store.status = "전송 중단: \(error.localizedDescription)" }
    }

    @MainActor
    private func reconcile(_ entry: CanvasOutboxEntry) async {
        guard entry.relayAddress == relayAddress else {
            store.status = "원래 Mac 수신 주소에서 패킷 영수증을 확인하세요. 재전송하지 않았습니다."
            return
        }
        do {
            try store.acceptReceipt(await relay.receipt(for:entry.id))
        } catch {
            store.status = "접수 결과 미확인 · \(entry.id.uuidString.prefix(8)) · 영수증 조회 실패. 재전송하지 않습니다."
        }
    }

    @MainActor
    private func checkConnection() async {
        guard !relayToken.isEmpty else { return }
        do {
            _ = try await relay.inboxTarget().session()
            store.displayedVoice = try? await relay.projection().activeVoiceSession
            if let pending = store.outbox.unresolved { await reconcile(pending) }
            else {
                store.status = "Mac 그림 수신함 연결됨"
            }
        } catch {
            store.displayedVoice = nil
            store.status = "연결 대기 · 칠판과 미확인 전송은 기기에 보존됩니다."
        }
    }

    private func refreshRevision() async {
        guard let packet = store.packet else { return }
        do {
            if let revision = try await relay.revision(for:packet.packetId) {
                store.applyAgentRevision(revision)
            } else { store.status = "에이전트 주석을 기다리고 있습니다." }
        } catch { store.status = "주석 확인 실패: \(error.localizedDescription)" }
    }
}

private struct VaultMarkdownEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = UIFontMetrics.default.scaledFont(for:.monospacedSystemFont(ofSize:17,weight:.regular))
        view.adjustsFontForContentSizeCategory = true
        view.autocorrectionType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.accessibilityLabel = "Obsidian Markdown 원본 편집기"
        view.accessibilityIdentifier = "obsidianMarkdownEditor"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        view.isEditable = context.environment.isEnabled
        guard view.markedTextRange == nil else { return }
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        if !view.text.utf8.elementsEqual(text.utf8) { view.text = text }
        let start = max(0,min(selection.location,text.utf16.count))
        let range = NSRange(location:start,length:max(0,min(selection.length,text.utf16.count - start)))
        if view.selectedRange != range {
            view.selectedRange = range
            view.scrollRangeToVisible(range)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: VaultMarkdownEditor
        var updating = false
        init(_ parent: VaultMarkdownEditor) { self.parent = parent }
        func textViewDidChange(_ view: UITextView) {
            guard !updating else { return }
            parent.text = view.text
            parent.selection = view.selectedRange
        }
        func textViewDidChangeSelection(_ view: UITextView) {
            guard !updating else { return }
            parent.selection = view.selectedRange
        }
    }
}

private struct CanvasInkHistoryButtons: View {
    @ObservedObject var history: CanvasInkHistory

    var body: some View {
        Group {
            Button { history.undo() } label: {
                Label("실행 취소", systemImage: "arrow.uturn.backward")
                    .frame(minWidth: 44, minHeight: 44)
            }
                .disabled(!history.availability.canUndo)
                .accessibilityLabel("잉크 실행 취소")
                .accessibilityIdentifier("canvasInkUndo")
            Button { history.redo() } label: {
                Label("다시 실행", systemImage: "arrow.uturn.forward")
                    .frame(minWidth: 44, minHeight: 44)
            }
                .disabled(!history.availability.canRedo)
                .accessibilityLabel("잉크 다시 실행")
                .accessibilityIdentifier("canvasInkRedo")
        }
    }
}

private struct ProjectionConnection: Hashable {
    let address: String
    let token: String
    let active: Bool
}

private struct IdentifiedUUID: Identifiable {
    let id: UUID
    init(_ id: UUID) { self.id = id }
}

private struct NodeTile: View {
    let node: CanvasNode
    @ObservedObject var store: CanvasStore
    @State private var dragOrigin: CanvasPoint?

    var body: some View {
        VStack(spacing:4) {
            Text(node.text.isEmpty ? "내용 입력" : node.text).font(.title3)
                .lineLimit(node.vaultNote == nil ? nil : 3)
            if let reference = node.vaultNote {
                Text(reference.blockID.map { "^\($0)" } ?? reference.path).font(.caption).lineLimit(1)
                Text(reference.sourceStateLabel).font(.caption2).lineLimit(2)
            }
        }
            .frame(width:node.frame.width,height:node.frame.height)
            .foregroundStyle(Color(uiColor:CanvasPalette.nodeText))
            .background(Color(uiColor:CanvasPalette.nodeFill),
                        in:RoundedRectangle(cornerRadius:14))
            .overlay(RoundedRectangle(cornerRadius:14)
                .stroke(node.confidence == .proposal ? .orange :
                    store.selectedNode == node.id ? Color(uiColor:CanvasPalette.link) : .gray,
                    lineWidth:3))
            .onTapGesture { store.select(node.id) }
            .accessibilityElement(children:.combine)
            .gesture(DragGesture().onChanged { value in
                if dragOrigin == nil { dragOrigin = CanvasPoint(x:node.frame.x,y:node.frame.y) }
                guard let dragOrigin else { return }
                store.selectedNode = node.id
                store.scene.moveNode(node.id,to:CanvasPoint(
                    x:dragOrigin.x+value.translation.width/store.zoom,
                    y:dragOrigin.y+value.translation.height/store.zoom))
            }.onEnded { _ in dragOrigin = nil })
    }
}
