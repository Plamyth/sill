#!/usr/bin/env python3
"""검수된 Node 소스와 검증된 Python을 실행하지 않는 오디오 중계 후보로 묶는다."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


NODE_COMMIT = "1f846e8b776dec9b504cebf78735e57dc1ad5cda"
SYSTEM = ("/usr/lib/", "/System/Library/")
MACHO = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"}


def sha(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def command(args):
    return subprocess.check_output(args, stderr=subprocess.STDOUT, text=True, timeout=60,
                                   env={"PATH": "/usr/bin:/bin", "LANG": "C"})


def links(path):
    text = command(["/usr/bin/otool", "-l", str(path)])
    loads = re.findall(r"\bcmd LC_(?:LOAD_DYLIB|LOAD_WEAK_DYLIB|REEXPORT_DYLIB|LOAD_UPWARD_DYLIB)\n\s+cmdsize \d+\n\s+name (.*?) \(offset", text)
    search = re.findall(r"\bcmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.*?) \(offset", text)
    return sorted(set(loads)), sorted(set(search))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--node-repo", type=Path, required=True)
    parser.add_argument("--review", type=Path, required=True)
    parser.add_argument("--python-evidence", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    package = output / "LocalAudioRelay"
    runtime = package / "runtime"
    runtime.mkdir(parents=True)
    receipt = {"nodeSourceCommit": NODE_COMMIT, "inputs": {}, "installed": False,
               "serverStarted": False, "audioOpened": False, "productionSigned": False, "exitCode": 2}
    try:
        review = json.loads(args.review.read_text())
        assert review["candidateCommit"] == NODE_COMMIT and review["independentReview"]["result"] == "CLEAR"
        repo = args.node_repo.resolve(strict=True)
        def git(*parts):
            return subprocess.check_output(["git", "-C", str(repo), *parts])
        assert git("rev-parse", NODE_COMMIT + "^{tree}").decode().strip() == review["candidateTree"]
        server = runtime / "server"
        server.mkdir()
        names = git("ls-tree", "--name-only", NODE_COMMIT, "server/").decode().splitlines()
        names = [name for name in names if name.endswith((".js", ".py"))]
        assert set(review["serverModules"]) == set(names)
        for name in names:
            data = git("show", NODE_COMMIT + ":" + name)
            assert hashlib.sha256(data).hexdigest() == review["serverModules"][name]
            (runtime / name).write_bytes(data)
        python_evidence = args.python_evidence.resolve(strict=True)
        previous = json.loads((python_evidence / "result.json").read_text())
        assert previous["exitCode"] == 0 and previous["inputsUnchanged"] and not previous["symlinks"]
        python = python_evidence / "runtime/python"
        actual = {str(p.relative_to(python)): sha(p) for p in python.rglob("*") if p.is_file()}
        assert actual == previous["outputsSHA256"]
        assert not any(p.is_symlink() for p in python.rglob("*"))
        shutil.copytree(python, runtime / "python")
        receipt["pythonInputHashes"] = actual
        node = Path("/opt/homebrew/bin/node").resolve(strict=True)
        mapping = {node: runtime / "node/bin/node"}
        original_links = {}
        pending = [node]
        while pending:
            source = pending.pop()
            receipt["inputs"][str(source)] = sha(source)
            loads, rpaths = links(source)
            resolved = {}
            def expand(value):
                return value.replace("@loader_path", str(source.parent)).replace("@executable_path", str(node.parent))
            for load in loads:
                if load.startswith(SYSTEM):
                    continue
                candidates = ([Path(expand(p)) / load[len("@rpath/"):] for p in rpaths]
                              if load.startswith("@rpath/") else [Path(expand(load))])
                found = {p.resolve() for p in candidates if p.is_absolute() and p.is_file()}
                assert len(found) == 1, (source, load, candidates)
                dependency = found.pop()
                assert dependency.is_relative_to("/opt/homebrew/Cellar"), dependency
                resolved[load] = dependency
                if dependency not in mapping:
                    target = runtime / "node/lib" / dependency.name
                    assert target not in mapping.values(), ("duplicate dylib name", dependency)
                    mapping[dependency] = target
                    pending.append(dependency)
            original_links[source] = (resolved, rpaths)
        for source, target in mapping.items():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            target.chmod(0o755)
            resolved, rpaths = original_links[source]
            for load, dependency in resolved.items():
                bundled = "@loader_path/" + os.path.relpath(mapping[dependency], target.parent)
                command(["/usr/bin/install_name_tool", "-change", load, bundled, str(target)])
            for search in rpaths:
                command(["/usr/bin/install_name_tool", "-delete_rpath", search, str(target)])
            if target.suffix == ".dylib":
                command(["/usr/bin/install_name_tool", "-id", "@rpath/" + target.name, str(target)])
            command(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(target)])
        dependencies = []
        entries = []
        for path in sorted(runtime.rglob("*")):
            assert not path.is_symlink()
            path.chmod(0o755 if path.is_dir() or path.stat().st_mode & 0o111 else 0o644)
            name = str(path.relative_to(runtime))
            entry = {"path": name, "kind": "directory" if path.is_dir() else "file", "mode": path.stat().st_mode & 0o7777}
            if path.is_file():
                entry.update(size=path.stat().st_size, sha256=sha(path))
                bundled, system = [], []
                with path.open("rb") as handle:
                    native = handle.read(4) in MACHO
                if native:
                    loads, searches = links(path)
                    assert all(p.startswith(("@loader_path/",) + SYSTEM) for p in searches), (path, searches)
                    for load in loads:
                        if load.startswith(SYSTEM):
                            system.append(load)
                        else:
                            assert load.startswith("@loader_path/"), (path, load)
                            target = (path.parent / load[len("@loader_path/"):]).resolve(strict=True)
                            assert target.is_relative_to(runtime) and target.is_file(), (path, load)
                            bundled.append(str(target.relative_to(runtime)))
                dependencies.append({"source": name, "bundled": sorted(set(bundled)), "system": sorted(set(system))})
            entries.append(entry)
        manifest = {"schemaVersion": 1, "runtimeABI": "native-audio-forwarding-stdio-v3", "nodeSourceCommit": NODE_COMMIT,
                    "port": 17648, "entries": entries, "dependencies": dependencies}
        (package / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        receipt["nodeVersion"] = command([str(mapping[node]), "--version"]).strip()
        for path in sorted(server.glob("*.js")):
            command([str(mapping[node]), "--check", str(path)])
        receipt["serverHashes"] = {str(p.relative_to(runtime)): sha(p) for p in sorted(server.iterdir())}
        receipt["inputsUnchanged"] = all(sha(Path(p)) == digest for p, digest in receipt["inputs"].items())
        receipt["pythonSourceUnchanged"] = all(sha(python / p) == digest for p, digest in actual.items())
        assert receipt["inputsUnchanged"] and receipt["pythonSourceUnchanged"]
        receipt.update(exitCode=0, manifestSHA256=sha(package / "manifest.json"), fileCount=len(dependencies),
                       nativeNodeFiles=len(mapping), dependencyClosureReadFromMachO=True)
    except Exception as error:
        receipt["error"] = str(error)
    (output / "result.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({k: v for k, v in receipt.items() if k not in ("inputs", "pythonInputHashes", "serverHashes")}, ensure_ascii=False))
    return receipt["exitCode"]


if __name__ == "__main__":
    raise SystemExit(main())
