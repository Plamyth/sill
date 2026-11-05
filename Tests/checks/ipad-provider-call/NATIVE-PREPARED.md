# iPad native prepared target 소비 준비

## 2026-11-05 native selector 후속 계약

아래 prepared-only 본문은 Root `8a59`를 읽었을 당시의 구현·미확정 사항을 보존한 이력이다. Root `9b094514` 후속 계약과 기준 `5558f027ae96ab935160f09a9adbf808537dd6af`의 native selector 구현으로 아래의 Dots-only·native 제어 미지원 설명은 현재 상태가 아니다. 최종 소유 WT와 검사 경로는 [README.md](README.md)의 최종 구현 절을 따른다.

- client control은 native에 한해 schema 2와 `expectedProviderKind: codex-app-server`를 사용한다. 요청 7필드·digest와 응답 schema 1은 유지한다. Dots는 schema 1을 유지한다.
- 현재 peer가 `providerCalls == 1`과 `providerCallKinds`의 native 지원을 명시할 때만 native 제어를 허용한다. 단순한 기본 선택이나 prepared hash 일치는 광고·권한이 아니다.
- prepared target과 challenge는 Core↔Host 내부 계약이다. Root 확정에 따라 HostRuntime이 `target.voiceSessionId`를 검증한다. client prepared ingress는 없고, 순수 decoder는 여전히 제품 수신 경로에 연결하지 않는다. 새 endpoint·최종 이벤트 envelope·광고를 추정해 추가하지 않았다.
- client는 matching native perform `started`의 유효한 UUID 원문을 `activeCall`에 보존한다. native stop 요청과 `stopped` 응답은 그 원문 문자열에 결속하며 다른 provider나 정규화한 세션 문자열을 수용하지 않는다. stop 실패는 활성 세션을 지우지 않으며 같은 세션 수동 stop만 허용한다.
- query 응답은 과거 기록으로 분리하며 현재 통화·미디어 권한을 만들지 않는다. native 표시 문구도 화면 관측을 주장하지 않고 Mac 응답과 과거 기록을 구분한다. Dots null 종료, 자동 4회·10초와 별도 수동 query 10초, 실제 TLS 교체 전 timeout 슬롯은 유지한다.

기준 후보 관련 731개 검사는 `native-selector-20261105/checks-02.log`와 cleanup 영수증으로 재사용한다. 최종 문구 변경의 관련 모델·실제 adapter 회귀는 README의 새 Mini job으로 별도 실행한다. 최초 throwing `&&` fixture 컴파일 실패는 기존 `checks.log`에 보존한다. 합성 검사 성공은 SDK·서명·설치·실제 Host/Core·native 통화·음성 입출력 수용이 아니다. 전체 SDK와 독립 비작성 검수는 부모가 소유하며 실제 앱 85/OFF는 변경하지 않는다.

최종 재검사는 2026-11-05 21:22 KST에 738개 통과와 Mini 임시본 삭제를 확인했다. native 모델은 문구·과거 응답 분리 회귀 7개를 더한 55개다. exact 입력 SHA256과 로그 경로는 README에 기록했다. 제품 해시 확인은 SDK·설치·실기 수용을 대신하지 않는다.

24k codec·리샘플링·미디어 transport·private challenge는 이 selector 작업의 범위 밖이다. 원음 저장·새 provider·API·권한·실제 통화 실행은 없다.

## Root 8a59 prepared-only 구현 이력

작업 키: `ipad-native-prepared-target-20261105`.
원담당/통합 책임자: `01a13ace-e372-7ed1-9946-149df37ee1c3`.
작성자 소유: `/Users/ambrion/.codex/worktrees/ipad-native-prepared-target-20261105`, `codex/ipad-native-prepared-target-20261105`.
기준: 공식 `integration/ccr-ipad`의 `d5a591fa8f57c3fb62ae17fea7c62bc1425f1f01`.
Host 정본: Root 전용 WT의 `8a59b524810775d132ee63d9cb2a8eb55dc02d18`를 Git 객체로 읽었다. Host·기기·integration 파일에는 쓰지 않았다.

## 확인한 현재 구조

`IPadCallTarget.nativeCodex`는 기본 선택이지만 `supportsProviderCall`은 Dots에만 true다. `StreamClient+ProviderCall`은 현재 자기 forwarding binding·인증된 Mac·전경·privacy 보호·freshness 등을 확인한 뒤 Dots용 221을 보낸다. `IPadProviderCall.receive`는 provider가 `chatgpt-dots-webguest`인 matching 요청만 수용한다. `4831a4c7`에서 이미 구현한 native 결과와 Dots 슬롯 분리를 재사용하고 중복 구현하지 않았다.

Host `ProviderCallBridge.swift`의 `CodexRealtimeTarget`과 고정 벡터가 확정한 필드는 아래 6개다.

| 필드 | 확정 규칙 |
| --- | --- |
| schema | `ccr-codex-realtime-target-v1` |
| providerKind | `codex-app-server` |
| providerInstanceId | 하이픈을 포함한 UUID 원문 문자열 |
| threadId | 하이픈을 포함한 UUID 원문 문자열 |
| voiceSessionId | 하이픈을 포함한 UUID 원문 문자열 |
| targetHash | 앞 5개 문자열의 순서 있는 JSON 배열 UTF-8 바이트의 SHA-256, 소문자 hex |

