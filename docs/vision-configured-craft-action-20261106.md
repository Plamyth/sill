# Vision 공통 Craft 음성 명령 소스 준비

기준은 `b997a824bf9b6b0730f148ac0da386a8f5850356`, tree `ad14ef1e75c192cc81676e6e7029f9fcb915e7b2`다. 같은 WT/브랜치에서 새 후속 커밋으로 진행한다. 기존 UI 체크리스트와 b997 이력은 보존한다. 이 문서는 이전 native prepared-producer 경로의 OFF 시작 차단 기록을 대체하는 새 공통 shortcut 방향이며, 이전 기록을 제품 완료로 바꾸지 않는다.

## 확정된 의미와 데이터

- 기존 Craft 사용자 할당을 재사용하는 500ms longPress다. 키 조합·새 native producer·appserver·대화·endpoint·wire 번호는 만들지 않는다.
- `Request`는 Core 초안의 schemaVersion, 단일 operationId, deviceId/deviceSessionId, inputID, trigger, expectedProfileId, expectedAssignmentSha256, issuedAt를 보존하는 로컬 값이다. issuedAt는 로컬 Date이며 최종 wire 표현이 확정되지 않아 request encoder나 sender는 구현하지 않았다.
- `Result`는 필수 outcome·operationId·deviceId·bindingSha256·invoked·effectConfirmed와 선택 reason을 받는다. outcome 생략이나 통화 started ACK를 허용하지 않는다. `effectConfirmed=true`는 유효한 shortcut 결과로 수용하지 않는다.
- `unknown + invoked=true`는 합법적인 executor 인계·효과 미확인 결과다. 해당 Bool을 보존한다. 통화 활성/종료를 추정하거나 자동으로 다시 토글하지 않는다. 사용자의 새 500ms 동작만 새 operationId를 만들 수 있다.
- assignment SHA는 호스트가 광고한 불투명 값이다. Core의 실제 KeyAssignment 다섯 필드(id/inputID/trigger/requiredModifiers/action) 정의를 Vision에서 재계산하지 않는다. 축약 세 필드 hash, 소문자 정규화, 별도 canonicalizer는 없다. 반환 hash와 문자열 그대로 비교한다. profileId와 settings SHA는 별도 fence 필드다.

## 최소 상태와 선택 보존

`VisionConfiguredCraftAction`은 순수 값 상태다. `idle → preparing → ready → awaiting → completed/unknown`과 취소만 관리하며 통화 세션·오디오 엔진·타이머·네트워크를 소유하지 않는다.

한 operation의 fence는 인증된 host, connection, window/admission, video, foreground, deviceSession, profile/assignment/settings SHA, local route generation 및 선택 revision을 고정한다. `takeInvocation`은 실제 sender 직전 다시 확인해야 하는 단일 소비 지점이다. 같은 후보를 두 번 소비할 수 없다. 준비 기한 8초와 응답 기한 10초가 끝나면 같은 operation의 취소/unknown이 되며 poll은 새 명령이나 ID를 만들지 않는다.

사용자가 저장한 `VisionRemoteAudioIntent.Desire`와 기존 방향별 revision을 읽는 getter를 재사용한다. 명시 선택이 없을 때만 기본 양방향을 준비하도록 요청한다. 명시된 각 OFF는 그대로 유지한다. 기존 Mac 장치 선택 요청 이력이 있으면 Vision 양방향을 기본 ON으로 강제하지 않고 그 장치 목록 revision을 결속한다. 장치 controller에는 기존 선택 카운터의 읽기 전용 getter만 추가했다.

fresh `providerCallSnapshot`의 방향이 선택과 같아야 한다. 선택된 ON은 기존 입출력 준비 상태를, OFF는 정리된 로컬 상태와 현재 원장의 OFF 방향을 확인한다. 양쪽 OFF도 현재 `.off` snapshot이 확인되면 허용하며 configured toggle에 native activeCall을 요구하지 않는다. 새 shortcut과 기존 통화 원장은 분리하고, 기존 activeCall이 남아 있는 경우의 명시적 종료 경로는 보존했다.

