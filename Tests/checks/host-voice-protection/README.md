# 호스트 원격 오디오 보호 포팅 검사

기준 소스는 `956abdca5056597e1045fc32b5e9422376f80be2`다. `190f2ab`, `a2567e7`의 보호·인증 복귀·참여자·실제 종료 코드와 현재 peer별 카탈로그를 함께 검사한다. 별도 Sentry 구현과 HTTP 원장은 이 변경에 포함하지 않는다.

## 실행

`OUTPUT`과 `BUILD`는 `storage-route path development-archive --project ccr-sill`이 반환한 경로 아래에 둔다. `OUTPUT`은 아직 없는 디렉터리여야 한다.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --build-system native --scratch-path "$BUILD" --jobs 2
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 Tests/checks/host-voice-protection/run.py "$OUTPUT" "$BUILD/arm64-apple-macosx/debug"
```

생산 CoreAudio 어댑터와 원래 상태 복원 코드도 주입 HAL로 실행한다. 실제 HAL·hog·장치·권한·통화·설치 동작은 없다. `result.json`은 입력 SHA, 종료 코드, 소스 불변성과 물리 동작 0을 기록한다.

## 보호와 연결 경계

`audioPrivacy.version=2`, `latched`, 장치별 입력·출력 채널 수, `masterMute` 또는 `unsupported` coverage를 실제 카탈로그에 전달한다. 미지원 장치가 있어도 지원되는 전체 음소거와 세 가상 기본값은 적용하며, 전체 보호와 원격 오디오는 거부한다.

`StreamCoordinator.nativeAudioBindingAuthorized`는 검증된 단일 원장 어댑터가 현재 페어링 fingerprint의 네이티브 바인딩을 확인하는 경계다. 연결이 없으면 false다. HTTP 바인딩이나 읽기 전용 voiceState를 네이티브 시작 ACK로 사용할 수 없다. 재생 승인·PCM 전달·마이크 승인에서 확인한다.

부모 Sentry 통합에서는 `sentryAudioReady`를 `audioPrivacy.verify`, `sentryLocalReturnUnavailableReason`을 `audioPrivacy.localReturnUnavailableReason`, `sentryRequestLocalReturn`을 `audioPrivacy.requestLocalReturn`에 연결한다. `localReturnDidComplete`는 `completeSentryLocalReturn(commitAudio:)`, 상태 변경은 `sentryAudioProtectionChanged()`에 연결한다. 기존 `revokeForLocalReturn`과 `inspectForLocalReturn`은 실제 종료 및 readback을 담당한다.

실제 `native.sill`과 `s23.audio.relay` 양쪽의 같은 operation·privacy generation·registry revision·boot 영수증이 필요하다. relay가 없거나 종료가 unknown이면 로컬 복귀도 닫힌다. 연결 해제와 일반 마이크 정리는 이전 물리 입력을 복원하지 않는다.

## DN32-LIVE 배타 무음 후보의 범위

`HostExclusiveAudioSilence`는 현재 사용 중인 장치나 기존 hog 소유자를 거부한다. 자신이 취득한 hog와 IOProc만 보유하며, C callback은 입력 PCM을 보관·전달하지 않고 모든 출력 buffer를 0으로 채운다. 장치 UID·ID·채널·sample rate·hog 소유권, 2회 이상 callback, 250ms 이내 heartbeat와 전체 채널 무음 바이트를 함께 확인한다. stop 실패 시 callback context와 hog를 유지하며 다른 소유자의 장치는 해제하지 않는다.

이 후보는 자동 실행하지 않으며 `Evidence.permitsRemoteAudio`는 false다. 실제 별도 프로세스가 배타 장치에 접근하지 못하는지와 M32R 내부 직접 모니터·USB return 경로는 물리 시험이 필요하다. hog PID와 0 출력 callback만으로 외부 믹서의 아날로그 입력·출력까지 차단됐다고 판단할 수 없다. 앱 종료 시 OS가 hog를 해제하므로 영속 하드웨어 mute와 같은 보호 수명도 보장하지 않는다. 따라서 현재 보호 계획은 이 후보를 사용해 `protected=true`를 만들지 않는다.

Apple SDK `AudioHardware.h`의 hog 토글·IOProc 계약과 [Apple CoreAudio 시작 계약](https://developer.apple.com/documentation/coreaudio/audiohardwaredevice/start(ioprocid:))을 기준으로 작성했다. 실물 시험과 독립 통합 검수는 이 검사 결과와 별개다.

## 현재 Android 정본

`integration/ccr-android`의 `128b7f904abf91bfe92e1507e2dba6523e7c7f88`에 있는 `docs/audio-forwarding-v1.md`와 네 파일의 계약을 읽었다. authority SHA는 `8299361f445480186c48cb267749e3f5a82a1f6bcf15c6e3d198480ab8fc5d83`, native-control SHA는 `23e47186121d3522a0cf18b2bd88fa363684266b17ea5df86dc1881bee9db31c`로 대조했다. 포트 17648·17649의 실행 전환과 provider 시작·종료 ACK는 부모와 본체 담당 범위다. 이 변경은 해당 런타임을 변경하지 않는다.
