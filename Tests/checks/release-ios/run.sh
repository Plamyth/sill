#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$root"
source Scripts/release-ios.sh
mkdir -p .build/checks/release-ios
scratch="$(mktemp -d "$root/.build/checks/release-ios/fixture.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
passed=0 failed=0

result() {
    if [ "$2" = "$3" ]; then
        echo "PASS $1: $2"
        passed=$((passed + 1))
    else
        echo "FAIL $1: expected $3, got $2"
        failed=$((failed + 1))
    fi
}

xcodebuild() {
    [ "$*" = -version ] || { echo "Unexpected xcodebuild command: $*" >&2; return 99; }
    if [ -n "$selected_xcode" ]; then
        printf 'Xcode %s\nBuild version fixture\n' "$selected_xcode"
    fi
}

for selected_xcode in 26.4 27.0 27.1 28.0 ''; do
    expected=reject
    case "$selected_xcode" in 27.0|27.1) expected=accept ;; esac
    problem="$(xcode_problem)"
    actual=accept
    if [ -n "$problem" ]; then actual=reject; fi
    result "Xcode ${selected_xcode:-missing}" "$actual" "$expected"
done

app="$scratch/Sill.app"
mkdir "$app"
python3 - "$app/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "wb") as output:
    plistlib.dump({
        "CFBundleIdentifier": "com.ambrion.sillcanvas.ipad",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "ITSAppUsesNonExemptEncryption": False,
        "NSLocalNetworkUsageDescription": "fixture",
        "NSBonjourServices": ["_sill._tcp"],
        "NSCameraUsageDescription": "fixture",
        "DTPlatformVersion": "27.0",
    }, output)
PY
cp iOSClient/PrivacyInfo.xcprivacy "$app/PrivacyInfo.xcprivacy"
selected_xcode=27.1
for sdk in 26.4 27.0 27.1 unknown ''; do
    expected=reject
    case "$sdk" in 27.0|27.1) expected=accept ;; esac
    /usr/libexec/PlistBuddy -c "Set :DTPlatformVersion $sdk" "$app/Info.plist"
    actual=accept
    if ! (check_app "$app" 1.0 1) >"$scratch/check.log" 2>&1; then actual=reject; fi
    result "App SDK ${sdk:-missing} with Xcode 27.1" "$actual" "$expected"
    if [ "$actual" != "$expected" ]; then cat "$scratch/check.log"; fi
done

/usr/libexec/PlistBuddy -c 'Set :DTPlatformVersion 27.0' "$app/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier me.saffer.sill' "$app/Info.plist"
actual=accept
if ! (check_app "$app" 1.0 1) >"$scratch/check.log" 2>&1; then actual=reject; fi
result 'Wrong app identity' "$actual" reject

uncommitted_changes() { echo ' M iOSClient/Info.plist'; }
actual=accept
if ! (check_committed '--upload') >"$scratch/check.log" 2>&1; then actual=reject; fi
result 'Upload from dirty source' "$actual" reject

python3 - "$root" "$scratch" <<'PY'
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

root, scratch = map(Path, sys.argv[1:])
script = root / "Scripts/release-ios.sh"
helper = root / "Scripts/release-ios-settings.py"
fixture = scratch / "project.pbxproj"
base = (root / "iOSClient/Sill.xcodeproj/project.pbxproj").read_text()


def parse(data):
    return json.loads(subprocess.check_output(
        ["/usr/bin/plutil", "-convert", "json", "-o", "-", "--", "-"], input=data,
    ))


graph = parse(base.encode())
objects = graph["objects"]
project = objects[graph["rootObject"]]
targets = {objects[ref]["name"]: objects[ref] for ref in project["targets"]}


def configs(owner):
    return objects[owner["buildConfigurationList"]]["buildConfigurations"]


ipad, phone, global_configs = configs(targets["Sill"]), configs(targets["SillPhone"]), configs(project)
# 원문 형식은 실제 프로젝트에서 재사용한다. 타깃의 버전만 서로 다르게 만든다.
for ref in ipad:
    old = objects[ref]["buildSettings"]["CURRENT_PROJECT_VERSION"]
    start = base.index(f"\t\t{ref} /*")
    end = base.index("\n\t\t};", start)
    base = base[:start] + base[start:end].replace(
        f"CURRENT_PROJECT_VERSION = {old};", "CURRENT_PROJECT_VERSION = 78;",
    ) + base[end:]
