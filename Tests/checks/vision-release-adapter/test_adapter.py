"""Deterministic adapter checks. Native/signing/build/network operations are fixtures."""

import copy
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import uuid


SCRIPT = Path(__file__).resolve().parents[3] / "Scripts/vision-release-adapter.py"
SPEC = importlib.util.spec_from_file_location("vision_release_adapter", SCRIPT)
adapter = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = adapter
SPEC.loader.exec_module(adapter)
GIT_ENV = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT="0")


class Boundary:
    """Emulate external Git, routing, SDK, signature and native operations."""

    def __init__(self, args):
        self.args = args
        self.calls = []
        self.source = None
        self.build = None
        self.remote_commit = None
        self.lock = {"passcodeRequired": False, "unlockedSinceBoot": True}
        self.installed = False
        self.installed_developer = True
        self.installed_version = None
        self.runtime = None
        self.boot = str(uuid.uuid4())
        self.install_count = 0
        self.launch_count = 0
        self.copy_count = 0
        self.fail_install = False
        self.stale_runtime = False
        self.wrong_runtime = False
        self.dead_process = False
        self.app_url = "file:///private/var/containers/Bundle/Application/fixture/SillVision.app"
        self.sign_team = adapter.TEAM
        self.move_ref_after_build = False
        self.after_build = None
        self.remote_url = "https://github.com/Plamyth/sill.git"
        self.dirty = False
        self.revision_count = 1

    @property
    def native_calls(self):
        return [call for call in self.calls if call[:2] == ["/usr/bin/xcrun", "devicectl"]]

    def run(self, args, cwd=None):
        args = [str(arg) for arg in args]
        self.calls.append(args)
        if args[0] == "/usr/bin/git":
            if "ls-remote" in args:
                return (self.remote_commit or self.source.commit) + "\t" + self.args.ref + "\n", ""
            words = args[3:]
            if words[0] == "status":
                return ("?? untracked.swift" if self.dirty else ""), ""
            values = {("symbolic-ref", "--quiet", "HEAD"): "refs/heads/fixture",
                      ("rev-parse", "HEAD"): self.source.commit,
                      ("rev-parse", "HEAD^{tree}"): self.source.tree,
                      ("rev-parse", "--is-shallow-repository"): "false",
                      ("remote", "get-url", "origin"): self.remote_url,
                      ("rev-list", "--count", "HEAD"): str(self.revision_count)}
            return values[tuple(words)] + "\n", ""
        if args[0] == adapter.ROUTER:
            return json.dumps({"path": self.args.output}), ""
        if args[:2] == ["/usr/bin/xcrun", "xcodebuild"]:
            self.build = next(arg.split("=", 1)[1] for arg in args if arg.startswith("CURRENT_PROJECT_VERSION="))
            derived = Path(args[args.index("-derivedDataPath") + 1])
            app = derived / "Build/Products/Release-xros/SillVision.app"
            (app / "_CodeSignature").mkdir(parents=True)
            info = {"CFBundleIdentifier": adapter.BUNDLE, "CFBundleExecutable": "SillVision",
                    "CFBundleVersion": self.build, "BTSourceCommit": self.source.commit,
                    "BTSourceTree": self.source.tree, "DTPlatformName": "xros"}
            (app / "Info.plist").write_bytes(plistlib.dumps(info))
            (app / "SillVision").write_bytes(b"fixture signed executable " + self.source.commit.encode())
            (app / "_CodeSignature/CodeResources").write_bytes(b"fixture signed resources")
            if self.move_ref_after_build:
                self.remote_commit = "a" * 40
            if self.after_build:
                self.after_build()
            return "fixture build only\n", ""
        if args[0] == "/usr/bin/codesign":
            if "--verify" in args:
                return "", ""
            if "--entitlements" in args:
                return plistlib.dumps({"application-identifier": adapter.TEAM + "." + adapter.BUNDLE,
                                       "com.apple.developer.team-identifier": adapter.TEAM}).decode(), ""
            return "", "Identifier=" + adapter.BUNDLE + "\nTeamIdentifier=" + self.sign_team + "\nCDHash=" + "d" * 40 + "\n"
        if args[:2] != ["/usr/bin/xcrun", "devicectl"]:
            raise AssertionError("Unexpected external operation: " + repr(args))
        result = {"deviceIdentifier": adapter.CORE_DEVICE}
        if args[3:5] == ["info", "lockState"]:
            result.update(self.lock)
        elif args[3:5] == ["info", "apps"]:
            result["apps"] = ([{"bundleIdentifier": adapter.BUNDLE, "bundleVersion": self.installed_version,
                                "url": self.app_url}] if self.installed and
                               (self.installed_developer or "--include-default-apps" in args) else [])
        elif args[3:5] == ["install", "app"]:
            self.install_count += 1
            if self.fail_install:
                raise adapter.Held("fixture_uncertain_install")
            self.installed = True
            self.installed_version = self.build
        elif args[3:5] == ["process", "launch"]:
            self.launch_count += 1
            self.runtime = self.make_runtime()
            result["process"] = {"processIdentifier": self.runtime["pid"]}
        elif args[3:5] == ["copy", "from"]:
            self.copy_count += 1
            if self.runtime is None:
                raise adapter.Held("fixture_runtime_absent")
            destination = Path(args[args.index("--destination") + 1])
            destination.write_text(json.dumps(self.runtime))
        elif args[3:5] == ["info", "processes"]:
            result["runningProcesses"] = [] if self.dead_process else [
                {"processIdentifier": self.runtime["pid"], "executable": self.app_url + "/SillVision"}]
        else:
            raise AssertionError("Unexpected device operation: " + repr(args))
        Path(args[args.index("--json-output") + 1]).write_text(json.dumps({"info": {"outcome": "success"}, "result": result}))
        return "", ""

    def make_runtime(self):
        path = self.revision / "prepare.json"
        built = adapter.read_json(path)["built"]
        at = adapter.now() - dt.timedelta(seconds=1000 if self.stale_runtime else 0)
        return {"schema": "ccr.vision.runtime/v1", **self.source.fields(), "bundleId": adapter.BUNDLE,
                "build": built["build"], "pid": 4321, "bootUUID": self.boot, "observedAt": at.isoformat(),
                **{key: built[key] for key in ("executableSHA256", "infoPlistSHA256", "codeResourcesSHA256")},
                **({"commit": "b" * 40} if self.wrong_runtime else {})}

    @property
    def revision(self):
        return Path(self.args.output) / (self.source.commit + "-" + self.source.tree + "-" + adapter.UDID)


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.repo = self.root / "repo"
        self.repo.mkdir()
        project = self.repo / "SillVision.xcodeproj"
        project.mkdir()
        (project / "project.pbxproj").write_text("fixture project")
        self.source = adapter.Source("1" * 40, "2" * 40)
        self.lease = self.root / "lease.json"
        self.write_lease()
        self.args = adapter.parser().parse_args([
            "prepare", "--repo", str(self.repo), "--remote", "origin",
            "--ref", "refs/heads/codex/vision-test-destinations-20261020",
            "--output", str(self.root / "routed-output"), "--lease", str(self.lease)])
        self.boundary = Boundary(self.args)
        self.boundary.source = self.source

    def advance_source(self):
        (self.repo / "SillVision.xcodeproj/project.pbxproj").write_text("next fixture")
        self.boundary.source = adapter.Source("3" * 40, "4" * 40)
        self.boundary.revision_count = 2

    def write_lease(self, **changes):
        lease = {"schema": "ccr.vision.device-lease/v1", "ownerThread": adapter.OWNER,
                 "deviceId": adapter.CORE_DEVICE, "expiresAt": (adapter.now() + dt.timedelta(hours=1)).isoformat(),
                 "permitted": {"install": True, "launch": True}}
        lease.update(changes)
        self.lease.write_text(json.dumps(lease))

    def execute(self, action):
        self.args.action = action
        return adapter.execute(self.args, self.boundary)

    def prepare(self):
        result = self.execute("prepare")
        self.assertEqual(result["status"], "prepared")
        self.assertEqual(self.boundary.native_calls, [])
        return result

    def deploy(self):
        self.prepare()
        return self.execute("deploy")

    def acceptance(self, deployed):
        fixture = self.root / "physical-fixture.txt"
        fixture.write_text("Isolated test-driver fixture only; this is not physical acceptance.")
        proof = adapter.evidence(fixture)
        rows = {name: {"status": "pass", "evidence": [proof]} for name in adapter.CHECKS}
        rows["runtime-source-readback"]["evidence"] = [deployed["nativeReadback"]["runtimeEvidence"]]
        return {"schema": "bt.test-acceptance/v1", "projectId": self.args.project_id,
                **self.source.fields(), "runtimeId": deployed["runtimeId"], "environment": self.args.environment,
                "externalEffects": "zero", "fixtureReset": {"status": "pass"},
                "isolation": {"dbIdentity": "fixture-db", "storageIdentity": "fixture-private-storage",
                              "providerMode": "deterministic-stub"}, "checks": rows}

    def save_acceptance(self, raw):
        path = self.root / "acceptance.json"
        path.write_text(json.dumps(raw))
        self.args.acceptance_evidence = str(path)

    def test_prepare_binds_signed_source_and_monotonic_build(self):
        prepared = self.prepare()
        self.assertEqual(prepared["built"]["build"], "1001")
        self.assertEqual(prepared["commit"], self.source.commit)
        self.assertEqual(prepared["tree"], self.source.tree)
        commands = self.boundary.calls
        self.assertTrue(any("INFOPLIST_KEY_BTSourceCommit=" + self.source.commit in row for row in commands))
        self.assertTrue(any("-resultBundlePath" in row for row in commands))
        self.assertFalse(any("xcode-select" in word for row in commands for word in row))

    def test_explicit_build_minimum_and_pin(self):
        self.args.build_number = 22
        self.args.commit, self.args.tree = self.source.commit, self.source.tree
        self.assertEqual(self.prepare()["built"]["build"], "22")
        self.args.build_number = 21
        with self.assertRaisesRegex(adapter.Held, "developer_build_below_minimum"):
            self.execute("prepare")

    def test_dirty_source_refused_before_build(self):
        (self.repo / "untracked.swift").write_text("dirty")
        self.boundary.dirty = True
        with self.assertRaisesRegex(adapter.Held, "source_dirty"):
            self.execute("prepare")
        self.assertFalse(any("xcodebuild" in call for call in self.boundary.calls))

    def test_wrong_pin_or_remote_source_refused(self):
        self.args.commit, self.args.tree = "a" * 40, self.source.tree
        with self.assertRaisesRegex(adapter.Held, "source_mismatch"):
            self.execute("prepare")
        self.args.commit = self.args.tree = None
        self.boundary.remote_commit = "a" * 40
        with self.assertRaisesRegex(adapter.Held, "official_ref_source_mismatch"):
            self.execute("prepare")

    def test_wrong_remote_identity_refused(self):
        self.boundary.remote_url = "https://github.com/Saffsanity/sill.git"
        with self.assertRaisesRegex(adapter.Held, "official_remote_identity_mismatch"):
            self.execute("prepare")

    def test_ref_move_during_build_is_refused(self):
        self.boundary.move_ref_after_build = True
        with self.assertRaisesRegex(adapter.Held, "official_ref_source_mismatch"):
            self.execute("prepare")
        self.assertFalse((self.boundary.revision / "prepare.json").exists())

    def test_local_and_remote_move_together_still_refused_against_start(self):
        original = self.boundary.revision

        def advance():
            self.advance_source()

        self.boundary.after_build = advance
        with self.assertRaisesRegex(adapter.Held, "source_changed_during_build"):
            self.execute("prepare")
        self.assertFalse((original / "prepare.json").exists())

    def test_same_base_supports_next_head_and_preserves_old_receipts(self):
        first = self.prepare()
        old = Path(first["evidence"])
        old_bytes = old.read_bytes()
        self.advance_source()
        second = self.prepare()
        self.assertNotEqual(first["evidence"], second["evidence"])
        self.assertEqual(old.read_bytes(), old_bytes)
        self.assertEqual(second["built"]["build"], "1002")

    def test_unowned_nonempty_output_refused(self):
        base = Path(self.args.output)
        base.mkdir()
        (base / "parent-onboarding.json").write_text("{}")
        with self.assertRaisesRegex(adapter.Held, "nonempty_output_unowned"):
            self.execute("prepare")
        self.assertFalse((base / "owner.json").exists())

    def test_missing_expired_wrong_owner_and_target_leases_make_zero_calls(self):
        invalid = [
            {"expiresAt": (adapter.now() - dt.timedelta(seconds=1)).isoformat()},
            {"deviceId": adapter.UDID}, {"ownerThread": "another-owner"}, {"permitted": {"install": True}},
        ]
        for changes in invalid:
            with self.subTest(changes=changes):
                self.write_lease(**changes)
                self.boundary.calls.clear()
                with self.assertRaises(adapter.Held):
                    self.execute("deploy")
                self.assertEqual(self.boundary.calls, [])
        self.args.lease = None
        with self.assertRaisesRegex(adapter.Held, "device_lease_missing"):
            self.execute("deploy")
        self.assertEqual(self.boundary.calls, [])

    def test_lease_is_rechecked_at_each_native_boundary(self):
        directory = self.root / "native"
        directory.mkdir()
        native = adapter.Native(self.args, self.boundary, directory)
        native.unlocked()
        before = len(self.boundary.native_calls)
        self.write_lease(expiresAt=(adapter.now() - dt.timedelta(seconds=1)).isoformat())
        with self.assertRaisesRegex(adapter.Held, "device_lease_expired"):
            native.app()
        self.assertEqual(len(self.boundary.native_calls), before)

    def test_unknown_or_locked_device_held_after_one_query(self):
        self.prepare()
        for state in ({}, {"passcodeRequired": True, "unlockedSinceBoot": True}):
            with self.subTest(state=state):
                self.boundary.lock = state
                self.boundary.calls.clear()
                with self.assertRaisesRegex(adapter.Held, "device_locked_or_lock_state_unknown"):
                    self.execute("deploy")
                self.assertEqual(len(self.boundary.native_calls), 1)
                self.assertEqual(self.boundary.install_count, 0)

    def test_legacy20_without_verified_recovery_is_held_without_install(self):
        self.prepare()
        self.boundary.installed = True
        self.boundary.installed_version = "20"
        with self.assertRaisesRegex(adapter.Held, "existing_app_replacement_held"):
            self.execute("deploy")
        self.assertEqual(self.boundary.install_count, 0)
        self.assertEqual(self.boundary.copy_count, 0)
        self.assertFalse((self.boundary.revision / "install-attempt.json").exists())

    def test_nondeveloper_existing_app_is_not_mistaken_for_empty_target(self):
        self.prepare()
        self.boundary.installed = True
        self.boundary.installed_developer = False
        self.boundary.installed_version = "20"
        with self.assertRaisesRegex(adapter.Held, "existing_app_replacement_held"):
            self.execute("deploy")
        self.assertEqual(self.boundary.install_count, 0)

    def test_missing_runtime_on_same_version_does_not_install(self):
        self.prepare()
        self.boundary.installed = True
        self.boundary.installed_version = self.boundary.build
        with self.assertRaisesRegex(adapter.Held, "fixture_runtime_absent"):
            self.execute("deploy")
        self.assertEqual(self.boundary.install_count, 0)

    def test_downgrade_and_unknown_installed_version_refused(self):
        self.prepare()
        self.boundary.installed = True
        for value in ("99999", None):
            self.boundary.installed_version = value
            with self.assertRaises(adapter.Held):
                self.execute("deploy")
        self.assertEqual(self.boundary.install_count, 0)

    def test_deploy_is_idempotent_only_after_matching_signed_runtime(self):
        first = self.deploy()
        self.assertEqual(first["status"], "applied")
        before = adapter.evidence(first["receiptPath"])
        second = self.execute("deploy")
        self.assertEqual(second["status"], "unchanged")
        self.assertEqual(first["runtimeId"], second["runtimeId"])
        self.assertEqual(self.boundary.install_count, 1)
        self.assertEqual(adapter.verify_evidence(before), before)
        self.boundary.runtime["executableSHA256"] = "0" * 64
        with self.assertRaisesRegex(adapter.Held, "runtime_signed_bytes_mismatch"):
            self.execute("deploy")
        self.assertEqual(self.boundary.install_count, 1)

    def test_explicit_install_and_launch_permissions_required(self):
        self.prepare()
        self.write_lease(permitted={"install": True, "launch": False})
        with self.assertRaisesRegex(adapter.Held, "device_lease_install_and_launch_required"):
            self.execute("deploy")
        self.assertEqual(self.boundary.install_count, 0)

    def test_uncertain_install_is_not_repeated(self):
        self.prepare()
        self.boundary.fail_install = True
        with self.assertRaisesRegex(adapter.Held, "fixture_uncertain_install"):
            self.execute("deploy")
        self.boundary.fail_install = False
        with self.assertRaisesRegex(adapter.Held, "previous_install_requires_readback"):
            self.execute("deploy")
        self.assertEqual(self.boundary.install_count, 1)
        self.assertFalse((self.boundary.revision / "deployment.json").exists())

    def test_next_revision_without_recovery_holds_and_retains_previous_good_identity(self):
        previous = self.deploy()
        previous_file = adapter.evidence(previous["receiptPath"])
        old_last_good = (Path(self.args.output) / "last-good.json").read_bytes()
        self.advance_source()
        self.boundary.calls.clear()
        self.prepare()
        with self.assertRaisesRegex(adapter.Held, "existing_app_replacement_held"):
            self.execute("deploy")
        self.assertFalse((self.boundary.revision / "install-attempt.json").exists())
        self.assertEqual(self.boundary.install_count, 1)
        self.assertEqual((Path(self.args.output) / "last-good.json").read_bytes(), old_last_good)
        adapter.verify_evidence(previous_file)

    def test_stale_wrong_source_and_dead_process_never_report_applied(self):
        for field in ("stale_runtime", "wrong_runtime", "dead_process"):
            with self.subTest(field=field):
                self.boundary.calls.clear()
                self.prepare()
                setattr(self.boundary, field, True)
                with self.assertRaises(adapter.Held):
                    self.execute("deploy")
                self.assertFalse((self.boundary.revision / "deployment.json").exists())
                setattr(self.boundary, field, False)
                # Reuse the actually installed fixture after the failed readback.
                self.boundary.runtime = self.boundary.make_runtime()
                self.boundary.installed = False
                attempt = self.boundary.revision / "install-attempt.json"
                attempt.unlink()

    def test_prepared_signature_or_bytes_tampering_held_before_device_calls(self):
        self.prepare()
        self.boundary.sign_team = "WRONGTEAM"
        with self.assertRaisesRegex(adapter.Held, "built_signature_identity_mismatch"):
            self.execute("deploy")
        self.assertEqual(self.boundary.native_calls, [])
        self.boundary.sign_team = adapter.TEAM
        manifest = adapter.read_json(self.boundary.revision / "prepare.json")
        Path(manifest["built"]["path"], "SillVision").write_bytes(b"tampered")
        with self.assertRaisesRegex(adapter.Held, "prepared_app_tampered"):
            self.execute("deploy")
        self.assertEqual(self.boundary.native_calls, [])

    def test_valid_isolated_evidence_is_accepted_with_fresh_native_readback(self):
        deployed = self.deploy()
        self.save_acceptance(self.acceptance(deployed))
        result = self.execute("accept")
        self.assertEqual(result["status"], "accepted")
        self.assertEqual(result["runtimeId"], deployed["runtimeId"])
        self.assertFalse(result["productionEnabled"])
        self.assertEqual(self.boundary.install_count, 1)

    def test_each_missing_false_or_evidenceless_check_is_refused(self):
        deployed = self.deploy()
        raw = self.acceptance(deployed)
        for name in adapter.CHECKS:
            for mode in ("missing", "false", "no-evidence"):
                with self.subTest(check=name, mode=mode):
                    broken = copy.deepcopy(raw)
                    if mode == "missing":
                        del broken["checks"][name]
                    elif mode == "false":
                        broken["checks"][name]["status"] = False
                    else:
                        broken["checks"][name]["evidence"] = []
                    with self.assertRaises(adapter.Held):
                        adapter.validate_acceptance(broken, self.source, self.args, deployed)

    def test_hash_mismatch_symlink_relative_and_missing_evidence_refused(self):
        deployed = self.deploy()
        raw = self.acceptance(deployed)
        link = self.root / "evidence-link"
        link.symlink_to(raw["checks"]["readiness"]["evidence"][0]["path"])
        cases = [
            {"path": str(link), "sha256": "0" * 64},
            {"path": "relative.txt", "sha256": "0" * 64},
            {"path": str(self.root / "absent"), "sha256": "0" * 64},
            {**raw["checks"]["readiness"]["evidence"][0], "sha256": "0" * 64},
        ]
        for row in cases:
            with self.subTest(row=row):
                broken = copy.deepcopy(raw)
                broken["checks"]["readiness"]["evidence"] = [row]
                with self.assertRaises(adapter.Held):
                    adapter.validate_acceptance(broken, self.source, self.args, deployed)

    def test_acceptance_source_runtime_environment_and_isolation_are_bound(self):
        deployed = self.deploy()
        raw = self.acceptance(deployed)
        cases = [{"commit": "0" * 40}, {"tree": "0" * 40}, {"runtimeId": "another-boot"},
                 {"environment": "production"}, {"externalEffects": "unknown"},
                 {"isolation": {}}, {"fixtureReset": {"status": "fail"}}, {"fixtureReset": ["pass"]}]
        for changes in cases:
            with self.subTest(changes=changes), self.assertRaises(adapter.Held):
                adapter.validate_acceptance({**raw, **changes}, self.source, self.args, deployed)

    def test_runtime_file_tampering_and_restarted_process_refuse_acceptance(self):
        deployed = self.deploy()
        self.save_acceptance(self.acceptance(deployed))
        self.boundary.boot = str(uuid.uuid4())
        self.boundary.runtime = self.boundary.make_runtime()
        with self.assertRaisesRegex(adapter.Held, "acceptance_live_runtime_changed"):
            self.execute("accept")
        file = Path(deployed["nativeReadback"]["runtimeEvidence"]["path"])
        file.write_text("{}")
        with self.assertRaisesRegex(adapter.Held, "evidence_hash_mismatch"):
            self.execute("accept")

    def test_native_copy_scope_is_only_fixed_runtime_file(self):
        self.deploy()
        copies = [row for row in self.boundary.native_calls if row[3:5] == ["copy", "from"]]
        self.assertTrue(copies)
        for row in copies:
            self.assertEqual(row[row.index("--source") + 1], "Documents/CCRReleaseRuntime.json")
            self.assertEqual(row[row.index("--domain-type") + 1], "appDataContainer")
            self.assertEqual(row[row.index("--domain-identifier") + 1], adapter.BUNDLE)
        self.assertFalse(any(word in ("uninstall", "--terminate-existing") for row in self.boundary.native_calls for word in row))

    def test_production_and_upload_fail_before_any_operations(self):
        for action in ("production", "upload"):
            with self.assertRaisesRegex(adapter.Held, "production_and_store_upload_disabled"):
                self.execute(action)
        self.assertEqual(self.boundary.calls, [])

    def test_missing_acceptance_evidence_does_not_query_device(self):
        self.deploy()
        self.boundary.calls.clear()
        with self.assertRaisesRegex(adapter.Held, "acceptance_evidence_missing"):
            self.execute("accept")
        self.assertEqual(self.boundary.native_calls, [])


