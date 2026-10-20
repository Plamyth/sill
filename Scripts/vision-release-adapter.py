#!/usr/bin/env python3
"""Prepare and verify CCR Vision test releases. Production is disabled."""

import argparse
import datetime as dt
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from dataclasses import dataclass
from urllib.parse import unquote, urlparse


OWNER = "01a13005-ff61-7780-b0e8-6dc171de1c9d"
BUNDLE = "dev.ambrion.SillVision"
TEAM = "ZPTXHJ866D"
UDID = "00008112-0001051A36C1A01E"
CORE_DEVICE = "D7C456D4-F34F-5DA1-A078-EC69DB34098A"
DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer"
ROUTER = "/Users/ambrion/.local/bin/storage-route"
CHECKS = (
    "runtime-source-readback", "readiness", "representative-api", "representative-ui",
    "isolated-data-provider", "fixture-reset", "external-effects-zero",
    "native-input", "audio-privacy", "sentry",
)
SHA = re.compile(r"[0-9a-f]{40}\Z")
RUNTIME_FILE = "Documents/CCRReleaseRuntime.json"
FRESH_SECONDS = 120


class Held(ValueError):
    pass


def require(condition, reason):
    if not condition:
        raise Held(reason)


def now():
    return dt.datetime.now(dt.timezone.utc)


def timestamp(value):
    require(isinstance(value, str), "timestamp_missing")
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        require(parsed.tzinfo is not None, "timestamp_timezone_missing")
        return parsed
    except ValueError as error:
        raise Held("timestamp_invalid") from error


def safe_path(value):
    path = Path(value)
    require(path.is_absolute() and ".." not in path.parts, "absolute_path_required")
    require(not any(p.is_symlink() for p in (path, *path.parents)), "symlink_path_refused")
    return path


def digest(path):
    with safe_path(path).open("rb") as source:
        value = hashlib.sha256()
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
        return value.hexdigest()


def evidence(path):
    path = safe_path(path)
    require(path.is_file(), "evidence_file_missing:" + str(path))
    return {"path": str(path), "sha256": digest(path)}


def verify_evidence(row):
    require(isinstance(row, dict) and isinstance(row.get("path"), str), "evidence_entry_invalid")
    actual = evidence(row["path"])
    require(actual["sha256"] == row.get("sha256"), "evidence_hash_mismatch:" + row["path"])
    return actual


def read_json(path):
    raw = json.loads(safe_path(path).read_text())
    require(isinstance(raw, dict), "json_object_required")
    return raw


