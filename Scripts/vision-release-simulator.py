#!/usr/bin/env python3
"""Isolated native SwiftUI release checks on the registered xrOS 27 simulator."""

import argparse
import fcntl
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import sys
import uuid

spec = importlib.util.spec_from_file_location("vision_physical_adapter", Path(__file__).with_name("vision-release-adapter.py"))
physical = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = physical
spec.loader.exec_module(physical)
Held, require = physical.Held, physical.require
safe_path, read_json, atomic_json = physical.safe_path, physical.read_json, physical.atomic_json
evidence, digest = physical.evidence, physical.digest
OWNER = physical.OWNER
UDID = "D354C526-248E-4C2E-A761-A2505C11F1DC"
SERVICE = "ccr-vision-xros27-d354"
BUNDLE = "dev.ambrion.SillVision.ReleaseTest"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.xrOS-27-0"
LIFECYCLE = str(Path.home() / ".local/bin/bt-service-lifecycle")
LEASES = Path.home() / ".local/state/service-lifecycle/leases"
REGISTRY = Path.home() / ".config/service-lifecycle/services.json"
SCHEME = "SillVisionReleaseTest"
TEST = "VisionReleaseSimulatorUITests/testWorkspaceFixture()"
SIM_CHECKS = ("runtime-source-readback", "readiness", "native-text-draft-ui",
              "isolated-text-provider", "fixture-reset", "external-effects-zero")


def validate_lease(lease_id, source, runner, clock=physical.now):
    require(isinstance(lease_id, str) and str(uuid.UUID(lease_id)) == lease_id, "canonical_lease_id_required")
    row = read_json(LEASES / (lease_id + ".json"))
    expected = {"schema": 1, "leaseId": lease_id, "serviceId": SERVICE, "owner": OWNER,
                "generation": source.commit, "managedBy": "bt-service-lifecycle",
                "resourceKind": "core-simulator", "simulatorUdid": UDID, "simulatorRuntime": RUNTIME}
    require(all(row.get(k) == v for k, v in expected.items()), "canonical_lease_identity_mismatch")
    require(physical.timestamp(row.get("startedAt")) <= clock() < physical.timestamp(row.get("expiresAt")),
            "canonical_lease_expired_or_future")
    services = read_json(REGISTRY).get("services", [])
    require(isinstance(services, list) and all(isinstance(s, dict) for s in services),
            "registered_services_invalid")
    configured = [s for s in services if s.get("id") == SERVICE]
    require(len(configured) == 1 and configured[0].get("lifecycle") == "leased" and
            configured[0].get("resource") == {"kind": "core-simulator", "udid": UDID}, "registered_service_mismatch")
    status = json.loads(runner.run([LIFECYCLE, "status"], accepted_return_codes=(0, 2))[0])
    require(isinstance(status, dict) and status.get("schema") == 1 and all(isinstance(status.get(k), list) and
            all(isinstance(v, dict) for v in status[k]) for k in ("leases", "violations")),
            "lifecycle_status_invalid")
    live = [r for r in status.get("leases", []) if r.get("leaseId") == lease_id]
    require(len(live) == 1 and all(live[0].get(k) == v for k, v in row.items()) and
            live[0].get("state") == "live" and live[0].get("live") is True and live[0].get("expired") is False,
            "canonical_lease_not_live")
    group = configured[0].get("singletonGroup")
    require(isinstance(group, str) and bool(group), "registered_singleton_group_missing")
    related_services = {s.get("id") for s in services if s.get("singletonGroup") == group or
                        s.get("resource") == {"kind": "core-simulator", "udid": UDID}}
    related_leases = {r.get("leaseId") for r in status["leases"] if r.get("serviceId") in related_services}
    require(all("services" not in v or (isinstance(v["services"], list) and
                all(isinstance(s, str) for s in v["services"])) for v in status["violations"]),
            "lifecycle_status_invalid")
    require(not any(v.get("serviceId") in related_services or v.get("leaseId") in related_leases or
                    v.get("singletonGroup") == group or v.get("group") == group or
                    related_services.intersection(v.get("services", []))
                    for v in status["violations"]), "lifecycle_violation")
    require(not any(r.get("leaseId") != lease_id and r.get("serviceId") in related_services and
                    r.get("live") is True for r in status["leases"]), "conflicting_simulator_lease")
    return row