class RunnerTests(unittest.TestCase):
    def test_real_git_dirty_source_and_head_binding_without_network(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()

            def git(*words):
                return subprocess.run(["/usr/bin/git", "-C", str(root), *words], env=GIT_ENV,
                                      capture_output=True, text=True, timeout=3, check=True).stdout.strip()

            git("init", "-b", "fixture")
            git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                "commit", "--allow-empty", "-m", "fixture")
            git("remote", "add", "origin", "https://github.com/Plamyth/sill.git")
            commit = git("rev-parse", "HEAD")
            tree = git("rev-parse", "HEAD^{tree}")
            args = adapter.parser().parse_args(["prepare", "--repo", str(root), "--remote", "origin",
                                                "--ref", "refs/heads/fixture", "--output", str(root / "unused")])

            class LocalGit:
                def run(self, words):
                    if "ls-remote" in words:
                        return commit + "\trefs/heads/fixture\n", ""
                    return git(*words[3:]), ""

            self.assertEqual(adapter.source_identity(args, LocalGit()), adapter.Source(commit, tree))
            (root / "dirty.swift").write_text("untracked")
            with self.assertRaisesRegex(adapter.Held, "source_dirty"):
                adapter.source_identity(args, LocalGit())

    def test_child_environment_is_fixed_without_mutating_parent(self):
        before = os.environ.get("DEVELOPER_DIR")
        result, _ = adapter.Runner(5).run([sys.executable, "-B", "-c",
                                         "import os; print(os.environ['DEVELOPER_DIR'])"])
        self.assertEqual(result.strip(), adapter.DEVELOPER_DIR)
        self.assertEqual(os.environ.get("DEVELOPER_DIR"), before)

    def test_budget_kills_and_reaps_child(self):
        with self.assertRaisesRegex(adapter.Held, "command_timeout"):
            adapter.Runner(0.03).run([sys.executable, "-B", "-c", "import time; time.sleep(5)"])
        with self.assertRaisesRegex(adapter.Held, "budget_invalid"):
            adapter.Runner(float("nan"))


if __name__ == "__main__":
    unittest.main()
