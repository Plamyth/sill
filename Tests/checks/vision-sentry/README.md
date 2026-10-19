# Vision Sentry 클라이언트 검증 입력

부모 담당이 승인된 RAM 실행 경로에서 실행합니다. 이 위임 작업에서는 빌드·테스트를 실행하지 않았습니다.

```sh
python3 -B "$SENTRY_SOURCE_ROOT/Tests/checks/vision-sentry/run.py" "$SENTRY_SOURCE_ROOT" "$SENTRY_PARENT_RAM_OUTPUT"
```

`SENTRY_SOURCE_ROOT`는 이 커밋의 읽기 전용 소스 루트이며 `SENTRY_PARENT_RAM_OUTPUT`은 부모 담당이 준비한 비어 있는 RAM 출력 경로입니다. Mini 영구 디스크에 소스를 복사하지 않습니다. 실행 결과는 출력 경로의 `result.json`과 단계별 로그에 기록됩니다. 실행 전후 입력 SHA256을 비교합니다.

## 정확한 입력 파일

- `Tests/checks/vision-sentry/run.py`, `Standins.swift`, `main.swift`
- `Tests/checks/vision-input-controls/Network.swift` — 외부 전송 없는 대역
- `Sources/StreamProtocol/{Switcher,StreamMessage,AudioRouting,AudioPrivacy,Compatibility,Sentry}.swift`
- `iOSClient/SessionLink.swift`, `iOSClient/StreamClient.swift`
- `visionOSClient/VisionSentryController.swift`, `StreamClient+VisionSentry.swift`, `SillVisionApp.swift`
- `SillVision.xcodeproj/project.pbxproj`, `Scripts/make-vision-project.py`

실제 컨트롤러·어댑터·SessionLink와 실제 StreamClient의 저장 필드를 사용합니다. 연결과 신뢰 입력만 대역에서 주입합니다. 전체 StreamClient 연결 수명과 네이티브 ornament는 부모의 전체 visionOS SDK 빌드와 독립 검수 대상입니다.

## 행동 검증 목록

- 213/214 방향·상한, 버전 1 JSON 왕복, 선택적 카탈로그 필드와 기존 호스트 호환
- 단일 대기 명령과 중복 전송 방지, `accepted`와 실제 `pending`/보호 상태 구분
- 이전 연결·요청·boot/session/revision 응답 거부, 새 카탈로그 우선
- 보호 A → 차단 B → stale A → stale A 이후에도 보호 상태 복원 금지
- 누락·미지원·해석 실패로 catalog가 없어져도 retired A를 반복 거부하고 B의 재관측은 수락
- 거부된 교체는 현재 revision을 retire하지 않음, 같은 revision의 상충 상태는 미확인으로 초기화
- 같은 peer의 boot/session 변경과 새 peer binding의 revision 이력 초기화 유지
- 같은 상태 revision에서 source/generation 변경 후 이전 ACK 차단
- 누락·미지원·해석 불가 capability 및 연결 해제 시 미확인으로 초기화
- 신뢰되지 않은 연결과 현재 Mac 소스 없음에서 활성화 거부
- 8초 제한, 제한 후 ACK 거부, 새 카탈로그 없이 자동 재시도 없음
- 보류 전송의 카탈로그 변경·재연결·capability 소실·제한 시간 취소
- 메인 타이머가 처리되기 전에도 실제 Network.send에서 만료 요청 차단
- 연결 해제 시 원격 해제 전송 없음, activation JSON에 해제·계정·제스처 필드 없음
- 한국어 네이티브 UI와 프로젝트 membership 정적 대조

## 기존 회귀 입력 보정

`Tests/checks/vision-display-selection/run.py`의 `PROTOCOL`은 입력 추출과 컴파일 목록에 모두 `Sources/StreamProtocol/Sentry.swift`를 포함합니다. `WindowList`의 선택적 `sentry` 타입 의존성을 충족합니다.

`Tests/checks/vision-input-controls/Standins.swift`는 실제 연결 setter·teardown에서 추출된 호출을 위한 명시적 inert `bindVisionSentry(to:)`를 제공합니다. 센츄리 동작은 위 전용 suite에서 검증합니다. 부모 담당은 기존 `extract.py`·`run.py`와 이 Standins를 RAM 실행 경로에 연결합니다. 기존 `remote.py`는 Orca probe와 영구 `/tmp` 출력을 사용하므로 실행하지 않습니다.

`SessionLink.Submission`의 선택적 마감 시각은 Sentry에만 전달됩니다. 부모 담당은 기존 SessionLink·Vision display selection 회귀 검사와 전체 visionOS SDK 빌드를 함께 수행합니다. 설치된 host137은 capability가 없어 이 버튼이 표시되지 않습니다. 실제 기기·호스트 보호 동작을 이 검사 결과로 대체하지 않습니다.