def bundle_manifest(path, source, runner):
    path = safe_path(path)
    info = plistlib.loads((path / "Info.plist").read_bytes())
    require(info.get("CFBundleIdentifier") == BUNDLE and info.get("DTPlatformName") == "xrsimulator",
            "test_simulator_bundle_required")
    require(info.get("BTSourceCommit") == source.commit and info.get("BTSourceTree") == source.tree,
            "built_source_mismatch")
    executable = info.get("CFBundleExecutable")
    require(isinstance(executable, str) and executable and Path(executable).name == executable,
            "built_executable_invalid")
    require(isinstance(info.get("CFBundleVersion"), str), "built_version_missing")
    runner.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", path])
    files = {}
    for item in sorted(path.rglob("*")):
        require(not item.is_symlink(), "bundle_symlink_refused")
        if item.is_file():
            files[str(item.relative_to(path))] = digest(item)
    return {"build": info["CFBundleVersion"], "executable": executable, "files": files,
            "executableSHA256": files[executable], "infoPlistSHA256": files["Info.plist"],
            "codeResourcesSHA256": files["_CodeSignature/CodeResources"]}


class Simulator:
    def __init__(self, args, source, runner, directory):
        self.args, self.source, self.runner, self.directory = args, source, runner, directory
        self.commands = []

    def run(self, command):
        lease = validate_lease(self.args.lease_id, self.source, self.runner)
        require((physical.timestamp(lease["expiresAt"]) - physical.now()).total_seconds() >
                self.args.native_budget_seconds, "lease_renewal_required_before_native_command")
        child = physical.Runner(self.args.native_budget_seconds)
        result = child.run(command)
        row = {"command": [str(x) for x in command], "stdout": result[0], "stderr": result[1]}
        path = self.directory / ("native-" + str(len(self.commands)) + ".json")
        atomic_json(path, row)
        self.commands.append(evidence(path))
        return result[0].strip()

    def simctl(self, *words):
        return self.run(["/usr/bin/xcrun", "simctl", *words])

    def ready(self):
        raw = json.loads(self.simctl("list", "devices", "--json"))
        rows = [d for d in raw.get("devices", {}).get(RUNTIME, []) if d.get("udid") == UDID]
        require(len(rows) == 1 and rows[0].get("state") == "Booted" and rows[0].get("isAvailable") is True,
                "registered_xros27_not_booted")

    def container(self, kind):
        return safe_path(self.simctl("get_app_container", UDID, BUNDLE, kind))

    def observe(self, built):
        self.ready()
        app, data = self.container("app"), self.container("data")
        require(bundle_manifest(app, self.source, self.runner) == built, "installed_bundle_bytes_mismatch")
        validate_lease(self.args.lease_id, self.source, self.runner)
        path = data / physical.RUNTIME_FILE
        raw = read_json(path)
        require(raw.get("schema") == "ccr.vision.runtime/v1" and self.source.matches(raw) and
                raw.get("bundleId") == BUNDLE and raw.get("build") == built["build"], "runtime_identity_mismatch")
        for key in ("executableSHA256", "infoPlistSHA256", "codeResourcesSHA256"):
            require(raw.get(key) == built[key], "runtime_bytes_mismatch:" + key)
        require(type(raw.get("pid")) is int and raw["pid"] > 0, "runtime_pid_invalid")
        require(str(uuid.UUID(raw.get("bootUUID", ""))) == raw["bootUUID"].lower(), "runtime_boot_invalid")
        age = (physical.now() - physical.timestamp(raw.get("observedAt"))).total_seconds()
        require(-5 <= age <= physical.FRESH_SECONDS, "runtime_stale_or_future")
        command = self.run(["/bin/ps", "-p", str(raw["pid"]), "-o", "comm="])
        require(command == str(app / built["executable"]), "runtime_process_not_installed_executable")
        identity = [UDID, self.source.commit, self.source.tree, raw["bootUUID"]]
        runtime_id = "ccr-vision-simulator:" + hashlib.sha256(json.dumps(identity).encode()).hexdigest()
        copied = self.directory / "actual-runtime.json"
        atomic_json(copied, raw)
        return {"runtimeId": runtime_id, "runtime": raw, "runtimeEvidence": evidence(copied),
                "container": str(data), "app": str(app)}


