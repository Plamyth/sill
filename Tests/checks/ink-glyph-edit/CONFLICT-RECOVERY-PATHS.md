# 충돌 복구 디렉터리와 실제 격리 파일 IO

2ccc97b의 새 choice/local/attempt 파일이 checkpoint 옆에 생성되지만 DEBUG isolated validateStateURL의 고정 StateFile 허용 목록에는 없어 실제 --ccr-test-runtime에서 거부되는 결함을 수정한다. 앞 normal/temp 문맥의 38개 검사는 이 격리 경계의 증거가 아니었다. 이전 영수증은 그대로 보존한다.

부모가 채택한 최소 보존 경로는 다음과 같다. 새 기능은 아직 설치·사용 전이므로 예전 인접 위치의 동적 파일을 이동하거나 삭제하는 migration은 넣지 않는다.

| 문맥 | 유일한 동적 복구 디렉터리 |
| --- | --- |
| 정상·Release | Application Support/CanvasConflictRecovery/ |
| DEBUG isolated | Application Support/CCRIntegrationTests/<현재 runtime UUID>/state/CanvasConflictRecovery/ |

허용하는 파일은 `CanvasConflictChoice.json`, `CanvasConflictLocal-<UUID>.json`, `CanvasConflictAttempt-<UUID>.json`뿐이다. 파일명의 UUID는 새 로컬 백업·이전 선택 보관 때 생성한 canonical 소문자/hyphen UUID다. 다른 **runtime UUID 디렉터리**는 거부한다. 파일명 UUID와 runtime UUID를 같은 값으로 강제하지 않는다. 경로 일부, 임의 JSON, 대소문자 별칭, 하위 디렉터리, 확장자 우회로 범위를 넓히지 않는다.

Workspace의 생성/조회/재열기/이전 요청 보관은 `CanvasRuntime.conflictRecoveryURL` 하나를 사용한다. isolated validator는 현재 runtime의 정확 디렉터리·파일 URL과 세 이름 문법을 대조한 다음 기존 checkPath를 적용한다. 기존 withParent/openat/O_NOFOLLOW·일반 파일·단일 hardlink 검사와 atomic write는 변경하지 않는다. 이미 받은 URL 뒤 부모가 symlink로 바뀐 경우도 실제 read/write에서 거부한다. 기존 scene/outbox/note/block recovery/checkpoint/preferences 및 runtime.json의 허용 범위는 변경하지 않는다.

`writeRuntimeReceipt`, 기존 descriptor read/write 함수, Scripts/actualCodeImages는 수정하지 않았다. 정상 ORIGINALS snapshot의 디렉터리 전체 해시와 부재/추가/변경 검사는 별도 Ohm 소유이며 이 writer가 완료했다고 주장하지 않는다. 부모가 두 worktree의 의미를 통합해야 한다.

## 실행한 실제 소스 경계

`recovery-isolation-check.py --output <검증된 외장>`은 제품 CanvasModel.swift 전체와 CanvasLocalFile을 DEBUG/Release로 직접 컴파일한다. DEBUG 자식 프로세스는 실제 `--ccr-test-runtime UUID`, context.json, embedded Info.plist를 읽어 CanvasRuntime.launch를 결정한다. LaunchState를 주입하거나 추출한 validator로 바꾸지 않는다. 정상/유효 격리/무효 격리/부모 링크/Release 문맥, 세 종류 생성·교체·재열기, 잘못된 이름, 다른 runtime UUID/root, symlink·hardlink·directory 및 늦은 부모 교체를 검사한다. 정상 scene/outbox와 새 복구 자료의 synthetic 원본 바이트는 전후 동일해야 한다. 테스트가 만든 hardlink만 제거해 보호 fixture의 link 수를 되돌리며 실제 앱·사용자 자료 삭제는 없다.

`reconciliation-check.py --isolated --sdk-check --output <검증된 외장>`은 실제 DEBUG Model/Store/Relay와 Workspace 함수 본문을 같은 실제 격리 실행으로 검사한다. 기존 38개 동작에서 choice/local/attempt가 정확 새 폴더에 쓰이고 재열리는 경로를 통과해야 한다. transport와 UI 상태 보관은 fixture이며 실제 HTTP/SwiftUI 화면·기기 수용은 아니다. 임의 public fixture 호스트를 쓰지 않고 context와 일치하는 RFC1918 endpoint를 URLProtocol로만 처리한다. 정상 app support의 scene/outbox/동적 복구 fixture 해시는 전후 대조한다. iOS27 제품 typecheck도 같은 최종 소스로 실행한다.

새 provider·앱·계정·Host·기기·Pencil 요청·push·운영 서비스 변경은 없다. unsigned 번들/설치 readback과 전체 앱 완료는 계속 false다. Pstack의 실제 실행 경계 대조와 반례 확인, Ponytail의 기존 descriptor IO/상태 경로 재사용을 적용한다.
