import SwiftUI

struct CurrentVoicePIP: View {
    let projection: ControlRoomProjection?
    let message: String?
    let expand: () -> Void
    let drag: AnyGesture<DragGesture.Value>

    var body: some View {
        TimelineView(.periodic(from:.now,by:5)) { context in
            let fresh = projection?.isFresh(now:context.date) == true
            let card = projection?.hasDisplayContent == true ? projection?.availableVoiceCard : nil
            let session = fresh ? projection?.observedSession(now:context.date) : nil
            VStack(alignment:.leading,spacing:0) {
                HStack {
                    Label("현재 음성 대화",systemImage:"waveform")
                    Spacer(minLength:4)
                    Image(systemName:"line.3.horizontal")
                }
                .font(.caption).padding(.horizontal,12).frame(height:34)
                .contentShape(Rectangle()).gesture(drag)
                .accessibilityLabel("음성 카드 이동")
                Button(action:expand) {
                    VStack(alignment:.leading,spacing:5) {
                        Text(card?.displayTitle ?? "현재 카드 미확인").font(.headline).lineLimit(1)
                        Text(card?.isAvailable == true ? card?.status ?? "상태 미제공" : "카드 사용 가능 상태 미확인")
                            .font(.caption)
                        if let progress = card?.latestProgress?.text {
                            Text(progress).font(.caption).lineLimit(2)
                        }
                        Text(session == nil ? "열린 음성 세션 미확인" : "음성 세션 관측됨")
                            .font(.caption).foregroundStyle(session == nil ? .secondary : .primary)
                        if let id = projection?.hasDisplayContent == true ? projection?.activeVoiceId : nil {
                            Text("대화 \(id)").font(.caption2).lineLimit(1).truncationMode(.middle)
                        }
                        if !fresh {
                            Text(message ?? "연결 또는 원본 관측이 오래되었습니다. 마지막 내용 · 읽기 전용")
                                .font(.caption2).foregroundStyle(.orange).lineLimit(3)
                        }
                        if let session {
                            Text("세션 \(session.sessionId)").font(.caption2).lineLimit(1).truncationMode(.middle)
                        } else if let message {
                            Text(message).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        } else if !fresh {
                            Text("최신 표시 정보 확인 필요").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).padding(12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(card == nil || !fresh).accessibilityIdentifier("currentVoicePIP")
                .accessibilityHint("현재 컨트롤룸 카드 펼치기")
            }
            .background(.regularMaterial,in:RoundedRectangle(cornerRadius:16))
            .overlay(RoundedRectangle(cornerRadius:16).stroke(.secondary.opacity(0.4)))
            .clipShape(RoundedRectangle(cornerRadius:16))
        }
    }
}

struct ControlRoomGrid: View {
    let projection: ControlRoomProjection?
    let message: String?
    @Binding var selection: ControlRoomNavigationSelection
    let expand: (ControlRoomCardReference) -> Void

    var body: some View {
        TimelineView(.periodic(from:.now,by:5)) { context in
            if let projection, projection.hasDisplayContent {
                let navigation = ControlRoomNavigation(projection:projection)
                let target = navigation.target(for:selection)
                VStack(alignment:.leading,spacing:6) {
                    controls(navigation)
                        .disabled(!projection.isFresh(now:context.date))
                    if !projection.isFresh(now:context.date) {
                        Text(message ?? "연결 또는 원본 관측이 오래되었습니다. 마지막 내용 · 읽기 전용")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("대화 · 3×3 · 읽기 전용 · \(projection.generatedAt)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    brainTrinityStatus(projection,now:context.date)
                    ControlRoomSourcePanel(projection:projection,now:context.date)
                    if target == .unavailable {
                        ContentUnavailableView("선택한 작업 공간 없음",systemImage:"square.grid.3x3",
                                               description:Text("섹션 또는 프로젝트를 다시 선택하세요."))
                    } else {
                        GeometryReader { geometry in
                            ScrollView([.horizontal,.vertical]) {
                                LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:ControlRoomGridGeometry.spacing),
                                                        count:ControlRoomGridGeometry.columns),spacing:ControlRoomGridGeometry.spacing) {
                                    ForEach(projection.slots(layoutID:target.layoutID)) { slot in
                                        slotCard(slot,projection:projection,target:target,now:context.date)
                                    }
                                }
                                .frame(width:ControlRoomGridGeometry.width(available:geometry.size.width))
                            }
                            .accessibilityIdentifier("controlRoomConversationGrid")
                        }
                    }
                }
                .padding(10)
            } else {
                ContentUnavailableView("컨트롤룸 미확인",systemImage:"square.grid.3x3",
                                       description:Text(message ?? "최신 표시 정보를 기다립니다."))
            }
        }
    }

    @ViewBuilder
    private func brainTrinityStatus(_ projection: ControlRoomProjection, now: Date) -> some View {
        if let feed = projection.freshBrainTrinity(now:now), let mode = feed.mode {
            Text(["브레인트리니티 \(mode.localizedTitle)",feed.reason,
                  "활동 \(feed.activities.count) · 검토 \(feed.reviewRequests.count)","읽기 전용"]
                .compactMap { $0 }.joined(separator:" · "))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                .accessibilityIdentifier("brainTrinityStatus")
        } else {
            Text("BT 피드 미확인 · 읽기 전용").font(.caption2).foregroundStyle(.secondary)
                .accessibilityIdentifier("brainTrinityStatus")
        }
    }

    private func brainTrinityBadges(_ badges: BrainTrinityBadges) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing:4) {
                ForEach(badges.activities) { activity in
                    Text("브레인트리니티 \(activity.phase.localizedTitle) · \(activity.key)")
                        .help(activity.reference.summary)
                        .accessibilityLabel("브레인트리니티 활동 \(activity.key), \(activity.phase.localizedTitle), \(activity.reference.summary)")
                }
                ForEach(badges.reviews) { review in
                    Text("BT 검토 · 읽기 전용 · \(review.id)")
                        .help(review.reference.summary)
                        .accessibilityLabel("BT 검토 읽기 전용, \(review.id), \(review.reference.summary)")
                }
            }
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("brainTrinityBadges")
    }