def atomic_json(path, value):
    path = safe_path(path)
    fd, temporary = tempfile.mkstemp(prefix="." + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(value, output, sort_keys=True, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class Runner:
    def __init__(self, seconds):
        require(math.isfinite(seconds) and seconds > 0, "budget_invalid")
        self.deadline = time.monotonic() + seconds

    def run(self, args, cwd=None):
        remaining = self.deadline - time.monotonic()
        require(remaining > 0, "budget_exhausted")
        environment = {k: v for k, v in os.environ.items() if not k.startswith("DEVICECTL_CHILD_")}
        environment["DEVELOPER_DIR"] = DEVELOPER_DIR
        child = subprocess.Popen([str(a) for a in args], cwd=cwd, env=environment,
                                 stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 start_new_session=True)
        try:
            stdout, stderr = child.communicate(timeout=remaining)
        except subprocess.TimeoutExpired as error:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.communicate()
            raise Held("command_timeout:" + Path(args[0]).name) from error
        require(child.returncode == 0, "command_failed:" + Path(args[0]).name + ":" + str(child.returncode))
        return stdout.decode("utf-8", errors="replace"), stderr.decode("utf-8", errors="replace")


@dataclass(frozen=True)
class Source:
    commit: str
    tree: str

    def fields(self):
        return {"commit": self.commit, "tree": self.tree}

    def matches(self, raw):
        return all(raw.get(k) == v for k, v in self.fields().items())


def source_identity(args, runner):
    repo = safe_path(args.repo)

    def git(*words):
        return runner.run(["/usr/bin/git", "-C", repo, *words])[0].strip()

    require((args.commit is None) == (args.tree is None), "expected_source_pin_pair_required")
    if args.commit is not None:
        require(SHA.fullmatch(args.commit) and SHA.fullmatch(args.tree), "expected_source_invalid")
    require(git("status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none") == "",
            "source_dirty")
    require(git("symbolic-ref", "--quiet", "HEAD").startswith("refs/heads/"), "source_detached")
    source = Source(git("rev-parse", "HEAD"), git("rev-parse", "HEAD^{tree}"))
    if args.commit is not None:
        require(source == Source(args.commit, args.tree), "source_mismatch")
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", args.remote), "remote_name_invalid")
    require(args.ref.startswith("refs/heads/") and not any(c.isspace() for c in args.ref), "official_ref_invalid")
    remote_url = git("remote", "get-url", args.remote)
    require(remote_url in ("https://github.com/Plamyth/sill.git", "git@github.com:Plamyth/sill.git"),
            "official_remote_identity_mismatch")
    rows = git("ls-remote", "--exit-code", "--refs", args.remote, args.ref).splitlines()
    require(rows == [source.commit + "\t" + args.ref], "official_ref_source_mismatch")
    return source


def validate_lease(path, device, clock=now):
    require(device in (UDID, CORE_DEVICE), "target_not_configured")
    require(path is not None, "device_lease_missing")
    lease = read_json(path)
    require(lease.get("schema") == "ccr.vision.device-lease/v1", "device_lease_schema_invalid")
    require(lease.get("ownerThread") == OWNER, "device_lease_owner_mismatch")
    require(lease.get("deviceId") == device, "device_lease_target_mismatch")
    require(timestamp(lease.get("expiresAt")) > clock(), "device_lease_expired")
    permitted = lease.get("permitted")
    require(isinstance(permitted, dict) and all(type(permitted.get(k)) is bool for k in ("install", "launch")),
            "device_lease_permissions_invalid")
    return permitted


def runtime_identity(raw, source, built, clock=now, fresh=True):
    require(raw.get("schema") == "ccr.vision.runtime/v1", "runtime_schema_invalid")
    require(source.matches(raw), "runtime_source_mismatch")
    require(raw.get("bundleId") == BUNDLE and raw.get("build") == built["build"], "runtime_app_mismatch")
    require(type(raw.get("pid")) is int and raw["pid"] > 0, "runtime_pid_invalid")
    try:
        require(str(uuid.UUID(raw.get("bootUUID", ""))) == raw["bootUUID"].lower(), "runtime_boot_invalid")
    except (ValueError, AttributeError) as error:
        raise Held("runtime_boot_invalid") from error
    for key in ("executableSHA256", "infoPlistSHA256", "codeResourcesSHA256"):
        require(raw.get(key) == built[key], "runtime_signed_bytes_mismatch:" + key)
    age = (clock() - timestamp(raw.get("observedAt"))).total_seconds()
    if fresh:
        require(-5 <= age <= FRESH_SECONDS, "runtime_stale_or_future")
    identity = [UDID, source.commit, source.tree, raw["bootUUID"].lower()]
    return "ccr-vision:" + hashlib.sha256(json.dumps(identity).encode()).hexdigest()


def install_needed(runtime, source, built):
    if runtime is None:
        return True
    require(runtime.get("schema") == "ccr.vision.runtime/v1" and runtime.get("bundleId") == BUNDLE,
            "installed_runtime_identity_unknown")
    require(all(isinstance(runtime.get(k), str) and SHA.fullmatch(runtime[k]) for k in ("commit", "tree")),
            "installed_runtime_source_unknown")
    if not source.matches(runtime):
        return True
    runtime_identity(runtime, source, built, fresh=False)
    return False


class Native:
    def __init__(self, args, runner, directory, clock=now):
        self.args, self.runner, self.directory, self.clock = args, runner, directory, clock
        self.receipts = []

    def call(self, words, permission=None):
        permitted = validate_lease(self.args.lease, self.args.device, self.clock)
        if permission:
            require(permitted[permission], "device_lease_" + permission + "_denied")
        output = self.directory / (str(len(self.receipts)) + "-native.json")
        require(not output.exists(), "native_output_already_exists")
        self.runner.run(["/usr/bin/xcrun", "devicectl", "device", *words[:2],
                         "--device", self.args.device, "--timeout", "60", "--json-output", output, *words[2:]])
        raw = read_json(output)
        info = raw.get("info")
        require(isinstance(info, dict) and info.get("outcome") == "success", "native_outcome_unknown")
        result = raw.get("result")
        require(isinstance(result, dict), "native_result_missing")
        if "deviceIdentifier" in result:
            require(isinstance(result["deviceIdentifier"], str) and
                    result["deviceIdentifier"].upper() in (UDID, CORE_DEVICE), "native_device_mismatch")
        self.receipts.append(evidence(output))
        return result

    def unlocked(self):
        state = self.call(["info", "lockState"])
        require(state.get("passcodeRequired") is False and state.get("unlockedSinceBoot") is True,
                "device_locked_or_lock_state_unknown")

    def app(self):
        result = self.call(["info", "apps", "--bundle-id", BUNDLE, "--include-default-apps", "--include-container-paths"])
        apps = result.get("apps")
        require(isinstance(apps, list), "installed_apps_unknown")
        require(all(isinstance(app, dict) and app.get("bundleIdentifier") == BUNDLE for app in apps),
                "installed_app_identity_unknown")
        require(len(apps) <= 1, "installed_app_ambiguous")
        return apps[0] if apps else None

    def runtime(self):
        output = self.directory / (str(len(self.receipts)) + "-runtime.json")
        require(not output.exists(), "runtime_output_already_exists")
        self.call(["copy", "from", "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE,
                   "--source", RUNTIME_FILE, "--destination", str(output)])
        return read_json(output), evidence(output)

    def live_process(self, app, runtime, executable):
        result = self.call(["info", "processes"])
        rows = result.get("runningProcesses")
        require(isinstance(rows, list), "native_processes_unknown")
        app_path = native_path(app.get("url"))
        wanted = app_path.rstrip("/") + "/" + executable
        matching = [row for row in rows if isinstance(row, dict) and row.get("processIdentifier") == runtime["pid"]]
        require(len(matching) == 1 and native_path(matching[0].get("executable")) == wanted,
                "runtime_process_not_live_in_installed_app")


def native_path(value):
    require(isinstance(value, str) and value, "native_app_path_unknown")
    parsed = urlparse(value)
    require(parsed.scheme in ("", "file") and not parsed.netloc, "native_app_path_invalid")
    path = unquote(parsed.path)
    require(path.startswith("/") and ".." not in Path(path).parts, "native_app_path_invalid")
    return path


def signed_app(path, source, runner):
    path = safe_path(path)
    info = plistlib.loads((path / "Info.plist").read_bytes())
    require(isinstance(info, dict), "built_info_invalid")
    require(info.get("CFBundleIdentifier") == BUNDLE, "built_bundle_mismatch")
    require(info.get("BTSourceCommit") == source.commit and info.get("BTSourceTree") == source.tree,
            "built_source_stamp_mismatch")
    require(info.get("DTPlatformName") == "xros", "built_platform_mismatch")
    executable = info.get("CFBundleExecutable")
    require(isinstance(executable, str) and Path(executable).name == executable, "built_executable_invalid")
    require(isinstance(info.get("CFBundleVersion"), str) and info["CFBundleVersion"], "built_version_missing")
    runner.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", path])
    stdout, stderr = runner.run(["/usr/bin/codesign", "--display", "--verbose=4", path])
    signature = dict(line.split("=", 1) for line in (stdout + "\n" + stderr).splitlines() if "=" in line)
    require(signature.get("Identifier") == BUNDLE and signature.get("TeamIdentifier") == TEAM,
            "built_signature_identity_mismatch")
    require(re.fullmatch(r"[0-9a-fA-F]{40,64}", signature.get("CDHash", "")), "built_cdhash_missing")
    stdout, _ = runner.run(["/usr/bin/codesign", "--display", "--entitlements", ":-", path])
    entitlements = plistlib.loads(stdout.encode())
    require(isinstance(entitlements, dict), "built_entitlements_invalid")
    require(entitlements.get("application-identifier") == TEAM + "." + BUNDLE and
            entitlements.get("com.apple.developer.team-identifier") == TEAM, "built_entitlements_mismatch")
    files = {}
    for item in sorted(path.rglob("*")):
        require(not item.is_symlink(), "built_symlink_refused")
        if item.is_file():
            files[str(item.relative_to(path))] = digest(item)
    return {"path": str(path), "bundleId": BUNDLE, "teamId": TEAM, "build": info["CFBundleVersion"],
            "executable": executable, "cdhash": signature["CDHash"].lower(), "files": files,
            "executableSHA256": files[executable], "infoPlistSHA256": files["Info.plist"],
            "codeResourcesSHA256": files["_CodeSignature/CodeResources"]}


def developer_build(args, runner):
    if args.build_number is not None:
        require(args.build_number >= 22, "developer_build_below_minimum")
        return str(args.build_number)
    require(runner.run(["/usr/bin/git", "-C", args.repo, "rev-parse", "--is-shallow-repository"])[0].strip() == "false",
            "developer_build_requires_complete_history")
    count = runner.run(["/usr/bin/git", "-C", args.repo, "rev-list", "--count", "HEAD"])[0].strip()
    require(count.isdecimal() and int(count) > 0, "developer_build_history_invalid")
    return str(1000 + int(count))


def prepare(args, source, runner, output):
    project = safe_path(args.repo) / "SillVision.xcodeproj"
    require((project / "project.pbxproj").is_file(), "existing_vision_project_missing")
    manifest = output / "prepare.json"
    if manifest.exists():
        return prepared(args, source, runner, output)
    derived = output / "DerivedData"
    result_bundle = output / "Build.xcresult"
    require(not derived.exists() and not result_bundle.exists(), "owned_build_incomplete_use_reviewed_clean_output")
    build = developer_build(args, runner)
    runner.run(["/usr/bin/xcrun", "xcodebuild", "-project", project, "-scheme", "SillVision",
                "-configuration", "Release", "-sdk", "xros", "-destination", "generic/platform=visionOS",
                "-derivedDataPath", derived, "-clonedSourcePackagesDirPath", output / "SourcePackages",
                "-resultBundlePath", result_bundle,
                "-disableAutomaticPackageResolution", "-skipPackageUpdates",
                "PRODUCT_BUNDLE_IDENTIFIER=" + BUNDLE, "DEVELOPMENT_TEAM=" + TEAM,
                "CURRENT_PROJECT_VERSION=" + build,
                "CODE_SIGNING_ALLOWED=YES", "CODE_SIGNING_REQUIRED=YES", "CODE_SIGN_STYLE=Automatic",
                "BT_RELEASE_SOURCE_COMMIT=" + source.commit, "BT_RELEASE_SOURCE_TREE=" + source.tree,
                "build"], cwd=args.repo)
    built = signed_app(derived / "Build/Products/Release-xros/SillVision.app", source, runner)
    require(built["build"] == build, "built_developer_version_mismatch")
    require(source_identity(args, runner) == source, "source_changed_during_build")
    raw = {"schema": "ccr.vision.prepared/v1", **source.fields(), "repo": args.repo,
           "remote": args.remote, "ref": args.ref, "ownerThread": OWNER,
           "developerDir": DEVELOPER_DIR, "built": built, "resultBundle": str(result_bundle),
           "observedAt": now().isoformat()}
    atomic_json(manifest, raw)
    return raw


def prepared(args, source, runner, output):
    raw = read_json(output / "prepare.json")
    require(raw.get("schema") == "ccr.vision.prepared/v1" and source.matches(raw), "prepared_source_mismatch")
    require(all(raw.get(k) == getattr(args, k) for k in ("repo", "remote", "ref")), "prepared_origin_mismatch")
    expected_path = output / "DerivedData/Build/Products/Release-xros/SillVision.app"
    require(isinstance(raw.get("built"), dict) and raw["built"].get("path") == str(expected_path),
            "prepared_app_path_mismatch")
    require(signed_app(expected_path, source, runner) == raw["built"], "prepared_app_tampered")
    require(raw["built"]["build"] == developer_build(args, runner), "prepared_build_number_mismatch")
    require(source_identity(args, runner) == source, "source_changed_during_prepare")
    return raw


def observe(native, source, built):
    app = native.app()
    require(app is not None, "installed_app_missing")
    runtime, runtime_file = native.runtime()
    runtime_id = runtime_identity(runtime, source, built, native.clock)
    require(app.get("bundleVersion") == built["build"], "installed_app_build_mismatch")
    native.live_process(app, runtime, built["executable"])
    return {"app": app, "runtime": runtime, "runtimeEvidence": runtime_file, "runtimeId": runtime_id}


def deploy(args, source, runner, output, native):
    built = prepared(args, source, runner, output)["built"]
    native.unlocked()
    app = native.app()
    prior_file = None
    install = True
    if app:
        version = app.get("bundleVersion")
        require(isinstance(version, str) and version.isdecimal(), "installed_app_version_unknown")
        require(int(version) <= int(built["build"]), "installed_app_downgrade_refused")
        if version == built["build"]:
            runtime, prior_file = native.runtime()
            install = install_needed(runtime, source, built)
    attempt = output / "install-attempt.json"
    if install:
        require(app is None, "existing_app_replacement_held:verified_recovery_baseline_and_driver_required")
        require(not attempt.exists(), "previous_install_requires_readback_no_automatic_retry")
        permitted = validate_lease(args.lease, args.device, native.clock)
        require(permitted["install"] and permitted["launch"], "device_lease_install_and_launch_required")
        previous = read_json(output.parent / "last-good.json") if (output.parent / "last-good.json").exists() else None
        if previous:
            verify_evidence(previous)
        atomic_json(attempt, {"schema": "ccr.vision.install-attempt/v1", **source.fields(),
                             "status": "uncertain", "previousGood": previous, "previousObservedApp": app,
                             "previousObservedRuntime": prior_file,
                             "rollback": "no-previous-runtime-no-restore-claimed", "observedAt": now().isoformat()})
        native.call(["install", "app", built["path"]], "install")
    permitted = validate_lease(args.lease, args.device, native.clock)
    if permitted["launch"]:
        native.call(["process", "launch", "--environment-variables", "{}", BUNDLE], "launch")
    observation = observe(native, source, built)
    require(source_identity(args, runner) == source, "source_changed_during_deploy")
    raw = {"schema": "ccr.vision.deployment/v1", "status": "applied" if install else "unchanged",
           **source.fields(), "projectId": args.project_id, "environment": args.environment,
           "deviceId": UDID, "coreDeviceId": CORE_DEVICE, "ownerThread": OWNER,
           "runtimeId": observation["runtimeId"], "nativeReadback": observation,
           "nativeEvidence": native.receipts, "preparedEvidence": evidence(output / "prepare.json"),
           "observedAt": now().isoformat(), "rollback": "no-existing-runtime-replaced",
           "productionEnabled": False, "receiptPath": str(native.directory / "deployment.json")}
    atomic_json(native.directory / "deployment.json", raw)
    atomic_json(output / "deployment.json", raw)
    atomic_json(output.parent / "last-good.json", evidence(native.directory / "deployment.json"))
    if attempt.exists():
        record = read_json(attempt)
        record.update(status="source-readback-verified", deployment=evidence(native.directory / "deployment.json"))
        atomic_json(attempt, record)
    return raw


def validate_deployment(raw, source, args, built):
    require(raw.get("schema") == "ccr.vision.deployment/v1" and
            raw.get("status") in ("applied", "unchanged"), "deployment_not_verified")
    require(source.matches(raw), "deployment_source_mismatch")
    require(raw.get("deviceId") == UDID and raw.get("coreDeviceId") == CORE_DEVICE and
            raw.get("ownerThread") == OWNER, "deployment_target_mismatch")
    require(raw.get("projectId") == args.project_id and raw.get("environment") == args.environment,
            "deployment_environment_mismatch")
    verify_evidence(raw.get("preparedEvidence"))
    rows = raw.get("nativeEvidence")
    require(isinstance(rows, list) and len(rows) >= 4, "deployment_native_evidence_missing")
    for row in rows:
        native = read_json(verify_evidence(row)["path"])
        info = native.get("info")
        require(isinstance(info, dict) and info.get("outcome") == "success", "deployment_native_outcome_invalid")
    readback = raw.get("nativeReadback") or {}
    require(isinstance(readback, dict), "deployment_readback_invalid")
    runtime = read_json(verify_evidence(readback.get("runtimeEvidence"))["path"])
    require(runtime == readback.get("runtime"), "deployment_runtime_tampered")
    runtime_id = runtime_identity(runtime, source, built, fresh=False)
    require(runtime_id == raw.get("runtimeId") == readback.get("runtimeId"), "deployment_runtime_mismatch")
    return readback


def validate_acceptance(raw, source, args, deployed):
    require(raw.get("schema") == "bt.test-acceptance/v1", "acceptance_schema_invalid")
    require(source.matches(raw), "acceptance_source_mismatch")
    require(raw.get("projectId") == args.project_id, "acceptance_project_mismatch")
    require(raw.get("runtimeId") == deployed["runtimeId"], "acceptance_runtime_mismatch")
    require(raw.get("environment") == args.environment == deployed["environment"], "acceptance_environment_mismatch")
    require(raw.get("externalEffects") == "zero", "external_effects_not_zero")
    isolation = raw.get("isolation")
    require(isinstance(isolation, dict) and all(isinstance(isolation.get(k), str) and isolation[k].strip()
            for k in ("dbIdentity", "storageIdentity", "providerMode")), "acceptance_isolation_missing")
    reset = raw.get("fixtureReset")
    require(isinstance(reset, dict) and reset.get("status") == "pass", "fixture_reset_not_passed")
    checks = raw.get("checks")
    require(isinstance(checks, dict), "acceptance_checks_missing")
    for name in CHECKS:
        check = checks.get(name)
        require(isinstance(check, dict), "missing-check:" + name)
        require(check.get("status") == "pass", "check-not-pass:" + name)
        rows = check.get("evidence")
        require(isinstance(rows, list) and rows, "missing-check-evidence:" + name)
        for row in rows:
            verify_evidence(row)
    native_file = deployed["nativeReadback"]["runtimeEvidence"]
    require(native_file in checks["runtime-source-readback"]["evidence"], "native_runtime_evidence_not_linked")


def accept(args, source, runner, output, native):
    require(args.acceptance_evidence is not None, "acceptance_evidence_missing")
    built = prepared(args, source, runner, output)["built"]
    deployed = read_json(output / "deployment.json")
    validate_deployment(deployed, source, args, built)
    raw = read_json(args.acceptance_evidence)
    validate_acceptance(raw, source, args, deployed)
    native.unlocked()
    live = observe(native, source, built)
    require(live["runtimeId"] == deployed["runtimeId"], "acceptance_live_runtime_changed")
    require(source_identity(args, runner) == source, "source_changed_during_acceptance")
    verified = {"schema": "ccr.vision.acceptance-validation/v1", **source.fields(),
                "runtimeId": live["runtimeId"], "nativeReadback": live, "nativeEvidence": native.receipts,
                "acceptanceEvidence": evidence(args.acceptance_evidence), "observedAt": now().isoformat()}
    validation_path = native.directory / "acceptance-validation.json"
    atomic_json(validation_path, verified)
    return {"status": "accepted", **source.fields(), "runtimeId": live["runtimeId"],
            "environment": args.environment, "evidence": str(safe_path(args.acceptance_evidence)),
            "validationEvidence": evidence(validation_path), "productionEnabled": False}


def parser():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("action", choices=("prepare", "deploy", "accept", "production", "upload"))
    cli.add_argument("--repo", required=True)
    cli.add_argument("--remote", required=True)
    cli.add_argument("--ref", required=True)
    cli.add_argument("--commit", help="Optional exact source pin, paired with --tree")
    cli.add_argument("--tree")
    cli.add_argument("--build-number", type=int, help="Developer build >=22; default complete Git revision count +1000")
    cli.add_argument("--output", required=True, help="Absolute storage-route development-archive output directory")
    cli.add_argument("--project-id", default="ccr-vision")
    cli.add_argument("--environment", default="vision-device-test")
    cli.add_argument("--device", default=CORE_DEVICE, choices=(CORE_DEVICE, UDID))
    cli.add_argument("--lease")
    cli.add_argument("--acceptance-evidence")
    cli.add_argument("--budget-seconds", type=float, default=600)
    return cli


def execute(args, runner):
    require(args.action not in ("production", "upload"), "production_and_store_upload_disabled")
    if args.action != "prepare":
        validate_lease(args.lease, args.device)
    source = source_identity(args, runner)
    base = safe_path(args.output)
    routed = json.loads(runner.run([ROUTER, "path", "development-archive", "--project", "CCR-Vision",
                                    "--filename", base.name])[0])
    require(routed.get("path") == str(base), "output_not_storage_routed")
    marker = {"schema": "ccr.vision.output/v1", "repo": args.repo, "ownerThread": OWNER,
              "remote": args.remote, "ref": args.ref, "projectId": args.project_id, "environment": args.environment}
    if not base.exists():
        base.mkdir(mode=0o700)
    if not (base / "owner.json").exists():
        require(not any(base.iterdir()), "nonempty_output_unowned")
        atomic_json(base / "owner.json", marker)
    require(read_json(base / "owner.json") == marker, "output_owner_mismatch")
    with safe_path(base / ".adapter.lock").open("a") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise Held("adapter_output_in_use") from error
        output = safe_path(base / (source.commit + "-" + source.tree + "-" + UDID))
        revision_marker = {**marker, **source.fields(), "deviceId": UDID}
        if not output.exists():
            output.mkdir(mode=0o700)
            atomic_json(output / "owner.json", revision_marker)
        require(read_json(output / "owner.json") == revision_marker, "output_revision_mismatch")
        directory = Path(tempfile.mkdtemp(prefix=args.action + "-", dir=output))
        try:
            if args.action == "prepare":
                result = {"status": "prepared", **prepare(args, source, runner, output),
                          "evidence": str(output / "prepare.json"), "productionEnabled": False}
            else:
                native = Native(args, runner, directory)
                action = deploy if args.action == "deploy" else accept
                result = action(args, source, runner, output, native)
            require(source_identity(args, runner) == source, "source_changed_during_action")
        except (Held, OSError, ValueError, TypeError, KeyError) as error:
            atomic_json(directory / "result.json", {"status": "held", "reason": str(error), **source.fields()})
            raise
        atomic_json(directory / "result.json", result)
        return result


def main():
    args = parser().parse_args()
    try:
        result = execute(args, Runner(args.budget_seconds))
    except (Held, OSError, ValueError, TypeError, KeyError, plistlib.InvalidFileException) as error:
        print(json.dumps({"status": "held", "reason": str(error), "productionEnabled": False}))
        return 2
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
