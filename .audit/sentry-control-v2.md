# Sentry v2 writer 결과

기준은 bf89ec30ceb693d01d71b604a889254342fb5577이다. 전용 branch는 codex/sentry-control-v2-20261025이다. 실제 Host213과 공유 권한 복구는 부모 소유다.

Pstack Feature/how를 적용했다. Model the Domain 원칙에 따라 DTO, ticket, ControlPreparation, ControlResult, 유효 generation과 작업 원장을 기존 Admission lock에 넣었다. Ponytail full의 기존 코드 재사용을 선택하여 별도 controller, 서비스, 의존성, 런타임을 만들지 않았다. 사용자 지시로 ARENA와 자식 생성은 실행하지 않았으며 독립 검수는 부모가 별도로 수행한다.

초기 SDK 검사에서 검사 코드의 throwing autoclosure를 수정했다. 다음 SDK 검사에서 기존 MobileEnrollment의 visionOS 2.5 API 가용성을 확인하여 검사 target을 2.5로 맞췄다. 마지막 첫 최종 검사에서는 production 계약 399개와 세 SDK 컴파일이 모두 통과했고 입력 해시가 변하지 않았다.

검사 산출물은 /Volumes/BT-Workspace/Development-Archives/CCR-Vision/sentry-control-v2-contract-20261025 아래에 있다. final.json은 현재 production DTO/Admission과 fixture의 입력 해시를 기록한다. source-selection.json은 기존 계약 172개와 전체 Host macOS 타입 검사, legacy.json은 기존 Sentry/curtain/cursor 136개 검사다. source-selection과 legacy는 마지막 원장 밖 오래된 revision의 unknown 반환 및 알려진 requestID의 원본문 conflict 우선 대조 변경 전 실행했다. 해당 변경은 final-fence.json의 원장 만료·ID 필드 변경·동기 재진입 검사로 검증했다.

로컬 실행 이유는 설치된 Xcode 세 플랫폼 SDK와 정확한 공유 프로토콜의 타입 검증이다. 새 원격 소스 사본과 실제 기기 또는 OS 표면을 실행하지 않았다. 모든 scratch는 작업 종료 후 제거되었다. 코드에는 actual UI, 입력, Host 앱, HAL, 기기, 키, 권한, 오디오, 서비스 조작이 없다.

부모 배선용 typed-api.md, request.schema.json, response.schema.json, fixtures.json을 동일 외장 계약 경로에 기록했다. 부모 대화에 대한 send_message_to_thread는 native ancestor 전송 금지 오류를 반환했다. 별도 native 전송 도구가 노출되지 않아 API 변경은 진행 메시지와 외장 파일에 남겼다. 전달 접수 또는 runtime 반영 완료로 보고하지 않는다.

미배선 경계는 현재 TLS paired owner 검사, 기기 회수 callback, 실제 on/off 표면과 capture readback, 설치·통합·실물 수용이다. writer는 push/PR/통합/배포를 수행하지 않는다. 독립 검수 전까지 merge-ready 또는 production 연결 수용으로 표시하지 않는다.

부모의 실제 release 동기 재진입 요구에 따라 일반 입력이 허용되던 inactive 상태에서 prepareControl 후 verify callback으로 allowsActions와 allows(epoch)를 다시 호출하는 반례를 추가했다. 실행 ticket 동안 두 경로는 모두 거절하고 sourceSelectionAdmission.ready=false를 유지한다. 제어 readback은 generic gate와 별개로 계속 응답한다. 성공한 off 후 기존 session/capture를 유지하고, onPrepared는 실행 fence 해제와 source selection 준비 상태 복구를 검증한다.

알려진 requestID의 조회는 현재 유효 role·원장 owner·원장 generation을 먼저 확인한 뒤 정확 rawRequest를 대조한다. 같은 작업의 hostBootID/sessionID/revision/authorizationGeneration 또는 공백을 바꾸면 requestConflict이다. 원장 없는 과거 boot/session/revision은 unknown이며 권한이 회수된 peer에게는 응답하지 않는다.

후속 최종 final-fence.json은 production 계약 413개, macOS/iOS/visionOS SDK 컴파일, 소스 해시 불변, scratch 제거를 모두 통과했다. 전체 writer 변경은 첫 계약 커밋과 원본문 충돌·재진입 반례의 후속 커밋 두 개이며 base부터 순서대로 부모가 수용한다.
