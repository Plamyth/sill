import hashlib
import json
import os
import shutil
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
    env["CLANG_MODULE_CACHE_PATH"] = str(scratch / "module-cache")
    env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(scratch / "module-cache")
    isolation = ["--cache-path", str(scratch / "cache"), "--config-path", str(scratch / "config"),
                 "--security-path", str(scratch / "security"), "--manifest-cache", "none"]
    artifact = None
    if mode == "sdk":
        code = subprocess.run(["swift", "build", "-c", "release", "--product", "SillMenuBar", "--scratch-path", str(scratch), *isolation], cwd=root, env=env).returncode
        artifact = scratch / "release" / "SillMenuBar"
    elif mode == "provision":
        code = subprocess.run(["python3", "Tests/checks/owner-bootstrap-provision/run.py"], cwd=root, env=env).returncode
    elif mode == "compatibility":
        for check in ["door-policy", "home-records", "remote-rules"]:
            if code == 0:
                code = subprocess.run(["bash", f"Tests/checks/{check}/run.sh"], cwd=root, env=env).returncode
    else:
        code = subprocess.run(["swift", "build", "-c", "release", "--target", "SillHostCore", "--scratch-path", str(scratch),
                               *isolation, "-Xswiftc", "-enable-testing", "-Xswiftc", "-DOWNER_BOOTSTRAP_CONTRACT"], cwd=root, env=env).returncode
        if code == 0:
            modules = next(scratch.glob("*/release/Modules"))
            output = modules.parent
            objects = sorted((output / "StreamProtocol.build").glob("*.o")) + sorted((output / "SillHostCore.build").glob("*.o"))
            description = json.loads((output / "description.json").read_text())
            arguments = next(c["otherArguments"] for c in description["swiftCommands"].values() if c["moduleName"] == "SillHostCore")
            package_name = arguments[arguments.index("-package-name") + 1]
            c_arguments = []
            index = 0
            while index < len(arguments):
                if arguments[index] in ("-Xcc", "-I", "-F"):
                    c_arguments.extend(arguments[index:index + 2])
                    index += 2
                else:
                    index += 1
            module_maps = [Path(value.split("=", 1)[1]) for value in c_arguments if value.startswith("-fmodule-map-file=")]
            if not module_maps or not all(path.is_file() for path in module_maps):
                raise RuntimeError("HostCore C module maps are missing from the SwiftPM compile command")
            for module_map in module_maps:
                objects.extend(sorted(module_map.parent.glob("*.o")))
            print(json.dumps({"phase": "contract-compile-inputs", "cModuleMaps": list(map(str, module_maps)),
                              "cArguments": c_arguments, "objectCount": len(objects)}, sort_keys=True), flush=True)
            binary = scratch / "checks"
            compiler = ["xcrun", "swiftc", "-O", "-parse-as-library", "-package-name", package_name, "-I", str(modules), "-module-cache-path", str(scratch / "module-cache"), *c_arguments]
            source = str(Path(__file__).with_name("main.swift"))
            code = subprocess.run([*compiler,
                                   source, *map(str, objects), "-o", str(binary)], cwd=root, env=env).returncode
            negative_contracts = {
                "PRINCIPAL": "has no member 'principal'",
                "BINDING": "has no member 'binding'",
                "PROOF": "to return type 'TailnetDeviceAccess.Proof'",
                "EVIDENCE": "to expected argument type 'TailnetDeviceAccess.Proof'",
                "ADMIT": "to expected argument type 'OwnerBootstrapSocket.Evidence'",
                "RECEIPT": "to expected argument type 'OwnerBootstrapSocket.Evidence'",
            }
            if code == 0:
                for contract, diagnostic in negative_contracts.items():
                    result = subprocess.run([*compiler, "-typecheck", "-D", "OWNER_PUBLIC_PROFILE_NO_" + contract, source],
                                            cwd=root, env=env, capture_output=True, text=True)
                    if result.returncode == 0 or diagnostic not in result.stderr:
                        print(result.stdout + result.stderr, flush=True)
                        print("FAIL public profile negative contract " + contract, flush=True)
                        code = 1
                        break
                    print("PASS public profile negative contract " + contract + ": " + diagnostic, flush=True)
            if code == 0:
                code = subprocess.run([str(binary)], cwd=root, env=env).returncode
                artifact = binary
    if code == 0 and artifact is not None and os.environ.get("SILL_CHECK_ARTIFACT_DIR"):
        target = Path(os.environ["SILL_CHECK_ARTIFACT_DIR"])
        target.mkdir(parents=True, exist_ok=True)
        shutil.copy2(artifact, target / ("SillMenuBar" if mode == "sdk" else "owner-host-contracts"))
    after = digest()
print(json.dumps({"phase": mode, "exitCode": code, "sourceBeforeSHA256": before,
                  "sourceAfterSHA256": after, "sourceUnchanged": before == after,
                  "scratchRemoved": not scratch.exists(), "runtimeConnections": 0,
                  "installedHostChanges": 0}, sort_keys=True), flush=True)
sys.exit(code if before == after else 3)