준비를 실제 수행할 adapter는 자신이 만든 방향 revision을 `recordPreparedSelection`에 연결해야 한다. 이 메서드는 요청 ID·동일 fence·현재 선택·정확 revision만 수용하고 요청 ID와 기한을 바꾸지 않는다. 준비 중 새 사용자 OFF·장치 선택·창/연결 변화가 오면 취소한다. 정리 directive에는 해당 operation의 선택/fence/revision이 들어 있으며 새 사용자 의도를 덮는 전역 초기화는 허용하지 않는다.

## 현재 연결되지 않은 부분

UI `configuredContext`는 기존 인증·입출력·선택 readback만 읽고, descriptor binding과 route generation은 nil, capability와 route 구현 표시는 false로 남는다. 따라서 현재 주 버튼은 실행 불가이며 operation 발급·새 미디어 준비·전송이 모두 0이다. 짧은 Button 동작은 비어 있고 longPress gesture만 연결했다.

`prepare/invoke/cancelPreparation`은 순수 상태의 directive다. 현재 UI에는 이를 실행하는 adapter가 없으며 실제 준비/취소/전송이 연결됐다고 주장하지 않는다. Core/Host가 인증 TLS peer·Host session, capability descriptor, 정확 route와 수신 adapter를 확정한 뒤에만 다음을 연결한다.

1. 광고 binding/지원 상태를 해당 현재 문맥에 넣는다.
2. 선택을 보존하는 기존 미디어 준비와 operation별 revision 영수증을 연결한다.
3. await 경계와 실제 sender 직전에 fence를 재검사하고 `takeInvocation`을 단 한 번 소비한다.
4. 취소·timeout의 해당 준비 자원만 정리하고 새 사용자 선택을 보존한다.
5. Core 결과는 invoked/rejected/unknown으로만 표시한다. timeout/unknown을 자동 재전송하지 않는다.

## 실행 근거

Pstack Feature/how/TDD와 Ponytail full로 기존 구조를 재사용했다. ARENA·새 순정 Goal·추가 모델 분할은 실행하지 않았다. Root의 독립 검수는 별도다.

- 수정 전 새 검사는 `FAIL 음성 주 동작에 500ms longPress가 없습니다. 짧은 누름과 통화 ACK 경로가 남아 있습니다.`로 실패했다.
- `Tests/checks/vision-configured-craft-action/run.py --mini <근거 폴더>/mini-final.json`: 최신 순수 모델 146개 통과. source 불변·scratch 제거·Mini ephemeral 정리 true. 실제 Host/Core/기기/오디오/입력 효과 0.
- 최초 Mini SSH 시도는 exit 255였고 cleanup은 true였다. 저비용 접속 확인 후 같은 owner/job으로 재시도했다. 실패 영수증을 덮지 않고 보존했다. 사용자 선택 정정 뒤 재검사한 최종 결과가 위 146개다.
- 기존 `vision-simple-call-controls/run.py --static-only`의 구조 검사 5개가 통과했다.
- 기존 제한 SDK runner에 새 순수 모델과 선택 모델을 포함했다. 실제 XROS 27.0, target 2.5에서 `[0,0,0]`, source 불변·scratch 제거 true다. StreamClient와 controller는 실행하지 않는 stub이다. 추가한 getter들은 구문 검사와 소스 검토 범위다.
- Xcode 일반·release-test 두 source phase와 생성기에 새 파일 등록을 확인했다. 전체 앱 빌드·서명·설치·실기 입력은 하지 않았다.

근거 폴더는 `/Volumes/BT-Workspace/Development-Archives/CCR-Vision/vision-configured-craft-action-20261106`다. 최종 commit/tree와 파일 SHA는 그 폴더의 `handoff.json`에 남긴다. 제품 연결·전체 앱 수용·실제 명령 효과·가청 입출력은 미검증이다. CUA 안전 거절을 우회하지 않으며 최종 실제 버튼 동작은 사용자 직접 행동으로 남긴다. Root/Host/Core/기기/키/권한/원장 쓰기는 0이다.
