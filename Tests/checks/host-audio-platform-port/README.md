# 호스트 오디오 플랫폼 포팅 비활성 검사

원담당은 `01a13005-5ea4-7060-a862-4591344f3748`이며 작업 키는 `s23-host-platform-port-20261021`이다.
기준은 `a7acf368bdd7d10e2b2965a8da2e7decc51590d9`이고 두 플랫폼 파일의 출처는 `2b4ce0da95cb819b1fc20985480622cd3f5f7bec`이다.
현재 보호 모델의 주입 API가 같아 두 파일만 원본 바이트 그대로 재사용한다. AppModel, StreamCoordinator, StreamServer, HID와 DesktopCapturePrivacy는 변경하지 않는다.

Pstack 기능 포팅 절차에서 기존 계약을 대조하고 Ponytail의 기존 구현 재사용을 선택했다. 설계 경쟁과 추가 위임은 하지 않으며 독립 검수는 부모 담당이 수행한다.
선행 조건은 지정 브랜치와 기준 커밋의 확인이며, 두 플랫폼 파일과 이 검사만 한 담당이 작성한다. 공유 상태를 조작하지 않고 Mini 작업별 실행 사본에서 검증한다.

MacBook에서는 소스 작성과 검토만 수행한다. 아래 명령으로 Mini에서 전체 패키지를 빌드하고 실제 호스트 모듈의 비활성 계약을 확인한다.

```sh
/Users/ambrion/.local/bin/mini-ephemeral-source run --source '/Users/ambrion/Documents/ChatGPT/BT_CCR(비전프로 앱)/work/sill-host-audio-platform-port' --owner 01a13005-5ea4-7060-a862-4591344f3748 --job s23-host-platform-port-20261021 --memory-mib 2048 -- python3 Tests/checks/host-audio-platform-port/run.py
```

`Checks.swift`는 실제 HAL 접근을 모두 실패 처리한 주입 경계를 사용하며 초기화와 비활성 `verify()`가 보호 성공을 반환하지 않는지 검사한다. 표면 보호는 초기화와 비활성 조회만 수행한다. 네이티브 생성자는 타입 연결만 컴파일하고 호출하지 않는다.
실제 HAL 읽기·쓰기, 화면 가림·입력 필터 설치, 인증, private factory 실행, 앱 실행·설치, S23 연결과 공유 서비스 수용은 이 검사의 범위가 아니다.
정상 보호 모델의 `verify()` 및 기존 데스크톱 보호는 그대로 유지한다. 실행 도구의 영수증에 있는 소스·명령 해시, 종료 코드와 `cleanup_verified=true`를 함께 확인해야 한다.
