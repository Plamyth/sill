# Vision 공통 Craft 음성 제어

기준 UI `b997a824bf9b6b0730f148ac0da386a8f5850356`, 초기 준비 모델 `e6c41ead57280aed44e990e661591b96424dac12`, Catalog exact6 수정 `71f19d4ee102ca1f96fc341c08212d3d4273c561`을 보존한 후속이다. e6의 전체 앱 빌드1834는 이 후속 소스의 빌드 결과가 아니다. 원담당은 같은 Vision WT/브랜치를 유지하며 Root 원장·Host/Core 전용 소스·설치·기기·키·오디오는 조작하지 않는다.

## 공통 소스와 의미

Host 후보 `4f8dbf370646008c841696f7b4681ef078e7f7af` / tree `955210e6996d441d20345fbbbe04c43d20a3bf85`의 `ConfiguredCraftAction.swift`를 정확한 바이트로 수용했다. 원 문서 SHA256은 `c40e367edb0c6609c9aa7b41930b77ecb54f0fcc676aee1f924b0672e967546e`다. 기존 Vision의 fetchCatalog212·payload 한도, 화면 stableIdentity, catalog ACK, providerCallKinds, testDestinations와 WindowList 계약을 보존하면서 StreamMessage에는 control225/state226와 정확한 방향·크기 제한만, Switcher에는 optional configuredCraftActions:Int와 기본 nil만 이식했다. 이 두 파일 전체는 Host 파일과 같다고 주장하지 않는다. Host 전용 파일은 이식하지 않았다.

Request/Catalog/Result는 공통 StreamProtocol 타입의 alias다. 별도 로컬 decoder를 제거했다. 실제 state raw bytes는 공통 `ConfiguredCraftActionState.decode`를 통과해야 한다. requestId·operation·현재 인증 deviceId와 원 operationId를 검증하고 exact union·추가 키·중복 키·숫자 토큰 검증을 같은 codec에 맡긴다. client9에는 operation이 있고 session/settings SHA는 없다. deviceId는 기존 DeviceIdentity.existing fingerprint를 사용하며 새 키나 session을 만들지 않는다. assignment SHA는 광고된 불투명 값으로 보존한다.

Catalog/query는 기존 인증 TLS 연결의 읽기 전용 명령이다. capability1을 받은 현재 연결에서만 catalog를 요청한다. catalog가 성공하기 전 binding을 추정하지 않는다. 미지원 Host244에서는 새 kind 전송과 준비가 모두0이다. 제품 설치·실제 지원·가청 효과의 수용은 별도다.

외부 invoke error(unavailable 포함)는 송신 뒤 실패도 포함할 수 있으므로 미실행이나 rejected로 승격하지 않는다. 원 operation의 UNKNOWN을 보존하고 사용자가 누른 read-only query로만 복구한다. typed actionResult.rejected와 unknown은 구별하며 null/다른 binding hash 및 unknown의 invoked false/true를 보존한다. invoked는 통화 시작·종료 ACK가 아니다. effectConfirmed는 항상 false다. timeout·unknown 뒤 자동 invoke나 자동 query 반복은 없다. 같은 인증 기기 reconnect에서도 원 operationId만 조회하며 이전 session을 echo하지 않는다.

4f8의 nested result.reason 제한은 정상 Craft producer의 하이픈 reason과 맞지 않는 알려진 차이다. Root가 공백 아닌 UTF-8<=256 계약의 후속 common file/doc hash를 전달하기 전까지 원 공통 소스를 수정하거나 reason을 치환하지 않는다. outer error의 stable code 규칙은 별도다.

## 실제 준비와 취소

500ms 길게 누르기 한 번만 새 operationId를 만든다. 짧은 Button action은 비어 있다. `VisionConfiguredCraftActionExecutor`가 기존 순수 모델의 prepare/invoke/cancelPreparation을 실제 Store·writer에 전달한다. 새 엔진이나 서비스, 주기 타이머는 없다. 기존 controller 방식의 취소 가능한 단발 deadline 한 개가 준비8초/응답10초와 읽기 응답 기한만 처리한다.

