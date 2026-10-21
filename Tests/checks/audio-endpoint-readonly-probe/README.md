# 오디오 장치 읽기 전용 진단

일회성 CoreAudio 진단을 표준 Python으로 다시 실행할 수 있게 만든 체크다. Host 소스나 오디오 설정을 변경하지 않는다. Python 3.10 이상을 사용하며 추가 패키지가 없다. 네이티브 backend는 macOS에서만 로드한다. 모듈 import와 가짜 backend 테스트는 CoreAudio를 로드하지 않는다.

## 조회 계약

`PropertyObservation`은 `has`, `sizeStatus`, `getStatus`, `settableStatus`, `settable`, `value`, `error`를 분리한다. `sizeBytes`와 `returnedSize`도 보존한다. OSStatus의 0은 해당 호출 성공, null은 미호출이다. `error`는 단계와 오류 문구의 배열이다.

- `has=false`이면 다른 속성 호출을 하지 않는다. 이는 조회 실패가 아니다.
- settable 조회가 실패해도 크기와 값 조회를 진행한다. 성공한 값과 실패한 settable 상태가 함께 남는다. 채널 값 조회가 성공하면 settable 실패와 무관하게 실제 개별 채널 범위를 조회한다.
- 크기 또는 값 조회가 실패하면 값은 null이다. 속성이 없다고 바꾸지 않는다.
- 장치 ID·UID·이름·alive·transport와 입력·출력의 실제 채널 합계를 기록한다. 장치 ID는 이번 표본 안에서만 식별자로 사용한다.
- 각 입력·출력 scope에서 main `0`과 실제 채널 `1..N`의 mute, volumeScalar, volumeDecibels를 조회한다. main이 없어도 개별 채널을 조회한다. 채널 수가 미확인이면 main만 남기고 `complete=false`로 표시한다.
- global scope에서 signed hog PID와 settable, IsRunningSomewhere, IsRunning을 기록한다.

HAL에서 연결하는 함수는 `AudioObjectHasProperty`, `AudioObjectGetPropertyDataSize`, `AudioObjectGetPropertyData`, `AudioObjectIsPropertySettable` 네 개다. Setter·Start·IOProc·listener를 연결하지 않는다. CFString 변환과 `CFRelease`는 별도 CoreFoundation 함수로 처리한다. 성공한 이름·UID get이 반환한 객체는 크기·타입·변환 검사 실패에도 한 번 해제한다. 실패한 get의 출력 포인터에는 소유권을 가정하지 않는다.

장치 수는 4096개, 속성 버퍼는 64 KiB, AudioBuffer 수는 1024개, scope별 채널 합계는 4096개가 상한이다. CFString은 UTF-16 16384 단위와 UTF-8 64 KiB가 상한이다. 초과 시 잘라서 성공 처리하지 않는다. 자료형 크기·반환 크기·실제 데이터 길이·중복 ID·중복 UID·잘린 AudioBufferList·NULL이 아닌 stream 데이터 포인터·NaN·무한대를 확인한다. `mData`를 역참조하거나 오디오 샘플을 읽지 않는다.

## 전후 표본과 결과

`anchors.before`와 `anchors.after`에는 전체 장치 ID 목록, 장치별 UID·hog·두 running 값, 기본 입력·출력·시스템 출력 ID가 들어간다. UID는 각 장치 ID에 연결되므로 기본 장치의 UID 변경도 비교에 포함된다. 이름 필터는 상세 조회 대상만 줄이며 전후 anchor 범위를 줄이지 않는다.

모든 필수 anchor 조회가 성공하고 전후 값·조회 상태가 일치하면 `stability.state=stable`이다. 변동·부재·실패·중복 identity·목록에 없는 기본 장치가 있으면 `unknown`이다. `changes`는 달라진 경로와 전후 관측을, `unknown`은 비교 불가능한 경로를 남긴다. 성공한 settable 조회의 false는 실패가 아니다.

`stable`은 전후 표본 일치만 뜻한다. 조회는 순차적이며 원자적이지 않다. 중간에 바뀌었다 돌아오는 상태와 미래의 hotplug·설정 변경을 배제하지 못한다. `diagnosticComplete`는 이름 선택·상세 조회 오류·채널 조회 완전성까지 포함한다. 종료 코드 0은 이 진단의 완전성만 뜻한다. 불완전한 JSON이나 실행 오류는 2다. 정상 진단은 불완전해도 JSON을 저장한다. 초기화·파일 오류 시 출력이 비어 있거나 일부만 있을 수 있으므로 종료 코드와 JSON을 함께 확인한다.

모든 보고서의 `propertyWrites=0`, `ioStarted=false`, `hogAcquired=false`, `physicalAccepted=false`는 고정이다. `audioSamplesRead=false`, `keysRead=false`도 고정이다. 장치 선택·hog 취득·I/O 시작·설치·재시작·실기기 조작은 없다. 이름·UID·상태 메타데이터만 읽으며 키나 인증 자료를 읽지 않는다.

## 부모 담당 실행 절차

이 작업자는 테스트와 네이티브 진단을 실행하지 않았다. 부모 담당이 다음 명령으로 가짜 backend 검사를 수행한다.

```sh
cd /Users/ambrion/.codex/worktrees/ccr-host-endpoint-probe-20261021/Tests/checks/audio-endpoint-readonly-probe
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v test_probe.py
```

