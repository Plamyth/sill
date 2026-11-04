#!/usr/bin/env python3
"""실제 App 분기 실행과 iOS SDK typecheck. 앱 실행·설치·네트워크·실기기 조작 없음."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument("output", type=Path)
parser.add_argument("--entry-only", action="store_true")
args = parser.parse_args()
archive = json.loads(subprocess.check_output([
    "/Users/ambrion/.local/bin/storage-route", "path", "development-archive", "--project", "BT_CCR-ipad"], text=True))
out = args.output.resolve()
assert out.is_relative_to(Path(archive["path"]).resolve())
out.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
inputs = [root / "iOSClient/SillApp.swift", root / "Scripts/ipad-source-identity.py",
          root / "iOSClient/CanvasBridge/CanvasModel.swift", root / "iOSClient/ContentView.swift",
          root / "iOSClient/Info.plist", root / "iOSClient/Info-Debug.plist",
          root / "iOSClient/Sill.xcodeproj/project.pbxproj", *sorted(here.glob("*.*"))]
hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
commands, cases = [], []


def run(label, command, extra_env=None):
    result = subprocess.run(list(map(str, command)), cwd=root, env=extra_env or env,
                            capture_output=True, text=True, timeout=180)
    (out / (label + ".log")).write_text(result.stdout + result.stderr)
    commands.append(dict(label=label, command=list(map(str, command)), exitCode=result.returncode))
    assert result.returncode == 0, label + "\n" + result.stdout + result.stderr
    return result.stdout


def declaration(text, start):
    begin = text.index(start)
    opening = text.index("{", begin)
    depth = 1
    for index in range(opening + 1, len(text)):
        depth += (text[index] == "{") - (text[index] == "}")
        if depth == 0:
            return text[begin:index + 1]
    raise AssertionError(start)


try:
    with tempfile.TemporaryDirectory(prefix="entry-", dir=out) as temporary:
        work = Path(temporary)
        model = inputs[2].read_text()
        runtime = work / "Runtime.swift"
        runtime.write_text("import Foundation\nimport CryptoKit\nimport Darwin\nimport MachO\n"
                           "enum CanvasSendError: Error { case outboxUnavailable }\n" +
                           declaration(model, "enum CanvasRuntime {") + "\n" +
                           declaration(model, "enum CanvasLocalFile {"))
        probe_app = work / "SillApp.swift"
        probe_app.write_text(inputs[0].read_text().replace("import SwiftUI", "import EntryProbeUI", 1))
        assert "@StateObject private var client = StreamClient()" in inputs[3].read_text()
        swift = ["/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-module-cache-path", work / "modules"]
        mac_sdk = run("mac-sdk", ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
        ios_sdk = run("ios-sdk", ["/usr/bin/xcrun", "--sdk", "iphoneos", "--show-sdk-path"]).strip()
        run("probe-ui", swift + ["-sdk", mac_sdk, "-parse-as-library", "-emit-module", "-emit-object",
            "-module-name", "EntryProbeUI", here / "ProbeUI.swift", "-emit-module-path",
            work / "EntryProbeUI.swiftmodule", "-o", work / "EntryProbeUI.o"])
        identity = "12345678-1234-4234-8234-123456789abc"
        bundles = {"ipad": "com.ambrion.sillcanvas.ipad", "iphone": "com.ambrion.sillcanvas.iphone",
                   "isolated": "com.ambrion.rea.ipad-runtime", "unknown": "example.invalid",
                   "suffix": "com.ambrion.sillcanvas.ipad.test", "missing": None}
        for debug in [True, False]:
            mode = "debug" if debug else "release"
            flags = ["-D", "DEBUG"] if debug else []
            run(mode + "-ios-sdk-typecheck", swift + flags + ["-sdk", ios_sdk, "-target", "arm64-apple-ios27.0",
                "-parse-as-library", "-typecheck", inputs[0], runtime, here / "Dependencies.swift"])
            for name, bundle in bundles.items():
                folder = work / (mode + "-" + name)
                folder.mkdir()
                info = dict(CFBundleExecutable="entry-check", CFBundleVersion="1",
                            CCRSourceCommit="a" * 40, CCRSourceTree="b" * 40)
                if bundle is not None:
                    info["CFBundleIdentifier"] = bundle
                plist = folder / "Info.plist"
                plist.write_bytes(plistlib.dumps(info))
                binary = folder / "entry-check"
                run(mode + "-" + name + "-compile", swift + flags + ["-D", "ENTRY_PROBE", "-sdk", mac_sdk,
                    "-parse-as-library", "-I", work, probe_app, runtime, here / "Dependencies.swift",
                    work / "EntryProbeUI.o", "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist", "-Xlinker", plist, "-o", binary])
                for trigger in ["normal", "valid", "invalid", "duplicate", "missing-context"]:
                    home = folder / trigger
                    support = home / "Library/Application Support"
                    support.mkdir(parents=True)
                    context = support / "CCRIntegrationTests" / identity
                    context.mkdir(parents=True)
                    if trigger != "missing-context":
                        (context / "context.json").write_text(json.dumps(dict(schema="ccr.ipad-test-context/v1",
                            id=identity, commit="a" * 40, tree="b" * 40,
                            relayAddress="http://192.168.1.2:8791", token="fixture-only-" + "t" * 24)))
                    sentinels = {}
                    for relative in re.findall(r'case \w+ = "([^"]+)"', declaration(model, "enum StateFile:")):
                        path = support / relative
                        path.parent.mkdir(parents=True, exist_ok=True)
                        path.write_bytes(b"original-user-state\x00{{c1::&#125;&#125;}}\n")
                        sentinels[path] = path.read_bytes()
                    arguments = [] if trigger == "normal" else ["--ccr-test-runtime", identity]
                    if trigger == "invalid":
                        arguments[-1] = "../invalid"
                    if trigger == "duplicate":
                        arguments *= 2
                    expected = "normal" if name in ["ipad", "iphone"] else "blocked"
                    if debug and trigger != "normal":
                        expected = "isolated" if trigger == "valid" else "blocked"
                    case_env = dict(env, HOME=str(home), CFFIXED_USER_HOME=str(home), ENTRY_EXPECTED=expected)
                    label = "-".join([mode, name, trigger])
                    observed = run(label, [binary, *arguments], case_env).strip()
                    assert all(p.read_bytes() == data for p, data in sentinels.items()), label
                    receipt = context / "state/runtime.json"
                    assert receipt.exists() == (expected == "isolated"), label
                    cases.append(dict(label=label, expected=expected, observed=observed, sentinelUnchanged=True))
        if not args.entry_only:
            for configuration, base in [("Debug", "Info-Debug.plist"), ("Release", "Info.plist")]:
                generated = work / (configuration + "-Info.plist")
                run(configuration + "-metadata", ["/usr/bin/python3", inputs[1], "--repo", root,
                    "--base", root / "iOSClient" / base, "--output", generated, "--configuration", configuration])
                metadata = plistlib.loads(generated.read_bytes())
                assert metadata["UIApplicationSceneManifest"]["UIApplicationSupportsMultipleScenes"] is False
                assert metadata["CCRSourceIdentityVerified"] is True
                run(configuration + "-verify", ["/usr/bin/python3", inputs[1], "--repo", root, "--verify-built", generated])
                (out / generated.name).write_bytes(generated.read_bytes())
        assert all(hashlib.sha256((root / name).read_bytes()).hexdigest() == digest for name, digest in hashes.items())
finally:
    (out / "result.json").write_text(json.dumps(dict(commands=commands, cases=cases, sourceSHA256=hashes,
        sourceUnchanged=all(hashlib.sha256((root / n).read_bytes()).hexdigest() == h for n, h in hashes.items()),
        scope="실제 App 소스의 import만 교체한 경계 실행. UI dependency는 계수용 대역. 실제 CanvasRuntime와 로컬 파일 경로. iOS SDK typecheck. 실 UI·실기·Host 연결 수용 아님."),
        ensure_ascii=False, indent=2) + "\n")
print(f"PASS {len(cases)}개 App 진입 경계, iOS SDK DEBUG/Release typecheck, 원본 sentinel 보존")
