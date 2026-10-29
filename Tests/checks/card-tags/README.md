# 카드 태그와 보기 필터

기준은 공식624597f62326df776099e90a626630e52e751803/tree05d2249fbcef40f4c95d02316a75dd0e5f96a9ca다. 원앱 R093/R094(`margin-tag-corrected-spec.md`, `margin-tag-audit-acceptance.json`)는 MarginNote Mac 자체 한 카드의 태그 추가·Undo/Redo·같은 프로세스 뷰 재열기·단일 필터·검색 해제를 실제로 관측했다. 전역 태그 삭제/계층/AND·OR/배치·cold restart/iPad·Pencil 전체 수용은 아니다. 이번 단위도 그 범위를 확대하지 않는다.

## 저장 계약

- 기존 CanvasAnnotation의 `author` UTF8가 정확히 `ccr.sill.card-tag/v1`이고 `nodeId`가 실제 note 카드에 연결된 레코드의 `text`를 `#태그` Markdown 원문으로 저장한다. 새 scene 필드·schema·DB·상위 상태관리·API는 없다. 원본 node.text/vaultNote/PDF provenance/댓글/획/도형/링크/부모자식 관계는 유지한다.
- 이 단위는 **캔버스 카드 분류**다. 연결된 별도 원문 노트의 본문이나 PDF를 분류 태그로 덮어쓰지 않는다. 원문의 `#문자열`, 일반 댓글, PDF 내용에서 태그를 추정하지 않는다. 사람/AI는 scene JSON의 동일 Markdown 문자열을 읽으며, 태그 목록은 재생성 가능한 메모리 파생값이다.
- 태그는 영문·한글·숫자·밑줄·붙임표의 공백 없는 단일 키워드 부분집합이며 숫자만/중첩 슬래시/이모지/HTML/개행은 이 단위에서 거부한다. 원본 표기·NFD는 저장 그대로 유지하고 비교 키에만 NFC/소문자를 사용한다. [Obsidian 공식 태그 문법](https://help.obsidian.md/tags)은 이보다 넓으므로 전체 문법 지원을 주장하지 않는다. 이름은UTF8 128바이트 이하다.
- 태그의 UUID 참조/중복 판정은 대소문자 차이를 같은 ID로 비교하지만 raw scene ID/문자열을 재작성하지 않는다. literal author가 다르거나 orphan/중복/잘못된 표식이면 자동 선택·병합·정리하지 않는다. 원본 레코드는 보존하고 해석/변경을 거부하거나 파생 목록에서 제외한다. 기존의 사람용 author `카드 태그`와 `#기존댓글` 조합도 일반 댓글로 유지하며 자동 이전하지 않는다. 버전이 붙은 기계용 namespace는 새 태그 메타데이터의 명시 선언이다. UI에는 `카드 태그`로 표시한다.
- Obsidian 관리 Markdown은 실제 태그 문자열을 코드 블록 밖 `### 카드 태그` 목록에 내보낸다. 기존 노드/링크 표시 후, 기존64KiB append/생략표시/1MiB note한도 안에서만 추가한다. 생략돼도 전체 scene JSON에는 태그가 남는다. 동일Canvas 문서 내 카드들의 태그가 그 Obsidian 문서의 태그로 노출된다.
- reader는 과거 legacy/structured/structured+diagram과 새 tagged/tagged+diagram의5종을 **각각 정확 생성**해 비교한다. 입력 Markdown을 strip/trim/NFC 정규화하지 않는다. 태그 없는 장면의 출력은 과거 바이트와 같다. 과거 문서 읽기는 note/JSON/PNG를 재작성하지 않으며 명시 CAS 저장 때만 새 표현을 쓴다. 메모 suffix의 BOM/CRLF/NFD/공백은 그대로 유지한다.
- 관리 태그 줄의 외부 수동 변경은 기존409 충돌 보호 대상이다. 새 줄을 임의 역파싱해 scene을 덮지 않는다. 기존 resolver/JSON/PNG/메모 보존/CAS 계약은 유지한다. 과거 Relay와 새 관리 태그 Markdown의 조합은 fail-closed일 수 있으므로 부모가 같은 검수 통합본으로 맞춰야 한다. 정식 Obsidian 앱의 실제 인덱스/클릭 수용은 별도다.

## 제품 동작

선택 모드에서 카드 태그 메뉴로 이름을 입력해 명시 추가한다. 입력 owner UUID/장면 SHA/장면세대/선택세대를 확인하며 지연된 이전 입력·선택/장면 ABA·mode/Pencil 전환은 원본에 적용하지 않는다. 열린 본문·댓글·PDF 복구·미조정 노트·Files blocked·busy는 기존 공통 guard를 소비한다. 실제 복구본 저장에 성공한 뒤 태그와 공통 graph Undo/Redo 기록을 설치하며 Files는 기존 pending/ready/blocked·파일 조정·bookmark·CAS를 쓴다. 태그 입력 자체는 UI 메모리 초안이며 앱 재시작 지속성을 새로 제공하지 않는다.

단일 태그 필터는 현재 표시 카드만 좁히고 원본 획과 일반 도형을 유지한다. native와Pele는 같은 파생 visibility를 소비하고 숨긴 카드/링크 선택을 거부한다. 필터/해제는 scene revision·원본 파일·태그·관계를 바꾸지 않는다. 필터 상태는 저장하지 않으며 새Store/다른scene은 전체 보기로 시작한다. MM32.04는 원앱의 필터 검색 해제 범위로 해석하며 태그 전역 삭제 기능으로 확대하지 않는다. 기존 한 단계 graph Undo/Redo를 재사용하며 별도 history DB는 만들지 않는다.

## 검사

```sh
python3 Tests/checks/card-tags/run.py --output /Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-completion-20261028/card-tags-evidence --sdk-check
```

실제 Model/Store/PKDrawing/Files에서 추가·취소/ABA·입력보호·노드/원문/댓글/계층/획바이트 보존·새Store재열기·공통UndoRedo·캐시쓰기실패·외부파일태그수신·Files경쟁/CAS·재시작pending·필터해제를 검사한다. 기존 카드/PDF 전수 검사는 재실행하지 않는다. macOS scoped bookmark는 테스트가 소유한 격리폴더에만 생성하며 실제 iPad picker/provider 지속성 수용이 아니다.

`--export-only --sdk-check`는 태그 입력과 PNG 내보내기 표시 소유권의 좁은 회귀 검사다. 실제 Store와 Workspace에서 추출한 시작·완료·표시 binding·취소 함수를 컴파일해, 태그 입력 중 시작 거부·늦은 완료 폐기·입력 취소 후 이전 파일창 재등장 방지·원본 바이트 보존을 실행한다. SwiftUI의 onChange 전달과 PNG 렌더러·문서 타입은 통제 fixture이며 실제 화면이나 픽셀 수용으로 세지 않는다. 기본 전수 검사와 별도로 실행한다.

같은 `tag-cases.json`을 Swift와 실제 Node 모듈이 검사한다. 실제 기존 ObsidianVault와 Git 기준 원본 generator를 오프라인 자체디렉터리에서 실행해5종표현·태그없는바이트동일·새instance·원문/MEMO·변조·409·형식/예산을 검증한다. iOS27전체CanvasBridge 타입과project등록도 검사한다. preview PNG는 주입fixture이고 UI·렌더·HTTP·실제Obsidian인덱스·키·Host·서비스·사용자vault·앱설치·기기효과는0이다.

Pstack how→실제 경계 추적→제품/파일 검사→독립검수를 사용하고 Ponytail로 기존모델/주석/graph history/Files/CAS/관리Markdown을 재사용했다. ARENA/순정Goal은 사용하지 않는다. source수용은 exactcheckpoint 독립검수 전 pending이며 전체 원앱/실물 수용을 의미하지 않는다. 부모만 공식integration에 반영한다.
