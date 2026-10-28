# 복수 페이지 문서의 첫 구현 단위

기준은 공식 `624597f62326df776099e90a626630e52e751803` / tree `05d2249fbcef40f4c95d02316a75dd0e5f96a9ca`다. 이 문서는 사용자가 수용한 방향을 한국어로 고정한다. 세부 형식명, 버전 숫자와 한도는 사용자 요구를 구현하기 위해 작성자가 선택한 계약이다. 기존 scene API, packet schema, relay wire를 변경하지 않는다.

## 직접 확인된 원앱 근거와 한계

`/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/myscript-page-management-20261029/observation.json`은 자체 MyScript 노트북의 페이지 복제 1→2와 서재 복귀 후 재열기에서 2페이지 유지를 관측했다. 같은 폴더 `background-observation.json`의 회색 격자/검정 페이지 구분은 시각 관측이며 배경 변경 후 재열기는 미확인이다.

`/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/myscript-page-data-final-20261029/REPORT.md`와 `result.json`은 notebook object145의 외부 page146→153 순서, 서로 다른 object UUID와 `duplicate_of` 관계를 확인했다. 두 패키지의 내부 pageID는 모두 `qoxhavla`이므로 내부 ID 하나를 전역 페이지 ID로 사용하지 않는다. 외부 UUID와 부모·순서가 식별 근거다. 양쪽 원본 ink SHA는 `9649618db27ab5d22f2f90f7a09baa98dd02f8245c52ff3a3e13453c901dae92`로 같다. 저장 자료의 색상 인코딩, 앱 전체 원자적 snapshot, 배경 재열기, cold restart는 확인하지 않았다. 이 구현에서 원앱 컨테이너를 새로 해독하거나 파일을 가져오지 않았다.

## 새 외곽과 페이지

`CanvasDocument`는 `format=ccr.canvas-document`, `version=1`, 문서 UUID, 문서 revision, 현재 페이지 UUID와 순서 있는 `[CanvasScene]`만 저장한다. 외곽에 구 scene의 `schemaVersion`, 잉크, 노드, 링크를 겹쳐 넣지 않는다. 구 reader가 선택된 페이지만 읽고 숨은 페이지를 버리는 성공 경로를 만들지 않는다. 새 문서 decode 실패는 legacy로 fallback하지 않는다. 알 수 없는 외곽/scene 필드, 새 버전·종류, 빠진 현재 페이지, 중복 페이지 ID, 잘못된 참조는 전체 문서를 거부한다.

구 scene 1/2/3은 읽기 시 명시적으로 한 페이지 문서로 감싼다. 원래 scene ID는 첫 페이지 ID이며 문서 ID로도 유지한다. 새 문서에 대한 기존 단일 scene 저장·게시 호출은 연결하지 않는다. Files의 `workspaceDocuments` 목록은 서로 다른 문서 목록이며 문서 안의 페이지 목록과 같지 않다.

복제는 원래 페이지 바로 뒤에 넣고 새 페이지 UUID와 모든 노드·링크·주석 UUID를 만든다. 링크 양끝과 주석의 노드 참조는 새 노드 ID로 재매핑한다. 원본 페이지, 원시 PKDrawing 바이트, 페이지 범위의 native strokeID와 `sourceStrokeIds`, 외부 Obsidian 경로·blockID·SHA, UTF8 본문·주석·스타일·frame·rotation은 보존한다. 반환되는 ID 대응표는 호출자가 복제 선택을 이어가는 데 쓸 수 있다. 원앱의 내부 pageID나 child_index 숫자를 CCR ID/정렬 규칙으로 복제하지 않는다.

문서 revision은 페이지 복제·교체·전환 때 증가한다. 페이지 전환 epoch는 실행 중에 따로 증가하며 A→B→A에서 예전 snapshot을 거부한다. snapshot에는 문서 UUID·전체 문서 SHA·페이지 UUID·페이지 revision·epoch와 메모리 인스턴스 식별자를 담는다. 새로 연 인스턴스에 예전 callback을 적용하지 않는다. 프로세스를 넘는 비동기 작업의 재개/승인은 이 첫 단위에서 제공하지 않는다.

## 전체 문서 Files 세대

새 head는 `ccr.sill-document-files/v2`이며 기존 `ccr.sill-files/v1` reader가 명시 거부한다. 같은 `<문서UUID>.sill` 안의 새 immutable generation에 `document.json`과 모든 페이지의 `drawing.pkdrawing`·`preview.png`를 쓴다. head에는 문서 SHA, generation UUID, 순서 있는 페이지 ID와 각 자산 SHA를 저장한다.

