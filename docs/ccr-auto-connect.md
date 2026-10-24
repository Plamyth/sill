# iPad reconnects to its saved Mac

The iPad app previously started Bonjour browsing after launch but waited for a tap even when it had a valid pairing. A fresh process has no in-memory `Reconnect` value, so the existing lost-session retry path cannot make the first connection.

`SavedMacs.automaticTarget` selects a formally paired Mac with a valid fingerprint, recognition key, and TLS home door. Once the app has stored `Sill.preferredTrustedMacID`, it selects only that Mac. Older installs without a preference select the uniquely newest eligible pairing once. A missing, revoked, or changed preferred record leaves the app disconnected; it never selects a different Mac by name.

After `startRemote`, the iOS client arms one startup attempt. It waits for an exact network row whose Mac ID and recognition tag match the saved record. `homeDecision` must recognize the pinned TLS door. The dial uses the saved certificate fingerprint and the existing device key. A successful authenticated session records that Mac as the preference. Manual connection and disconnection stop the startup attempt. The app does not open pairing, generate a device key, or use a plain home door for this path.

This path uses the existing saved pairing instead of constructing a synthetic lost-session `Reconnect` value. That keeps initial selection separate from retries after an established session ends. It does not add a background poller. If the saved Mac is absent or its trust record is invalid, the normal Mac list remains available for an explicit user choice.

The pure saved-Mac policy checks cover explicit preference, older-record migration, invalid trust records, and ambiguous pairing order. A signed build was installed on the iPad Pro with bundle `com.ambrion.sillcanvas.ipad`. Two consecutive process relaunches connected to the separate `CCR Sill.app` Mac host without a tap or another pairing code. The Canvas scene file hash matched before and after installation. This verifies local automatic connection on that device and host; remote network recovery and another Apple device still need their own physical checks.

## 보호 복구 뒤 화면 선택 계약

2026-10-24 Host·Core·Android·iPad 담당이 `WindowList.sourceSelectionAdmission`을 공통 계약으로 확정했다. 원본 DTO는 Host 체크포인트 `bfa452d8b438e42612b12f3a7c04ce510bb2f3e6`의 `Sources/StreamProtocol/Sentry.swift`에 있으며, 소비자는 `WindowList`의 선택적 필드만 추가한다.

```json
{"schemaVersion":1,"generation":2,"ready":true}
```

`generation`은 1 이상 9,007,199,254,740,991 이하의 정수다. Host가 연결별로 현재 값을 보존하고 해당 연결의 선택 허용 여부가 바뀔 때 새 단조 증가 값을 배정한다. 다른 기기의 캡처나 같은 상태의 반복 목록은 이 값을 바꾸지 않는다. `ready`는 Host의 `SentryAdmission.allowsActions`와 같은 판정이며, 캡처 epoch의 존재를 요구하지 않는다.

새 iPad 앱은 필드가 없거나 잘못됐거나 `ready=false`이면 자동 화면·창 선택을 보내지 않는다. 따라서 배포 순서는 이 계약을 제공하는 Host를 먼저 반영하고 새 iPad 앱을 후속 반영하는 것이다. 필드의 선택성은 구형 클라이언트가 새 Host의 목록을 읽는 호환성을 위한 것이며, 새 클라이언트가 준비 신호 없는 구형 Host에 자동 진입한다는 뜻은 아니다. 명시적인 수동 선택은 기존 Host의 허용 검사 아래 유지한다.

보호 중 거부된 미확인 자동 선택은 새 허용 세대에서 한 번 재개한다. 중간 차단 목록을 받지 못했더라도 더 새로운 세대가 있어야 한다. 원래 선택 CAS, 사용자 의도, 인증된 Mac, Host 실행, 연결, 현재 화면 목록과 목표를 유지한다. 수동 선택·해제, 다른 선택 CAS나 연결을 관측한 뒤 옛 목록이 도착해도 자동 의도를 되살리지 않는다. 보호 취소 때 전송 보류 중인 옛 티켓도 폐기한다. 타이머 재시도는 추가하지 않는다.

이미 제출·보류한 미확인 창이 사라지면 그 복구를 취소하고 다른 화면으로 바꾸지 않는다. 같은 창 ID가 나중에 다시 나타나도 이 취소를 되돌리지 않는다. 첫 선택을 보내기 전부터 저장된 창이 없는 fresh reconnect의 기존 데스크톱 복구는 별도 동작으로 유지한다.

이 신호는 소스 선택 전송만 허용한다. 실제 영상 표시, 입력, 마이크·스피커와 통화 제어는 각각 기존 epoch·presentation·media 계약의 검증이 필요하다. 소스 검사 통과를 실물 영상이나 오디오 수용으로 기록하지 않는다.
