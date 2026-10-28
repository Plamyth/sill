# 공식45b5와 client 명시 조정의 의미 통합

공식45b5eab13621522c54b58aabd52d3e3b6c4e2b16/treef3155ab5afa998b38d5cb96967dfc724477f5cc9를 a8fe269 client 계보에 merge한다. 공식 서버2c90 및 spacing7c5는 부모 독립 CLEAR의 정확 소스를 소비한다. 서버나 spacing geometry를 다시 구현하지 않는다. 자동 텍스트 병합은 성공했지만 실제 pending/presentation의 결합 경계는 추가 보완한다.

canApplyReconciledCanvas는 pendingInkSpacing/pendingInkTextEditing의 기존 hasPendingWork, inkShapeProposal, inkMathRequest/proposal, handwritingRequest를 확인한다. applied/undone 이력이나 닫은 controller의 weak 참조 자체를 영구 busy로 보지 않는다. 기존 공통 inkBusy 및 spacing propose/confirm/graph Undo·Redo 함수는 유지한다.

spacing/glyph/shape/math/conflict의 다섯 editor는 하나의 item sheet로 표시한다. 이미 표시 중인 editor는 늦게 도착한 후보에 의해 교체되지 않는다. 해당 editor를 닫을 때 그 editor의 미확정 작업만 취소하며 spacing/glyph의 applied Undo 상태는 invalidatePending으로 보존한다. 원래 spacing Task 취소·문구 선택·확정 hook과 모듈 자체 generation 검사는 그대로 재사용한다. inspector·note·댓글·연결·import/export 등 기존 다른 화면이 열렸을 때 conflict 조회 응답이 새 sheet를 겹쳐 열지 않는다. 기존 다른 화면 전체를 새 체계로 재작성하지 않는다.

conflict 조회/자료 갱신은 request token·presentation epoch·주소/token·scene·로컬 바이트 SHA와 Task 취소를 확인한다. 확인 화면의 연결 주소/token/epoch도 고정해 다른 연결로 예전 DTO를 보내지 않는다. 다른 editor 열림·취소·화면 이탈·연결 변경 뒤의 늦은 응답은 새 화면을 열거나 선택본을 설치하지 않는다. 이는 실제 SwiftUI 시각 수용이 아니라 원본 함수의 native 실행과 SDK로 검증한다.

로컬 완료 정책은 choice.resolved를 쓴 다음 checkpoint를 마지막 authoritative commit으로 해제하는 것이다. choice 마지막 쓰기가 실패하면 checkpoint는 held로 남는다. checkpoint 쓰기 실패 뒤의 resolved choice도 명시적 동일 결정 확인으로 복구할 수 있다. checkpoint가 없거나 읽을 수 없을 때는 같은 주소/scene의 보존 choice로 barrier를 복원하는 초기화 분기를 둔다. 정상 resolved choice가 남아 있어도 새 server held J를 우선 GET으로 읽는다. GET404일 때만 이전 resolved 결정의 로컬 완료를 명시적으로 재확인하며 SHA 일치만으로 해제하지 않는다. 원래 a8fe의 checkpoint→choice 순서 반례는 변경 전 근거로 보존한다.

복구 파일은 기존 전용 CanvasConflictRecovery의 exact 이름/UUID/no-follow만 허용한다. helper는 checkpoint 파일 자체의 정상 여부와 독립적으로 현재 runtime state 디렉터리를 사용하므로 checkpoint의 실제 IO 오류가 보존 choice 읽기를 막지 않는다. writeRuntimeReceipt, 기존 descriptor IO, Ohm codeImages/adapter는 수정하지 않는다.

native 집중 검사는 실제 spacing/glyph의 읽기와 미리보기·취소, 실제 도형 제안, 공통 spacing Undo·Redo, 단일 sheet 상태 전이, 늦은 GET 취소/token/scene/다른 sheet, 서버 성공 뒤 choice/checkpoint의 실제 directory IO 실패와 재열기를 다룬다. UI 상태 보관과 transport는 fixture다. 서버 실제 파일·HTTP 수용으로 확대하지 않는다. 공식 spacing의 좁은 제품 검사를 함께 실행하며 geometry 전체와 서버 전체 suite는 반복하지 않는다.

별도로 실제 URLSession→서버2c90에서 recoveryID UUID의 대문자 JSON 인코딩이 strict journal lookup과 맞지 않는 반례가 도착했다. DTO/expected/UI를 유지하고 transport 인코딩만 canonical 소문자 문자열로 바꾸는 별도 후속 commit과 정확 JSON body 검사를 제공한다. 이 변경 전 native fixture 통과를 실제 HTTP 통과로 세지 않는다.