for ref in phone + global_configs:
    start = base.index(f"\t\t{ref} /*")
    end = base.index("\n\t\t};", start)
    block = base[start:end]
    if ref in phone:
        block = block.replace("MARKETING_VERSION = 0.5.1;", "MARKETING_VERSION = 9.9;")
    else:
        block = block.replace("buildSettings = {", "buildSettings = {\n\t\t\t\tCURRENT_PROJECT_VERSION = 901;\n\t\t\t\tMARKETING_VERSION = 9.9;")
    base = base[:start] + block + base[end:]

passed = 0


def check(name, condition):
    global passed
    assert condition, name
    passed += 1
    print(f"통과: {name}")


def run(command):
    return subprocess.run(
        ["bash", "-c", 'source "$RELEASE_SCRIPT"; pbxproj="$PBX_FIXTURE"; ' + command],
        env={**os.environ, "RELEASE_SCRIPT": str(script), "PBX_FIXTURE": str(fixture),
             "BUMP_RECEIPT": str(scratch / "bump-commit.txt")},
        capture_output=True, text=True,
    )


fixture.write_text(base)
result = run("project_setting CURRENT_PROJECT_VERSION")
check("iPad 78·iPhone 4의 getter", result.returncode == 0 and result.stdout.strip() == "78")
result = run("project_setting MARKETING_VERSION")
check("iPhone·프로젝트 값이 달라도 iPad marketing version 유지", result.returncode == 0 and result.stdout.strip() == "0.5.1")

# 실제 CLI도 같은 getter를 사용하며 Xcode·서명 단계 전에 종료한다.
cli = scratch / "cli"
(cli / "Scripts").mkdir(parents=True)
(cli / "iOSClient/Sill.xcodeproj").mkdir(parents=True)
shutil.copy(script, cli / "Scripts/release-ios.sh")
shutil.copy(helper, cli / "Scripts/release-ios-settings.py")
(cli / "iOSClient/Sill.xcodeproj/project.pbxproj").write_text(base)
result = subprocess.run(["bash", str(cli / "Scripts/release-ios.sh"), "--print-version"], capture_output=True, text=True)
check("실제 --print-version 출력", result.returncode == 0 and result.stdout.strip() == "0.5.1 (78)")

# bump_build의 실제 호출 경로를 실행하되 git 발행만 기록으로 대체한다.
before = parse(fixture.read_bytes())
result = run('''git() {
    case "$1" in
        status) ;;
        commit) printf '%s\\n' "$*" > "$BUMP_RECEIPT" ;;
        rev-parse) echo fixture ;;
        *) return 99 ;;
    esac
}
bump_build 0.5.1 78''')
expected = copy.deepcopy(before)
for ref in ipad:
    expected["objects"][ref]["buildSettings"]["CURRENT_PROJECT_VERSION"] = "79"
check("bump는 iPad 두 설정만 79로 갱신", result.returncode == 0 and parse(fixture.read_bytes()) == expected)
check("iPhone·프로젝트 전역·marketing version 보존", all(
    parse(fixture.read_bytes())["objects"][ref] == before["objects"][ref]
    for ref in phone + global_configs
))
check("bump 커밋 경로는 해당 pbxproj 하나", (scratch / "bump-commit.txt").read_text().endswith(f"-- {fixture}\n"))

# 네 빌드 번호가 같아도 다른 타깃은 올리지 않는다.
same = base.replace("CURRENT_PROJECT_VERSION = 78;", "CURRENT_PROJECT_VERSION = 4;")
fixture.write_text(same)
before = parse(fixture.read_bytes())
result = subprocess.run(["python3", str(helper), str(fixture), "Sill",
                         "com.ambrion.sillcanvas.ipad", "ZPTXHJ866D",
                         "CURRENT_PROJECT_VERSION", "4", "5"], capture_output=True)
expected = copy.deepcopy(before)
for ref in ipad:
    expected["objects"][ref]["buildSettings"]["CURRENT_PROJECT_VERSION"] = "5"