def prepare(args, source, runner, output):
    manifest = output / "prepare.json"
    app = output / "DerivedData/Build/Products/Debug-xrsimulator/SillVisionReleaseTest.app"
    if not manifest.exists():
        require(not (output / "DerivedData").exists(), "incomplete_build_requires_review")
        runner.run(["/usr/bin/xcrun", "xcodebuild", "-project", str(Path(args.repo) / "SillVision.xcodeproj"),
                    "-scheme", SCHEME, "-configuration", "Debug", "-sdk", "xrsimulator",
                    "-destination", "generic/platform=visionOS Simulator", "-derivedDataPath", output / "DerivedData",
                    "-resultBundlePath", output / "NativeBuild.xcresult",
                    "-disableAutomaticPackageResolution", "-skipPackageUpdates", "CODE_SIGN_IDENTITY=-",
                    "CODE_SIGNING_ALLOWED=YES", "DEVELOPMENT_TEAM=" + physical.TEAM,
                    "BT_RELEASE_SOURCE_COMMIT=" + source.commit, "BT_RELEASE_SOURCE_TREE=" + source.tree,
                    "build-for-testing"], cwd=args.repo)
        built = bundle_manifest(app, source, runner)
        runs = list((output / "DerivedData/Build/Products").glob("*.xctestrun"))
        require(len(runs) == 1, "native_ui_test_driver_missing_or_ambiguous")
        raw = {"schema": "ccr.vision.simulator-prepared/v1", **source.fields(), "built": built,
               "app": str(app), "xctestrun": evidence(runs[0]),
               "nativeBuildResultBundle": str(output / "NativeBuild.xcresult")}
        atomic_json(manifest, raw)
    raw = read_json(manifest)
    require(raw.get("schema") == "ccr.vision.simulator-prepared/v1" and source.matches(raw), "prepared_source_mismatch")
    require(raw.get("app") == str(app) and bundle_manifest(app, source, runner) == raw.get("built"), "prepared_bundle_changed")
    physical.verify_evidence(raw.get("xctestrun"))
    return raw


def deploy(args, source, runner, output, native):
    prepared = prepare(args, source, runner, output)
    native.ready()
    inventory = native.simctl("listapps", UDID)
    try:
        installed = json.loads(inventory)
    except ValueError:
        path = native.directory / "installed-apps.plist"
        path.write_text(inventory)
        installed = json.loads(runner.run(["/usr/bin/plutil", "-convert", "json", "-o", "-", path])[0])
    require(isinstance(installed, dict), "installed_apps_shape_unsupported")
    previous = installed.get(BUNDLE)
    intent = output / "install-intent.json"
    if previous is not None:
        require(bundle_manifest(native.container("app"), source, runner) == prepared["built"],
                "existing_test_bundle_replacement_held:parent_recovery_required")
    else:
        require(not intent.exists(), "uncertain_install_requires_readback")
        atomic_json(intent, {**source.fields(), "bundleId": BUNDLE, "status": "uncertain"})
        native.simctl("install", UDID, prepared["app"])
    context = {**source.fields(), "runID": str(uuid.uuid4())}
    native.simctl("launch", UDID, BUNDLE, "--ccr-release-context", json.dumps(context))
    observation = native.observe(prepared["built"])
    if intent.exists():
        atomic_json(intent, {**read_json(intent), "status": "source-readback-verified",
                             "runtimeEvidence": observation["runtimeEvidence"]})
    raw = {"schema": "ccr.vision.simulator-deployed/v1", **source.fields(), "bundleId": BUNDLE,
           "preparedEvidence": evidence(output / "prepare.json"), "leaseId": args.lease_id,
           "runtimeReadback": observation, "runtimeId": observation["runtimeId"],
           "nativeEvidence": native.commands, "runtimeAccepted": False, "productionEnabled": False}
    atomic_json(output / "deployment.json", raw)
    return raw


def test_run_file(prepared, destination, context):
    path = physical.verify_evidence(prepared["xctestrun"])["path"]
    run = plistlib.loads(Path(path).read_bytes())
    configs = run.get("TestConfigurations", [])
    require(len(configs) == 1, "native_ui_test_configuration_unsupported")
    targets = configs[0].get("TestTargets", [])
    require(len(targets) == 1 and targets[0].get("BlueprintName") == "VisionReleaseSimulatorUITests",
            "native_ui_test_driver_unsupported")
    target = targets[0]
    require(target.get("IsUITestBundle") is True, "actual_ui_test_bundle_required")
    target["EnvironmentVariables"] = {**target.get("EnvironmentVariables", {}),
                                      "CCR_VISION_RELEASE_CONTEXT": json.dumps(context)}
    # __TESTROOT__ must keep referring to the original built Products directory.
    def relocate(value):
        if isinstance(value, str):
            return value.replace("__TESTROOT__", str(Path(path).parent))
        if isinstance(value, list):
            return [relocate(x) for x in value]
        if isinstance(value, dict):
            return {k: relocate(v) for k, v in value.items()}
        return value
    run = relocate(run)
    actual = run["TestConfigurations"][0]["TestTargets"][0]
    require(actual.get("UITargetAppPath") == prepared["app"], "ui_driver_target_app_mismatch")
    destination.write_bytes(plistlib.dumps(run))


