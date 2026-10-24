#!/usr/bin/env python3
import hashlib
import atexit
from pathlib import Path
import plistlib
import subprocess
import shutil
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
output = Path(sys.argv[1]).resolve()
fixture = Path(tempfile.mkdtemp(prefix="source-identity-fixture-", dir=output))
atexit.register(shutil.rmtree, fixture)
script = root / "Scripts/ipad-source-identity.py"


def git(*args):
    return subprocess.check_output(["/usr/bin/git", "-C", str(fixture), *args], stderr=subprocess.STDOUT).decode().strip()


def run(*args, success=True):
    result = subprocess.run([sys.executable, str(script), "--repo", str(fixture), *map(str, args)], capture_output=True, text=True)
    assert (result.returncode == 0) == success, result.stdout + result.stderr
    return result


git("init", "-q")
(fixture / "source.txt").write_text("fixture source\n")
git("add", "source.txt")
git("-c", "user.name=CCR 검사", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "소스 식별 fixture")
commit, tree = git("rev-parse", "HEAD"), git("rev-parse", "HEAD^{tree}")
base = output / "base-info.plist"
built = output / "built-info.plist"
base.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.ambrion.sillcanvas.ipad", "CFBundleVersion": "62"}))
args = ["--base", base, "--output", built]
run(*args, "--configuration", "Release")
metadata = plistlib.loads(built.read_bytes())
assert (metadata["CCRSourceCommit"], metadata["CCRSourceTree"]) == (commit, tree)
assert metadata["CCRSourceIdentityVerified"] is True
run("--verify-built", built)
custom = output / "custom-info.plist"
custom.write_bytes(plistlib.dumps(dict(metadata, CCRTestRuntime="preserved")))
custom_hash = hashlib.sha256(custom.read_bytes()).hexdigest()
run(*args, "--selected-info", custom, "--configuration", "Debug")
assert plistlib.loads(built.read_bytes())["CCRTestRuntime"] == "preserved"
assert hashlib.sha256(custom.read_bytes()).hexdigest() == custom_hash
custom.write_bytes(plistlib.dumps(dict(metadata, CCRSourceTree="e" * 40)))
run(*args, "--selected-info", custom, "--configuration", "Debug", success=False)
run("--verify-built", custom, success=False)
run(*args, "--selected-info", base, "--configuration", "Debug", success=False)
(fixture / "untracked.txt").write_text("unverified input")
before = built.read_bytes()
run(*args, "--configuration", "Release", success=False)
assert built.read_bytes() == before
run(*args, "--configuration", "Debug")
unverified = plistlib.loads(built.read_bytes())
assert unverified["CCRSourceIdentityVerified"] is False
assert "CCRSourceCommit" not in unverified and "CCRSourceTree" not in unverified
run("--verify-built", built, success=False)
run(*args, "--selected-info", custom, "--configuration", "Debug", success=False)

project = plistlib.loads(subprocess.check_output(["/usr/bin/plutil", "-convert", "xml1", "-o", "-", str(root / "iOSClient/Sill.xcodeproj/project.pbxproj")]))
objects = project["objects"]
target = next(value for value in objects.values() if value.get("isa") == "PBXNativeTarget" and value.get("name") == "Sill")
phases = [objects[ref] for ref in target["buildPhases"]]
identity_phase = next(phase for phase in phases if phase.get("name") == "Prepare iPad source identity")
assert "ipad-source-identity.py" in identity_phase["shellScript"]
assert identity_phase["outputPaths"] == ["$(DERIVED_FILE_DIR)/CCR-Source-Info.plist", "$(DERIVED_FILE_DIR)/CCR-Source-Info.pending.plist"]
config_list = objects[target["buildConfigurationList"]]
for reference in config_list["buildConfigurations"]:
    settings = objects[reference]["buildSettings"]
    assert settings["INFOPLIST_FILE"] == "$(DERIVED_FILE_DIR)/CCR-Source-Info.plist"
    assert settings["CCR_SOURCE_BASE_INFOPLIST_FILE"] in ["Info-Debug.plist", "Info.plist"]
sources = next(phase for phase in phases if phase["isa"] == "PBXSourcesBuildPhase")
compiled = [objects[objects[ref]["fileRef"]]["path"] for ref in sources["files"]]
for name in ["IPadAppUpdate.swift", "IPadAppUpdateController.swift", "IPadAppUpdateView.swift"]:
    assert compiled.count(name) == 1
print("PASS 실제 metadata 작성·검증 스크립트, 외부 customInfo 보존·불일치 거부, Release dirty 차단, Debug 미검증, 실제 xcodeproj 연결.")
