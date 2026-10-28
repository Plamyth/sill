#!/usr/bin/env python3
"""원본은 읽기만 하고 적용 가능한 접합 diff와 격리 검사 입력을 만든다."""
from pathlib import Path
import difflib
import shutil
import sys
root = Path(__file__).resolve().parents[3]

def changes():
    out = {}
    path = 'iOSClient/CanvasBridge/CanvasModel.swift'
    s = (root/path).read_text().replace('case note, box }', 'case note, box, ellipse, line }')
    out[path] = s
    path = 'iOSClient/CanvasBridge/CanvasStore.swift'
    s = (root/path).read_text()
    mark = '    @Published private(set) var inkSelection: Set<UUID> = []'
    insert = '''    @Published private(set) var inkShapeProposal: CanvasInkShapeProposal?
    private var inkShapeGeneration: UInt64?
    private var inkShapeSelectionGeneration: UInt64 = 0
    private var inkShapeExpectedSelectionGeneration: UInt64?

    var inkShapeIsCurrent: Bool {
        guard let proposal = inkShapeProposal else { return false }
        return !inkBusy && mode == .lasso && proposal.source == scene &&
            proposal.selection == inkSelection && inkShapeGeneration == linkSceneGeneration &&
            inkShapeExpectedSelectionGeneration == inkShapeSelectionGeneration
    }

    func proposeInkShape() {
        cancelInkShape()
        guard !inkBusy, mode == .lasso else { status = "영역 선택 도구로 도형을 먼저 선택하세요."; return }
        do {
            inkShapeProposal = try CanvasInkShapeProposal.make(scene:scene,drawing:drawing,selection:inkSelection)
            inkShapeGeneration = linkSceneGeneration
            inkShapeExpectedSelectionGeneration = inkShapeSelectionGeneration
            status = "도형 후보를 원본과 비교한 뒤 확정하세요."
        } catch { status = error.localizedDescription }
    }

    func cancelInkShape() { inkShapeProposal = nil; inkShapeGeneration = nil; inkShapeExpectedSelectionGeneration = nil }

    @discardableResult
    func confirmInkShape() -> Bool {
        guard inkShapeIsCurrent, let proposal = inkShapeProposal else {
            status = "원본이나 선택이 바뀌어 확정하지 않았습니다."
            cancelInkShape()
            return false
        }
        do {
            let before = scene
            let next = try proposal.confirmed(in:scene,selection:inkSelection)
            try persistScene(next)
            scene = next
            recordGraphEdit(before:before)
            cancelInkShape()
            status = "도형을 확정했습니다. 원본 획과 출처 연결을 보존했습니다."
            return true
        } catch { status = error.localizedDescription; return false }
    }

'''
    assert s.count(mark) == 1
    s = s.replace(mark, insert+mark)
    s = s.replace('        inkSelection = next\n', '        inkShapeSelectionGeneration &+= 1\n        inkSelection = next\n')
    s = s.replace('            if oldValue != mode {\n', '            if oldValue != mode {\n                cancelInkShape()\n')
    out[path] = s
    path = 'iOSClient/CanvasBridge/CanvasWorkspace.swift'
    s = (root/path).read_text()
    s = s.replace('            Button("상자")', '''            Button("선택한 획 도형 보정",systemImage:"wand.and.stars") { store.proposeInkShape() }
                .disabled(store.inkSelection.isEmpty || store.inkBusy || store.mode != .lasso)
                .accessibilityIdentifier("canvasProposeInkShape")
            Button("상자")''',1)
    mark = '        .onDisappear { dictation.cancel();'
    assert mark in s
    s = s.replace(mark, '''        .sheet(item:Binding(get:{ store.inkShapeProposal },set:{ if $0 == nil { store.cancelInkShape() } })) { proposal in
            CanvasInkShapePreview(proposal:proposal,current:store.inkShapeIsCurrent,
                confirm:{ _ = store.confirmInkShape() },cancel:{ store.cancelInkShape() })
        }
        .onDisappear { store.cancelInkShape(); dictation.cancel();''',1)
    s = s.replace('            Text(node.text.isEmpty ? "내용 입력" : node.text).font(.title3)', '''            Text(node.text.isEmpty ? (node.kind == .note ? "내용 입력" : "") : node.text).font(.title3)''')
    s = s.replace('''            .background(Color(uiColor:CanvasPalette.nodeFill),
                        in:RoundedRectangle(cornerRadius:14))
            .overlay(RoundedRectangle(cornerRadius:14)''', '''            .background(node.kind == .note ? Color(uiColor:CanvasPalette.nodeFill) : .clear,
                        in:RoundedRectangle(cornerRadius:14))
            .overlay(CanvasInkShapeOutline(kind:node.kind)''')
    s = s.replace('Text(node.kind == .box ? "선택한 상자" : "선택한 메모")', 'Text(node.kind == .box ? "선택한 상자" : node.kind == .ellipse ? "선택한 타원" : node.kind == .line ? "선택한 직선" : "선택한 메모")')
    s = s.replace('            .onTapGesture { store.select(node.id) }', '            .contentShape(.interaction, Rectangle().inset(by:node.kind == .line ? -21 : 0))\n            .onTapGesture { store.select(node.id) }')
    out[path] = s
    path = 'iOSClient/CanvasBridge/SceneRenderer.swift'
    s = (root/path).read_text()
    s = s.replace('''                UIBezierPath(roundedRect: frame, cornerRadius: 14).fill()''', '''                if node.kind == .note { UIBezierPath(roundedRect: frame, cornerRadius: 14).fill() }''')
    s = s.replace('''                let outline = UIBezierPath(roundedRect: frame, cornerRadius: 14)''', '''                let outline: UIBezierPath
                if node.kind == .ellipse { outline = UIBezierPath(ovalIn:frame) }
                else if node.kind == .line {
                    outline = UIBezierPath()
                    outline.move(to:CGPoint(x:frame.minX,y:frame.midY))
                    outline.addLine(to:CGPoint(x:frame.maxX,y:frame.midY))
                } else if node.kind == .note { outline = UIBezierPath(roundedRect:frame,cornerRadius:14) }
                else { outline = UIBezierPath(rect:frame) }''')
    out[path] = s
    path = 'iOSClient/Sill.xcodeproj/project.pbxproj'
    s = (root/path).read_text()
    import re
    seeds = [line for line in s.splitlines(True) if 'PencilTextCorrection.swift' in line]
    ids = sorted(set(re.findall(r'\b[A-F0-9]{24}\b',''.join(seeds))))
    mapping = {value:'5A9E20261029'+str(i).zfill(12) for i,value in enumerate(ids)}
    for line in seeds:
        new = line.replace('PencilTextCorrection.swift','CanvasInkShapeProposal.swift')
        for old,value in mapping.items(): new = new.replace(old,value)
        s = s.replace(line,line+new)
    out[path] = s
    path = 'Tests/integration/ipad-runtime/CanvasBridge.xcodeproj/project.pbxproj'
    s = (root/path).read_text()
    s = s.replace(' objects = {', ' objects = {\n  5A9E20261028000000000001 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "../../../iOSClient/CanvasBridge/CanvasInkShapeProposal.swift"; sourceTree = "<group>"; };\n  5A9E20261028000000000002 = {isa = PBXBuildFile; fileRef = 5A9E20261028000000000001; };')
    s = s.replace('children = (A00000000000000000000040,', 'children = (5A9E20261028000000000001,A00000000000000000000040,')
    s = s.replace('files = (A00000000000000000000020,', 'files = (5A9E20261028000000000002,A00000000000000000000020,')
    out[path] = s
    return out

if __name__ == '__main__':
    output = Path(sys.argv[1])
    output.mkdir(parents=True,exist_ok=True)
    patch = ''
    for name, content in changes().items():
        original = (root/name).read_text()
        patch += ''.join(difflib.unified_diff(original.splitlines(True),content.splitlines(True),fromfile='a/'+name,tofile='b/'+name))
        target = output/name
        target.parent.mkdir(parents=True,exist_ok=True)
        target.write_text(content)
    source = 'iOSClient/CanvasBridge/CanvasInkShapeProposal.swift'
    shutil.copyfile(root/source,output/source)
    (Path(__file__).parent/'integration.patch').write_text(patch)