def validate_results(summary, tests):
    require(summary.get("result") == "Passed" and summary.get("passedTests") == 1 and
            summary.get("failedTests") == 0 and summary.get("skippedTests") == 0, "native_ui_tests_not_passed")
    def leaves(node):
        if isinstance(node, dict):
            yield node
            for value in node.values():
                yield from leaves(value)
        elif isinstance(node, list):
            for value in node:
                yield from leaves(value)
    matches = [n for n in leaves(tests) if n.get("nodeType") == "Test Case" and
               n.get("name") == "testWorkspaceFixture()" and n.get("result") == "Passed"]
    require(len(matches) == 1, "representative_actual_swiftui_test_missing")


def validate_fixture(raw, source, context, observation):
    require(raw.get("schema") == "ccr.vision.simulator-fixture/v1" and source.matches(raw), "fixture_source_mismatch")
    require(raw.get("runID") == context["runID"] and raw.get("bootUUID") == observation["runtime"]["bootUUID"] and
            raw.get("bundleId") == BUNDLE, "fixture_runtime_mismatch")
    require(raw.get("storageIdentity") == str(Path(observation["container"]) / "Documents/CCRReleaseFixture"),
            "fixture_not_private_test_container")
    require(raw.get("events") == ["written", "read-verified", "reset-verified"] and
            raw.get("fixtureAbsent") is True, "fixture_write_read_reset_not_verified")
    require(raw.get("providerMode") == "deterministic-stub" and raw.get("externalEffects") == "zero",
            "isolated_provider_required")
    require(raw.get("sessionIsolated") is True, "session_not_isolated")


def accept(args, source, runner, output, native):
    prepared = prepare(args, source, runner, output)
    deployed = read_json(output / "deployment.json")
    require(deployed.get("schema") == "ccr.vision.simulator-deployed/v1" and source.matches(deployed) and
            deployed.get("bundleId") == BUNDLE, "simulator_deployment_required")
    physical.verify_evidence(deployed.get("preparedEvidence"))
    native.ready()
    require(bundle_manifest(native.container("app"), source, runner) == prepared["built"],
            "existing_test_bundle_replacement_held:parent_recovery_required")
    context = {**source.fields(), "runID": str(uuid.uuid4())}
    run = native.directory / "NativeUI.xctestrun"
    test_run_file(prepared, run, context)
    result = native.directory / "NativeUI.xcresult"
    native.run(["/usr/bin/xcrun", "xcodebuild", "test-without-building", "-xctestrun", run,
                "-destination", "platform=visionOS Simulator,id=" + UDID,
                "-resultBundlePath", result, "-parallel-testing-enabled", "NO",
                "-maximum-concurrent-test-simulator-destinations", "1", "-disable-concurrent-destination-testing",
                "-only-testing:VisionReleaseSimulatorUITests/VisionReleaseSimulatorUITests/testWorkspaceFixture"])
    reports = {}
    for kind in ("summary", "tests"):
        raw = json.loads(runner.run(["/usr/bin/xcrun", "xcresulttool", "get", "test-results", kind,
                                     "--path", result, "--format", "json"])[0])
        path = native.directory / (kind + ".json")
        atomic_json(path, raw)
        reports[kind] = raw
    validate_results(reports["summary"], reports["tests"])
    observation = native.observe(prepared["built"])
    validate_lease(args.lease_id, source, runner)
    fixture_path = Path(observation["container"]) / "Documents/CCRReleaseFixture/receipt.json"
    fixture = read_json(fixture_path)
    validate_fixture(fixture, source, context, observation)
    require(not (fixture_path.parent / "draft.json").exists(), "fixture_reset_readback_failed")
    atomic_json(native.directory / "actual-fixture.json", fixture)
    rows = [observation["runtimeEvidence"], evidence(native.directory / "actual-fixture.json"),
            evidence(native.directory / "summary.json"), evidence(native.directory / "tests.json")]
    return {"schema": "ccr.vision.simulator-diagnostic/v1", "status": "diagnostic-verified", **source.fields(),
            "releaseStatus": "held:full-remote-driver-missing",
            "profile": "isolated-native-text-draft-simulator", "deviceId": UDID, "bundleId": BUNDLE,
            "ownerThread": OWNER, "leaseId": args.lease_id, "runtimeId": observation["runtimeId"],
            "runtimeAccepted": True, "uiAccepted": True, "wholeProductTestAccepted": False,
            "productionEnabled": False, "externalEffects": "zero", "providerMode": "deterministic-stub",
            "checks": {name: {"status": "pass", "evidence": rows} for name in SIM_CHECKS},
            "physicalRequiredChecks": list(physical.CHECKS),
            "unverified": ["modern-display-picker", "multiwindow-admission", "video-stream",
                           "physical-gaze", "physical-audio", "HAL", "sentry", "full-remote-acceptance"],
            "nativeEvidence": native.commands, "resultBundle": str(result)}


