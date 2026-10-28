#!/usr/bin/env python3
from pathlib import Path
import difflib
import shutil
import sys
root=Path(__file__).resolve().parents[3]

def changes():
    out={}
    p='iOSClient/CanvasBridge/CanvasStore.swift'; s=(root/p).read_text()
    mark='    @Published private(set) var inkSelection: Set<UUID> = []'
    insert='''    @Published private(set) var inkMathProposal: CanvasInkMathProposal?
    @Published var inkMathDraft = ""
    @Published var inkMathInputBusy = false
    private var inkMathRequest: UUID?
    private var inkMathGeneration: UInt64?
    private var inkMathSelectionGeneration: UInt64 = 0
    private var inkMathExpectedSelectionGeneration: UInt64?
    var inkMathIsCurrent: Bool {
        guard let proposal = inkMathProposal else { return false }
        return !inkBusy && mode == .lasso && proposal.source == scene &&
            proposal.selection == inkSelection && inkMathGeneration == linkSceneGeneration &&
            inkMathExpectedSelectionGeneration == inkMathSelectionGeneration
    }
    func cancelInkMath() { inkMathRequest = nil; inkMathProposal = nil; inkMathInputBusy = false }

    func proposeInkMath(recognize: (PKDrawing) async -> String? = { drawing in
        let recognizer = PKStrokeRecognizer()
        await recognizer.updateDrawing(drawing)
        return await recognizer.recognizedText()
    }) async {
        cancelInkMath()
        guard !inkBusy, mode == .lasso else { status = "영역 선택 도구로 수식을 먼저 선택하세요."; return }
        do {
            let snapshot = try CanvasInkMathProposal.capture(scene:scene,drawing:drawing,selection:inkSelection,recognized:nil)
            let request = UUID(), generation = linkSceneGeneration, selectionGeneration = inkMathSelectionGeneration
            inkMathRequest = request
            let recognized = await recognize(snapshot.original)
            guard inkMathRequest == request, generation == linkSceneGeneration,
                  selectionGeneration == inkMathSelectionGeneration, snapshot.source == scene,
                  snapshot.selection == inkSelection, mode == .lasso, !inkBusy else { return }
            inkMathRequest = nil
            inkMathProposal = try CanvasInkMathProposal.capture(scene:scene,drawing:drawing,selection:inkSelection,recognized:recognized)
            inkMathDraft = recognized ?? ""
            inkMathGeneration = generation
            inkMathExpectedSelectionGeneration = selectionGeneration
            status = recognized == nil ? "인식 후보가 없습니다. 원본을 보며 식을 직접 교정하세요." : "인식 후보를 원본과 비교하고 식을 교정한 뒤 확정하세요."
        } catch { status = error.localizedDescription }
    }

    @discardableResult
    func confirmInkMath() -> Bool {
        guard inkMathIsCurrent, !inkMathInputBusy, let proposal = inkMathProposal else {
            status = "원본·선택이 바뀌었거나 입력 중입니다. 현재 초안과 원본을 유지합니다."
            return false
        }
        do {
            let before = scene
            let next = try proposal.confirmed(in:scene,selection:inkSelection,expression:inkMathDraft)
            try persistScene(next)
            scene = next
            recordGraphEdit(before:before)
            cancelInkMath()
            status = "확인한 수식과 계산 결과를 메모로 저장했습니다. 원본 획은 보존했습니다."
            return true
        } catch { status = error.localizedDescription; return false }
    }

'''
    assert s.count(mark)==1;s=s.replace(mark,insert+mark)
    s=s.replace('            linkSceneGeneration &+= 1','            inkMathRequest = nil\n            linkSceneGeneration &+= 1',1)
    s=s.replace('            if oldValue != mode {','            if oldValue != mode {\n                cancelInkMath()',1)
    s=s.replace('        inkSelection = next\n','        inkMathRequest = nil\n        inkMathSelectionGeneration &+= 1\n        inkSelection = next\n',1)
    out[p]=s
    p='iOSClient/CanvasBridge/CanvasWorkspace.swift';s=(root/p).read_text()
    s=s.replace('    @State private var proposalInputBusy = false','    @State private var proposalInputBusy = false\n    @State private var mathSelection = NSRange(location:0,length:0)',1)
    s=s.replace('        .onDisappear { dictation.cancel();','''        .sheet(item:Binding(get:{ store.inkMathProposal },set:{ if $0 == nil { store.cancelInkMath() } })) { _ in inkMathSheet }
        .onDisappear { store.cancelInkMath(); dictation.cancel();''',1)
    s=s.replace('            Button("상자")','''            Button("선택한 수식 계산",systemImage:"function") { Task { await store.proposeInkMath() } }
                .disabled(store.inkSelection.isEmpty || store.mode != .lasso || store.inkBusy)
                .accessibilityIdentifier("canvasProposeInkMath")
            Button("상자")''',1)
    mark='    private var proposalSheet: some View {'
    insert='''    private var inkMathSheet: some View {
        NavigationStack {
            Form {
                if let proposal = store.inkMathProposal {
                    CanvasInkMathOriginalPreview(drawing:proposal.original).frame(height:180)
                    Text("원문 인식 후보: \\(proposal.recognizedText ?? "없음 · 직접 교정이 필요합니다")")
                    Text("원본을 보며 식만 입력하세요. 예: (1+2)÷2. Apple Pencil 손글씨 입력이나 키보드로 교정할 수 있습니다.")
                    VaultMarkdownEditor(text:$store.inkMathDraft,selection:$mathSelection,
                        identifier:"canvasInkMathEditor",label:"수식 교정 편집기",
                        inputBusy:$store.inkMathInputBusy,editSession:{ store.inkMathProposal?.id })
                        .id(proposal.id).frame(minHeight:180)
                    if let calculation = try? CanvasInkMathProposal.calculate(store.inkMathDraft) {
                        Text("계산 미리보기: \\(calculation.expression) = \\(calculation.result)")
                            .accessibilityIdentifier("canvasInkMathResult")
                    } else {
                        Text(inkMathFailure).foregroundStyle(.orange)
                    }
                    if !store.inkMathIsCurrent { Text("원본이나 선택이 바뀌었습니다. 초안은 유지하며 확정하지 않습니다.").foregroundStyle(.red) }
                    Text(store.status)
                }
            }
            .navigationTitle("수식 교정과 계산 확인")
            .toolbar {
                ToolbarItem(placement:.confirmationAction) {
                    Button("원본을 보존하고 확정") { _ = store.confirmInkMath() }
                        .disabled(!store.inkMathIsCurrent || store.inkMathInputBusy || (try? CanvasInkMathProposal.calculate(store.inkMathDraft)) == nil)
                        .accessibilityIdentifier("canvasConfirmInkMath")
                }
                ToolbarItem(placement:.cancellationAction) {
                    Button("취소") { store.cancelInkMath() }.disabled(store.inkMathInputBusy)
                }
            }
        }.interactiveDismissDisabled(store.inkMathInputBusy)
         .onAppear { mathSelection = NSRange(location:0,length:0) }
    }
    private var inkMathFailure: String {
        do { _ = try CanvasInkMathProposal.calculate(store.inkMathDraft); return "" }
        catch { return error.localizedDescription }
    }

'''
    assert mark in s;s=s.replace(mark,insert+mark);out[p]=s
    p='iOSClient/Sill.xcodeproj/project.pbxproj';s=(root/p).read_text()
    import re
    seeds=[line for line in s.splitlines(True) if 'PencilTextCorrection.swift' in line]
    mapping={v:'6A7A20261029'+str(i).zfill(12) for i,v in enumerate(sorted(set(re.findall(r'\b[A-F0-9]{24}\b',''.join(seeds)))))}
    for line in seeds:
        new=line.replace('PencilTextCorrection.swift','CanvasInkMathProposal.swift')
        for old,value in mapping.items():new=new.replace(old,value)
        s=s.replace(line,line+new)
    out[p]=s
    p='Tests/integration/ipad-runtime/CanvasBridge.xcodeproj/project.pbxproj';s=(root/p).read_text()
    s=s.replace(' objects = {',' objects = {\n  6A7A20261028000000000001 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "../../../iOSClient/CanvasBridge/CanvasInkMathProposal.swift"; sourceTree = "<group>"; };\n  6A7A20261028000000000002 = {isa = PBXBuildFile; fileRef = 6A7A20261028000000000001; };')
    s=s.replace('children = (A00000000000000000000040,','children = (6A7A20261028000000000001,A00000000000000000000040,')
    s=s.replace('files = (A00000000000000000000020,','files = (6A7A20261028000000000002,A00000000000000000000020,')
    out[p]=s
    return out

if __name__=='__main__':
    output=Path(sys.argv[1]);output.mkdir(parents=True,exist_ok=True)
    patch=''
    for name,content in changes().items():
        patch+=''.join(difflib.unified_diff((root/name).read_text().splitlines(True),content.splitlines(True),fromfile='a/'+name,tofile='b/'+name))
        target=output/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_text(content)
    source='iOSClient/CanvasBridge/CanvasInkMathProposal.swift';shutil.copyfile(root/source,output/source)
    (Path(__file__).parent/'integration.patch').write_text(patch)