    private func controls(_ navigation: ControlRoomNavigation) -> some View {
        let section = navigation.sections.first(where: { $0.id == selection.sectionID })
        return ScrollView(.horizontal) {
            HStack(spacing:6) {
                VStack(alignment:.leading,spacing:0) {
                    Text("섹션").font(.caption2).foregroundStyle(.secondary)
                    Picker("섹션",selection:Binding(get:{ selection.sectionID },set:{ id in
                        selection.sectionID = id
                        selection.projectID = nil
                    })) {
                        ForEach(navigation.sections) { option in Text(option.label).tag(option.id) }
                    }
                    .accessibilityLabel("컨트롤룸 섹션")
                    .accessibilityValue(navigation.sections.first(where: { $0.id == selection.sectionID })?.label ?? "미확인")
                    .accessibilityIdentifier("controlRoomSection")
                }
                Image(systemName:"chevron.right").accessibilityHidden(true)
                VStack(alignment:.leading,spacing:0) {
                    Text("필터").font(.caption2).foregroundStyle(.secondary)
                    Picker("필터",selection:$selection.filter) {
                        ForEach(ControlRoomStatusFilter.allCases) { filter in Text(filter.localizedTitle).tag(filter) }
                    }
                    .accessibilityLabel("대화 상태 필터")
                    .accessibilityValue(selection.filter.localizedTitle)
                    .accessibilityIdentifier("controlRoomStatusFilter")
                }
                Image(systemName:"chevron.right").accessibilityHidden(true)
                VStack(alignment:.leading,spacing:0) {
                    Text("프로젝트").font(.caption2).foregroundStyle(.secondary)
                    Picker("프로젝트",selection:Binding(get:{ selection.projectID },set:{ id in
                        selection.projectID = id
                    })) {
                        Text("섹션 3×3").tag(nil as ControlRoomProjectID?)
                        ForEach(section?.projects ?? []) { option in
                            Text(option.label + (option.workspaceID == nil ? " · workspace 미제공" : ""))
                                .tag(Optional(option.id)).disabled(option.workspaceID == nil)
                        }
                    }
                    .accessibilityLabel("컨트롤룸 프로젝트")
                    .accessibilityValue(section?.projects.first(where: { $0.id == selection.projectID })?.label ?? "섹션 3×3")
                    .accessibilityIdentifier("controlRoomProject")
                }
            }
            .pickerStyle(.menu).font(.callout).fixedSize(horizontal:true,vertical:false)
        }
        .scrollIndicators(.hidden)
    }

