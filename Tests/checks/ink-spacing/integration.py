#!/usr/bin/env python3
from pathlib import Path
import difflib,shutil,sys,re
root=Path(__file__).resolve().parents[3]
def changes():
 out={};p='iOSClient/CanvasBridge/CanvasStore.swift';s=(root/p).read_text()
 # 원래 invalidate 경로의 같은 단계에서 spacing도 취소한다.
 s=s.replace('pendingInkTextEditing?.invalidatePending()', 'pendingInkTextEditing?.invalidatePending()\n            pendingInkSpacing?.invalidatePending()')
 mark='    private weak var pendingInkTextEditing: CanvasInkTextEditing?'
 s=s.replace(mark,mark+'''
    private weak var pendingInkSpacing: CanvasInkSpacingProposal?

    func proposeInkSpacing(left: String, right: String, action: CanvasInkSpacingProposal.Action,
                           amount: Double, editing: CanvasInkSpacingProposal,
                           readEvidence: CanvasInkTextEditing.ReadEvidence = CanvasInkTextEditing.nativeEvidence) async {
        pendingInkSpacing?.invalidatePending()
        pendingInkTextEditing?.invalidatePending()
        cancelInkShape()
        pendingInkSpacing = editing
        guard inkTextEditAllowed, let node = inkTextDeletionTarget else {
            editing.cancel(); status = "두 그룹 전체에 대응하는 원본 획을 먼저 선택하세요."; return
        }
        await editing.propose(scene:scene,nodeID:node.id,selection:inkSelection,left:left,right:right,action:action,amount:amount,
            isCurrent:{ [weak self] snapshot in
                guard let self else { return false }
                return self.inkTextEditAllowed && snapshot.matches(scene:self.scene,selection:self.inkSelection)
            },readEvidence:readEvidence)
    }
    @discardableResult
    func confirmInkSpacing(_ editing: CanvasInkSpacingProposal) -> Bool {
        guard inkTextEditAllowed else { status = "다른 입력이나 저장이 진행 중입니다. 원본 간격을 유지합니다."; return false }
        do {
            let next = try editing.confirm(current:scene,selection:inkSelection,persist:{ try self.persistScene($0) })
            installInkTextScene(next)
            status = "원본 획 간격을 복구본에 반영했습니다. Files 원본 미저장·Obsidian 동기화 대기입니다."
            return true
        } catch { status = "원본 간격을 저장하지 않았습니다. \\(error.localizedDescription)"; return false }
    }
    @discardableResult
    func undoInkSpacing(_ editing: CanvasInkSpacingProposal, redo: Bool = false) -> Bool {
        guard inkTextEditAllowed else { status = "다른 입력이나 저장이 진행 중입니다. 원본을 유지합니다."; return false }
        do {
            let next = try redo ? editing.redo(current:scene,persist:{ try self.persistScene($0) }) :
                editing.undo(current:scene,persist:{ try self.persistScene($0) })
            installInkTextScene(next)
            status = "원본 획 간격 이력을 복구본에 반영했습니다. Files 원본 미저장·Obsidian 동기화 대기입니다."
            return true
        } catch { status = "원본을 덮어쓰지 않았습니다. \\(error.localizedDescription)"; return false }
    }
''')
 out[p]=s
 p='iOSClient/CanvasBridge/CanvasWorkspace.swift';s=(root/p).read_text()
 mark='    @StateObject private var store = CanvasStore()';s=s.replace(mark,mark+'''
    @StateObject private var inkSpacing = CanvasInkSpacingProposal()
    @State private var inkSpacingOpen = false
''',1)
 mark='        .onDisappear { store.cancelInkShape();'
 s=s.replace(mark,'''        .sheet(isPresented:$inkSpacingOpen) {
            CanvasInkSpacingSheet(editing:inkSpacing,text:store.inkTextDeletionTarget?.text ?? "선택한 문구 없음",
                propose:{ left,right,action,amount in Task { await store.proposeInkSpacing(left:left,right:right,action:action,amount:amount,editing:inkSpacing) } },
                confirm:{ if store.confirmInkSpacing(inkSpacing) { inkSpacingOpen = false } },
                cancel:{ inkSpacing.cancel(); inkSpacingOpen = false })
        }
        .onDisappear { inkSpacing.invalidatePending(); store.cancelInkShape();''',1)
 mark='            Button("선택한 획 도형 보정"';i=s.index(mark)
 s=s[:i]+'''            Button("원본 획 간격") { inkSpacing.cancel(); inkSpacingOpen = true }
                .disabled(store.inkTextDeletionTarget == nil || store.inkBusy)
                .accessibilityIdentifier("canvasInkSpacing")
            Button("원본 간격 되돌리기") { _ = store.undoInkSpacing(inkSpacing) }.disabled(!inkSpacing.canUndo)
            Button("원본 간격 다시 실행") { _ = store.undoInkSpacing(inkSpacing,redo:true) }.disabled(!inkSpacing.canRedo)
'''+s[i:];out[p]=s
 p='iOSClient/Sill.xcodeproj/project.pbxproj';s=(root/p).read_text();seeds=[line for line in s.splitlines(True) if 'CanvasInkTextEditing.swift' in line]
 mapping={v:'6C9C20261029'+str(i).zfill(12) for i,v in enumerate(sorted(set(re.findall(r'\b[A-F0-9]{24}\b',''.join(seeds)))))}
 for line in seeds:
  new=line.replace('CanvasInkTextEditing.swift','CanvasInkSpacingProposal.swift')
  for old,value in mapping.items():new=new.replace(old,value)
  s=s.replace(line,line+new)
 out[p]=s
 p='Tests/integration/ipad-runtime/CanvasBridge.xcodeproj/project.pbxproj';s=(root/p).read_text()
 s=s.replace(' objects = {',' objects = {\n  6C9C20261029000000000001 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "../../../iOSClient/CanvasBridge/CanvasInkSpacingProposal.swift"; sourceTree = "<group>"; };\n  6C9C20261029000000000002 = {isa = PBXBuildFile; fileRef = 6C9C20261029000000000001; };')
 s=s.replace('children = (A00000000000000000000040,','children = (6C9C20261029000000000001,A00000000000000000000040,')
 s=s.replace('files = (A00000000000000000000020,','files = (6C9C20261029000000000002,A00000000000000000000020,')
 out[p]=s;return out
if __name__=='__main__':
 output=Path(sys.argv[1]);output.mkdir(parents=True,exist_ok=True);patch=''
 for name,content in changes().items():
  patch+=''.join(difflib.unified_diff((root/name).read_text().splitlines(True),content.splitlines(True),fromfile='a/'+name,tofile='b/'+name))
  target=output/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_text(content)
 name='iOSClient/CanvasBridge/CanvasInkSpacingProposal.swift';shutil.copyfile(root/name,output/name)
 (Path(__file__).parent/'integration.patch').write_text(patch)
