# Verify iPad startup and CCR record retirement

Run these commands from the repository root.

```sh
REMOTE_DEFAULT_OUTPUT="$(storage-route path development-archive --project BT_CCR-ipad --filename remote-default-checks | python3 -c 'import json,sys; print(json.load(sys.stdin)["path"])')"
python3 iOSClient/Tests/remote-default/run.py --output "$REMOTE_DEFAULT_OUTPUT"
python3 iOSClient/Tests/remote-default/policies.py --focused
python3 iOSClient/Tests/remote-default/compare.py
```

`run.py`는 실제 startup·유선 폴백·원격 실패·전경 복귀·재시도 메서드와 `sessionEnded`의 보안/폴백 구간을 추출한다. `--output`에는 `storage-route`가 반환한 새 출력 폴더를 전달한다. 기존 폴더를 덮어쓰지 않는다. 입력·컴파일 캐시·실행파일은 원담당의 Mini RAM 경로에서 실행 후 정리하고 해시와 정리 영수증을 출력 폴더에 남긴다. It compiles these with the real `DiscoveryPolicy` and deterministic clock, connection, and identity stand-ins. The iOS conditional branch is selected explicitly for this macOS logic test. No network connection or Keychain operation occurs.

`policies.py --focused` compiles the real protocol value types, `SavedMacs`, `DiscoveryPolicy`, and `RemoteDialPolicy`. It tests automatic trust selection and CCR retirement, including the supplied pairing chronology. It also extracts the production retirement integration method. Its session and preferences stand-ins verify the admission, signature, preference, active-pairing, and persistence boundaries.

`compare.py` runs the existing `policy`, `home-device`, and `remote-rules` suites against both HEAD and the working sources. It preserves their logs and compares the exact failing assertions. A successful comparison means the failure lists match. It does not mean these older suites pass.

`run.py` 이외의 기존 검사 스크립트는 이 폴더 아래에서 임시 소스·실행파일·컴파일 캐시를 생성한다. Mini 임시 실행 경로에서 수행하고 해당 경로의 정리를 확인한다. Existing test files outside iOSClient are read only. No Mac host source is compiled. The comparison reads committed protocol/client sources with `git show`.

These tests prove client decisions and persistence boundaries through stand-ins. They do not prove a real TLS handshake, USB routing, remote service availability, physical iPad behavior, or installation. Full native iOS compilation requires an iPhoneOS SDK.

Mini 임시 소스에서 Git 없이 비교할 때에는 정확한 기준 ref의 입력 파일을 상대 경로 그대로 export하고 `CCR_REMOTE_BASELINE_DIR`에 그 루트를, `CCR_REMOTE_BASELINE_REV`에 정확한 commit을 지정한다. 비교기는 기존 실패 목록도 JSON으로 출력한다. 이 snapshot은 테스트 입력이며 source-guard의 Git checkout 동일성 수용을 대신하지 않는다.
