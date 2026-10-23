# 물리 출력 프로세스 tap 후보

기준은 `d6f113c100b09e7e23af50f7fb87b32e5ea10d38`이다. 원담당은 iPad 대화 `01a13ace-e372-7ed1-9946-149df37ee1c9d`, 통합·독립 검수 담당은 호스트 대화 `01a13005-ff61-7780-b0e8-6dc171de1c9d`다. 실제 HAL/tap/hog/장치/앱 호출은 이번 작업 범위에서 금지한다.

## 실행 절차와 병렬 경계

- Pstack Feature의 관련 구조 조사, 최소 설계, 독립 구현, 주입 검사, 정확한 커밋 반환을 수행한다. ARENA·순정 Goal은 사용하지 않는다. 부모가 제품 한도를 확인해 이 기존 담당에게 분리한 구현이므로 중복 하위 작성자를 만들지 않는다. 독립 검수는 부모가 맡는다.
- 선행 확인은 정확한 기준 커밋, 기존 `HostExclusiveAudioSilence` 구조, Apple SDK의 tap 설명과 읽기 속성이다.
- 독립 작업은 이 파일과 새 후보·주입 검사뿐이다. 부모의 gateway·기존 AudioPrivacy·Exclusive·Package·실제 호스트와 공유 상태를 수정하지 않는다.
- 공유 상태 쓰기는 없다. 같은 오디오 장치·앱·서비스 시험은 이 단계에 넣지 않는다.
- 최소 분해는 한 후보 transaction과 한 독립 검사다. Ponytail은 기존 `Operations / Device / Evidence` 형태와 플랫폼 API를 재사용하고 별도 프레임워크·런타임·일반화된 정책 계층을 추가하지 않는 방식으로 적용한다.

## 검사

macOS 14.2 이상 API가 있는 SDK에서 `python3 Tests/checks/host-process-output-silence/run.py`로 컴파일하고 주입 검사만 실행한다. `Operations.native(uid:)`는 호출하지 않는다. 실제 `CATapDescription` 객체 구성은 검사하지만 `AudioHardwareCreateProcessTap`은 검사 중 실행하지 않는다. Mini에서는 기존 `mini-ephemeral-source` 작업 경로로 실행하고 정리 영수증을 회수한다.

## 부모 통합 지점

소스는 기존 `SillHostCore` 폴더에 들어가므로 Package 변경은 필요 없다. 이 후보를 아직 `HostAudioPrivacy.plan()`이나 원격 오디오 허용 판단에 연결하지 않는다.

검수와 별도 공유 호스트 시험이 허용된 후에만 부모가 `HostProcessOutputSilence(uid: uid, ops: .native(uid: uid))`를 생성하고 명시적으로 `startCandidate()`를 부른다. `inspectCandidate()`는 같은 장치 ID·UID·물리 transport·전체 출력 stream inventory·물리/가상 format과 본인 tap UUID·private/exclusive/muted/deviceUID/index를 다시 읽는다. 전후 readback 사이의 원자적 장치 잠금이나 지속 감시는 입증하지 않는다.

종료는 모든 native/relay 참여자를 fencing·drain한 후 부모가 `retireAfterAuthenticatedReturn()`을 명시 호출한다. 생성 중 부분 실패는 소유 UUID가 확인되는 tap만 정리한다. 소유권·제거 부재 readback이 불명확하면 핸들과 실패 상태를 유지한다. 객체 해제나 프로세스 사망이 외부 출력을 계속 막는다고 가정하지 않는다.

부모는 `startCandidate()`가 실패해도 `hasOwnedResources == true`이면 후보 객체를 강하게 보존해야 한다. 정리 재시도와 소유권·부재 readback이 끝나기 전에 객체를 버리거나 후보를 대체하지 않는다.

모든 `Evidence.permitsRemoteAudio`는 `false`다. 입력 차단·아날로그 믹서 경로·실제 여러 프로세스의 출력·BlackHole 동시 경로·장치 hotplug·프로세스 사망 후 보호는 별도 검증 전 미입증이다. 실제 DN32-LIVE와 실행 중인 149, ControlRoomAudio, 17648/17649, iPad 및 음성은 그대로 보존한다.

API 근거는 설치된 `CoreAudio.framework/Headers/CATapDescription.h`, `AudioHardwareTapping.h`, `AudioHardware.h`와 [Apple tap 문서](https://developer.apple.com/documentation/coreaudio/catapdescription)다. 장치별 stream의 `.muted` 설명이며 조건부 음소거·전역 mixdown을 선택하지 않는다.
