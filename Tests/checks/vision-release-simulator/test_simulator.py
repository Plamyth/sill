#!/usr/bin/env python3
"""Deterministic adapter boundary tests. Never invokes an SDK or simulator."""

import datetime as dt
import importlib.util
import json
from pathlib import Path
import plistlib
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("vision_simulator", ROOT / "Scripts/vision-release-simulator.py")
sim = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = sim
spec.loader.exec_module(sim)
SOURCE = sim.physical.Source("a" * 40, "b" * 40)
LEASE_ID = "00000000-0000-4000-8000-000000000001"
BOOT_ID = "00000000-0000-4000-8000-000000000002"


class Runner:
    def __init__(self, output="", exit_code=0):
        self.output, self.calls, self.exit_code = output, [], exit_code

    def run(self, command, cwd=None, accepted_return_codes=(0,)):
        self.calls.append([str(x) for x in command])
        sim.require(self.exit_code in accepted_return_codes, "command_failed:fixture:" + str(self.exit_code))
        return self.output, ""


class BoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.leases = self.root / "leases"
        self.leases.mkdir()
        self.registry = self.root / "services.json"
        sim.atomic_json(self.registry, {"services": [{"id": sim.SERVICE, "lifecycle": "leased",
            "singletonGroup": "vision-simulator",
            "resource": {"kind": "core-simulator", "udid": sim.UDID}}]})
        self.row = {"schema": 1, "leaseId": LEASE_ID, "serviceId": sim.SERVICE, "owner": sim.OWNER,
                    "generation": SOURCE.commit, "managedBy": "bt-service-lifecycle", "resourceKind": "core-simulator",
                    "simulatorUdid": sim.UDID, "simulatorRuntime": sim.RUNTIME, "simulatorName": "fixture",
                    "startedAt": (sim.physical.now() - dt.timedelta(seconds=5)).isoformat(),
                    "expiresAt": (sim.physical.now() + dt.timedelta(seconds=1800)).isoformat()}
        sim.atomic_json(self.leases / (LEASE_ID + ".json"), self.row)
        for name, value in (("LEASES", self.leases), ("REGISTRY", self.registry)):
            p = patch.object(sim, name, value)
            p.start()
            self.addCleanup(p.stop)
        self.args = SimpleNamespace(lease_id=LEASE_ID, native_budget_seconds=1)

    def status_runner(self, **updates):
        return Runner(json.dumps({"schema": 1, "leases": [{**self.row, "state": "live", "live": True,
                                                "expired": False, **updates}], "violations": []}))

    def bundle(self):
        app = self.root / "Test.app"
        app.mkdir()
        (app / "_CodeSignature").mkdir()
        (app / "_CodeSignature/CodeResources").write_bytes(b"signed resources")
        (app / "Test").write_bytes(b"actual executable fixture")
        info = {"CFBundleIdentifier": sim.BUNDLE, "DTPlatformName": "xrsimulator",
                "CFBundleExecutable": "Test", "CFBundleVersion": "14",
                "BTSourceCommit": SOURCE.commit, "BTSourceTree": SOURCE.tree}
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        return app

    def observation(self):
        return {"container": str(self.root / "private-test-container"), "runtime": {"bootUUID": BOOT_ID}}

    def fixture(self):
        return {"schema": "ccr.vision.simulator-fixture/v1", **SOURCE.fields(), "runID": LEASE_ID,
                "bootUUID": BOOT_ID, "bundleId": sim.BUNDLE,
                "storageIdentity": str(Path(self.observation()["container"]) / "Documents/CCRReleaseFixture"),
                "providerMode": "deterministic-stub", "externalEffects": "zero",
                "sessionIsolated": True,
                "events": ["written", "read-verified", "reset-verified"], "fixtureAbsent": True}

    def test_live_canonical_lease(self):
        runner = self.status_runner()
        self.assertEqual(sim.validate_lease(LEASE_ID, SOURCE, runner), self.row)
        self.assertEqual(runner.calls, [[sim.LIFECYCLE, "status"]])

    def test_registered_guest_route_preserves_exact_simulator_identity(self):
        registry = sim.read_json(self.registry)
        registry["services"][0]["resource"]["guestOutputRoute"] = {
            "outputDeviceUid": "BuiltInSpeakerDevice", "files": ["var/run/com.apple.coresimulator.audio.plist"]}
        sim.atomic_json(self.registry, registry)
        self.assertEqual(sim.validate_lease(LEASE_ID, SOURCE, self.status_runner()), self.row)
        registry["services"][0]["resource"]["udid"] = BOOT_ID
        sim.atomic_json(self.registry, registry)
        with self.assertRaises(sim.Held):
            sim.validate_lease(LEASE_ID, SOURCE, self.status_runner())

    def test_status_exit_two_keeps_unrelated_violations_separate(self):
        status = json.loads(self.status_runner().output)
        other = {**status["leases"][0], "leaseId": BOOT_ID, "serviceId": "other-project",
                 "live": False, "expired": True}
        status["leases"].append(other)
        status["violations"] = [{"type": "expired_lease", "leaseId": BOOT_ID}]
        self.assertEqual(sim.validate_lease(LEASE_ID, SOURCE, Runner(json.dumps(status), 2)), self.row)
        with self.assertRaisesRegex(sim.Held, "command_failed"):
            sim.validate_lease(LEASE_ID, SOURCE, Runner(json.dumps(status), 3))

    def test_same_singleton_violations_and_concurrent_owner_are_held(self):
        registry = sim.read_json(self.registry)
        registry["services"].append({"id": "same-group", "singletonGroup": "vision-simulator"})
        sim.atomic_json(self.registry, registry)
        status = json.loads(self.status_runner().output)
        status["leases"].append({**status["leases"][0], "leaseId": BOOT_ID, "serviceId": "same-group"})
        with self.assertRaisesRegex(sim.Held, "conflicting_simulator_lease"):
            sim.validate_lease(LEASE_ID, SOURCE, Runner(json.dumps(status)))
        status["leases"][-1].update(live=False, expired=True)
        status["violations"] = [{"type": "expired_lease", "leaseId": BOOT_ID}]
        with self.assertRaisesRegex(sim.Held, "lifecycle_violation"):
            sim.validate_lease(LEASE_ID, SOURCE, Runner(json.dumps(status), 2))

    def test_explicit_return_codes_do_not_change_runner_default(self):
        command = [sys.executable, "-B", "-c", "print('status-json'); raise SystemExit(2)"]
        runner = sim.physical.Runner(10)
        self.assertEqual(runner.run(command, accepted_return_codes=(0, 2))[0].strip(), "status-json")
        with self.assertRaisesRegex(sim.Held, "command_failed"):
            runner.run(command)

    def test_canonical_singleton_conflict_shape_is_held(self):
        status = json.loads(self.status_runner().output)
        for violation in (
            {"type": "singleton_conflict", "group": "vision-simulator", "services": [sim.SERVICE, "same-group"]},
            {"type": "singleton_conflict", "group": "another-group", "services": [sim.SERVICE]},
        ):
            status["violations"] = [violation]
            with self.subTest(violation=violation), self.assertRaisesRegex(sim.Held, "lifecycle_violation"):
                sim.validate_lease(LEASE_ID, SOURCE, Runner(json.dumps(status), 2))

    def test_first_sdk_failure_retains_native_diagnostics_reference(self):
        args = SimpleNamespace(action="prepare", device=sim.UDID, repo=str(self.root),
                               remote="origin", ref="refs/heads/fixture", output=str(self.root / "output"))
        class FailedBuild:
            def run(inner, command, cwd=None):
                if str(command[0]) == sim.physical.ROUTER:
                    return json.dumps({"path": args.output}), ""
                self.assertIn("-resultBundlePath", command)
                result = Path(command[command.index("-resultBundlePath") + 1])
                result.mkdir()
                raise sim.Held("command_failed:xcrun:65")
        with patch.object(sim.physical, "source_identity", return_value=SOURCE):
            with self.assertRaisesRegex(sim.Held, "command_failed:xcrun:65"):
                sim.execute(args, FailedBuild())
        results = list(Path(args.output).glob("*/prepare-*/result.json"))
        self.assertEqual(len(results), 1)
        held = sim.read_json(results[0])
        self.assertTrue(held["nativeBuildResultBundleExists"])
        self.assertTrue(Path(held["nativeBuildResultBundle"]).is_dir())

    def test_changed_installed_bundle_is_held_before_mutating_ui_test(self):
        app = self.bundle()
        built = sim.bundle_manifest(app, SOURCE, Runner())
        marker = self.root / "prepare.json"
        sim.atomic_json(marker, {"prepared": True})
        sim.atomic_json(self.root / "deployment.json", {"schema": "ccr.vision.simulator-deployed/v1",
                        **SOURCE.fields(), "bundleId": sim.BUNDLE, "preparedEvidence": sim.evidence(marker)})
        (app / "Test").write_bytes(b"changed outside this deployment")
        native = SimpleNamespace(ready=lambda: None, container=lambda _: app)
        with patch.object(sim, "prepare", return_value={"built": built}):
            with self.assertRaisesRegex(sim.Held, "existing_test_bundle_replacement_held"):
                sim.accept(self.args, SOURCE, Runner(), self.root, native)

    def test_copied_json_does_not_authorize(self):
        sim.atomic_json(self.root / "copied.json", self.row)
        (self.leases / (LEASE_ID + ".json")).unlink()
        runner = self.status_runner()
        with self.assertRaises(OSError):
            sim.validate_lease(LEASE_ID, SOURCE, runner)
        self.assertEqual(runner.calls, [])

    def test_lease_boundary_rejection_before_status(self):
        for key, value in {"owner": "other", "generation": "c" * 40, "simulatorUdid": "another",
                           "serviceId": "other", "resourceKind": "phone", "managedBy": "copied",
                           "simulatorRuntime": "com.apple.CoreSimulator.SimRuntime.xrOS-26-0",
                           "expiresAt": "2000-01-01T00:00:00Z"}.items():
            with self.subTest(key=key):
                sim.atomic_json(self.leases / (LEASE_ID + ".json"), {**self.row, key: value})
                runner = self.status_runner()
                with self.assertRaises(sim.Held):
                    sim.validate_lease(LEASE_ID, SOURCE, runner)
                self.assertEqual(runner.calls, [])

    def test_status_must_agree_and_be_live(self):
        for changes in ({"live": False}, {"expired": True}, {"state": "unknown"}, {"generation": "c" * 40}):
            with self.subTest(changes=changes), self.assertRaises(sim.Held):
                sim.validate_lease(LEASE_ID, SOURCE, self.status_runner(**changes))

    def test_revocation_between_native_calls(self):
        runner = self.status_runner()
        native = sim.Simulator(self.args, SOURCE, runner, self.root)
        child = Runner("native result")
        with patch.object(sim.physical, "Runner", return_value=child):
            self.assertEqual(native.simctl("list", "devices", "--json"), "native result")
            (self.leases / (LEASE_ID + ".json")).unlink()
            with self.assertRaises(OSError):
                native.simctl("install", sim.UDID, "/does-not-run.app")
        self.assertEqual(len(child.calls), 1)

    def test_native_timeout_preserves_actual_partial_output_and_stays_held(self):
        native = sim.Simulator(self.args, SOURCE, self.status_runner(), self.root)
        command = [sys.executable, "-B", "-c",
                   "import os,time; os.write(1,b'native-start\\n'); "
                   "os.write(2,b'native-error\\xff\\n'); time.sleep(5)"]
        with self.assertRaisesRegex(sim.Held, "command_timeout"):
            native.run(command)
        self.assertEqual(len(native.commands), 1)
        row = sim.read_json(self.root / "native-0.json")
        self.assertEqual(row["command"], command)
        self.assertEqual(row["stdout"], "native-start\n")
        self.assertEqual(row["stderr"], "native-error\ufffd\n")
        self.assertTrue(row["timedOut"])
        self.assertGreater(row["timeoutSeconds"], 0)
        self.assertLessEqual(row["timeoutSeconds"], self.args.native_budget_seconds)
        self.assertTrue(row["reason"].startswith("command_timeout:"))
        self.assertEqual(sim.evidence(self.root / "native-0.json"), native.commands[0])

    def test_native_timeout_decodes_missing_or_text_output(self):
        for stdout, stderr in ((None, None), ("부분 출력", "오류 출력")):
            with self.subTest(stdout=stdout):
                native = sim.Simulator(self.args, SOURCE, self.status_runner(), self.root)

                class TimedOut:
                    def run(self, command):
                        cause = sim.physical.subprocess.TimeoutExpired(command, 1, output=stdout, stderr=stderr)
                        raise sim.Held("command_timeout:fixture") from cause

                with patch.object(sim.physical, "Runner", return_value=TimedOut()):
                    with self.assertRaisesRegex(sim.Held, "command_timeout:fixture"):
                        native.run(["fixture"])
                row = sim.read_json(self.root / "native-0.json")
                self.assertEqual(row["stdout"], stdout or "")
                self.assertEqual(row["stderr"], stderr or "")

    def test_other_native_refusal_does_not_create_timeout_evidence(self):
        native = sim.Simulator(self.args, SOURCE, self.status_runner(), self.root)
        with patch.object(sim.physical, "Runner", return_value=Runner(exit_code=65)):
            with self.assertRaisesRegex(sim.Held, "command_failed:fixture:65"):
                native.run(["fixture"])
        self.assertEqual(native.commands, [])
        self.assertFalse((self.root / "native-0.json").exists())

    def test_unregistered_service_rejected(self):
        sim.atomic_json(self.registry, {"services": []})
        with self.assertRaises(sim.Held):
            sim.validate_lease(LEASE_ID, SOURCE, self.status_runner())

    def test_original_bundle_and_device_are_refused(self):
        app = self.bundle()
        info = plistlib.loads((app / "Info.plist").read_bytes())
        for key, value in (("CFBundleIdentifier", sim.physical.BUNDLE), ("DTPlatformName", "xros"),
                           ("BTSourceCommit", "c" * 40), ("CFBundleExecutable", "../escape")):
            (app / "Info.plist").write_bytes(plistlib.dumps({**info, key: value}))
            runner = Runner()
            with self.subTest(key=key), self.assertRaises(sim.Held):
                sim.bundle_manifest(app, SOURCE, runner)
            self.assertEqual(runner.calls, [])

    def test_bundle_manifest_hashes_actual_bytes(self):
        app = self.bundle()
        before = sim.bundle_manifest(app, SOURCE, Runner())
        (app / "Test").write_bytes(b"changed")
        after = sim.bundle_manifest(app, SOURCE, Runner())
        self.assertNotEqual(before["executableSHA256"], after["executableSHA256"])
        self.assertEqual(before["infoPlistSHA256"], after["infoPlistSHA256"])

    def test_observe_requires_actual_runtime_bytes_and_live_executable(self):
        app = self.bundle()
        built = sim.bundle_manifest(app, SOURCE, Runner())
        data = self.root / "data"
        (data / "Documents").mkdir(parents=True)
        raw = {"schema": "ccr.vision.runtime/v1", **SOURCE.fields(), "bundleId": sim.BUNDLE,
               "build": built["build"], "pid": 1234, "bootUUID": BOOT_ID,
               "observedAt": sim.physical.now().isoformat(),
               **{k: built[k] for k in ("executableSHA256", "infoPlistSHA256", "codeResourcesSHA256")}}
        runtime_path = data / sim.physical.RUNTIME_FILE
        sim.atomic_json(runtime_path, raw)
        native = sim.Simulator(self.args, SOURCE, Runner(), self.root)
        with patch.object(sim, "validate_lease"), patch.object(native, "ready"), patch.object(native, "container", side_effect=lambda kind: app if kind == "app" else data), \
                patch.object(native, "run", return_value=str(app / "Test")):
            observation = native.observe(built)
            self.assertEqual(observation["runtime"], raw)
            self.assertEqual(sim.read_json(observation["runtimeEvidence"]["path"]), raw)
            for key, value in {"commit": "c" * 40, "bundleId": sim.physical.BUNDLE, "pid": 0,
                               "executableSHA256": "0" * 64, "observedAt": "2000-01-01T00:00:00Z"}.items():
                sim.atomic_json(runtime_path, {**raw, key: value})
                with self.subTest(key=key), self.assertRaises(sim.Held):
                    native.observe(built)
            runtime_path.unlink()
            with self.assertRaises(OSError):
                native.observe(built)
            sim.atomic_json(runtime_path, raw)
            with patch.object(native, "run", return_value="/unrelated/Executable"), self.assertRaises(sim.Held):
                native.observe(built)

    def test_deploy_never_replaces_a_different_test_build(self):
        native = sim.Simulator(self.args, SOURCE, Runner(), self.root)
        prepared = {"app": "/prepared.app", "built": {"build": "14"}}
        with patch.object(sim, "prepare", return_value=prepared), patch.object(native, "ready"), \
                patch.object(native, "simctl", return_value=json.dumps({sim.BUNDLE: {"CFBundleVersion": "15"}})) as calls, \
                patch.object(native, "container", return_value=self.root), \
                patch.object(sim, "bundle_manifest", return_value={"build": "15"}):
            with self.assertRaisesRegex(sim.Held, "existing_test_bundle_replacement_held"):
                sim.deploy(self.args, SOURCE, Runner(), self.root, native)
        self.assertEqual([c.args for c in calls.call_args_list], [("listapps", sim.UDID)])

    def test_readiness_requires_exact_booted_available_xros27(self):
        native = sim.Simulator(self.args, SOURCE, Runner(), self.root)
        row = {"udid": sim.UDID, "state": "Booted", "isAvailable": True}
        for runtime, value in ((sim.RUNTIME, row), (sim.RUNTIME, {**row, "state": "Shutdown"}),
                               (sim.RUNTIME, {**row, "isAvailable": False}), ("other", row)):
            with patch.object(native, "simctl", return_value=json.dumps({"devices": {runtime: [value]}})):
                if runtime == sim.RUNTIME and value == row:
                    native.ready()
                else:
                    with self.assertRaises(sim.Held):
                        native.ready()

    def test_fixture_write_read_reset_and_source_binding(self):
        context = {"runID": LEASE_ID}
        sim.validate_fixture(self.fixture(), SOURCE, context, self.observation())
        for key, value in {"commit": "c" * 40, "runID": BOOT_ID, "bootUUID": LEASE_ID,
                           "bundleId": sim.physical.BUNDLE, "providerMode": "live", "externalEffects": "unknown",
                           "sessionIsolated": False,
                           "storageIdentity": "/original/container", "events": ["reset-verified"],
                           "fixtureAbsent": False}.items():
            with self.subTest(key=key), self.assertRaises(sim.Held):
                sim.validate_fixture({**self.fixture(), key: value}, SOURCE, context, self.observation())

    def test_native_xctest_pass_is_required(self):
        summary = {"result": "Passed", "passedTests": 1, "failedTests": 0, "skippedTests": 0}
        tests = {"testNodes": [{"name": "testWorkspaceFixture()", "nodeType": "Test Case", "result": "Passed"}]}
        sim.validate_results(summary, tests)
        for changes in ({"result": "Failed"}, {"failedTests": 1}, {"passedTests": 0}, {"skippedTests": 1}):
            with self.subTest(changes=changes), self.assertRaises(sim.Held):
                sim.validate_results({**summary, **changes}, tests)
        for nodes in ({}, {"testNodes": [{"name": "another()", "nodeType": "Test Case", "result": "Passed"}]}):
            with self.assertRaises(sim.Held):
                sim.validate_results(summary, nodes)

    def remote_fixture(self):
        return {"schema": "ccr.vision.simulated-remote-peer/v1", "profile": "remote", **SOURCE.fields(),
                "runID": LEASE_ID, "bootUUID": BOOT_ID, "owner": sim.OWNER, "bundleId": sim.BUNDLE,
                "window": LEASE_ID, "admission": BOOT_ID,
                "storageIdentity": str(Path(self.observation()["container"]) / "Documents/CCRRemoteFixture" / LEASE_ID / BOOT_ID),
                "providerMode": "simulated-loopback-tls-peer", "externalEffects": "zero",
                "wholeProductTestAccepted": False, "tlsMutualPinVerified": True,
                "clientSignedIdentityVerified": True, "nativePresentationObserved": True,
                "framesSent": 4, "epoch": BOOT_ID, "generation": "fixture-generation",
                "inputs": [{"generation": "fixture-generation", "videoEpoch": BOOT_ID,
                            "event": {"text": {"_0": "remote fixture 41"}}}],
                "providerAbsent": True, "providerResetVerified": True, "stopped": True, "problem": ""}

    def test_remote_fixture_requires_real_native_and_peer_witnesses(self):
        raw = self.remote_fixture()
        sim.validate_remote_fixture(raw, SOURCE, {"runID": LEASE_ID}, self.observation())
        for key, value in {"profile": "text", "commit": "c" * 40, "runID": BOOT_ID,
                           "bootUUID": LEASE_ID, "owner": "other", "bundleId": sim.physical.BUNDLE,
                           "storageIdentity": "/original/container", "externalEffects": "unknown",
                           "wholeProductTestAccepted": True, "tlsMutualPinVerified": False,
                           "clientSignedIdentityVerified": False, "nativePresentationObserved": False,
                           "framesSent": 1, "providerAbsent": False, "providerResetVerified": False,
                           "stopped": False, "problem": "input failed", "inputs": []}.items():
            with self.subTest(key=key), self.assertRaises(sim.Held):
                sim.validate_remote_fixture({**raw, key: value}, SOURCE, {"runID": LEASE_ID}, self.observation())

    def test_remote_fixture_rejects_stale_epoch_and_wrong_text(self):
        raw = self.remote_fixture()
        for item in ({**raw["inputs"][0], "generation": "stale"},
                     {**raw["inputs"][0], "videoEpoch": LEASE_ID},
                     {**raw["inputs"][0], "event": {"text": {"_0": "wrong text"}}}):
            with self.subTest(item=item), self.assertRaises(sim.Held):
                sim.validate_remote_fixture({**raw, "inputs": [item]}, SOURCE,
                                            {"runID": LEASE_ID}, self.observation())

    def test_native_results_must_match_requested_remote_scenario(self):
        summary = {"result": "Passed", "passedTests": 1, "failedTests": 0, "skippedTests": 0}
        remote = {"testNodes": [{"name": "testRemotePeerFixture()", "nodeType": "Test Case", "result": "Passed"}]}
        sim.validate_results(summary, remote, "testRemotePeerFixture()")
        with self.assertRaises(sim.Held):
            sim.validate_results(summary, remote)

    def test_xctestrun_keeps_native_driver_and_exact_context(self):
        original = self.root / "original.xctestrun"
        original.write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": [{
            "BlueprintName": "VisionReleaseSimulatorUITests", "IsUITestBundle": True,
            "TestHostPath": "__TESTROOT__/runner.app", "UITargetAppPath": "__TESTROOT__/Test.app"}]}]}))
        destination = self.root / "execution.xctestrun"
        context = {**SOURCE.fields(), "runID": LEASE_ID}
        before = original.read_bytes()
        sim.test_run_file({"xctestrun": sim.evidence(original), "app": str(self.root / "Test.app")}, destination, context)
        target = plistlib.loads(destination.read_bytes())["TestConfigurations"][0]["TestTargets"][0]
        self.assertEqual(json.loads(target["EnvironmentVariables"]["CCR_VISION_RELEASE_CONTEXT"]), context)
        self.assertEqual(target["UITargetAppPath"], str(self.root / "Test.app"))
        self.assertEqual(original.read_bytes(), before)

    def test_missing_native_driver_is_held(self):
        original = self.root / "empty.xctestrun"
        original.write_bytes(plistlib.dumps({}))
        with self.assertRaisesRegex(sim.Held, "native_ui_test_configuration_unsupported"):
            sim.test_run_file({"xctestrun": sim.evidence(original)}, self.root / "out", {})

    def test_sdk_format_one_keeps_exact_native_target_and_context(self):
        original = self.root / "sdk.xctestrun"
        target = {"BlueprintName": "VisionReleaseSimulatorUITests", "IsUITestBundle": True,
                  "TestHostPath": "__TESTROOT__/runner.app", "UITargetAppPath": "__TESTROOT__/Test.app"}
        original.write_bytes(plistlib.dumps({"VisionReleaseSimulatorUITests": target,
            "__xctestrun_metadata__": {"FormatVersion": 1}}))
        before = original.read_bytes()
        destination = self.root / "execution.xctestrun"
        context = {**SOURCE.fields(), "runID": LEASE_ID}
        sim.test_run_file({"xctestrun": sim.evidence(original), "app": str(self.root / "Test.app")},
                          destination, context)
        result = plistlib.loads(destination.read_bytes())
        actual = result["VisionReleaseSimulatorUITests"]
        self.assertEqual(json.loads(actual["EnvironmentVariables"]["CCR_VISION_RELEASE_CONTEXT"]), context)
        self.assertEqual(actual["UITargetAppPath"], str(self.root / "Test.app"))
        self.assertEqual(result["__xctestrun_metadata__"]["FormatVersion"], 1)
        self.assertEqual(original.read_bytes(), before)

    def test_format_one_rejects_unknown_versions_extra_targets_and_wrong_app(self):
        original = self.root / "sdk.xctestrun"
        target = {"BlueprintName": "VisionReleaseSimulatorUITests", "IsUITestBundle": True,
                  "UITargetAppPath": "__TESTROOT__/Test.app"}
        valid = {"VisionReleaseSimulatorUITests": target, "__xctestrun_metadata__": {"FormatVersion": 1}}
        for raw in ({**valid, "__xctestrun_metadata__": {"FormatVersion": 99}},
                    {**valid, "AnotherUITest": target},
                    {**valid, "VisionReleaseSimulatorUITests": {**target, "UITargetAppPath": "__TESTROOT__/SillVision.app"}}):
            with self.subTest(raw=raw):
                original.write_bytes(plistlib.dumps(raw))
                with self.assertRaises(sim.Held):
                    sim.test_run_file({"xctestrun": sim.evidence(original), "app": str(self.root / "Test.app")},
                                      self.root / "execution.xctestrun", {})

    def test_native_ui_driver_cannot_target_original_app(self):
        original = self.root / "wrong.xctestrun"
        original.write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": [{
            "BlueprintName": "VisionReleaseSimulatorUITests", "IsUITestBundle": True,
            "UITargetAppPath": "__TESTROOT__/SillVision.app"}]}]}))
        with self.assertRaisesRegex(sim.Held, "ui_driver_target_app_mismatch"):
            sim.test_run_file({"xctestrun": sim.evidence(original), "app": str(self.root / "Test.app")},
                              self.root / "out", {})

    def test_production_and_other_device_have_zero_calls(self):
        for action, device in (("production", sim.UDID), ("upload", sim.UDID), ("deploy", sim.physical.UDID)):
            runner = Runner()
            with self.assertRaises(sim.Held):
                sim.execute(SimpleNamespace(action=action, device=device), runner)
            self.assertEqual(runner.calls, [])

    def test_profile_preserves_all_physical_required_checks(self):
        self.assertIn("native-input", sim.physical.CHECKS)
        self.assertIn("audio-privacy", sim.physical.CHECKS)
        self.assertIn("sentry", sim.physical.CHECKS)
        self.assertFalse(set(sim.physical.CHECKS).issubset(sim.SIM_CHECKS))

    def test_generated_targets_and_physical_configuration(self):
        project = plistlib.loads((ROOT / "SillVision.xcodeproj/project.pbxproj").read_bytes())
        objects = project["objects"]
        targets = {o["name"]: o for o in objects.values() if o.get("isa") == "PBXNativeTarget"}
        self.assertEqual(set(targets), {"SillVision", "SillVisionReleaseTest", "VisionReleaseSimulatorUITests"})
        for name, expected in (("SillVision", sim.physical.BUNDLE), ("SillVisionReleaseTest", sim.BUNDLE)):
            configs = objects[targets[name]["buildConfigurationList"]]["buildConfigurations"]
            for key in configs:
                self.assertEqual(objects[key]["buildSettings"]["PRODUCT_BUNDLE_IDENTIFIER"], expected)
        self.assertEqual(targets["VisionReleaseSimulatorUITests"]["productType"], "com.apple.product-type.bundle.ui-testing")

    def test_product_ui_is_not_replaced_or_blanket_disabled(self):
        workspace = (ROOT / "visionOSClient/SillVisionApp.swift").read_text()
        context = (ROOT / "visionOSClient/VisionReleaseTestContext.swift").read_text()
        session = (ROOT / "visionOSClient/VisionAppSession.swift").read_text()
        self.assertNotIn(".disabled(VisionReleaseTestContext.isTestBundle)", workspace)
        self.assertNotIn("VisionReleaseFixtureView", workspace + context)
        self.assertIn("VisionTextDraftPanel(client: client", workspace)
        self.assertIn("MockCatalog.client(settings: .legacy, menus: nil)", session)
        self.assertNotIn("TextField(", context)


if __name__ == "__main__":
    unittest.main()
