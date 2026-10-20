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
    def __init__(self, output=""):
        self.output, self.calls = output, []

    def run(self, command, cwd=None):
        self.calls.append([str(x) for x in command])
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
        return Runner(json.dumps({"leases": [{**self.row, "state": "live", "live": True,
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
