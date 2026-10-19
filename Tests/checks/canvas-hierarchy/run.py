#!/usr/bin/env python3
"""Run the complete production model with Apple's macOS SDK and archive input hashes."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
output = Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=True)
model = root / "iOSClient/CanvasBridge/CanvasModel.swift"
suites = [Path(__file__).with_name("main.swift"),
          root / "Tests/checks/ipad-canvas-revisions/main.swift"]
inputs = [model, Path(__file__).resolve(), *suites]


def hashes():
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in inputs}


before = hashes()
env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], env=env, text=True).strip()
compiler = subprocess.check_output(["xcrun", "swiftc", "--version"], env=env, text=True).strip()
results = []
status = 0
for suite in suites:
    name = suite.parent.name
    binary = output / name
    command = ["xcrun", "swiftc", "-swift-version", "5", "-sdk", sdk,
               "-module-cache-path", str(output / "modules"), str(model), str(suite), "-o", str(binary)]
    result = subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=180)
    (output / f"{name}-compile.log").write_text(result.stdout)
    print(result.stdout, end="", flush=True)
    entry = {"suite": name, "command": command, "compileExitCode": result.returncode}
    if result.returncode == 0:
        run = subprocess.run([str(binary)], env=env, text=True, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, timeout=30)
        (output / f"{name}-runtime.log").write_text(run.stdout)
        print(run.stdout, end="", flush=True)
        entry["runtimeExitCode"] = run.returncode
        status |= int(run.returncode != 0)
    else:
        status = 1
    results.append(entry)
after = hashes()
status |= int(before != after)
receipt = {"baseCommit": "c24ec06f3a08d5762822715640f317e18e033148",
           "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
           "worktree": str(root), "sdk": sdk, "compiler": compiler,
           "host": "MacBook local native SDK; Mini has no Apple SDK",
           "inputHashes": before, "afterHashes": after, "inputsUnchanged": before == after,
           "results": results, "exitCode": status}
(output / "result.json").write_text(json.dumps(receipt, indent=2) + "\n")
sys.exit(status)