    private func slotCard(_ slot: ControlRoomSlot, projection: ControlRoomProjection,
                          target: ControlRoomGridTarget, now: Date) -> some View {
        let matches = selection.filter.matches(slot)
        let card = slot.availableCard
        let badges = projection.brainTrinityBadges(layoutID:target.layoutID,index:slot.index,now:now)
        return Button {
            if let card { expand(.slot(layoutID:target.layoutID,index:slot.index,threadId:card.id)) }
        } label: {
            Color(uiColor:.secondarySystemBackground)
                .aspectRatio(ControlRoomGridGeometry.aspectRatio,contentMode:.fit)
                .overlay(alignment:.topLeading) {
                    VStack(alignment:.leading,spacing:4) {
                        HStack {
                            Text("\(slot.index+1) · \(slot.sourceKindLabel)").lineLimit(1)
                            Spacer(minLength:2)
                            if !matches { Text("필터 불일치").lineLimit(1) }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                        Text(slot.displayTitle ?? projection.projectLabel(for:slot) ??
                             (slot.threadId == nil ? "빈 슬롯" : "대화 확인 불가"))
                            .font(.callout.weight(.semibold)).lineLimit(2)
                        if !badges.activities.isEmpty || !badges.reviews.isEmpty {
                            brainTrinityBadges(badges)
                        }
                        if let project = projection.project(for:slot), project.displayLabel != project.label {
                            Text(project.label).font(.caption2).lineLimit(1)
                        }
                        if let card {
                            HStack(spacing:4) {
                                Image(systemName:card.needsInput ? "exclamationmark.bubble" :
                                    card.isRunning ? "play.circle" : "circle")
                                Text(card.status ?? "상태 미제공")
                                if let turn = card.turnStatus { Text("· \(turn)") }
                            }
                            .font(.caption).lineLimit(1)
                            .foregroundStyle(card.needsInput ? Color.orange : Color.primary)
                            if let request = card.inputRequestSummary {
                                Text("입력 요청 · \(request)").font(.caption).lineLimit(2)
                            }
                            if let progress = card.latestProgress?.text {
                                Text(progress).font(.caption).lineLimit(2)
                            }
                        } else if let reason = slot.availabilityLabel {
                            Text(reason).font(.caption).foregroundStyle(.orange).lineLimit(2)
                        }
                    }
                    .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).padding(10)
                }
                .clipShape(RoundedRectangle(cornerRadius:12))
                .overlay(RoundedRectangle(cornerRadius:12).stroke(card?.needsInput == true ? Color.orange : Color.secondary.opacity(0.3)))
                .opacity(matches ? 1 : 0.45)
        }
        .buttonStyle(.plain).disabled(card == nil || !projection.isFresh(now:now))
        .accessibilityElement(children:.combine)
        .accessibilityIdentifier("controlRoomSlot-\(slot.index)")
        .accessibilityHint(card == nil ? "읽기 전용. 현재 연결된 대화가 없습니다." :
            matches ? "대화 상세 보기" : "필터 불일치. 원래 슬롯 위치를 유지합니다.")
    }
}

private struct ControlRoomSourcePanel: View {
    let projection: ControlRoomProjection
    let now: Date
    @State private var expanded = false
    @State private var selection = ControlRoomSourceSelection()

