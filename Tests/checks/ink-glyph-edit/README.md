# 원본 획과 한 글자 삭제

기준은 `c03d9c2de9eb39cfd50501a73a060a0a34375c8c`다. 제품 소유 파일은 `iOSClient/CanvasBridge/CanvasInkTextEditing.swift` 하나다. 기존 Model/Store/Workspace는 수정하지 않았다. `integration.patch`는 이 기준 Store/Workspace에 적용할 정확한 접합 패치이며 검사는 자기 `.build`의 사본에서만 적용한다. 제품 편집기 전체 완료나 설치 수용은 아니다.

## 구현 계약

`Snapshot`은 sceneID/revision/scene SHA/native drawing SHA/선택 획 ID/원문/노드 ID/UTF16 범위를 보존한다. `Phase`는 인식 중·명시 모호·미리보기·적용·Undo 상태를 구분한다. `PKStrokeRecognizer.recognizedText(strokeIDs:)`와 대소문자 일치·부분단어 검색의 실제 strokeID를 사용하며 bbox로 문자 소유권을 정하지 않는다.

유일한 Character만 처리한다. 전체 인식문, 삭제 획만의 재인식, 나머지 획의 재인식이 기대 문자와 UTF8로 일치해야 한다. 다른 글자의 검색 획과 삭제 획이 겹치거나, 다른 노드가 출처를 공유하거나, 대상에 mask가 있으면 원본을 유지하고 명시적으로 거절한다. 반복 문자·검색0/복수결과·알 수 없는 ID·미지원 인식도 거절한다. 주변 획의 mask/transform/필압은 보존한다. 현재 기능은 획의 일부를 새로 잘라 glyph에 배분하지 않는다.

미리보기는 원본과 결과의 native drawing·문자를 보여준다. 확정은 같은 snapshot에서 원자 저장 콜백이 성공한 뒤 상태를 바꾼다. Undo/Redo는 전체 문자·획을 함께 복원하고 revision은 계속 증가한다. 다른 수정이 들어오면 Undo로 덮지 않는다. 이력은 현재 편집 세션 한 단계이며 앱 재실행 뒤 Undo 복원은 구현하지 않았다.

## 실제 검사와 증거 주입의 구분

최초 유효 실행의 51개 검사는 native PKDrawing 생성·마스크·변환·필압·파일 쓰기/읽기와 접합된 실제 CanvasStore의 저장·새 Store 재열기·Undo/Redo를 포함한다. 이 성공 경로의 **문자-획 대응 Evidence는 주입했다**. Apple 인식 성공이나 실제 Pencil 수용이 아니다.

`native-recognizer-baseline.json`은 별도 무주입 결과다. 보존된 ownfixture 3개를 실제 recognizer로 읽었으나 모두 text=nil/search0이었다. 34획 원본 한 개가 혼합 한글/영문 필기이고, 나머지는 mask가 있는1획과0획 음성 대조군이다. 후자 둘을 유효 손글씨 인식 실패 표본으로 확대하지 않는다.

`native-capability.json`은 추가 가설 한 번의 결과다. macOS27.0.1 명령행 bundle에서 API recognitionVersion9와 en/ko 지원·실효 언어를 읽었고 recognizer.drawing은 원본34획과 같다. strokeID 필터 없는 recognizedText도 nil이다. 언어 목록과 버전은 엔진 추론 성공이 아니다.

`recognizer-log-extract.json`은 그 자기 프로세스만의 기존 로그다. handwritingd.remoterecognition 연결과34획 처리가 기록됐으나 `Remote Recognition error` 및 `Document layout analysis failed ... bailing out the whole analysis`가 있다. 상세 오류는 OS의 private 값이다. 권한·키·로그 개인정보 설정을 바꾸지 않았다. 명령행 macOS에서 전체 엔진이 원천 미지원인지, 샘플/좌표/런타임 문맥 제한인지는 확정하지 않았다. 같은 query와 parameter 변형을 반복하지 않는다.

ownfixture의 원본34획은 PDF 계열 transform을 포함한다. native 렌더에서 영문 줄과 밑줄·다른 한글·선이 함께 보이며 y축 반전 표현도 있다. 34획 전체를 `Apple pencil`만의 획 선택으로 표시할 근거가 없다. 원래 올가미 선택의 UUID 집합은 보존 기록에 없으므로 시각적 bbox로 이를 자동 추정하지 않는다.0획 OCR 카드의 PKDrawing을 원래 영문 필기로 바꾸지 않는다. 원본/좌표를 임의로 고쳐 인식 성공을 만드는 경로도 제품에 넣지 않았다.

실제 인식→안전한 단일 글리프 획 대응의 성공은 **미입증**이다. 부모가 정한 최종 설치 빌드의 한 Pencil 묶음에서 지원 언어와 실제 선택 획을 사용해 확인해야 한다. 지금 새 Pencil 요청은0이다.

## 재현