def execute(args, runner):
    require(args.action in ("prepare", "deploy", "accept"), "production_and_store_disabled")
    require(args.device == UDID, "only_registered_simulator_permitted")
    source = physical.source_identity(args, runner)
    if args.action != "prepare":
        validate_lease(args.lease_id, source, runner)
    base = safe_path(args.output)
    route = [physical.ROUTER, "path", "development-archive", "--project", "CCR-Vision"]
    if not base.exists():
        route += ["--filename", base.name]
    routed = json.loads(runner.run(route)[0])
    require(routed.get("path") == str(base.parent if base.exists() else base), "output_not_storage_routed")
    marker = {"schema": "ccr.vision.simulator-output/v1", "repo": args.repo, "ownerThread": OWNER,
              "remote": args.remote, "ref": args.ref, "deviceId": UDID, "bundleId": BUNDLE}
    if not base.exists():
        base.mkdir(mode=0o700)
    if not (base / "owner.json").exists():
        require(not any(base.iterdir()), "output_unowned")
        atomic_json(base / "owner.json", marker)
    require(read_json(base / "owner.json") == marker, "output_owner_mismatch")
    with (base / ".simulator.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise Held("simulator_output_in_use") from error
        output = base / (source.commit + "-" + source.tree)
        output.mkdir(mode=0o700, exist_ok=True)
        directory = output / (args.action + "-" + str(uuid.uuid4()))
        directory.mkdir(mode=0o700)
        try:
            if args.action == "prepare":
                result = {"status": "prepared", **prepare(args, source, runner, output), "productionEnabled": False}
            else:
                result = (deploy if args.action == "deploy" else accept)(args, source, runner, output,
                                                                          Simulator(args, source, runner, directory))
            require(physical.source_identity(args, runner) == source, "source_changed_during_action")
        except (Held, OSError, ValueError, TypeError, KeyError) as error:
            atomic_json(directory / "result.json", {"status": "held", "reason": str(error),
                                                   **source.fields(), "productionEnabled": False,
                                                   "nativeBuildResultBundle": str(output / "NativeBuild.xcresult"),
                                                   "nativeBuildResultBundleExists": (output / "NativeBuild.xcresult").exists()})
            raise
        atomic_json(directory / "result.json", result)
        return result


def parser():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("action", choices=("prepare", "deploy", "accept", "production", "upload"))
    for flag in ("repo", "remote", "ref", "output"):
        cli.add_argument("--" + flag, required=True)
    cli.add_argument("--commit")
    cli.add_argument("--tree")
    cli.add_argument("--device", default=UDID)
    cli.add_argument("--lease-id")
    cli.add_argument("--budget-seconds", type=float, default=600)
    cli.add_argument("--native-budget-seconds", type=float, default=120)
    return cli


def main():
    args = parser().parse_args()
    try:
        require(0 < args.native_budget_seconds <= 600, "native_budget_invalid")
        result = execute(args, physical.Runner(args.budget_seconds))
    except (Held, OSError, ValueError, TypeError, KeyError, plistlib.InvalidFileException) as error:
        print(json.dumps({"status": "held", "reason": str(error), "productionEnabled": False}))
        return 2
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
