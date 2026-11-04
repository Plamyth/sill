# iPad TestFlight build 78 작업

- [x] 1. Reproduce it yourself on the matching surface. 기존 회귀 12개 통과. getter와 bump가 프로젝트 전체를 검색·치환하는 원인을 확인했다.
- [x] 2. Binary-search the cause. Sill과 SillPhone의 네 설정이 모두 4여서 기존 검사가 타깃 혼입을 드러내지 못했다.
- [x] 3. Plan the fix. plutil의 객체 그래프로 Sill의 두 설정을 선택하고 해당 숫자만 갱신한다.
- [x] 4. Verify on the same surface. 기존 회귀 12개와 타깃별 버전 fixture 23개가 통과했다.
- [x] 5. Stage the commits. 완성된 이번 변경만 검사해 커밋 대상으로 고정한다. 실패 재현은 아래 실행 근거로 보존하고 완성된 한 단위로 커밋한다.
- [x] 6. Run Opening a PR. skip: 사용자가 push/merge 0과 부모의 독립 검수·통합을 지정했다.

상위 절차는 Pstack 0.9.129 poteto-mode의 Bug fix다. Ponytail full의 기존 구조·native plutil·Python 표준 라이브러리 우선 원칙을 적용한다. 데이터 형태는 PBXProject.targets에서 Sill PBXNativeTarget과 XCConfigurationList를 거쳐 얻는 Debug/Release 설정 두 개다. Model the Domain 원칙에 따라 getter와 bump가 같은 참조 해석을 사용한다. ARENA와 순정 Goal은 사용하지 않는다.

이 세션에는 spawn_agent 도구가 없다. how의 단일 조사와 architect의 최소 설계는 직접 수행하고, ARENA 후보 경쟁은 사용자 금지로 생략한다. 독립 검수·통합·ASC·서명·실물은 부모 소유로 남긴다. 필수 범위는 릴리스 도구와 후보 번호이며 앱·Host·기기·자격증명 조작은 없다.

처리량 판단: 같은 스크립트·프로젝트·회귀 파일을 바꾸는 좁은 단위이므로 writer를 나누지 않는다. 검사 fixture는 임시 경로에서 격리한다. 프로젝트 재직렬화로 전체 파일을 바꾸지 않고 객체 그래프로 선택한 숫자만 편집한다.

## 실행 결과와 번호 결정 근거

검증 시각은 2026-11-04T18:45:08Z, 한국 시각 2026-11-05 03:45:08이다. 작업 키는 `ipad-testflight-build78-20261105`다. 시작 브랜치는 `codex/ipad-testflight-build78-20261105`, 기준 커밋은 `1a93ea5b2646dac6b982736202e2dd85428c4b9e`, 기준 트리는 `eb2415495b67735cfc1776569bb5b6353c167743`이며 시작 시 dirty 변경은 없었다. 지정한 `build78-source` 외의 워크트리·부모 파일은 수정하지 않았다.

부모 원장은 [상위 작업 원장](../../todo.md)이다. 다음 부모 영수증의 필요한 필드만 읽었다. ASC에 직접 접속하거나 계정·키·프로필을 읽거나 복사하지 않았다.

- [ASC 읽기 영수증](../../asc-readback.json)의 `appInfoReadback`은 AppleAppID `6830811628`, bundle `com.ambrion.sillcanvas.ipad`, 동일 팀 `ZPTXHJ866D`와 식별 일치를 기록했다. `testflightBefore.builds`는 0이다. 해당 영수증의 `observedAt`은 `2026-11-04T18:18:20.585275+00:00`이다. 이번 작업의 직접 ASC 재관측은 아니다.
- [설치 전 보존 영수증](../../preservation-before.json)은 같은 bundle의 설치 버전 `0.5.1`, 빌드 `77`, 삭제 없음으로 기록했다. 이 작업은 기기를 새로 조회하거나 조작하지 않았다.
- 따라서 후보 `0.5.1 (78)`은 설치 77보다 크며, 부모가 확인한 ASC 빌드 0과 충돌하지 않는다. 소스의 기존 번호 4를 설치 번호로 오인하지 않았다. 설치된 signed 77을 다시 표시하거나 변경하지 않았다.

위 영수증은 부모가 갱신할 수 있다. 아래 SHA-256은 이번 읽기 시점의 파일을 가리킨다. 개인정보·인증정보·계정 정보·본문은 복제하지 않았다.

| 근거 | SHA-256 |
| --- | --- |
| `../asc-readback.json` | `72b05d3ec5e446bc091b98a09565f433581aa3b4e7c42a2c60f6602de3e0545a` |
| `../preservation-before.json` | `0982337c0bff60e5cbc029025e35bdab356a8a8a846621baebed62f0a697cbd2` |

