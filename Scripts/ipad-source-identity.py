#!/usr/bin/env python3
import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess


def git(repo, *args):
    return subprocess.check_output(["/usr/bin/git", "--no-optional-locks", "-C", str(repo), *args], stderr=subprocess.PIPE).decode().strip()


def identity(repo):
    commit = git(repo, "rev-parse", "--verify", "HEAD")
    tree = git(repo, "rev-parse", "--verify", "HEAD^{tree}")
    if not all(re.fullmatch(r"[0-9a-f]{40}", value) for value in (commit, tree)):
        raise ValueError("Git SHA 형식이 올바르지 않습니다.")
    if git(repo, "status", "--porcelain=v1", "--untracked-files=all"):
        raise ValueError("미커밋 또는 미추적 소스는 정확한 HEAD로 표시할 수 없습니다.")
    if git(repo, "submodule", "status", "--recursive"):
        raise ValueError("추가 소스 저장소의 출처 검증이 필요합니다.")
    return commit, tree


def validate_existing(info, expected, required=False):
    present = "CCRSourceCommit" in info or "CCRSourceTree" in info
    if required or present:
        if (info.get("CCRSourceCommit"), info.get("CCRSourceTree")) != expected:
            raise ValueError("기존 Info.plist의 소스 커밋·트리가 현재 clean Git과 다릅니다.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--base", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--selected-info", type=Path)
    parser.add_argument("--configuration", default="Release")
    parser.add_argument("--verify-built", type=Path)
    args = parser.parse_args()
    if args.verify_built:
        expected = identity(args.repo)
        with args.verify_built.open("rb") as stream:
            info = plistlib.load(stream)
        validate_existing(info, expected, required=True)
        if info.get("CCRSourceIdentityVerified") is False:
            raise ValueError("검증되지 않은 빌드입니다.")
        print("빌드 Info.plist의 정확한 소스 커밋·트리를 확인했습니다.")
        return
    if not args.base or not args.output:
        parser.error("--base와 --output이 필요합니다.")
    external = args.selected_info and args.selected_info.resolve() != args.output.resolve()
    source = args.selected_info if external else args.base
    with source.open("rb") as stream:
        info = plistlib.load(stream)
    try:
        expected = identity(args.repo)
    except (ValueError, subprocess.CalledProcessError):
        if args.configuration != "Debug" or "CCRSourceCommit" in info or "CCRSourceTree" in info:
            raise ValueError("정확한 clean Git 소스를 확인하지 못해 빌드를 중단합니다.")
        info["CCRSourceIdentityVerified"] = False
        print("Debug 소스가 미확인입니다. 설치 완료 확인에 사용할 소스 식별값을 넣지 않습니다.")
    else:
        validate_existing(info, expected, required=bool(external))
        info.update(CCRSourceCommit=expected[0], CCRSourceTree=expected[1], CCRSourceIdentityVerified=True)
        if identity(args.repo) != expected:
            raise ValueError("소스 식별값 작성 중 Git 소스가 바뀌었습니다.")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(".pending.plist")
    with temporary.open("wb") as stream:
        plistlib.dump(info, stream)
    os.replace(temporary, args.output)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        raise SystemExit("iPad 소스 식별값 확인 실패: " + str(error))