UUID 비교용 대소문자 허용과 hash 바이트 보존을 분리한다. UUID 값을 정규화해 저장하거나 hash 입력의 대소문자를 바꾸지 않는다. 추가·누락·null·잘못된 타입·Dots 필드가 섞인 입력은 거부한다.

## 최소 구현

기존 `Sources/StreamProtocol/ProviderCall.swift`에 `CodexRealtimePreparedTarget`을 추가했다. 기존 정확한 key 검사와 CryptoKit을 재사용하며 새 의존성과 프로젝트 Sources 등록은 필요 없다. Host 소유의 local 타입을 옮기거나 수정하지 않았다.

기존 `iOSClient/IPadProviderCall.swift`의 선택 enum에 `preparedNativeTarget(from:)` 순수 함수를 추가했다. native 선택에서만 확정 payload를 파싱하며 별도 저장·통신·권한 부여·미디어 시작을 하지 않는다. `supportsProviderCall`, 기존 모델의 receive/perform/query, 원래 221/222 adapter는 변경하지 않았다.

## 남은 계약과 명시적 미구현

- Host의 challenge prepared target은 Core↔Host 내부 교환이다. 현재 iPad 221 request에는 provider/target 선택 필드가 없고 222에는 prepared target과 final-event envelope가 없다. iPad에 전달하는 확정 ingress/메시지 kind/버전·인증·scope·외부 targetHash 상관관계는 이번 정본에서 확인되지 않는다. 이 소비 함수는 확정 ingress에서 호출할 준비이며 현재 제품 수신 경로에 연결하지 않았다.
- Host `8a59`의 `ProviderCallResult`가 native provider 문자열을 허용한다는 사실은 native의 final started/stopped/error 이벤트, 순서·취소·재접속·요청/세션/target 상관관계와 실제 통화 성공을 정의하지 않는다. 이미 있는 Dots 요청에 native 결과를 수용하지 않는다.
- prepared target hash 일치는 바이트 무결성 검사다. 소유권·전달 승인·현재 통화·보호 attestation·센츄리·마이크/스피커 허용을 만들지 않는다. 과거 query 결과도 현재 미디어 허가가 아니다.
- iPad `IPadMicrophonePCM.sampleRate`는 48,000이다. 이 prepared 계약은 native의 24k codec, 채널·샘플 형식·프레이밍·리샘플링·미디어 transport를 정의하지 않는다. PCM 변환·새 media kind·codec 선택을 구현하지 않았다.
- 실제 native 시작·중지, final 이벤트 소비, iPad 설치·실기·Host/Core 공동 수용은 미완이다. 키 생성·유료 API·제품 설치·공유 UI 조작은 0회다.

## 검증과 계보

Host `8a59`의 `native-target-vectors.json` 원문을 byte 그대로 재사용했다. 소문자·대문자 UUID의 서로 다른 golden SHA256, 필드별 누락/null/type, 잘못된 schema/provider, legacy/final-event/codec/credential 혼합, hash 변조, matching hash를 다시 만든 malformed UUID, 다른 선택 대상 거부와 기존 native 미지원 경계를 실행했다.

`Tests/checks/ipad-provider-call/run.py`를 공식 Mini ephemeral 소스 경로에서 실행했다. provider 모델·wire 212개, 기존 forwarding 모델 191개, 실제 forwarding adapter 64개, 실제 provider adapter 85개, admission 69개가 통과했다. source unchanged와 scratch removed, 공식 runner의 cleanup verified를 확인했다. 이 결과는 native 통화나 실기 수용이 아니다.

Mac 필수 iOS SDK 검사는 정확한 공유 StreamProtocol 전체와 실제 `IPadProviderCall.swift`만 arm64 iOS 27 SDK로 컴파일했다. 서명·전체 앱 패키징·설치를 하지 않았으며 전체 integration 앱 빌드와 독립 비작성 검수는 부모 담당의 후속 단계다. 외장 산출물 `native-prepared-target-20261105`에 exact 소스 hash, Host 계약 hash, SDK log와 Mini 영수증을 남긴다.

## Pstack / Ponytail 실행 범위

Pstack Feature의 how·계약 대조→최소 설계→독점 작성→matching 검증 경로를 수행했다. ARENA와 순정 Goal을 사용하지 않았다. Ponytail full로 기존 DTO 파일·key 검사·iPad 선택 enum·provider 회귀 runner를 재사용했다.

- 선행 조건: 공식 integration ref/remote/HEAD와 clean 상태, 기존 native 결과 후보, Root exact Git 객체를 확인했다.
- 독립 작업: Mini의 순수·가짜 전송 검사와 Mac의 SDK 컴파일을 병렬로 실행했다. 부모의 81 실기 OFF 작업은 공유하지 않는다.
- 공유 가변 상태: 이 새 WT만 작성한다. Host·기기·integration·오디오·registry·키·서비스를 조작하지 않는다.
- 최소 분해: 확정 DTO와 순수 선택 소비만 같은 작성자가 맡는다. 미확정 final-event/codec 구현이나 별도 실행 담당을 만들지 않는다. 독립 비작성 검수와 단일 통합은 부모가 소유한다.
