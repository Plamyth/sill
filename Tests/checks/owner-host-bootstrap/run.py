import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]


def digest():
    result = hashlib.sha256()
    files = [root / "Package.swift"]
    for directory in ["Sources", "Tests", "Scripts", "iOSClient"]:
        files.extend(p for p in (root / directory).rglob("*") if p.is_file() and "__pycache__" not in p.parts)
    for path in sorted(files):
        result.update(str(path.relative_to(root)).encode() + b"\0" + path.read_bytes())
    return result.hexdigest()


before = digest()
env = dict(os.environ)
env["SDKROOT"] = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
env["PYTHONDONTWRITEBYTECODE"] = "1"
mode = sys.argv[1] if len(sys.argv) > 1 else "tests"
code = 0
with tempfile.TemporaryDirectory(prefix="sill-owner-check-") as temporary:
    scratch = Path(temporary)
    if mode == "sdk":
        code = subprocess.run(["swift", "build", "-c", "release", "--product", "SillMenuBar", "--scratch-path", str(scratch)], cwd=root, env=env).returncode
    elif mode == "provision":
        code = subprocess.run(["python3", "Tests/checks/owner-bootstrap-provision/run.py"], cwd=root, env=env).returncode
    elif mode == "compatibility":
        for check in ["door-policy", "home-records", "remote-rules"]:
            if code == 0:
                code = subprocess.run(["bash", f"Tests/checks/{check}/run.sh"], cwd=root, env=env).returncode
    else:
        code = subprocess.run(["swift", "build", "-c", "release", "--target", "SillHostCore", "--scratch-path", str(scratch),
                               "-Xswiftc", "-enable-testing", "-Xswiftc", "-DOWNER_BOOTSTRAP_CONTRACT"], cwd=root, env=env).returncode
        if code == 0:
            modules = next(scratch.glob("*/release/Modules"))
            output = modules.parent
            objects = sorted((output / "StreamProtocol.build").glob("*.o")) + sorted((output / "SillHostCore.build").glob("*.o"))
            description = json.loads((output / "description.json").read_text())
            arguments = next(c["otherArguments"] for c in description["swiftCommands"].values() if c["moduleName"] == "SillHostCore")
            package_name = arguments[arguments.index("-package-name") + 1]
            binary = scratch / "checks"
            code = subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-package-name", package_name, "-I", str(modules),
                                   str(Path(__file__).with_name("main.swift")), *map(str, objects), "-o", str(binary)], cwd=root, env=env).returncode
            if code == 0:
                code = subprocess.run([str(binary)], cwd=root, env=env).returncode
    after = digest()
print(json.dumps({"phase": mode, "exitCode": code, "sourceBeforeSHA256": before,
                  "sourceAfterSHA256": after, "sourceUnchanged": before == after,
                  "scratchRemoved": not scratch.exists(), "runtimeConnections": 0,
                  "installedHostChanges": 0}, sort_keys=True), flush=True)
sys.exit(code if before == after else 3)
