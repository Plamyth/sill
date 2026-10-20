#!/usr/bin/env python3
"""gain과 PCM 쓰기를 Mini의 stdin 입력으로 검사한다. 오디오 앱이나 장치는 실행하지 않는다."""

import argparse
import ast
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[3]
CHECK = Path(__file__).resolve().parent
BASE = "3696051eda68e149926132668ac596bf5689d397"
FILES = [
    "visionOSClient/VisionAudioGain.swift",
    "visionOSClient/VisionAudioPlayer.swift",
    "visionOSClient/VisionAudioBuffer.swift",
    "visionOSClient/VisionAudioHardware.swift",
    "Scripts/make-vision-project.py",
    "SillVision.xcodeproj/project.pbxproj",
    "Tests/checks/vision-output-gain/main.swift",
    "Tests/checks/vision-output-gain/run.py",
]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def render_callback(player):
    start = player.index("try output.start(ticket, format: format, version: version, authorization: authorization)")
    opening = player.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        if player[end] == "{":
            depth += 1
        elif player[end] == "}":
            depth -= 1
        end += 1
    return player[start:end]


def static_checks(sources):
    objects = plistlib.loads(sources[FILES[5]])["objects"]
    path = FILES[0]
    refs = [key for key, item in objects.items() if item.get("path") == path]
    assert len(refs) == 1, "gain 파일 참조가 정확히 하나여야 한다"
    builds = [key for key, item in objects.items() if item.get("fileRef") == refs[0]]
    assert len(builds) == 1, "gain 빌드 참조가 정확히 하나여야 한다"
    targets = [item for item in objects.values() if item.get("isa") == "PBXNativeTarget"
               and item.get("name") in ("SillVision", "SillVisionReleaseTest")]
    assert len(targets) == 2
    for target in targets:
        entries = [entry for phase in target["buildPhases"]
                   if objects[phase]["isa"] == "PBXSourcesBuildPhase"
                   for entry in objects[phase]["files"]]
        assert entries.count(builds[0]) == 1, target["name"]
    assignments = {node.targets[0].id: node.value for node in ast.parse(sources[FILES[4]]).body
                   if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name)}
    client = ast.literal_eval(assignments["CLIENT"])
    generated = eval(compile(ast.Expression(assignments["files"]), "generator-files", "eval"),
                     {"__builtins__": {}}, {"CLIENT": client})
    assert generated.count(path) == 1, "프로젝트 생성 목록에도 gain을 한 번 포함해야 한다"
    for unchanged in FILES[2:4]:
        baseline = subprocess.check_output(["git", "show", BASE + ":" + unchanged], cwd=ROOT)
        assert sources[unchanged] == baseline, unchanged + "는 변경 범위 밖이다"
    player = sources[FILES[1]].decode()
    original = player.replace("{ [gain = VisionAudioGain.shared] _, _, frames, list in", "{ _, _, frames, list in")
    original = original.replace("                    let renderGain = gain.renderGain\n", "")
    original = original.replace("= renderGain == 0 ? 0 : sample * renderGain", "= sample")
    baseline = subprocess.check_output(["git", "show", BASE + ":" + FILES[1]], cwd=ROOT).decode()
    assert original == baseline, "Player 변경은 최종 PCM gain 적용에 한정해야 한다"


REMOTE = r'''
import hashlib, json, os, shutil, subprocess, sys, tempfile
source = sys.stdin.buffer.read()
received = hashlib.sha256(source).hexdigest()
output = tempfile.mkdtemp(prefix="vision-output-gain-")
code = 1
try:
    result = subprocess.run(["/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-O",
                             "-module-cache-path", output + "/cache", "-",
                             "-o", output + "/gain-check"], input=source, timeout=180)
    code = result.returncode
    del source
    if code == 0:
        code = subprocess.run([output + "/gain-check"], timeout=60).returncode
except subprocess.TimeoutExpired:
    print("검사 시간 예산 초과", file=sys.stderr)
    code = 124
finally:
    if "source" in globals():
        del source
    shutil.rmtree(output)
    print("REMOTE_RECEIPT=" + json.dumps({"received_sha256": received,
          "source_transport": "stdin_memory", "source_released": "source" not in globals(),
          "output_path": output, "output_removed": not os.path.lexists(output),
          "exit_code": code}), flush=True)
sys.exit(code)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--emit-swift", action="store_true")
    args = parser.parse_args()
    sources = {path: (ROOT / path).read_bytes() for path in FILES}
    static_checks(sources)
    callback = render_callback(sources[FILES[1]].decode())
    tests = sources[FILES[6]].decode()
    assert tests.count("__PRODUCTION_RENDER_CALLBACK__") == 1
    program = (sources[FILES[0]].decode() + "\n" + sources[FILES[2]].decode() + "\n"
               + tests.replace("__PRODUCTION_RENDER_CALLBACK__", callback)).encode()
    if args.emit_swift:
        sys.stdout.buffer.write(program)
        return 0
    owner = os.environ.get("CODEX_THREAD_ID", "vision-playback-gain-20261021")
    result = subprocess.run([str(Path.home() / ".local/bin/mini"), "run", "--cwd", "/Users/sin-wonho",
                             "--", "python3", "-c", REMOTE], input=program, capture_output=True, timeout=300)
    stdout, stderr = result.stdout.decode(), result.stderr.decode()
    print(stdout, end="")
    print(stderr, end="", file=sys.stderr)
    rows = [line.removeprefix("REMOTE_RECEIPT=") for line in stdout.splitlines() if line.startswith("REMOTE_RECEIPT=")]
    remote = json.loads(rows[-1]) if rows else None
    unchanged = all((ROOT / path).read_bytes() == data for path, data in sources.items())
    passed = (result.returncode == 0 and unchanged and remote is not None
              and remote["received_sha256"] == sha(program)
              and remote["source_released"] and remote["output_removed"])
    receipt = {
        "owner": owner, "base_commit": BASE,
        "checked_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "source_sha256": {path: sha(data) for path, data in sources.items()},
        "sent_sha256": sha(program), "callback_sha256": sha(callback.encode()),
        "remote": remote, "source_unchanged": unchanged, "exit_code": result.returncode,
        "passed": passed, "stdout": stdout, "stderr": stderr,
        "boundary": "Mini 순수 상태와 실제 PCM callback 본문을 비활성 버퍼로 검사. 하드웨어 wrapper 실행, 소리, 장치, 앱, 설치, 시뮬레이터, HAL, 전체 SDK 빌드, source-guard 이전 수용, 독립 검수는 포함하지 않음.",
    }
    folder = CHECK / "receipts"
    folder.mkdir(exist_ok=True)
    name = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ") + ".json"
    path = folder / name
    path.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    print("실행 영수증 " + str(path))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