준비는 기존 VisionRemoteAudioAuthority의 단일 owner와 방향별 revision을 사용한다. 명시 선택이 없을 때만 기본 입출력을 준비하고, 명시 OFF/다른 장치는 보존한다. Store는 실제 pendingNativeSelection과 manual ticket을 거쳐 기존 reconcileVisionForwarding·visionAudio.enable·toggleVisionMicrophone/startVisionMicrophoneAutomatically를 사용한다. 새 producer나 native API를 만들지 않았다. 준비 함수는 mediaReady를 생성하지 않는다. 현재 fresh forwarding snapshot, 실제 로컬 microphone/playback 상태와 정리 상태를 읽어 선택 방향과 일치해야 한다. 확인된 both OFF도 허용하며 active call을 요구하지 않는다.

준비 영수증은 operationId·host·원 선택·방향 revision을 보관한다. 취소는 해당 영수증의 현재 revision만 되돌린다. 준비 후 사용자 한 방향 변경은 그대로 두고 준비가 만든 다른 방향만 회수한다. 새 operation·다른 창·다른 host의 새 선택은 늦은 취소가 건드리지 않는다. 원래 선택 부재의 준비 전체를 취소하면 미선택 상태를 복원한다. 이미 존재한 명시 선택과 기존 실행 자원은 보존한다. 인계가 끝난 준비는 기존 독립 마이크/스피커 의도로 남고, 실제 통화 상태를 추정하지 않는다.

scene/foreground/focus·window/admission·video·connection·선택 revision·장치 revision과 Sentry 상태 변화는 같은 모델을 갱신한다. 준비 취소 후 늦은 readback은 invoke를 만들지 않는다. UI 소멸 취소는 그 UI가 만든 operationId에만 결속된다. 기존 연결 초기화와 Store retirement에도 취소가 연결된다. 기존 active native call 종료 식별자·오류·정리 경로는 보존한다.

## 실제 writer와 결과 조회

원래 StreamClient receive callback와 SessionLink writer를 재사용한다. invoke 직전에 현재 authenticated peer·scope·selection·fresh readback·Sentry inactive를 다시 검사하고 takeInvocation을 한 번 소비한다. 큐 제출은 현재 NWConnection과 input permit, readback freshUntil을 상한으로 하는 Submission deadline에 결속된다. scope 또는 준비 상실은 해당 request의 큐 제출을 취소한다. 새 연결에 늦은 명령을 옮기거나 자동 재송신하지 않는다.

Sentry active/unknown이면 prepare/invoke0이며 차단을 표시한다. catalog/query는 읽기 전용으로 허용하며 보호를 해제하지 않는다. UNKNOWN에는 결과 확인 버튼이 원 operation query만 수행한다. 별도 endpoint·decoder·서비스·새 대화·키 하드코딩은 없다.

## 검증과 남은 수용

검사 정본은 `Tests/checks/vision-configured-craft-action/run.py`다. 기존 pure model 검사와 공통 production Protocol 전부, 실제 directive executor, 실제 Store 본문을 격리 컴파일한다. Store fixture는 기존 inert playback/microphone/permission/network 포트를 재사용한다. fake mediaReady를 제품 경로에 넣지 않으며 실제 장치·오디오·OS 권한은 실행하지 않는다. 검사 중 미디어 준비 메서드 호출은 무효 포트의 호출 수다.

최초 실패는 `FAIL prepare/invoke/cancelPreparation의 제품 executor가 UI에 연결되지 않았습니다.`였다. 실행 증거·실패 영수증·source SHA·Mini 정리 결과와 후속 SDK 빌드는 외장의 `vision-craft-media-executor-20261106` 및 `vision-craft-media-executor-build1835-20261106`에 남긴다. 기존 audit 두 파일은 `vision-configured-craft-full-build-20261106/audit-preservation`에 검증 사본과 이동 원본으로 보존돼 있다.

Pstack Feature/how/TDD와 model-the-domain으로 operation 준비 영수증과 기존 상태 모델을 사용했고 Ponytail full로 기존 authority·writer·fixture를 재사용했다. 71f 독립 검수와 후속 구현은 정확 commit 객체로 분리한다. Root가 후속 exact 소스를 통합·독립 검수하며 실제 Host/Core 설치, Codex 사용자 키 동작, Vision 착용·가청 입출력은 아직 미검증이다. productAcceptance=false를 유지한다.