`python3 Tests/checks/ink-glyph-edit/run.py --policy-only`는 보존 native nil 결과를 반복 호출하지 않고 정책·Store·SDK를 검사한다. 원래 무주입 실행은 baseline 영수증과 capability probe에 보존했다. 새 조건의 근거가 있는 경우에만 기본 실행으로 native API를 추가 확인한다. `CapabilityProbe.swift`는 언어·엔진·전체/ID 필터 차이를 조사한 좁은 독립 실행이며 앱 설치·기기 제어를 하지 않는다.

컴파일과 파일 왕복은 iOS/macOS27 PencilKit SDK 및 실제 macOS27.0.1이 있는 맥북에서 실행했다. Mini의 OS26.6.2/SDK26.5에는 이27 API가 없어 해당 실행을 옮겼다고 표시하지 않는다. 모든 출력은 storage-route의 동일 SSD에서 자기 `.build`에만 둔다.

## Pstack 작업 기록

- [x] how. 기존 proposeHandwriting/searchHandwriting→PencilKit→scene projection→persistScene→파일 재열기 경로를 대조했다.
- [x] 데이터형 우선. Snapshot/Proposal/Phase/History와 명시 Refusal을 선택했다.
- [x] 설계. 사용자 ARENA 금지에 따라 기존 native API·정상 scene·원자 파일 저장을 재사용했다. 다른 이름의 경쟁 절차를 만들지 않았다.
- [x] 병목. 소유 브랜치·c03d·storage writer 분리와 SDK27 필요를 먼저 확인했다.
- [x] 독립 작업. SDK 검사와 native 검사 컴파일은 병렬 실행했다. 같은 파일 쓰기는 단일 writer다.
- [x] 공유 상태. 다른 WT·기기·원앱·REA active target·Host·사용자 원본에 쓰기0이다.
- [x] 최소 분해. 결합된 문자/획/Undo 책임을 한 제품 파일에 둔다. Store/Workspace 접합은 별도 패치다.
- [x] Ponytail full. 기존 PKStrokeRecognizer·CanvasScene·CanvasLocalFile·SDK를 재사용했다. 새 provider/의존성0이다.
- [x] 유효 표면 검사. 증거주입 성공과 무주입 nil/엔진 오류를 분리했다. 테스트 수를 기능 완료율로 쓰지 않는다.
- [ ] 새 독립 검수. spawn_agent 도구가 없고 부모의 최종 통합 검수가 남는다. 최초 초안에 대한 부모의 검토를 새 head 전체 CLEAR로 확대하지 않는다.
- [x] 제품 접합은 a8810155로 별도 고정했다. 아래 shape 후보와 pure note 경로를 분리한다. whole unsigned build는 clean 최종 HEAD의 `.build/whole-*/build.json`으로 확인한다.

초기 검사 실행기의 경로 문자열 비교는 BT_CCR-iPad/ipad 대소문자 별칭 때문에 거절됐다. 실제 같은 디스크/디렉터리 inode를 검증하는 samefile로 고쳤다. 타입 검사 초안의 MainActor encode와 테스트 CGFloat/PKInk 비교 오류도 수정했다. 초기 실패 로그는 자기 `.build`에 보존했으며 native 인식 실패와 구분한다.

## 68a1b4aa 실제 제품 접합

새 제품 WT는 공식 로컬 integration `68a1b4aaad6faba5a5449d82b81e147479b81930`에서 만들고 glyph 소유 commit98d9fe4를 cherry-pick했다. 실제 Store/Workspace와 정상 iPad/iPhone project source phase에 연결했다. 도구 안에서 원본 획을 선택하고, 기존 인식 요소 한 개에 정확히 대응할 때만 한 글자 선택·native 미리보기·명시 확정·glyph Undo/Redo를 제공한다. 새 노트 서재·공통 wire를 만들지 않았다.

통합 검사 명령은 `python3 Tests/checks/ink-glyph-edit/run.py --actual-product --policy-only`다. 사본 대신 실제 제품 Store/Workspace를 컴파일한다. 65개 native 파일·Store 검사가 통과했고 전체 Canvas iOS27 SDK 타입 검사가 통과했다. 실제 Store의 선택/장면/모드/Pencil trace ABA 뒤 옛 callback 거부도 포함한다. 무주입 인식을 다시 실행하지 않았다.

Files 연결·저장 중 또는 blocked에서는 glyph 편집을 시작하지 않는다. local persistScene 성공은 기기 복구본 반영이며 Files 원본 성공이 아니다. UI는 Files 미저장·Obsidian 동기화 대기로 표시하고, Files 세대 저장/재독출 후에만 기존 fileWorkspaceCanSync가 relay를 허용한다. 실제 폴더권한 실패·외부 CAS 충돌·같은 원본 재시도·새 Store 재열기로 이를 확인했다. 이전 원본 current.json과 native bytes, 미저장 복구본을 각각 대조했다.