    var body: some View {
        DisclosureGroup("소스·세션",isExpanded:$expanded) {
            VStack(alignment:.leading,spacing:6) {
                HStack {
                    Picker("소스",selection:Binding(get:{ selection.source },set:{ source in
                        selection.reconcile(projection)
                        selection.select(source:source)
                    })) {
                        ForEach(ControlRoomSource.allCases) { source in Text(source.label).tag(source) }
                    }
                    .pickerStyle(.menu).accessibilityIdentifier("controlRoomSource")
                    Spacer(minLength:4)
                    Text("조회·선택 전용").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView(.vertical) {
                    VStack(alignment:.leading,spacing:5) {
                        summary
                        if let session = selection.session(in:projection) {
                            details(session)
                        } else {
                            Text("세션을 선택하세요. 사라지거나 식별자가 바뀐 세션은 자동 승계하지 않습니다.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth:.infinity,alignment:.leading)
                    .textSelection(.enabled)
                }
                .frame(maxHeight:130)
                sessionList
            }
            .font(.caption)
            .padding(.top,4)
        }
        .accessibilityIdentifier("controlRoomSourceSessions")
        .onChange(of:projection.sourceSelectionContext,initial:true) { _,_ in selection.reconcile(projection) }
    }

    private var summary: some View {
        VStack(alignment:.leading,spacing:4) {
            if let summary = projection.sourceSummary(for:selection.source) {
                Text("소스 전체 요약 · \(summary.label)")
                Text("요약 관측 · \(summary.observedAt ?? "미제공")")
                if let reason = summary.reason { Text("소스 안내 · \(reason)") }
            } else {
                Text("소스 전체 요약 미제공")
            }
            Text("요약 연결은 개별 세션의 연결·권한을 뜻하지 않습니다.")
                .foregroundStyle(.secondary)
            if !projection.isFresh(now:now) {
                Text("마지막 관측 · 읽기 전용").foregroundStyle(.orange)
            }
            if let unified = projection.unifiedControl {
                if unified.schema != 1 { Text("미지원 소스·세션 형식").foregroundStyle(.orange) }
                if let error = unified.error { Text("소스 조회 안내 · \(error)").foregroundStyle(.orange) }
                if unified.truncated { Text("일부 세션만 제공됨").foregroundStyle(.orange) }
                let unsupported = projection.sourceSessions.filter { !$0.isSupported }.count
                if unsupported > 0 { Text("미지원 소스 행 \(unsupported)개").foregroundStyle(.orange) }
            } else {
                Text("소스·세션 정보 미제공 · 기존 관제만 지원")
            }
        }
    }

    private var sessionList: some View {
        let sessions = projection.sessions(for:selection.source)
        return VStack(alignment:.leading,spacing:3) {
            HStack {
                Text("\(selection.source.label) 세션 \(sessions.count)개")
                Spacer()
                if selection.sessionID != nil {
                    Button("선택 해제") { selection.clear() }.buttonStyle(.borderless)
                }
            }
            ScrollView(.vertical) {
                LazyVStack(alignment:.leading,spacing:3) {
                    if sessions.isEmpty { Text("표시할 세션 없음").foregroundStyle(.secondary) }
                    ForEach(sessions) { session in
                        Button {
                            selection.select(session:session,in:projection)
                        } label: {
                            VStack(alignment:.leading,spacing:2) {
                                Label(session.titleLabel,systemImage:selection.sessionID == session.id ? "checkmark.circle.fill" : "circle")
                                Text([session.sessionId ?? "세션 미제공",session.runId ?? "실행 미제공",session.hostId]
                                    .compactMap { $0 }.joined(separator:" · "))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth:.infinity,minHeight:44,alignment:.leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("controlRoomSourceSession")
                        .accessibilityAddTraits(selection.sessionID == session.id ? .isSelected : [])
                    }
                }
            }
            .frame(maxHeight:100)
            .accessibilityIdentifier("controlRoomSourceSessionList")
        }
    }

    private func details(_ row: ControlRoomSourceSession) -> some View {
        VStack(alignment:.leading,spacing:4) {
            Text(row.titleLabel).font(.callout.weight(.semibold))
            Text("조회·선택 전용 · 이 화면은 읽기 전용입니다.")
            if selection.source == .cursorCloud {
                if let display = selection.resultDisplay(in:projection,now:now) {
                    Text("Cloud \(display.label) · 대화 기록 아님").font(.callout.weight(.semibold))
                    if display.text.isEmpty {
                        Text("\(display.label)이 비어 있습니다.")
                    } else {
                        Text(verbatim:display.text).textSelection(.enabled)
                            .accessibilityIdentifier(display.isCurrent ? "controlRoomCurrentResult" : "controlRoomLastObservedResult")
                    }
                } else {
                    Text("현재 응답이 미제공이거나 조회 조건을 충족하지 않습니다.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("이 소스의 현재 응답 본문은 미지원입니다.").foregroundStyle(.secondary)
            }
            field("원본 상태",row.status)
            field("실행 상태",row.executionStatus)
            field("표시 상태",row.displayStatus)
            field("상태 출처",row.statusSource)
            field("에이전트 상태",row.agentStatus)
            field("행 연결 상태",row.connectionState)
            if selection.source == .cursorCloud {
                Text("행 읽기 관측 · \(selection.resultDisplay(in:projection,now:now)?.label ?? "본문 미제공")")
            } else {
                Text("행 관측 · \(row.isFresh(now:now) ? "최신" : "최신성 미확인")")
            }
            field("행 관측 시각",row.observedAt)
            field("행 연결 시각",row.connectedAt)
            field("소스 버전",row.sourceRevision?.formatted)
            field("외부 식별자",row.externalId)
            field("세션",row.sessionId)
            field("실행",row.runId)
            field("호스트",row.hostId)
            field("인스턴스",row.instanceId)
            field("시작 시각",row.startedAt)
            field("작업 공간",row.workspaceIdentity)
            field("프로젝트",row.projectId)
            field("행 키",row.key)
            field("원본 원담당",row.ownerThreadId)
            Text("확인된 원담당 · \(row.ownerLabel)")
            field("Codex 대화",row.threadId)
            field("Codex 활성 실행",row.activeTurnId)
            Text("행 보고 권한 · 조회 \(flag(row.capabilities?.read)) · 전송 \(flag(row.capabilities?.send)) · 읽기 전용 \(flag(row.readOnly))")
            Text("현재 행 기준 전송 조건 · \(row.reportedSendAllowed(now:now) && projection.isFresh(now:now) ? "보고됨" : "미확인 또는 불가") · 이 화면에서는 실행 미지원")
            Text(row.sessionConnection(now:now).label)
            if let connection = row.sourceConnection {
                field("개별 연결 제공자",connection.provider)
                field("개별 연결 상태",connection.state)
                field("개별 연결 관측",connection.observedAt)
                field("개별 연결 시작",connection.connectedAt)
                field("개별 연결 원담당",connection.owner)
                field("개별 연결 세션",connection.sessionId)
                field("개별 연결 실행",connection.runId)
                field("개별 연결 버전",connection.sourceRevision?.formatted)
                Text("개별 연결 보고 권한 · 조회 \(flag(connection.capabilities?.read)) · 전송 \(flag(connection.capabilities?.send)) · 읽기 전용 \(flag(connection.readOnly))")
                if let reason = connection.reason { field("개별 연결 안내",reason) }
            }
        }
        .accessibilityIdentifier("controlRoomSourceSessionDetail")
    }

    private func field(_ label: String, _ value: String?) -> some View {
        Text("\(label) · \(value ?? "미제공")").font(.caption)
            .frame(maxWidth:.infinity,alignment:.leading)
    }
    private func flag(_ value: Bool?) -> String {
        value.map { $0 ? "예" : "아니요" } ?? "미확인"
    }
}

struct ControlRoomCardDetail: View {
    let reference: ControlRoomCardReference
    let projection: ControlRoomProjection?
    let message: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from:.now,by:5)) { context in
                if let projection, projection.hasDisplayContent, let card = reference.card(in:projection) {
                    ScrollView {
                        VStack(alignment:.leading,spacing:16) {
                            if !projection.isFresh(now:context.date) {
                                Text(message ?? "연결 또는 원본 관측이 오래되었습니다. 마지막 내용 · 읽기 전용")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            Text(card.displayTitle).font(.title2)
                            Text("대화 \(card.id)").font(.caption).textSelection(.enabled)
                            Text(card.status ?? "상태 미제공")
                            if let project = card.project { Text("프로젝트 \(project)").font(.caption) }
                            if let turn = card.turnStatus { Text("턴 \(turn)") }
                            if let progress = card.latestProgress?.text {
                                Text("최근 진행").font(.headline)
                                Text(progress).textSelection(.enabled)
                            }
                            if let user = card.latestUser?.text {
                                Text("최근 사용자 입력").font(.headline)
                                Text(user).textSelection(.enabled)
                            }
                            if let tools = card.activeTools, !tools.isEmpty {
                                Text("실행 도구 \(tools.joined(separator:", "))").font(.caption)
                            }
                            if let pending = card.pendingTools, pending > 0 {
                                Text("대기 도구 \(pending)").font(.caption)
                            }
                            if case .voice = reference {
                                if let session = projection.observedSession(now:context.date) {
                                    Text("관측된 세션 \(session.sessionId)").textSelection(.enabled)
                                    Text("관측 시각 \(session.observedAt)").font(.caption)
                                } else { Text("열린 음성 세션 미확인") }
                            }
                            evidence("음성 기록",card.voiceState)
                            evidence("목표",card.goal)
                            evidence("입력·승인 요청",card.inputRequest)
                            ForEach(card.events ?? []) { event in
                                VStack(alignment:.leading,spacing:4) {
                                    Text([event.role,event.kind,event.ts].compactMap { $0 }.joined(separator:" · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let text = event.text { Text(text).textSelection(.enabled) }
                                    if let source = event.source { Text(source).font(.caption2).foregroundStyle(.secondary) }
                                    if let session = event.voiceSessionId { Text("세션 \(session)").font(.caption2) }
                                }
                                Divider()
                            }
                            evidence("실행 관측",card.executions)
                            Text([card.source,card.provenance,card.owner,card.permission,card.result,card.observedAt]
                                .compactMap { $0 }.joined(separator:"\n"))
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }.frame(maxWidth:.infinity,alignment:.leading).padding()
                    }
                } else {
                    ContentUnavailableView("현재 카드 미확인",systemImage:"waveform",
                                           description:Text(message ?? "최신 원본 카드가 없습니다."))
                }
            }
            .navigationTitle("컨트롤룸 카드")
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("닫기") { dismiss() } } }
        }
    }

    @ViewBuilder
    private func evidence(_ title: String, _ value: ProjectionValue?) -> some View {
        if let value {
            DisclosureGroup(title) {
                Text(value.formatted).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth:.infinity,alignment:.leading)
            }
        }
    }
}