## 변경과 검증

기존 getter는 프로젝트 전체의 `4`와 `78`을 함께 읽어 종료코드 1로 실패했다. 기존 bump는 네 설정이 모두 4인 fixture에서 iPhone까지 네 설정을 5로 바꿨다. 기준 커밋의 스크립트로 이 두 현상을 격리 재현했다.

수정한 `project_setting`과 `bump_build`는 같은 작은 helper를 호출한다. native `plutil`이 읽은 `PBXProject.targets → Sill → XCConfigurationList → Debug/Release` 참조를 사용한다. bundle과 프로젝트에서 상속한 팀을 확인하고, 누락·불일치·모호한 타깃/bundle·조건부 식별 설정을 거부한다. bump는 다음 정수만 허용하며 쓰기 전 전체 객체 그래프를 비교해 두 번호 외 변경을 거부한다. 주석과 프로젝트 서식을 보존하기 위해 확정한 두 객체의 숫자만 바꾼다. 새 외부 의존성·일반 프레임워크는 없다.

실제 프로젝트 변경은 아래 두 설정의 `CURRENT_PROJECT_VERSION` 4 → 78뿐이다.

- `A10000010000000000009301`, Sill Debug.
- `A10000010000000000009302`, Sill Release.

검증 명령과 관측 결과는 다음과 같다.

- `bash Tests/checks/release-ios/run.sh`: 기존 12개와 추가 23개가 통과했다. fixture는 iPad 78, iPhone 4·별도 marketing version, 프로젝트 전역 901·별도 marketing version을 사용한다. getter, 실제 CLI, 78 → 79 bump, 네 타깃 설정이 모두 4인 경우, 두 설정만 변경, 제한된 커밋 경로, 누락·불일치·모호 bundle·팀·조건부 설정 거부와 쓰기 전 원본 보존을 확인했다. fixture의 git commit만 기록용 함수로 대체했다.
- `bash Scripts/release-ios.sh --print-version`: `0.5.1 (78)`.
- `bash -n Scripts/release-ios.sh Tests/checks/release-ios/run.sh`: 통과.
- `plutil -lint iOSClient/Sill.xcodeproj/project.pbxproj`: 통과.
- 기준 커밋과 현재 pbxproj를 각각 plutil로 읽어 두 번호만 치환한 예상 그래프와 비교했다. SillPhone·프로젝트 전역·marketing version·그 밖의 객체 변경은 0이다.
- `git diff --check`: 통과. `deslop` 관점에서 중복 getter 검증을 제거하고 이번 경로만 검토했다. 독립 `no-comments` 검수는 부모 담당으로 남긴다.

| 구현 파일 | SHA-256 |
| --- | --- |
| `Scripts/release-ios.sh` | `8e3cda1acfe2185aded1e67b3c815058570040e09c89605002e517a14482406b` |
| `Scripts/release-ios-settings.py` | `0cdabf0513989277e40b9f191c5e68a81ed84609d1c2165aff786864fa3df5dd` |
| `Tests/checks/release-ios/run.sh` | `51d25eff60a2e89f0feaddbea856d88040a008226e9bedecf2d67e9b717c674a` |
| `iOSClient/Sill.xcodeproj/project.pbxproj` | `929ff31569ec6d6e12e26199bf0b5aee6045146a51daa5449beb675b647a0ed9` |

## 반환 상태

구현·회귀 검사는 완료했다. 실제 archive/export/upload, 서명·프로비저닝 변경, 설치·실물 수용, push/merge는 모두 0이다. 기존 소스 dirty 거부, 업로드 전 소스 검사, Xcode/SDK 검사와 provisioning updates 비활성화 경로를 보존했다. 앱 UI·Info·owner bootstrap·Host·서명 키/프로필·저장된 그림·설정·신뢰는 변경하지 않았다. 마지막 세 항목의 실제 업데이트 후 보존 수용은 부모의 설치 시험 범위다.

다음 행동은 부모가 이 커밋을 독립 검수한 뒤 통합하고, 부모 소유의 ASC·서명·실물 절차로 진행하는 것이다. 이 후보를 TestFlight 업로드나 같은 앱 업데이트 수용 완료로 표시하지 않는다. 공유 기기·브라우저·서버·오디오 자원은 점유하지 않았다. 테스트 서버 반영과 독립 검수는 이번 하위 작업에 포함되지 않는다.

Notion 가이드 `0.0.6` 읽기는 404 `object_not_found`로 실패했다. 이 작업은 저장소 내 코드·검증 영수증만 만들었고 Notion에는 저장하지 않았다.