테스트는 부재와 실패, settable 실패와 값 분리, signed hog, main 부재와 개별 채널 존재, 64채널 합계, 잘못된 버퍼·채널 상한·NaN·반환 크기, hotplug·UID·세 기본 장치·hog·두 running 변동, CFString 반환 메모리 해제를 다룬다. 가짜 CFString 테스트도 네이티브 라이브러리를 로드하지 않는다.

네이티브 실행 전 부모 담당은 저장 정책의 UUID 검사를 거쳐 새 출력 경로를 받는다.

```sh
/Users/ambrion/.local/bin/storage-route path development-archive --project CCR-Vision --filename audio-endpoint-readonly-probe-20261021.json
```

반환 JSON의 `path`를 아래 `--output` 값으로 전달한다. 프로그램은 경로를 추정하거나 폴더를 만들지 않으며 기존 파일을 덮어쓰지 않는다. 같은 이름의 영수증이 있으면 다른 파일명을 정해 storage-route를 다시 호출한다. 아래 명령은 부모 담당의 실행 예시다.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 /Users/ambrion/.codex/worktrees/ccr-host-endpoint-probe-20261021/Tests/checks/audio-endpoint-readonly-probe/probe.py \
  --device-name 'LG TV SSCR2' \
  --device-name 'DN32-LIVE' \
  --device-name '‘iPhone’ 마이크' \
  --output "$PROBE_OUTPUT"
```

`PROBE_OUTPUT`에는 부모가 받은 실제 절대경로를 넣는다. `--device-name`은 반복 가능한 정확 일치 필터다. 세 이름을 함께 지정하면 세 장치를 선택한다. 같은 이름이 여러 장치에 있거나 일치하는 이름이 없으면 `selectionErrors`가 남고 완료 판정은 false다. 필터가 없으면 모든 열거 장치가 상세 대상이다.

## SDK와 기존 근거

작성 시 `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk/System/Library/Frameworks/` 아래 헤더를 읽어 확인했다. 재실행 호스트의 SDK·Python·probe 소스 버전과 JSON 해시는 부모 영수증에 함께 기록한다.

| 헤더 | selector·자료형 |
| --- | --- |
| CoreAudio.framework/Versions/A/Headers/AudioHardwareBase.h | scope `glob`, `inpt`, `outp`, main `0`; `lnam`·`uid `는 호출자 소유 CFString; `livn`·`tran`·`goin`은 UInt32 |
| CoreAudio.framework/Versions/A/Headers/AudioHardware.h | `dev#`는 AudioDeviceID 배열; `dIn `·`dOut`·`sOut`은 AudioDeviceID; `slay`는 AudioBufferList; `mute`·`gone`은 UInt32; `volm`·`vold`는 Float32; `oink`는 signed pid_t |
| CoreAudioTypes.framework/Versions/A/Headers/CoreAudioBaseTypes.h | AudioBuffer의 UInt32 채널 수·바이트 수와 포인터, AudioBufferList의 개수와 가변 배열. ctypes의 네이티브 정렬·offset·sizeof로 해석한다. |
| CoreFoundation.framework/Versions/A/Headers/CFBase.h, CFString.h | Boolean은 unsigned char, OSStatus는 SInt32. CFStringGetLength·UTF-8 변환·타입 확인·CFRelease 계약을 사용한다. |

SDK의 `sys/_types/_pid_t.h`와 `sys/_types.h`에서 pid_t가 signed 32비트 정수임도 확인했다. SDK에 따른 ABI 변경을 임의로 추정하지 않는다.

기존 Host의 `Sources/SillHost/AudioHardwareRoutes.swift`, `HostAudioPrivacy.swift`, `HostAudioPrivacyModel.swift`를 참조했다. Host 구현을 import하거나 변경하지 않는다. 이 진단은 기존 `endpointMute` 실패를 보호 성공으로 승격하지 않는다.

기존 `/Volumes/BT-Workspace/Development-Archives/CCR-Vision/audio-endpoint-capability-followup-20261021.json`에는 LG TV SSCR2, DN32-LIVE, iPhone 마이크의 volumeScalar·dB main과 `1..32` 부재, mute 부재, hog `-1`과 settable true, running `0`이 기록돼 있다. 같은 결과의 재관측은 새 보호 증거가 아니다. 이번 산출물의 목적은 소스가 없던 진단을 재사용 가능한 체크로 남기는 것이다. 현재 미사용 표본·속성 부재·settable만으로 항구적 무음이나 전체 물리 차단, 모든 공개 수단의 부재를 추정하지 않는다.

Pstack Feature의 코드 작성 담당으로 단일 전용 워크트리에서 구현했다. Model the Domain에 따라 관측 자료형과 selector 표를 사용하고 Ponytail full에 따라 표준 라이브러리 두 Python 파일과 이 문서만 둔다. 선행 조건은 기준 커밋·SDK 확인이며, 독립 작업 흐름은 부모의 Android 수정과 이 진단이다. 공유 변경 대상은 없고 최소 분해는 단일 작성자다. ARENA·Orca·추가 에이전트를 사용하지 않는다. 테스트·네이티브 실행·독립 검수·통합은 부모 단계이며 이 코드의 자기 승인을 완료 근거로 삼지 않는다.
