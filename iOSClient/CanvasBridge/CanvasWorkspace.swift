import PencilKit
import SwiftUI

struct CanvasWorkspace: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = CanvasStore()
    @State private var relayAddress = "http://192.168.45.4:8791"
    @State private var relayToken = ""
    @State private var connectionOpen = false
    @State private var exportOpen = false
    @State private var importOpen = false
    @State private var inspectorOpen = false
    @State private var readProjection: ControlRoomProjection?
    @State private var projectionMessage: String?
    @State private var expandedCard: ControlRoomCardReference?
    @State private var selectedThreadId: UUID?
    @State private var pipPlacement = VoicePIPPlacement()
    @State private var pipDragOrigin: CGPoint?

    init() {
        if let connection = CanvasRelay.loadConnection() {
            _relayAddress = State(initialValue:connection.address)
            _relayToken = State(initialValue:connection.token)
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
        .onChange(of:scenePhase) { _,phase in
            if phase != .active { store.saveNow() }
            else { Task { await checkConnection() } }
        }
        .task { await checkConnection() }
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
                toolsMenu
                recipientMenu
                sendButton
            }.fixedSize(horizontal:true,vertical:false)
            HStack(spacing:8) {
                toolsMenu
                recipientMenu
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
            Button("상자") { store.addNode(.box) }
            Button("메모") { store.addNode(.note) }
            Button("글자 인식") { Task { await store.proposeHandwriting() } }
            Button("화살표") { store.beginLink() }.disabled(store.selectedNode == nil)
            Button("구조 데이터",systemImage:"sidebar.right") { inspectorOpen = true }
            Button("연결",systemImage:"network") { connectionOpen = true }
            Button("가져오기") { importOpen = true }
            Button("내보내기") { exportOpen = true }
        }
    }

    private var sendButton: some View {
        Button("현재 대화로 보내기",systemImage:"paperplane.fill") {
            Task { await send() }
        }.buttonStyle(.borderedProminent).disabled(store.sendBusy)
    }

    private var recipientMenu: some View {
        Menu {
            Button("현재 음성 대화") { selectedThreadId = nil }
                .disabled(store.displayedVoice == nil)
            ForEach(readProjection?.currentGrid ?? []) { slot in
                if let card = slot.availableCard, card.source == "codex",
                   let id = UUID(uuidString:card.id) {
                    Button("\(slot.index + 1) · \(card.displayTitle)") { selectedThreadId = id }
                }
            }
        } label: {
            Label(selectedThreadId == nil ?
                  (store.displayedVoice == nil ? "받는 대화 선택" : "현재 음성 대화") :
                  "받는 대화 \(selectedThreadId?.uuidString.prefix(8) ?? "")",
                  systemImage:"person.crop.square")
        }
        .accessibilityIdentifier("canvasRecipientMenu")
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
                ForEach(store.scene.strokes) { stroke in strokeView(stroke) }
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
            guard let first = stroke.points.first else { return }
            path.move(to:CGPoint(x:first.x,y:first.y))
            for point in stroke.points.dropFirst() {
                path.addLine(to:CGPoint(x:point.x,y:point.y))
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
                Button("내용 수정") {
                    store.proposedNode = id
                    store.proposalText = node.text
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

    private var connectionSheet: some View {
        NavigationStack {
            Form {
                TextField("Mac 수신 주소",text:$relayAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("일회용 연결 토큰",text:$relayToken)
                Text("현재 열린 음성 대화와 세션을 전송 직전에 다시 확인합니다. 접수 결과가 불명확하면 같은 패킷의 영수증만 조회합니다.")
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
        let frozenDrawing = store.drawing
        let displayed = store.displayedVoice
        let selected = selectedThreadId
        let connection = relay
        let address = relayAddress
        do {
            if let pending = try store.unresolvedPacket() {
                await reconcile(pending)
                return
            }
            guard let image = SceneRenderer.png(scene:frozen,drawing:frozenDrawing) else {
                throw CanvasSendError.invalidPacket
            }
            let projection = try await connection.projection()
            store.displayedVoice = projection.activeVoiceSession
            let session: VoiceSession
            let targetMode: String?
            if let selected {
                guard let current = readProjection, current.isFresh(),
                      current.currentGrid.contains(where: { slot in
                          slot.availableCard?.source == "codex" &&
                          slot.availableCard?.id.lowercased() == selected.uuidString.lowercased()
                      }) else { throw CanvasSendError.changedSession }
                session = VoiceSession(threadId:selected,
                    sessionId:"manual:\(selected.uuidString.lowercased())",
                    observedAt:current.generatedAt)
                targetMode = "selected-chat"
            } else {
                guard projection.activeVoiceSession != nil else { throw CanvasSendError.missingTarget }
                session = try projection.session(matching:displayed)
                targetMode = nil
            }
            if let existing = try store.existingPacket(for:frozen,session:session) {
                await reconcile(existing)
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
            store.displayedVoice = try await relay.projection().activeVoiceSession
            if let pending = store.outbox.unresolved { await reconcile(pending) }
            else {
                store.status = store.displayedVoice == nil ? "연결됨 · 열린 음성 세션 없음" : "Control Room 연결됨 · 현재 음성 세션 확인"
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
        Text(node.text.isEmpty ? "내용 입력" : node.text)
            .font(.title3).frame(width:node.frame.width,height:node.frame.height)
            .foregroundStyle(Color(uiColor:CanvasPalette.nodeText))
            .background(Color(uiColor:CanvasPalette.nodeFill),
                        in:RoundedRectangle(cornerRadius:14))
            .overlay(RoundedRectangle(cornerRadius:14)
                .stroke(node.confidence == .proposal ? .orange :
                    store.selectedNode == node.id ? Color(uiColor:CanvasPalette.link) : .gray,
                    lineWidth:3))
            .onTapGesture { store.select(node.id) }
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