별도 `obsidian-roundtrip.cjs`는 실제 기존 ObsidianVault 모듈과 격리 보관함 파일에서 glyph 변경·native JSON·Markdown·메모 CRLF·새 인스턴스 재열기·Undo·CAS409 보존을 검사한다. 공유 relay 프로세스·사용자 vault·네트워크에는 영향0이다. PNG는1픽셀 전송 fixture이므로 실제 preview 시각 수용으로 세지 않는다. 최초 CAS 검사는 payload revision과 인자를 잘못 짝지어400을 받았고, 일치한 payload와 오래된 SHA로409를 재검증했다. 제품 보호를 완화하지 않았다.

새 native 인식 성공과 실제 iPad 화면·Pencil 수용은 여전히 미완료다. glyph 확정은 기존 PKCanvasView의 잉크만 Undo하는 기록을 무효화하고 별도 glyph 명령으로 문자와 획을 함께 되돌린다. 이전 native Undo 이력의 앱 재실행 보존은 제공하지 않는다.


## 2026-10-29 shape 접합 후보와 호환성 보류

glyph 순수 note 제품 접합은 `a8810155f5a32b019957b9f96905c0d66153930a`다. 이후 shape 원소유 e529975를 `33136572c1bbeac10f3f6bce62839c970104da28`로 cherry-pick했다. 이 WT는 부모가 배정한 Store/Workspace 단독 writer이며 저장 정본68a의 보호를 재사용한다. 두 초안의 패치를 실제 코드에 의미 단위로 합쳤고 원본 integration.patch는 각 출발점의 역사적 패치로 보존한다.

**shape는 공통 wire 변경 후보이며 전체 수용은 false다.** 새 Kind ellipse/line을 같은 schemaVersion2로 저장하면 구형68에서 decode가 실패한다. 공식 relay f61f516은 새 kind를 검사하지 않고 저장하며 Mermaid는 전부 상자, 구조 설명은 새 kind를 요소로 투영한다. iPad CanvasDiagramSnapshot과 이를 호출하는 CanvasPeleView도 상자 투영이다. 새 schema 번호와 소비자 협약을 이 writer가 독단으로 정하지 않았다.

따라서 현재 제품은 기존 box 보정만 확정·파일 왕복 가능하다. line/ellipse는 native 비교 미리보기와 명시적 `shape_wire_contract_pending` 거부까지만 가능하다. 확정 버튼을 막고, Store persistScene·Files.save·scene decode·CanvasDiagramSnapshot/Pele·saveVaultCanvas가 새 종류를 거부한다. fileWorkspaceCanSync도 false다. 현재 relay에 신규 kind를 조용히 쓰는 경로를 열지 않는다. 단위 검사의 Proposal.confirmed가 만드는 line/ellipse JSON은 격리 fixture일 뿐 제품 저장 성공으로 세지 않는다. schema2 신규 kind의 decoder 거부·Files 외부 쓰기0도 검사했다.

부모의 relay 소유 단위에서 버전 및 capability/명시 거부, 노드별 Mermaid/Pele 의미 투영, Obsidian 종류 설명, 신구 클라이언트 읽기·쓰기 정책을 합의·구현한 뒤 같은 exact pair를 검증해야 한다. 그때 이 거부를 호환 계약에 맞게 바꾸고 line/ellipse 왕복을 다시 검증한다. 서버 소스를 이 WT에서 수정하지 않았다. 자세한 포인터는 SHAPE-WIRE-CONTRACT.md와 shape-wire-contract.json에 있다.

`python3 Tests/checks/ink-glyph-edit/product-check.py`는 실제 결합 소스와 기존 Files 회귀49·안전23, shape70을 각각 격리된 새 경로에서 실행한다. glyph65는 대응 Evidence 주입이며 native 인식 재실행0이다. shape70은 실제 PencilKit 기하·원본 보존·상자 Store/Files 왕복·Undo/Redo·stale·불가 kind의 명시 거부다. 실제 ObsidianVault 모듈의 격리 파일 왕복은 note glyph15·기존 box17로 분리한다. line/ellipse 왕복 완료라는 뜻이 아니다. SDK27은 전체 Canvas 코드와 실제 UI hook를 타입 검사했으며 UI를 열거나 실제 터치 수용을 하지 않았다.

최초 결합 runner가 이전 실행의 격리 폴더를 재사용하여 기존 문서 목록과 구형 ellipse 캐시에 충돌했다. 제품 원본 실패와 구분해 로그를 보존하고 실행별 UUID 경로로 수정했다. 새 경로에서 모두 재검증했다. 실패한 실행의 결과를 완료 근거로 사용하지 않는다.

`whole-build.py`는 clean HEAD를 요구하며 정상 com.ambrion.sillcanvas.ipad의 Debug arm64 전체 앱을 무서명 빌드하고 Info.plist의 commit/tree/verified와 실제 executable SHA를 기록한다. 프로필은 이미 승인된 public bootstrap 한 개만 읽는다. 설치·push·서버 전환은 없다. 빌드 성공은 native 인식·Pencil·WKWebView 시각 수용·shape 전체 왕복 수용을 대체하지 않는다.
