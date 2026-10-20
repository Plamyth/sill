#!/usr/bin/env python3
"""생산 Dock 리더의 OS 경계를 inert fixture로 치환하여 검사한다."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

root, out = (Path(p).resolve() for p in sys.argv[1:])
route = json.loads(subprocess.check_output([
    "/Users/ambrion/.local/bin/storage-route", "path", "development-archive", "--project", "CCR-Vision"
]))
assert out.is_relative_to(Path(route["path"]) / "host-native-dock-20261021")
out.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
if not Path(env["DEVELOPER_DIR"]).is_dir():
    env.pop("DEVELOPER_DIR")
env["CLANG_MODULE_CACHE_PATH"] = str(out / "module-cache")


def run(name, command):
    result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=120)
    (out / f"{name}.log").write_text(result.stdout + result.stderr)
    print(result.stdout + result.stderr, end="")
    return result.returncode


protocol = sorted((root / "Sources/StreamProtocol").glob("*.swift"))
code = run("protocol", [
    "/usr/bin/xcrun", "swiftc", "-emit-library", "-emit-module", "-module-name", "StreamProtocol",
    *map(str, protocol), "-emit-module-path", str(out / "StreamProtocol.swiftmodule"),
    "-o", str(out / "libStreamProtocol.dylib"),
])
if code:
    sys.exit(code)
original = (root / "Sources/SillHost/RemoteDockReader.swift").read_text()
catalog = (root / "Sources/SillHost/WindowCatalog.swift").read_text()
policy = re.search(r"nonisolated static func isPrivateApplication\(_ bundleID: String\) -> Bool \{[^}]+\}", catalog)
assert policy, "생산 비공개 앱 정책을 찾지 못했습니다."
fixture = (Path(__file__).parent / "fixture.swift").read_text()
fixture = fixture.replace("// PRODUCTION_POLICY", "enum WindowCatalog { " + policy[0] + " }")
reader = original
for name in ["AXIsProcessTrusted", "AXUIElementCreateApplication", "AXUIElementPerformAction",
             "AXUIElementSetMessagingTimeout", "AXUIElementCopyAttributeValue"]:
    reader = reader.replace(name, "Fixture" + name)
reader = reader.replace("AXUIElement", "FixtureElement")
reader = reader.replace("NSRunningApplication", "FixtureRunningApplication")
reader = reader.replace("Bundle(url:", "FixtureBundle(url:")
reader = reader.replace("ProcessInfo.processInfo.systemUptime", "Fixture.now")
reader = reader.replace("NSWorkspace.shared.icon", "FixtureWorkspace.shared.icon")
reader = reader.replace("private var icons:", "var icons:")
assert not re.search(r"(?<![A-Za-z])AX(?:UIElement\w+|IsProcessTrusted)\(", reader)
source = out / "inert.swift"
source.write_text(reader + "\n" + fixture)
inputs = [root / "Sources/SillHost/RemoteDockReader.swift", root / "Sources/SillHost/WindowCatalog.swift", *protocol,
          Path(__file__).resolve(), Path(__file__).parent / "fixture.swift"]
(out / "inputs.json").write_text(json.dumps({str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}, indent=2))
code = run("inert-compile", [
    "/usr/bin/xcrun", "swiftc", "-parse-as-library", "-I", str(out), "-L", str(out), "-lStreamProtocol",
    "-Xlinker", "-rpath", "-Xlinker", str(out), str(source), "-o", str(out / "checks"),
])
if code:
    sys.exit(code)
code = run("inert-run", [str(out / "checks")])
(out / "policy.swift").write_text("import Foundation\nenum WindowCatalog { " + policy[0] + " }\n")
sdk = run("sdk-typecheck", [
    "/usr/bin/xcrun", "swiftc", "-typecheck", "-parse-as-library", "-I", str(out),
    str(root / "Sources/SillHost/RemoteDockReader.swift"), str(out / "policy.swift"),
])
print(f"격리 검사 종료 코드 {code}, 실제 SDK typecheck 종료 코드 {sdk}")
sys.exit(code or sdk)