저장 입력의 모든 페이지·순서·자산을 검사하고, 기존 head token SHA와 비교하며, 기존 세대 전체도 다시 읽는다. 새 세대 전체를 쓴 뒤 실제 파일 readback과 SHA·순서 검증을 완료하고 head를 마지막에 원자 교환한다. 비선택 페이지 변경도 전체 head token의 CAS 충돌이다. 일부 페이지/자산 누락·손상은 전체 읽기 실패이며 선택 페이지만으로 성공하지 않는다. 새 generation 실패 시 기존 head를 유지하고 이전 세대를 삭제하지 않는다. 보안 범위 폴더와 파일 조정을 재사용하며 디렉터리 fd, UUID 경로, no-follow, regular-file 검사로 심볼릭 링크를 따르지 않는다.

협력 writer는 문서별 파일 lock을 쓴다. **비협력 외부 writer에 대한 절대 CAS는 아니다.** 마지막 SHA 확인과 head 교환 사이에 외부 교환이 끼어들면 교환 후 displaced head를 비교한다. 이때 활성 head가 우리 제안일 수 있다. 이전 head·외부 displaced head·제안 generation을 모두 보존하고 `publicationUnconfirmed`를 반환한다. 자동 rollback이나 성공 checkpoint로 바꾸지 않는다. 발행 전 durable `publish-UUID.json`은 재열기에서도 `publicationPending`으로 읽히며 후속 쓰기를 막는다. 정상 전체 readback 후에만 `commit-UUID.json`으로 바꾼다. 이 첫 단위에는 미확인 발행을 명시 조정하는 제품 UI가 없으며 복구 원장을 자동 삭제하지 않는다.

문서 JSON 16MiB, 페이지 128개, 기존 페이지 JSON/잉크 4MiB, 문서 전체 preview 합계 32MiB는 작성자가 선택한 제한이다. 원앱 기능 한도가 아니다. 실제 Files provider의 원격 내구성·클라우드 원자성은 별도 검증 대상이다.

## 이번에 연결하지 않은 제품 경계

Store, Workspace, 기존 CanvasFileWorkspace·Model, relay, Pele, PDF·태그 제품 코드는 바꾸지 않는다. pbxproj는 새 두 소스의 컴파일 등록만 한다. **새 문서 쓰기 제품 UI 활성화는 0이다.** 기존 scene API나 같은 canonical 원본으로 선택 페이지만 게시하는 경로를 추가하지 않는다.

다음 통합은 전체 문서 지원을 명시하는 paired relay capability, 문서 전체 canonical Obsidian/Files CAS·복구, 페이지별 AI 읽기/수정, 전체 페이지 투영, Store/UI를 함께 연결해야 한다. 해당 capability를 확인하기 전에는 새 문서를 같은 원본의 단일 scene으로 게시하면 안 된다. 라이브러리에 현재 페이지를 읽는 속성이 있다는 사실이 게시 허가가 아니다.

페이지 전환/문서 교체의 실제 Store gate는 열린 ink glyph·spacing·shape·math 제안, 카드/노트 편집, PDF pending/held, outbox, block/note/PDF 복구 원장, conflict choice/local/attempt, 미확인 Files 발행 등 **화면에 숨은 복구 상태까지** 조회해 막아야 한다. 이 첫 단위는 앱의 숨은 복구 원장을 직접 읽거나 그 barrier가 통합됐다고 주장하지 않는다. 자체 Files 발행 원장의 지속 barrier와 페이지 snapshot epoch만 구현했다. 원문/draft/작업 ID, Undo, 취소·늦은 callback의 Store 접합은 부모 통합 전 미완료다.

## 검증과 판정

`Tests/checks/canvas-document/run.py --output <승인 외장 경로> --sdk-check`가 실제 macOS PencilKit/로컬 Files 검사와 iOS27의 새 문서 단위 타입 검사를 수행한다. 결과·컴파일 캐시·격리 home·tmp는 출력 경로 안에만 둔다. tracked 결과를 덮지 않으며 HOME을 바꾸지 않는다.

무주입 검사는 PKDrawing 바이트/필압/transform 왕복, ID 재매핑, 구형 reader 거부, 구 scene/Files 읽기, 두 페이지 파일 왕복, 비선택 페이지 CAS, 실제 파일 누락과 권한 실패, ABA 거부다. 별도 주입 검사는 generation 뒤 실패, 교환 뒤 실패, CAS 확인 직후 비협력 외부 head 교환이다. 주입 검사를 OS crash나 원앱 성공 근거로 세지 않는다. 원본 사용자 파일·앱 UI·기기·Host·네트워크·서비스는 사용하지 않는다. 전체 빌드·설치·실기기·MyScript 전체 동등성·제품 복수 페이지 수용은 모두 미완료다.

Pstack의 기존 설계 재사용→경계 구현→네이티브 검증→정확 소스 고정 경로를 적용했다. Ponytail은 기존 CanvasScene, Foundation 파일 조정, PencilKit, Darwin 원자 rename을 재사용하는 데 적용했다. 별도 DB·provider·프레임워크·ARENA·순정 Goal을 추가하지 않는다. 독립 아키텍처 검토 조건은 구현/검사의 기준이며, 이번 코드의 독립 소스 검수와 공식 통합은 별도 단계다.
