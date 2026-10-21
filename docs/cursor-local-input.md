# Cursor 원본 창의 로컬 입력 후보

이 경로는 아직 설치된 Host142나 CCR 화면에 연결되지 않았다. 운영·실기기 수용이 아닌 후보 계약이다. 기존 Sill 영상·active source·videoEpoch·217/218 오디오 연결은 변경하지 않는다.

## 권한과 소유

- `ccr-local`만 허용한다. AF_UNIX 연결의 실제 uid/PID, 프로세스 시작 시각, 정식 Obsidian 실행 경로와 코드 서명을 Host가 확인한다. Host가 발급한 connectionID는 이 채널에서만 조회 키로 쓰며 다른 채널의 권한이 아니다.
- 최초에 `window-scoped` 원본 화면 제어를 명시적으로 켠 요청만 받는다. 정확한 Cursor 창/PID/서명·프로세스 수명·보존한 AX 창·실제 영상 세대를 연결한다.
- 이 초기 후보는 일반 Sill viewer 연결이 등록되어 있는 동안 로컬 Cursor 입력을 거절한다. 전역 source 전환·대기 중 원격 입력·현장 보호도 로컬 소유를 철회한다. 기존 원격 소유를 빼앗지 않는다.
- 특정 대화 전송·승인 같은 `conversation-scoped` 명령은 `conversation_authority_unavailable`, `sill-delegated` 입력은 `delegated_input_unsupported`로 거절한다. companion0.2의 instance/workspace/selectedIds는 관찰값이며 활성 대화의 원자적 실행 권한으로 쓰지 않는다.
- 이 lease는 CCR/Sill이 검증하는 입력 경로를 조정한다. 물리 사용자·다른 프로그램·다른 에이전트·같은 사용자 권한의 비협조적 프로세스 전체를 통제한다고 보장하지 않는다.

## 발견과 전송

정식 `/Applications/CCR Sill.app` 안에서만 `~/Library/Application Support/CCR Sill/LocalInput/rpc.sock`을 연다. discovery.json은 schema, hostPID, hostBootID, socketPath와 소켓 inode/device를 제공한다. 파일0600·디렉터리0700이며 PID나 파일 내용을 인증 증명으로 삼지 않는다. 호출자도 접속한 Host의 OS peer·프로세스 수명·기존 지정 서명과 정식 경로를 확인해야 한다.

서버 수명 동안 삭제하지 않는 lifecycle.lock을 배타적으로 보유한다. stale 정리는 죽은 PID·자기 파일 신원·연결 거절을 확인한 경우에만 수행한다. 기존 live/알 수 없는 소유는 보존한다.

UTF-8 NDJSON 한 줄에 요청 하나를 보낸다. 메시지 외곽은64KiB, 실제 요청 JSON 검증은 기존16KiB 미만 제한을 적용한다. 중복 JSON 키·BOM·비정상 UTF-8은 거절한다. 한 연결에 효과가 있는 요청 하나만 진행한다. 최대8채널이며 backpressure 실패는 채널을 닫고 그 소유자의 Down만 해제한다.

## 요청과 멱등성

공통 필드는 다음과 같다.

| 필드 | 값 |
| --- | --- |
| schema | 1 |
| requestID | 요청 상관 UUID |
| sequence | 연결 안에서0부터 정확히1씩 증가하는 정수, 최대2^53-1 |
| origin | ccr-local |
| interaction | `{ "kind": "window-scoped" }` |
| operation | hello, bindWindow, renew, input, release |
| connectionID | hello에는 없음. 이후에는 Host가 그 채널에 발급한 UUID |

효과의 멱등성 키는 실제 채널과 sequence다. 미확인 요청은 sequence/requestID/원문 바이트를 유지해 재전송한다. 진행 중 동일 요청은 합치고, 완료한 마지막 요청은 원래 영수증을 돌려준다. 같은 sequence의 다른 ID나 바이트는 채널을 닫는다. 더 오래된 sequence는 다시 실행하지 않는다. 재전송된 영수증은 새 권한이나 TTL 갱신이 아니며 observedAt도 원래 값이다. 채널 종료로 결과를 확인할 수 없으면 자동으로 새 sequence나 연결에 같은 효과를 재발행하지 않는다.

### 연결

```json
{"schema":1,"requestID":"요청 UUID","sequence":0,"origin":"ccr-local","interaction":{"kind":"window-scoped"},"operation":"hello"}
```

observed 응답의 connectionID를 보존한다. 지원 플래그는 구현된 계약이며 현재 제어 권한이나 실제 UI 수용이 아니다.

### 창과 영상 바인딩

bindWindow는 controlEnabled=true와 capture를 보낸다. capture는 pid, windowID, captureGeneration, videoEpoch, frameWidth, frameHeight 및 선택적인 instanceID/workspace로 구성된다. 확장 호스트 PID를 Cursor 메인/창 PID로 대신하지 않는다. 실제 MediaStream에서 관찰한 새 영상 세대를 보내며, 원본 대화 세대를 추정해서 넣지 않는다.

Host는 좌표 비율과 현재 창을 확인한다. activate=true는 이 명시적 제어 요청에 한해 대상 앱/창을 활성화한다. 기존 활성화·AX raise·key 처리와 게시 직전 소유 검사를 재사용하며 Sill의 선택 영상은 바꾸지 않는다. 포커스를 확인하지 못하면 입력 없이 거절한다. 이후 창 초점·수명·위치/크기·인가가 달라지면 소유한 Down을 해제하고 새 바인딩을 요구한다. 실제 영상 좌표 맞춤과 UI 동작은 별도 실증이 필요하다.

bound 응답의 leaseID, leaseGeneration과 captureGeneration/videoEpoch를 보존한다. TTL은 기본500ms, 허용100…2000ms다. 갱신은 같은 창/연결의 lease ID와 세대를 유지한다. 활성 제어 중 TTL 안에 renew하고, 갱신 실패 시 입력을 멈춘다. 입력 요청 자체는 TTL을 연장하지 않는다.

### 입력과 해제

input에는 위 네 scope 값과 기존 StreamProtocol.InputEvent 형식의 event를 넣는다. 위치는0…1이고, 텍스트는256UTF-8바이트 이하이며 정상 유한 스크롤과 HID 키만 허용한다. 각 실제 CGEvent 게시 직전에 동일 채널·peer·lease·창/초점과 원격 우선권을 다시 확인한다.

inputPosted/postedEvents는 요청한 CGEvent가 OS에 게시된 수만 뜻한다. 정리용 Up은 이 수에 넣지 않는다. 대상 앱의 처리 완료, 전체 텍스트의 원자적 입력, 특정 대화 전송·승인 성공을 의미하지 않는다. 후속 UI readback은 호출자가 확인한다.

release는 정확한 현재 scope만 해제하고 검증된 채널은 유지한다. 새 bindWindow는 새 lease를 발급한다. 채널 종료·기한 만료·원격 선점·현장 보호·포커스 상실에서도 해당 소유자의 Down만 정리한다. 원래 영상 세대와 다른 요청은 새 창에 적용하지 않는다.
