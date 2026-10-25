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
    @State private var pendingNodeEdit: (sceneID: UUID, node: CanvasNode)?
    @State private var proposalSelection = NSRange(location:0,length:0)
    @State private var proposalInputBusy = false
    @State private var handwritingSearchOpen = false
    @State private var handwritingQuery = ""
    @State private var dictationOpen = false
    @State private var vaultOpen = false
    @State private var vaultDirectory = ""
    @State private var vaultEntries: [CanvasRelay.VaultEntry] = []
    @State private var vaultStatus = ""
    @State private var vaultDiscardOpen = false
    @State private var recoveryDiscardOpen = false
    @State private var noteRecoveryDiscardOpen = false
    @State private var syncedSceneSha: String?
    @State private var canvasNoteSha: String?
    @State private var pendingSceneSha: String?
    @State private var canvasVaultBlocked = false
    @State private var canvasSyncBusy = false
    @State private var canvasVaultEnabled = true
    @State private var vaultSceneID: UUID?
    @State private var vaultSyncAddress: String?
    @State private var projectionGeneration = ControlRoomConnectionGeneration()
    @State private var readProjection: ControlRoomProjection?
    @State private var projectionMessage: String?
    @State private var expandedCard: ControlRoomCardReference?
    @State private var pipPlacement = VoicePIPPlacement()
    @State private var pipDragOrigin: CGPoint?
    @State private var diagramMode: DiagramMode = .original

    private enum DiagramMode: String, CaseIterable {
        case original = "원본 그림"
        case diagram = "다이어그램"
        case split = "나란히 보기"
    }

    init() {
        if let connection = CanvasRelay.loadConnection() {
            _relayAddress = State(initialValue:connection.address)
            _relayToken = State(initialValue:connection.token)
            var data = try? CanvasLocalFile.read(Self.canvasVaultCheckpointURL())
            #if DEBUG
            if case .normal = CanvasRuntime.launch {
                data = data ?? UserDefaults.standard.data(forKey:"canvasVaultCheckpoint")
            }
            #else
            data = data ?? UserDefaults.standard.data(forKey:"canvasVaultCheckpoint")
            #endif
            if let data,
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
            Picker("그림판 보기",selection:$diagramMode) {
                Text("원본 그림").tag(DiagramMode.original)
                Text("다이어그램").tag(DiagramMode.diagram)
                Text("나란히 보기").tag(DiagramMode.split)
            }
            .pickerStyle(.segmented).padding(.horizontal,10).padding(.vertical,6)
            .accessibilityIdentifier("canvasDiagramMode")
            GeometryReader { geometry in
                ZStack(alignment:.topLeading) {
                    HStack(spacing:diagramMode == .split ? 1 : 0) {
                        canvas
                            .frame(width:diagramMode == .diagram ? 0 :
                                diagramMode == .split ? max(0,(geometry.size.width - 1) / 2) : geometry.size.width)
                            .clipped()
                            .opacity(diagramMode == .diagram ? 0 : 1)
                            .allowsHitTesting(diagramMode != .diagram)
                            .accessibilityHidden(diagramMode == .diagram)
                        if diagramMode != .original { diagram }
                    }
                    if geometry.size.width >= 100 && geometry.size.height >= 100 {
                        voicePIP(in:geometry.size)
                    }
                }
                .coordinateSpace(name:"voicePIPContainer")
                .clipped()
                .onChange(of:geometry.size) { _,_ in pipDragOrigin = nil }
            }
            Text(store.sceneRecoveryNotice.isEmpty ? store.status : store.sceneRecoveryNotice)
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
        .onDisappear { dictation.cancel(); store.cancelLink(); store.clearLinkSelection(); store.saveNow() }
        .onChange(of:scenePhase) { _,phase in
            if phase != .active {
                store.cancelLink()
                store.clearLinkSelection()
                store.saveNow()
                dictation.cancel()
            }
            else { Task { await checkConnection() } }
        }
        .onChange(of:relayAddress) { _,_ in store.setNoteConnection(address:relayAddress,token:relayToken) }
        .onChange(of:diagramMode) { _,_ in store.clearLinkSelection() }
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
            guard !Task.isCancelled else { return }
            let generation = projectionGeneration.begin(address:relayAddress,token:relayToken)
            readProjection = generation.retainsContent ? readProjection?.disconnected() : nil
            store.displayedVoice = nil
            defer {
                if projectionGeneration.owns(generation) {
                    readProjection = readProjection?.disconnected()
                    store.displayedVoice = nil
                }
            }
            guard scenePhase == .active, !relayToken.isEmpty else {
                projectionMessage = "Mac 연결 필요 · 마지막 내용은 읽기 전용입니다."
                return
            }
            let connection = relay
            do {
                for await update in try connection.controlRoomEvents(retaining:readProjection) {
                    guard !Task.isCancelled, projectionGeneration.owns(generation) else { return }
                    switch update {
                    case .snapshot(let projection): readProjection = projection
                    case .unavailable: readProjection = nil
                    case .disconnected(let last, _): readProjection = last
                    }
                    projectionMessage = update.message
                    store.displayedVoice = readProjection?.observedSession()
                }
            } catch {
                guard projectionGeneration.owns(generation), !Task.isCancelled else { return }
                projectionMessage = "관제 이벤트 연결을 시작할 수 없습니다. 주소와 연결 상태를 확인하세요."
            }
        }
        .alert("손글씨 찾기", isPresented:$handwritingSearchOpen) {
            TextField("찾을 글자", text:$handwritingQuery)
            Button("찾기") {
                let query = handwritingQuery
                Task { await store.searchHandwriting(query) }
            }.disabled(handwritingQuery.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            Button("취소", role:.cancel) { }
        } message: {
            Text("원본 획에서 일치하는 손글씨를 찾아 영역으로 선택합니다.")
        }
        .sheet(isPresented:$connectionOpen) { connectionSheet }
        .sheet(isPresented:$inspectorOpen,onDismiss: {
            guard let pending = pendingNodeEdit else { return }
            pendingNodeEdit = nil
            guard store.scene.id == pending.sceneID,
                  let current = store.scene.nodes.first(where:{ $0.id == pending.node.id }),
                  current == pending.node, current.text.utf8.elementsEqual(pending.node.text.utf8) else {
                store.status = "요소가 바뀌었습니다. 최신 요소를 다시 선택해 주세요."
                return
            }
            store.proposedNode = pending.node.id
            store.proposalText = pending.node.text
        }) {
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
            Button("Obsidian 노트",systemImage:"doc.text") {
                vaultOpen = true
                Task { await loadVaultEntries() }
            }
            Divider()
            Picker("그리기 도구",selection:$store.mode) {
                ForEach(CanvasMode.allCases,id:\.self) { Text($0.rawValue).tag($0) }
            }
            Picker("지우기 방식", selection: $store.eraserStyle) {
                ForEach(CanvasEraserStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Picker("부분 지우개 크기 · CCR 포인트", selection: $store.eraserSize) {
                ForEach(CanvasEraserSize.allCases, id: \.self) { size in
                    Text(size.label).frame(minWidth:44,minHeight:44).tag(size)
                }
            }
            .disabled(store.eraserStyle != .partial)
            .accessibilityValue(store.eraserStyle == .partial ? store.eraserSize.label : "획 전체 지우기에서는 적용되지 않음")
            .accessibilityHint("CCR에서 정한 캔버스 포인트 단위이며 확대 비율에 따라 표시 크기가 달라집니다.")
            .accessibilityIdentifier("canvasPartialEraserSize")
            Button("상자") { store.addNode(.box) }
            Button("메모") { store.addNode(.note) }
            Button("손글씨 찾기",systemImage:"magnifyingglass") { handwritingSearchOpen = true }
            Button("글자 인식") { Task { await store.proposeHandwriting() } }
            Button("선택한 글자 인식") { Task { await store.proposeHandwriting(selectedOnly:true) } }
                .disabled(store.inkSelection.isEmpty)
            Button("음성 설명",systemImage:"mic") { dictationOpen = true }
            Button("화살표") { store.beginLink() }.disabled(store.selectedNode == nil)
            Button("하위 요소 연결") { store.beginChildLink() }.disabled(store.selectedNode == nil)
            foldButton
            if store.linkStart != nil { Button("연결 취소") { store.cancelLink() } }
            Button("구조 데이터",systemImage:"sidebar.right") { inspectorOpen = true }
            Button("구조 수정 되돌리기",systemImage:"arrow.uturn.backward") { store.undoGraphEdit() }
                .disabled(!store.canUndoGraph)
            Button("구조 수정 다시 실행",systemImage:"arrow.uturn.forward") { store.redoGraphEdit() }
                .disabled(!store.canRedoGraph)
            Button("연결",systemImage:"network") { connectionOpen = true }
            Button("가져오기") { importOpen = true }
            Button("내보내기") { exportOpen = true }
        }
        .frame(minWidth:44,minHeight:44)
    }

    private var foldButton: some View {
        let node = store.scene.nodes.first { $0.id == store.selectedNode }
        let collapsed = node?.isCollapsed == true
        return Button { store.toggleSelectedChildren() } label: {
            Label(collapsed ? "하위 요소 펼치기" : "하위 요소 접기",
                  systemImage: collapsed ? "chevron.down" : "chevron.right")
                .frame(minWidth:44,minHeight:44)
        }
        .disabled(node.map { !store.scene.canToggleChildren(of:$0.id) } ?? true)
        .accessibilityValue(collapsed ? "접힘" : "펼침")
        .accessibilityHint("하위 요소의 표시만 바꾸며 원본 획과 연결을 보존합니다.")
        .accessibilityIdentifier("canvasHierarchyFold")
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
                if !store.noteRecoveryNotice.isEmpty {
                    VStack(alignment:.leading,spacing:6) {
                        Text(store.noteRecoveryNotice).font(.footnote)
                        if let recovery = store.noteRecovery, store.vaultNote == nil {
                            Text(recovery.base.path).font(.caption).textSelection(.enabled)
                            Button("보존된 노트 입력 열기") {
                                store.setNoteConnection(address:relayAddress,token:relayToken)
                                let connection = relay
                                Task { await store.restoreNoteDraft(load:connection.vaultNote) }
                            }.frame(minHeight:44).disabled(store.vaultLoading)
                                .accessibilityIdentifier("obsidianRestoreNoteDraft")
                            Button("보존된 노트 입력 버리기",role:.destructive) { noteRecoveryDiscardOpen = true }
                                .frame(minHeight:44).disabled(store.vaultLoading)
                                .accessibilityIdentifier("obsidianDiscardNoteRecovery")
                        }
                    }.padding(.horizontal)
                }
                if !store.blockRecoveryNotice.isEmpty {
                    VStack(alignment:.leading,spacing:6) {
                        Text(store.blockRecoveryNotice).font(.footnote)
                        if store.blockRecovery != nil && !store.vaultBlockEditing {
                            Button("보존된 문단 입력 열기") { _ = store.restoreLinkedBlockDraft() }
                                .frame(minHeight:44).accessibilityIdentifier("obsidianRestoreBlockDraft")
                            Button("보존된 입력 버리기",role:.destructive) { recoveryDiscardOpen = true }
                                .frame(minHeight:44).accessibilityIdentifier("obsidianDiscardBlockRecovery")
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal)
                        .disabled(store.vaultDirty || store.vaultSaving || store.vaultLoading)
                }
                if let note = store.vaultNote {
                    Text(note.path).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal)
                    if store.vaultBlockEditing {
                        VaultMarkdownEditor(text:$store.vaultBlockDraft,selection:$store.vaultBlockSelection,
                            identifier:"obsidianLinkedBlockEditor",label:"Obsidian 연결 문단 편집기",
                            inputBusy:$store.vaultInputBusy,editSession:{ store.vaultInputSessionID })
                            .id(store.vaultInputSessionID)
                            .frame(minHeight:150).disabled(store.vaultLoading || store.vaultInputSessionID == nil)
                            .accessibilityIdentifier("obsidianLinkedBlockEditor")
                        Text("연결 문단 편집 · 블록 표식과 다른 문단은 그대로 보존됩니다.")
                            .font(.footnote).padding(.horizontal)
                    } else {
                        VaultMarkdownEditor(text:$store.vaultDraft,selection:$store.vaultSelection,
                            inputBusy:$store.vaultInputBusy,editSession:{ store.vaultInputSessionID })
                            .id(store.vaultInputSessionID)
                            .frame(minHeight:150)
                            .disabled(store.vaultLoading || store.vaultInputSessionID == nil)
                            .accessibilityIdentifier("obsidianMarkdownEditor")
                    }
                    VStack(alignment:.leading,spacing:6) {
                        if let id = store.vaultLinkedBlockID {
                            Text("연결 블록 ^\(id)").font(.caption).textSelection(.enabled)
                        }
                        if !store.vaultBlockEditing {
                        if store.vaultLinkedBlockID != nil {
                            Button { _ = store.beginLinkedBlockEdit() } label: {
                                Text("연결 문단만 수정").frame(maxWidth:.infinity,minHeight:44)
                            }.disabled(!store.vaultCanAttach)
                                .accessibilityIdentifier("obsidianEditLinkedBlock")
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
                        }
                        if store.noteRecoveryWriteFailed {
                            Button { store.retryNoteDraftPreservation() } label: {
                                Text("입력 보존 다시 시도").frame(maxWidth:.infinity,minHeight:44)
                            }.disabled(store.vaultBlocked || store.vaultSaving || store.vaultLoading || store.vaultInputBusy)
                                .accessibilityIdentifier("obsidianRetryNotePreservation")
                        }
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
                        Button(store.vaultBlockHasPendingSave ? "저장 결과 확인" : "저장") { Task { await saveVaultNote() } }
                            .frame(minWidth:44,minHeight:44)
                            .disabled(store.vaultBlockEditing ? !store.vaultBlockCanSave : !store.vaultCanSave)
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
            .interactiveDismissDisabled(store.vaultDirty || store.vaultSaving || store.vaultInputBusy)
            .alert("보존된 노트 입력을 버릴까요?",isPresented:$noteRecoveryDiscardOpen) {
                Button("입력 버리기",role:.destructive) { _ = store.discardNoteRecovery() }
                Button("취소",role:.cancel) {}
            } message: {
                Text("이 기기에 보존한 미저장 노트 입력만 버립니다. Obsidian 원본과 이미 저장된 결과는 변경하지 않습니다.")
            }
            .alert("보존된 입력을 버릴까요?",isPresented:$recoveryDiscardOpen) {
                Button("입력 버리기",role:.destructive) { _ = store.discardLinkedBlockRecovery() }
                Button("취소",role:.cancel) {}
            } message: {
                Text("이 기기의 복구 입력과 미확인 작업 기록만 버립니다. 이미 서버에 저장된 결과는 취소되지 않습니다.")
            }
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
        if store.vaultBlockEditing {
            await store.saveLinkedBlock(replace: { path,id,edit in
                try await connection.replaceVaultBlock(at:path,blockID:id,edit:edit)
            },load:connection.vaultNote)
            return
        }
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
        try CanvasRuntime.stateURL(.checkpoint)
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
        guard !canvasSyncBusy, !Task.isCancelled, !store.inkHistory.usingTool else { return }
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
                !store.inkHistory.usingTool &&
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
        guard !store.inkHistory.usingTool, !canvasVaultBlocked, !canvasSyncBusy, let syncedSceneSha, let canvasNoteSha,
              vaultSceneID == store.scene.id, vaultSyncAddress == relayAddress else { return }
        do {
            guard let remote = try await relay.vaultCanvas(id:store.scene.id),
                  !store.inkHistory.usingTool,
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
        let visible = store.scene.visibility
        let displayed = store.displayedScene
        return GeometryReader { _ in
            ZStack(alignment:.topLeading) {
                Color(uiColor:CanvasPalette.background)
                PencilCanvas(store:store,isVisible:diagramMode != .diagram)
                if store.scene.drawingBase64.isEmpty {
                    ForEach(store.scene.strokes) { stroke in strokeView(stroke) }
                }
                ForEach(displayed.links.filter { visible.linkIDs.contains($0.id) }) { link in linkView(link,in:displayed) }
                ForEach(displayed.nodes.filter { visible.nodeIDs.contains($0.id) }) { node in
                    nodeView(node).accessibilityHidden(diagramMode == .diagram)
                }
                ForEach(store.scene.annotations.filter { visible.annotationIDs.contains($0.id) }) { note in
                    annotationView(note,in:displayed).accessibilityHidden(diagramMode == .diagram)
                }
                if store.mode == .select, let id = store.selectedNode, visible.nodeIDs.contains(id),
                   let node = store.scene.nodes.first(where:{ $0.id == id }),
                   let shown = displayed.nodes.first(where:{ $0.id == id }),
                   let corner = shown.scenePoint(.init(x:shown.frame.x + shown.frame.width,y:shown.frame.y + shown.frame.height)),
                   let rotationHandle = shown.scenePoint(.init(x:shown.frame.center.x,y:shown.frame.y + shown.frame.height + 44 / store.zoom)) {
                    CanvasNodeResizeHandle(store:store,node:node,sceneID:store.scene.id)
                        .position(x:corner.x,y:corner.y)
                        .allowsHitTesting(diagramMode != .diagram)
                        .accessibilityHidden(diagramMode == .diagram)
                    CanvasNodeRotationHandle(store:store,node:node,sceneID:store.scene.id)
                        .position(x:rotationHandle.x,y:rotationHandle.y)
                        .allowsHitTesting(diagramMode != .diagram)
                        .accessibilityHidden(diagramMode == .diagram)
                }
                if store.mode == .select, let id = store.selectedLink,
                   let link = store.scene.links.first(where:{ $0.id == id }),
                   let endpoints = store.scene.linkEndpoints(store.displayedLink(link)) {
                    ForEach(CanvasLink.Endpoint.allCases,id:\.self) { endpoint in
                        CanvasEndpointHandle(store:store,linkID:id,endpoint:endpoint)
                            .position(x:endpoint == .from ? endpoints.from.x : endpoints.to.x,
                                      y:endpoint == .from ? endpoints.from.y : endpoints.to.y)
                    }
                }
            }
            .frame(width:store.scene.width,height:store.scene.height)
            .coordinateSpace(name:"canvasScene")
            .scaleEffect(store.zoom,anchor:.topLeading)
            .offset(store.pan)
        }
        .clipped()
        .contentShape(Rectangle())
        .background(Color(uiColor:.secondarySystemBackground))
    }

    private var diagram: some View {
        VStack(alignment:.leading,spacing:8) {
            Text("같은 구조 데이터의 자동 배치 · 원본 획 위치는 유지됩니다.").font(.caption)
            Text("자유그림의 자동 의미 해석은 미지원입니다. 요소를 누르면 기존 편집기로 연결됩니다.")
                .font(.caption).foregroundStyle(.secondary)
            CanvasPeleView(scene:store.scene,selectedNode:store.selectedNode,onSelect:{ id in
                store.selectedNode = id
                inspectorOpen = true
            },onError:{ store.status = $0 })
        }.padding(8)
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

    private func linkView(_ link: CanvasLink, in displayed: CanvasScene) -> some View {
        let endpoints = displayed.linkEndpoints(store.displayedLink(link))
        let line = Path { path in
            guard let endpoints else { return }
            let from = endpoints.from, to = endpoints.to
            path.move(to:CGPoint(x:from.x,y:from.y))
            path.addLine(to:CGPoint(x:to.x,y:to.y))
        }
        let arrow = Path { path in
            guard let endpoints else { return }
            let from = endpoints.from, to = endpoints.to
            let angle = atan2(to.y-from.y,to.x-from.x)
            for sign in [-1.0,1.0] {
                path.move(to:CGPoint(x:to.x,y:to.y))
                path.addLine(to:CGPoint(x:to.x-20*cos(angle+sign*0.45),
                                        y:to.y-20*sin(angle+sign*0.45)))
            }
        }
        return ZStack {
            line.stroke(Color(uiColor:CanvasPalette.link),style:StrokeStyle(
                lineWidth:store.selectedLink == link.id ? 5 : 3,lineCap:.round))
            arrow.stroke(Color(uiColor:CanvasPalette.link),style:StrokeStyle(lineWidth:3,lineCap:.round))
        }
        .contentShape(line.strokedPath(StrokeStyle(lineWidth:24 / store.zoom,lineCap:.round)))
        .onTapGesture { store.selectLink(link.id) }
        .allowsHitTesting(store.mode == .select)
        .accessibilityElement(children:.ignore)
        .accessibilityLabel(link.label.isEmpty ? "연결선" : "연결선 \(link.label)")
        .accessibilityValue(store.selectedLink == link.id ? "선택됨. 시작점과 끝점을 끌어 연결 위치 변경" : "선택 안 됨")
        .accessibilityIdentifier("canvasLink-\(link.id.uuidString)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { store.selectLink(link.id) }
    }

    private func nodeView(_ node: CanvasNode) -> some View {
        NodeTile(node:node,store:store)
            .position(x:node.frame.center.x,y:node.frame.center.y)
            .allowsHitTesting(store.mode == .select)
    }

    private func annotationView(_ note: CanvasAnnotation, in displayed: CanvasScene) -> some View {
        Group {
            if let node = displayed.nodes.first(where:{$0.id == note.nodeId}) {
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
                let parentLink = store.scene.links.first(where:{ $0.kind == .parentChild && $0.to == id })
                if let parent = store.scene.nodes.first(where:{ $0.id == parentLink?.from }) {
                    Text("상위 요소 · \(parent.text.isEmpty ? "이름 없는 요소" : parent.text)")
                        .accessibilityIdentifier("canvasHierarchyParent")
                    Button("상위 연결 해제") { store.unlinkFromParent() }.frame(minHeight:44)
                }
                let childIDs = Set(store.scene.links.filter { $0.kind == .parentChild && $0.from == id }.map(\.to))
                let children = store.scene.nodes.filter { childIDs.contains($0.id) }
                Text("하위 요소 \(children.count)개").accessibilityIdentifier("canvasHierarchyChildren")
                foldButton
                ForEach(children) { child in
                    Text(child.text.isEmpty ? "이름 없는 요소" : child.text).font(.caption)
                }
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
                        pendingNodeEdit = (sceneID:store.scene.id,node:node)
                        inspectorOpen = false
                    }
                }
            } else {
                Text("요소를 탭하면 텍스트와 출처를 볼 수 있습니다.").foregroundStyle(.secondary)
            }
            Divider()
            Text("에이전트 주석 \(store.scene.annotations.count)개")
            ForEach(store.scene.annotations.filter {
                $0.nodeId == nil || store.scene.visibility.annotationIDs.contains($0.id)
            }) { note in
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
                Text("손글씨로 입력하거나 글자를 선택해 ‘선택 글자 교정’에서 바꿀 글자를 입력하고 적용하세요. ‘펜 교정’을 켜면 지그재그는 삭제, 위로 긋기는 같은 줄의 공백 합치기, 아래로 긋기는 나누기입니다. 원본 획과 출처는 유지됩니다.")
                VaultMarkdownEditor(text:$store.proposalText,selection:$proposalSelection,
                                    identifier:"canvasNodeTextEditor",label:"요소 글자 편집기",
                                    inputBusy:$proposalInputBusy,
                                    editSession:{ store.proposalInputSessionID })
                    .id(store.proposalInputSessionID)
                    .frame(minHeight:240)
                if !store.proposalIsCurrent {
                    Text("다른 곳에서 요소나 장면이 바뀌었습니다. 입력은 유지하며 덮어쓰지 않습니다. 닫고 최신 요소를 다시 열어 주세요.")
                        .foregroundStyle(.orange)
                }
            }
            .navigationTitle("구조 요소 확인")
            .toolbar {
                ToolbarItem(placement:.confirmationAction) {
                    Button("확정") { store.confirmProposal() }
                        .disabled(!store.proposalIsCurrent || proposalInputBusy)
                }
                ToolbarItem(placement:.cancellationAction) {
                    Button("나중에") { store.proposedNode = nil }
                }
            }
        }
        .onAppear {
            proposalSelection = NSRange(location:0,length:0)
            proposalInputBusy = false
        }
        .onChange(of:store.proposedNode) { _,_ in
            proposalSelection = NSRange(location:0,length:0)
            proposalInputBusy = false
        }
        .onDisappear { proposalInputBusy = false }
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

private struct CanvasNodeRotationHandle: View {
    @ObservedObject var store: CanvasStore
    let node: CanvasNode
    let sceneID: UUID
    @State private var dragOwner: UUID?
    @GestureState private var gestureActive = false

    private var degrees: Double {
        store.displayedScene.nodes.first(where:{ $0.id == node.id })?.rotationDegrees ?? 0
    }

    var body: some View {
        Image(systemName:"arrow.clockwise")
            .font(.system(size:16 / store.zoom,weight:.bold))
            .foregroundStyle(Color(uiColor:CanvasPalette.link))
            .frame(width:24 / store.zoom,height:24 / store.zoom)
            .background(Color(uiColor:CanvasPalette.background),in:Circle())
            .frame(width:44 / store.zoom,height:44 / store.zoom)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance:0,coordinateSpace:.named("canvasScene"))
                .updating($gestureActive) { _, active, _ in active = true }
                .onChanged { value in
                    if dragOwner == nil {
                        let owner = UUID()
                        dragOwner = owner
                        store.beginNodeRotation(node,sceneID:sceneID,owner:owner)
                    }
                    guard let owner = dragOwner else { return }
                    store.updateNodeRotation(owner:owner,
                        from:.init(x:value.startLocation.x,y:value.startLocation.y),
                        to:.init(x:value.location.x,y:value.location.y))
                }.onEnded { value in
                    guard let owner = dragOwner else { return }
                    defer { dragOwner = nil }
                    guard store.updateNodeRotation(owner:owner,
                        from:.init(x:value.startLocation.x,y:value.startLocation.y),
                        to:.init(x:value.location.x,y:value.location.y)) else {
                        store.cancelNodeRotation(owner:owner)
                        return
                    }
                    store.finishNodeRotation(owner:owner)
                })
            .onChange(of:gestureActive) { _, active in
                if !active, let owner = dragOwner {
                    store.cancelNodeRotation(owner:owner)
                    dragOwner = nil
                }
            }
            .onDisappear {
                if let owner = dragOwner { store.cancelNodeRotation(owner:owner) }
                dragOwner = nil
            }
            .accessibilityLabel("선택한 요소 회전")
            .accessibilityHint("손잡이를 요소 중심 둘레로 끌어 회전합니다.")
            .accessibilityValue(Text("회전 \(degrees,specifier:"%.0f")도"))
            .accessibilityAction(named:Text("시계 방향으로 15도 회전")) {
                store.rotateNode(node,sceneID:sceneID,to:(node.rotationDegrees ?? 0) + 15)
            }
            .accessibilityAction(named:Text("반시계 방향으로 15도 회전")) {
                store.rotateNode(node,sceneID:sceneID,to:(node.rotationDegrees ?? 0) - 15)
            }
            .accessibilityAction(named:Text("회전 원위치")) {
                store.rotateNode(node,sceneID:sceneID,to:0)
            }
            .accessibilityIdentifier("canvasNodeRotate-\(node.id.uuidString)")
    }
}

private struct CanvasNodeResizeHandle: View {
    @ObservedObject var store: CanvasStore
    let node: CanvasNode
    let sceneID: UUID
    @State private var dragOwner: UUID?
    @GestureState private var gestureActive = false

    var body: some View {
        Image(systemName:"arrow.up.left.and.arrow.down.right")
            .font(.system(size:16 / store.zoom,weight:.bold))
            .foregroundStyle(Color(uiColor:CanvasPalette.link))
            .frame(width:24 / store.zoom,height:24 / store.zoom)
            .background(Color(uiColor:CanvasPalette.background),in:RoundedRectangle(cornerRadius:4 / store.zoom))
            .frame(width:44 / store.zoom,height:44 / store.zoom)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance:0,coordinateSpace:.named("canvasScene"))
                .updating($gestureActive) { _, active, _ in active = true }
                .onChanged { value in
                    if dragOwner == nil {
                        let owner = UUID()
                        dragOwner = owner
                        store.beginNodeResize(node,sceneID:sceneID,owner:owner)
                    }
                    guard let owner = dragOwner else { return }
                    store.updateNodeResize(owner:owner,translation:CanvasPoint(
                        x:value.translation.width,y:value.translation.height))
                }.onEnded { value in
                    guard let owner = dragOwner else { return }
                    defer { dragOwner = nil }
                    guard store.updateNodeResize(owner:owner,translation:CanvasPoint(
                        x:value.translation.width,y:value.translation.height)) else {
                        store.cancelNodeResize(owner:owner)
                        return
                    }
                    store.finishNodeResize(owner:owner)
                })
            .onChange(of:gestureActive) { _, active in
                if !active, let owner = dragOwner {
                    store.cancelNodeResize(owner:owner)
                    dragOwner = nil
                }
            }
            .onDisappear {
                if let owner = dragOwner { store.cancelNodeResize(owner:owner) }
                dragOwner = nil
            }
            .accessibilityLabel("선택한 요소 크기 조절")
            .accessibilityHint("우하단 손잡이를 Pencil이나 손가락으로 끌어 너비와 높이를 바꿉니다.")
            .accessibilityValue(Text("너비 \(node.frame.width,specifier:"%.0f"), 높이 \(node.frame.height,specifier:"%.0f")"))
            .accessibilityAction(named:Text("너비 늘리기")) {
                store.adjustNodeSize(node,sceneID:sceneID,by:.init(x:20,y:0))
            }
            .accessibilityAction(named:Text("너비 줄이기")) {
                store.adjustNodeSize(node,sceneID:sceneID,by:.init(x:-20,y:0))
            }
            .accessibilityAction(named:Text("높이 늘리기")) {
                store.adjustNodeSize(node,sceneID:sceneID,by:.init(x:0,y:20))
            }
            .accessibilityAction(named:Text("높이 줄이기")) {
                store.adjustNodeSize(node,sceneID:sceneID,by:.init(x:0,y:-20))
            }
            .accessibilityIdentifier("canvasNodeResize-\(node.id.uuidString)")
    }
}

private struct CanvasEndpointHandle: View {
    @ObservedObject var store: CanvasStore
    let linkID: UUID
    let endpoint: CanvasLink.Endpoint
    @State private var dragOwner: UUID?
    @GestureState private var gestureActive = false

    var body: some View {
        Circle().fill(Color(uiColor:CanvasPalette.background))
            .overlay(Circle().stroke(Color(uiColor:CanvasPalette.link),lineWidth:3 / store.zoom))
            .frame(width:20 / store.zoom,height:20 / store.zoom)
            .frame(width:44 / store.zoom,height:44 / store.zoom)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance:0,coordinateSpace:.named("canvasScene"))
                .updating($gestureActive) { _, active, _ in active = true }
                .onChanged { value in
                    if dragOwner == nil {
                        let owner = UUID()
                        dragOwner = owner
                        store.beginEndpointDrag(endpoint,linkID:linkID,owner:owner)
                    }
                    guard let owner = dragOwner else { return }
                    store.updateEndpointDrag(owner:owner,to:CanvasPoint(x:value.location.x,y:value.location.y))
                }.onEnded { value in
                    guard let owner = dragOwner else { return }
                    defer { dragOwner = nil }
                    guard store.updateEndpointDrag(owner:owner,to:CanvasPoint(x:value.location.x,y:value.location.y)) else {
                        store.cancelEndpointDrag(owner:owner)
                        return
                    }
                    store.finishEndpointDrag(owner:owner)
                })
            .onChange(of:gestureActive) { _, active in
                if !active, let owner = dragOwner {
                    store.cancelEndpointDrag(owner:owner)
                    dragOwner = nil
                }
            }
            .onDisappear {
                if let owner = dragOwner { store.cancelEndpointDrag(owner:owner) }
                dragOwner = nil
            }
            .accessibilityLabel(endpoint == .from ? "연결선 시작점" : "연결선 끝점")
            .accessibilityHint("끌어서 이 요소 경계의 연결 위치를 바꿉니다.")
            .accessibilityIdentifier("canvasLinkEndpoint-\(endpoint.rawValue)-\(linkID.uuidString)")
    }
}

struct VaultMarkdownEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var identifier = "obsidianMarkdownEditor"
    var label = "Obsidian Markdown 원본 편집기"
    var inputBusy: Binding<Bool> = .constant(false)
    var editSession: () -> UUID?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = NodeTextView()
        view.delegate = context.coordinator
        view.font = UIFontMetrics.default.scaledFont(for:.monospacedSystemFont(ofSize:17,weight:.regular))
        view.adjustsFontForContentSizeCategory = true
        view.autocorrectionType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.accessibilityLabel = label
        view.accessibilityIdentifier = identifier
        context.coordinator.configure(view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.invalidateSelectionCorrection()
        view.isEditable = context.environment.isEnabled && context.coordinator.isCurrent
        guard context.coordinator.isCurrent, view.markedTextRange == nil,
              !context.coordinator.scribbling, !context.coordinator.correcting,
              context.coordinator.pendingCorrection == nil else { return }
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        if !view.text.utf8.elementsEqual(text.utf8) {
            view.text = text
            view.undoManager?.removeAllActions()
        }
        let start = max(0,min(selection.location,text.utf16.count))
        let range = NSRange(location:start,length:max(0,min(selection.length,text.utf16.count - start)))
        if view.selectedRange != range {
            view.selectedRange = range
            view.scrollRangeToVisible(range)
        }
        context.coordinator.refreshControls(view)
    }

    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        guard let view = view as? NodeTextView else { return }
        coordinator.retire(view)
        view.inputStateChanged = nil
        view.delegate = nil
        view.undoManager?.removeAllActions()
    }

    final class NodeTextView: UITextView {
        var inputStateChanged: (() -> Void)?
        let correctionTrace = CAShapeLayer()
        override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
            super.setMarkedText(markedText,selectedRange:selectedRange)
            inputStateChanged?()
        }
        override func unmarkText() {
            super.unmarkText()
            inputStateChanged?()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: VaultMarkdownEditor
        var updating = false
        var scribbling = false
        private let session: UUID?
        private var active = true
        fileprivate weak var editor: UITextView?
        private var erase: UIBarButtonItem?
        private var undo: UIBarButtonItem?
        private var redo: UIBarButtonItem?
        private var correction: UIBarButtonItem?
        private var selectionCorrection: UIBarButtonItem?
        private(set) var pendingCorrection: CanvasPencilTextSnapshot?
        private weak var correctionAlert: UIAlertController?
        private var correctionGesture: PencilTextGestureRecognizer?
        fileprivate var correcting = false
        fileprivate var correctionEnabled = false
        private var gestureSnapshot: CanvasPencilTextSnapshot?
        init(_ parent: VaultMarkdownEditor) {
            self.parent = parent
            session = parent.editSession()
        }
        fileprivate var isCurrent: Bool {
            active && session != nil && session == parent.editSession()
        }
        func retire(_ view: UITextView) {
            cancelSelectionCorrection()
            if isCurrent { parent.inputBusy.wrappedValue = false }
            active = false
            view.isEditable = false
            correctionGesture?.isEnabled = false
            correctionGesture?.onTracking = nil
            correctionGesture?.onStroke = nil
            correctionGesture?.onPoints = nil
            (view as? NodeTextView)?.correctionTrace.removeFromSuperlayer()
            editor = nil
            #if !os(visionOS)
            for interaction in view.interactions where interaction is UIScribbleInteraction {
                view.removeInteraction(interaction)
            }
            #endif
        }
        func configure(_ view: NodeTextView) {
            editor = view
            view.undoManager?.removeAllActions()
            let gesture = PencilTextGestureRecognizer(target: nil, action: nil)
            gesture.isEnabled = false
            gesture.onTracking = { [weak self, weak view] active in
                guard let self, let view, self.isCurrent else { return }
                self.correcting = active
                if active, let session = self.session {
                    self.gestureSnapshot = CanvasPencilTextSnapshot(text:view.text,session:session,selection:view.selectedRange)
                }
                self.publishInputState(view)
            }
            gesture.onPoints = { [weak self, weak view] points in
                guard let self, let view, self.isCurrent else { return }
                let path = UIBezierPath()
                if let first = points.first {
                    path.move(to:first)
                    for point in points.dropFirst() { path.addLine(to:point) }
                }
                view.correctionTrace.path = path.cgPath
            }
            gesture.onStroke = { [weak self] points in
                guard let self, let snapshot = self.gestureSnapshot else { return }
                self.gestureSnapshot = nil
                self.applyCorrection(points,snapshot:snapshot)
            }
            view.addGestureRecognizer(gesture)
            correctionGesture = gesture
            view.correctionTrace.strokeColor = UIColor.systemBlue.cgColor
            view.correctionTrace.fillColor = UIColor.clear.cgColor
            view.correctionTrace.lineWidth = 2
            view.layer.addSublayer(view.correctionTrace)
            view.inputStateChanged = { [weak self, weak view] in
                guard let self, let view else { return }
                self.textViewDidChange(view)
            }
            #if !os(visionOS)
            view.addInteraction(UIScribbleInteraction(delegate:self))
            #endif
            let toolbar = UIToolbar()
            let erase = UIBarButtonItem(title:"선택 글자 지우기",style:.plain,target:self,action:#selector(eraseSelection))
            let undo = UIBarButtonItem(title:"실행 취소",style:.plain,target:self,action:#selector(undoEdit))
            let redo = UIBarButtonItem(title:"다시 실행",style:.plain,target:self,action:#selector(redoEdit))
            let correction = UIBarButtonItem(title:"펜 교정 켜기",style:.plain,target:self,action:#selector(toggleCorrection))
            let selectionCorrection = UIBarButtonItem(title:"선택 글자 교정",style:.plain,target:self,action:#selector(showSelectionCorrection))
            selectionCorrection.accessibilityIdentifier = "canvasSelectedTextCorrection"
            self.selectionCorrection = selectionCorrection
            correction.accessibilityIdentifier = "canvasPencilCorrectionMode"
            self.correction = correction
            self.erase = erase
            self.undo = undo
            self.redo = redo
            toolbar.items = [undo,redo,UIBarButtonItem(systemItem:.flexibleSpace),correction,selectionCorrection,erase]
            toolbar.sizeToFit()
            view.inputAccessoryView = toolbar
            refreshControls(view)
        }
        func refreshControls(_ view: UITextView) {
            let ready = isCurrent && view.isEditable && view.markedTextRange == nil && !scribbling && !correcting && pendingCorrection == nil
            correction?.isEnabled = ready
            selectionCorrection?.isEnabled = ready &&
                canvasSelectedCharacterRange(in:view.text,selection:view.selectedRange) == view.selectedRange && view.selectedRange.length > 0
            erase?.isEnabled = ready && canvasSelectedCharacterRange(in:view.text,selection:view.selectedRange) != nil
            undo?.isEnabled = ready && view.undoManager?.canUndo == true
            redo?.isEnabled = ready && view.undoManager?.canRedo == true
        }
        private func publishInputState(_ view: UITextView) {
            guard isCurrent else { return }
            parent.inputBusy.wrappedValue = view.markedTextRange != nil || scribbling || correcting || pendingCorrection != nil
            refreshControls(view)
        }
        @objc private func toggleCorrection() {
            guard isCurrent, let editor, editor.markedTextRange == nil, !scribbling, !correcting, pendingCorrection == nil else { return }
            correctionEnabled.toggle()
            correctionGesture?.isEnabled = correctionEnabled
            correction?.title = correctionEnabled ? "손글씨 입력으로" : "펜 교정 켜기"
            correction?.accessibilityValue = correctionEnabled ? "펜 교정" : "손글씨 입력"
            (editor as? NodeTextView)?.correctionTrace.path = nil
        }
        func applyCorrection(_ points: [CGPoint], expectedText: String) {
            guard isCurrent, correctionEnabled, let editor, editor.isEditable,
                  editor.markedTextRange == nil, !scribbling, pendingCorrection == nil,
                  editor.text.utf8.elementsEqual(expectedText.utf8),
                  parent.text.utf8.elementsEqual(expectedText.utf8),
                  let gesture = correctionGesture(points,in:editor),
                  let range = correctionRange(points,gesture:gesture,in:editor),
                  let edit = CanvasPencilTextCorrection.edit(in:editor.text,gesture:gesture,range:range) else { return }
            applyTextChange(edit,in:editor)
        }
        func applyCorrection(_ points: [CGPoint], snapshot: CanvasPencilTextSnapshot) {
            guard let editor, snapshot.matches(text:editor.text,session:parent.editSession(),selection:editor.selectedRange) else { return }
            applyCorrection(points,expectedText:snapshot.text)
        }
        @discardableResult
        private func applyTextChange(_ edit: CanvasPencilTextChange, in editor: UITextView) -> Bool {
            guard let start = editor.position(from:editor.beginningOfDocument,offset:edit.range.location),
                  let end = editor.position(from:start,offset:edit.range.length),
                  let textRange = editor.textRange(from:start,to:end) else { return false }
            editor.replace(textRange,withText:edit.replacement)
            textViewDidChange(editor)
            return true
        }
        private func correctionGesture(_ points: [CGPoint], in view: UITextView) -> CanvasPencilTextGesture? {
            guard let first = points.first, let last = points.last,
                  let position = view.closestPosition(to:CGPoint(x:(first.x+last.x)/2,y:(first.y+last.y)/2)) else { return nil }
            let offset = view.offset(from:view.beginningOfDocument,to:position)
            var widths: [CGFloat] = []
            for location in [offset-1,offset] {
                guard let range = canvasSelectedCharacterRange(in:view.text,selection:NSRange(location:location,length:1)),
                      let start = view.position(from:view.beginningOfDocument,offset:range.location),
                      let end = view.position(from:start,offset:range.length),
                      let textRange = view.textRange(from:start,to:end) else { continue }
                widths += view.selectionRects(for:textRange).map(\.rect.width).filter { $0 > 0 && $0.isFinite }
            }
            guard let width = widths.min() else { return nil }
            return CanvasPencilTextCorrection.gesture(for:points,minimumEraseWidth:max(1,min(24,width*0.8)))
        }
        func correctionRange(_ points: [CGPoint], gesture: CanvasPencilTextGesture,
                                     in view: UITextView) -> NSRange? {
            guard !points.isEmpty, points.count <= 4096,
                  points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                  let first = points.first, let last = points.last else { return nil }
            let center = CGPoint(x:(first.x + last.x)/2,y:(first.y + last.y)/2)
            if gesture != .erase {
                guard let position = view.closestPosition(to:center) else { return nil }
                let caret = NSRange(location:view.offset(from:view.beginningOfDocument,to:position),length:0)
                if gesture == .join {
                    guard let edit = CanvasPencilTextCorrection.edit(in:view.text,gesture:.join,range:caret),
                          let start = view.position(from:view.beginningOfDocument,offset:edit.range.location),
                          let end = view.position(from:start,offset:edit.range.length),
                          let range = view.textRange(from:start,to:end),
                          view.selectionRects(for:range).contains(where:{ $0.rect.width > 0 && $0.rect.insetBy(dx:-3,dy:0).contains(center) }) else { return nil }
                } else if !view.caretRect(for:position).insetBy(dx:-3,dy:0).contains(center) { return nil }
                return caret
            }
            let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
            let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
            let bounds = CGRect(x:minX,y:minY,width:maxX-minX,height:maxY-minY)
            guard bounds.height <= 80, bounds.width <= 500 else { return nil }
            var hits: [(range: NSRange, rect: CGRect)] = [], offset = 0
            var firstHitY: CGFloat?
            for character in view.text {
                let length = String(character).utf16.count
                defer { offset += length }
                guard let start = view.position(from:view.beginningOfDocument,offset:offset),
                      let end = view.position(from:start,offset:length),
                      let range = view.textRange(from:start,to:end) else { return nil }
                let hitRects = view.selectionRects(for:range).map(\.rect).filter {
                    $0.width > 0 && bounds.contains(CGPoint(x:$0.midX,y:$0.midY))
                }
                if let hit = hitRects.first {
                    if let firstHitY, abs(hit.midY-firstHitY) > max(3,hit.height/2) { return nil }
                    firstHitY = firstHitY ?? hit.midY
                    if let previous = hits.last, NSMaxRange(previous.range) != offset { return nil }
                    hits.append((NSRange(location:offset,length:length),hit))
                }
            }
            // A physical scratch can cross neighbouring glyphs at this font size.
            // Its centre selects one complete Character; wider deletion stays explicit selection.
            let targets = hits.filter { hit in
                let edge = max(1,min(3,hit.rect.width * 0.15))
                return hit.rect.insetBy(dx:edge,dy:-4).contains(CGPoint(x:bounds.midX,y:bounds.midY))
            }
            guard targets.count == 1 else { return nil }
            return targets[0].range
        }
        func beginSelectionCorrection() -> CanvasPencilTextSnapshot? {
            guard isCurrent, let session, let editor, editor.isEditable,
                  editor.markedTextRange == nil, !scribbling, !correcting, pendingCorrection == nil,
                  editor.text.utf8.elementsEqual(parent.text.utf8), editor.selectedRange.length > 0,
                  canvasSelectedCharacterRange(in:editor.text,selection:editor.selectedRange) == editor.selectedRange else { return nil }
            let snapshot = CanvasPencilTextSnapshot(text:editor.text,session:session,selection:editor.selectedRange)
            pendingCorrection = snapshot
            publishInputState(editor)
            return snapshot
        }
        @discardableResult
        func confirmSelectionCorrection(_ snapshot: CanvasPencilTextSnapshot, replacement: String) -> Bool {
            guard pendingCorrection?.id == snapshot.id else { return false }
            guard selectionCorrectionIsCurrent(snapshot), let editor,
                  let edit = CanvasPencilTextCorrection.replacement(in:snapshot.text,selection:snapshot.selection,with:replacement) else {
                cancelSelectionCorrection(snapshot)
                return false
            }
            pendingCorrection = nil
            let applied = applyTextChange(edit,in:editor)
            correctionAlert?.dismiss(animated:false)
            correctionAlert = nil
            publishInputState(editor)
            return applied
        }
        func cancelSelectionCorrection(_ snapshot: CanvasPencilTextSnapshot? = nil) {
            if let snapshot, pendingCorrection?.id != snapshot.id { return }
            pendingCorrection = nil
            correctionAlert?.dismiss(animated:false)
            correctionAlert = nil
            if let editor { publishInputState(editor) }
        }
        private func selectionCorrectionIsCurrent(_ snapshot: CanvasPencilTextSnapshot) -> Bool {
            guard isCurrent, let editor, editor.isEditable, editor.markedTextRange == nil, !scribbling, !correcting else { return false }
            return snapshot.matches(text:editor.text,session:parent.editSession(),selection:editor.selectedRange) &&
                parent.text.utf8.elementsEqual(snapshot.text.utf8)
        }
        fileprivate func invalidateSelectionCorrection() {
            if let snapshot = pendingCorrection, !selectionCorrectionIsCurrent(snapshot) {
                cancelSelectionCorrection(snapshot)
            }
        }
        @objc private func showSelectionCorrection() {
            guard let editor else { return }
            var responder: UIResponder? = editor
            while responder != nil && !(responder is UIViewController) { responder = responder?.next }
            guard let presenter = responder as? UIViewController, presenter.presentedViewController == nil,
                  let snapshot = beginSelectionCorrection(),
                  let range = Range(snapshot.selection,in:snapshot.text) else { return }
            let alert = UIAlertController(title:"선택 글자 교정",
                message:"적용 결과: \(String(snapshot.text[range]).debugDescription)\n직접 입력하거나 iOS 손글씨 입력을 사용하세요.",preferredStyle:.alert)
            alert.addTextField { field in
                field.text = String(snapshot.text[range])
                field.placeholder = "바꿀 글자 직접 입력"
                field.accessibilityIdentifier = "canvasSelectedTextCorrectionInput"
                field.autocorrectionType = .no
                field.smartQuotesType = .no
                field.smartDashesType = .no
                field.smartInsertDeleteType = .no
            }
            let field = alert.textFields?.first
            var input = CanvasPencilTextCorrectionInput(text:snapshot.text,selection:snapshot.selection,raw:field?.text ?? "")
            let apply = UIAlertAction(title:"적용",style:.default) { [weak self, weak field] _ in
                guard let self else { return }
                guard let field, field.markedTextRange == nil,
                      input.raw.utf8.elementsEqual((field.text ?? "").utf8) else { self.cancelSelectionCorrection(snapshot); return }
                self.confirmSelectionCorrection(snapshot,replacement:input.preferred)
            }
            let rawApply = UIAlertAction(title:"입력 그대로 적용",style:.default) { [weak self, weak field] _ in
                guard let self else { return }
                guard let field, field.markedTextRange == nil,
                      input.raw.utf8.elementsEqual((field.text ?? "").utf8) else { self.cancelSelectionCorrection(snapshot); return }
                self.confirmSelectionCorrection(snapshot,replacement:input.raw)
            }
            apply.isEnabled = false
            rawApply.isEnabled = false
            field?.addAction(UIAction { [weak field, weak alert, weak apply, weak rawApply] _ in
                guard let field, let alert, let apply, let rawApply else { return }
                input = CanvasPencilTextCorrectionInput(text:snapshot.text,selection:snapshot.selection,raw:field.text ?? "")
                var message = "적용 결과: \(input.preferred.debugDescription)"
                if input.word != nil {
                    message += "\n단어 적용은 바깥 공백과 분리된 마침표를 정리합니다.\n입력 그대로 적용: \(input.raw.debugDescription)"
                }
                alert.message = message
                apply.isEnabled = field.markedTextRange == nil &&
                    CanvasPencilTextCorrection.replacement(in:snapshot.text,selection:snapshot.selection,with:input.preferred) != nil
                rawApply.isEnabled = input.word != nil && field.markedTextRange == nil &&
                    CanvasPencilTextCorrection.replacement(in:snapshot.text,selection:snapshot.selection,with:input.raw) != nil
            },for:.editingChanged)
            alert.addAction(UIAlertAction(title:"취소",style:.cancel) { [weak self] _ in self?.cancelSelectionCorrection(snapshot) })
            alert.addAction(rawApply)
            alert.addAction(apply)
            alert.preferredAction = apply
            correctionAlert = alert
            presenter.present(alert,animated:true)
        }
        @available(iOS 16.0, *)
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard textView === editor, isCurrent, textView.isEditable, textView.markedTextRange == nil,
                  !scribbling, !correcting, pendingCorrection == nil,
                  range == textView.selectedRange, range.length > 0,
                  canvasSelectedCharacterRange(in:textView.text,selection:range) == range else {
                return UIMenu(children:suggestedActions)
            }
            let source = textView.text ?? ""
            let action = UIAction(title:"선택 글자 교정…") { [weak self, weak textView] _ in
                guard let textView, textView.selectedRange == range,
                      textView.text.utf8.elementsEqual(source.utf8) else { return }
                self?.showSelectionCorrection()
            }
            return UIMenu(children:suggestedActions + [action])
        }
        @objc private func eraseSelection() {
            guard isCurrent, let editor, editor.isEditable, editor.markedTextRange == nil, !scribbling, !correcting, pendingCorrection == nil,
                  let range = canvasSelectedCharacterRange(in:editor.text,selection:editor.selectedRange),
                  let start = editor.position(from:editor.beginningOfDocument,offset:range.location),
                  let end = editor.position(from:start,offset:range.length),
                  let selected = editor.textRange(from:start,to:end) else { return }
            editor.selectedTextRange = selected
            editor.deleteBackward()
            textViewDidChange(editor)
        }
        @objc private func undoEdit() {
            guard isCurrent, let editor, editor.isEditable, editor.markedTextRange == nil, !scribbling, !correcting, pendingCorrection == nil else { return }
            editor.undoManager?.undo()
            textViewDidChange(editor)
        }
        @objc private func redoEdit() {
            guard isCurrent, let editor, editor.isEditable, editor.markedTextRange == nil, !scribbling, !correcting, pendingCorrection == nil else { return }
            editor.undoManager?.redo()
            textViewDidChange(editor)
        }
        func textViewDidChange(_ view: UITextView) {
            guard !updating, isCurrent, view === editor else { return }
            invalidateSelectionCorrection()
            parent.text = view.text
            parent.selection = view.selectedRange
            publishInputState(view)
        }
        func textViewDidChangeSelection(_ view: UITextView) {
            guard !updating, isCurrent, view === editor else { return }
            invalidateSelectionCorrection()
            parent.selection = view.selectedRange
            publishInputState(view)
        }
    }
}

#if !os(visionOS)
extension VaultMarkdownEditor.Coordinator: UIScribbleInteractionDelegate {
    func scribbleInteraction(_ interaction: UIScribbleInteraction, shouldBeginAt location: CGPoint) -> Bool {
        isCurrent && !correctionEnabled && pendingCorrection == nil && editor?.isEditable == true
    }
    func scribbleInteractionWillBeginWriting(_ interaction: UIScribbleInteraction) {
        guard isCurrent else { return }
        cancelSelectionCorrection()
        scribbling = true
        if let editor { publishInputState(editor) }
    }
    func scribbleInteractionDidFinishWriting(_ interaction: UIScribbleInteraction) {
        guard isCurrent else { return }
        scribbling = false
        if let editor { textViewDidChange(editor) }
    }
}
#endif


private final class PencilTextGestureRecognizer: UIGestureRecognizer {
    var onTracking: ((Bool) -> Void)?
    var onPoints: (([CGPoint]) -> Void)?
    var onStroke: (([CGPoint]) -> Void)?
    private var points: [CGPoint] = []
    private var started: TimeInterval = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, let touch = touches.first, touch.type == .pencil else {
            state = .failed; return
        }
        started = touch.timestamp
        points = [touch.location(in:view)]
        state = .began
        onTracking?(true)
        onPoints?(points)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .began || state == .changed, let touch = touches.first,
              touch.type == .pencil else { return }
        guard touch.timestamp - started <= 2, points.count < 500 else { state = .cancelled; return }
        points.append(contentsOf:(event.coalescedTouches(for:touch) ?? [touch]).map { $0.location(in:view) })
        state = .changed
        onPoints?(points)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .began || state == .changed, let touch = touches.first,
              touch.type == .pencil else { return }
        points.append(touch.location(in:view))
        state = .ended
        onTracking?(false)
        if touch.timestamp - started <= 2, points.count <= 500 { onStroke?(points) }
        onPoints?([])
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }
    override func reset() {
        super.reset()
        points = []
        onTracking?(false)
        onPoints?([])
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
            .rotationEffect(.radians(node.rotationRadians))
            .onTapGesture { store.select(node.id) }
            .accessibilityElement(children:.combine)
            .accessibilityIdentifier("canvasNode-\(node.id.uuidString)")
            .accessibilityValue(node.isCollapsed == true ? "하위 요소 접힘" : "하위 요소 펼침")
            .gesture(DragGesture(coordinateSpace:.named("canvasScene")).onChanged { value in
                guard store.nodeResizeDrag == nil, store.nodeRotationDrag == nil, store.endpointDrag == nil,
                      store.scene.visibility.nodeIDs.contains(node.id) else { return }
                if dragOrigin == nil { dragOrigin = CanvasPoint(x:node.frame.x,y:node.frame.y) }
                guard let dragOrigin else { return }
                store.selectedNode = node.id
                store.moveSelected(to:CGPoint(
                    x:dragOrigin.x+value.translation.width,
                    y:dragOrigin.y+value.translation.height))
            }.onEnded { _ in dragOrigin = nil })
    }
}