check("네 설정이 4여도 iPad 두 개만 bump", result.returncode == 0 and parse(fixture.read_bytes()) == expected)

cases = {
    "iPad 빌드 불일치": base.replace("CURRENT_PROJECT_VERSION = 78;", "CURRENT_PROJECT_VERSION = 77;", 1),
    "iPad 버전 불일치": base.replace("MARKETING_VERSION = 0.5.1;", "MARKETING_VERSION = 0.5.2;", 1),
    "누락된 iPad 빌드": base.replace("CURRENT_PROJECT_VERSION = 78;", "", 1),
    "iPad bundle 불일치": base.replace("PRODUCT_BUNDLE_IDENTIFIER = com.ambrion.sillcanvas.ipad;", "PRODUCT_BUNDLE_IDENTIFIER = wrong.app;", 1),
    "다른 타깃의 중복 bundle": base.replace("com.ambrion.sillcanvas.iphone", "com.ambrion.sillcanvas.ipad"),
    "타깃 이름 모호": base.replace("name = SillPhone;", "name = Sill;"),
    "서명 팀 불일치": base.replace("DEVELOPMENT_TEAM = ZPTXHJ866D;", "DEVELOPMENT_TEAM = WRONGTEAM1;", 1),
    "조건부 bundle 모호": base.replace("PRODUCT_BUNDLE_IDENTIFIER = com.ambrion.sillcanvas.ipad;", '"PRODUCT_BUNDLE_IDENTIFIER[sdk=iphoneos*]" = wrong.app;\n\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.ambrion.sillcanvas.ipad;', 1),
}
for name, text in cases.items():
    fixture.write_text(text)
    key = "MARKETING_VERSION" if name == "iPad 버전 불일치" else "CURRENT_PROJECT_VERSION"
    result = run(f"project_setting {key}")
    check(f"{name} getter 거부", result.returncode != 0 and not result.stdout)
    result = subprocess.run(["python3", str(helper), str(fixture), "Sill",
                             "com.ambrion.sillcanvas.ipad", "ZPTXHJ866D",
                             key, "78", "79"], capture_output=True)
    check(f"{name} 쓰기 거부·원본 보존", result.returncode != 0 and fixture.read_text() == text)

import runpy
from unittest.mock import patch

fixture.write_text(base)
module = runpy.run_path(str(helper))
namespace = module["main"].__globals__
original_parse = namespace["parse"]
concurrent = base.replace("ENABLE_PREVIEWS = YES;", "ENABLE_PREVIEWS = NO;", 1)
injected = False

def parse_with_concurrent_edit(data):
    global injected
    result = original_parse(data)
    if not injected:
        fixture.write_text(concurrent)
        injected = True
    return result

namespace["parse"] = parse_with_concurrent_edit
rejected = False
with patch.object(sys, "argv", [str(helper), str(fixture), "Sill",
                               "com.ambrion.sillcanvas.ipad", "ZPTXHJ866D",
                               "CURRENT_PROJECT_VERSION", "78", "79"]):
    try:
        module["main"]()
    except ValueError:
        rejected = True
check("최초 읽기 이후 동시 편집은 거부하고 현재 원문 보존", rejected and fixture.read_text() == concurrent)

fixture.write_text(base)
result = run('''git() {
    case "$1" in
        status) python3 -c 'import os;from pathlib import Path;p=Path(os.environ["PBX_FIXTURE"]);p.write_text(p.read_text().replace("name = Sill;", "name = ConcurrentSill;", 1))' ;;
        checkout) printf unexpected-checkout > "$BUMP_RECEIPT"; return 99 ;;
        *) return 99 ;;
    esac
}
bump_build 0.5.1 78''')
check("갱신 후 getter 거부에도 다른 편집과 빌드 번호 보존",
      result.returncode != 0 and "name = ConcurrentSill;" in fixture.read_text()
      and fixture.read_text().count("CURRENT_PROJECT_VERSION = 79;") == 2
      and (scratch / "bump-commit.txt").read_text() != "unexpected-checkout")

print(f"추가 회귀 {passed}개 통과. 실제 archive/export/upload는 호출하지 않았다.")
PY

echo "$passed passed, $failed failed; archive/export/upload not invoked"
[ "$failed" = 0 ]
