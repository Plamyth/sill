import ast
from dataclasses import replace
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from extract import fixture
from run import (DEVELOPER_DIR, Process, cleanup_group, compiler_output_bound,
                 execute, group_members)


class RunnerContract(unittest.TestCase):
    def save_witness(self, name, result):
        if directory := os.environ.get('VISION_RUNNER_TEST_OUTPUT'):
            Path(directory, name + '.json').write_text(json.dumps(result, indent=2) + '\n')

    def test_remote_compile_and_mutant_source_parity(self):
        directory = Path(__file__).parent
        lists = []
        for name in ['run.py', 'remote.py']:
            tree = ast.parse((directory / name).read_text())
            candidates = [ast.literal_eval(node) for node in ast.walk(tree) if isinstance(node, ast.List)
                          and all(isinstance(item, ast.Constant) and isinstance(item.value, str) for item in node.elts)
                          and any(isinstance(item, ast.Constant) and item.value == 'Client.swift' for item in node.elts)]
            self.assertEqual(len(candidates), 1, name)
            lists.append(candidates[0])
        self.assertEqual(lists[0], lists[1])
        files, _ = fixture()
        self.assertTrue(all(name in files for name in lists[0]))
        self.assertTrue({'SpatialCallbacks.swift', 'LifecycleTests.swift'} <= set(lists[1]))
        variants = {}
        tree = ast.parse((directory / 'remote.py').read_text())
        expressions = {}
        for node in ast.walk(tree):
            if not isinstance(node, ast.Assign):
                continue
            target = node.targets[0]
            if isinstance(target, ast.Name) and target.id in ['sources', 'variant']:
                expressions[target.id] = compile(ast.Expression(node.value), 'remote.py', 'eval')
            if isinstance(target, ast.Name) and target.id == 'mutants':
                variants.update(ast.literal_eval(node.value))
            elif isinstance(target, ast.Subscript) and isinstance(target.value, ast.Name) and target.value.id == 'mutants':
                variants[ast.literal_eval(target.slice)] = ast.literal_eval(node.value)
        self.assertEqual(len(variants), 6)
        package = Path('/inert-fixture')
        sources = eval(expressions['sources'], {'package': package})
        self.assertEqual(sources, [str(package / name) for name in lists[0]])
        for original, replacement, _ in variants.values():
            actual = eval(expressions['variant'], {'package': package, 'sources': sources,
                                                   'originalPath': original, 'replacement': replacement})
            self.assertEqual(actual, [str(package / replacement) if name == original else str(package / name) for name in lists[0]])
            compiled = [str(Path(name).relative_to(package)) for name in actual]
            self.assertEqual(compiled.count(replacement), 1)
            self.assertIn('SpatialCallbacks.swift', compiled)
            self.assertIn('LifecycleTests.swift', compiled)
            self.assertTrue(all(name in files for name in compiled))
            self.assertNotEqual(files[original], files[replacement])

    def test_cleanup_after_leader_exits_with_live_descendant(self):
        script = 'import subprocess,sys; p=subprocess.Popen([sys.executable,"-c","import time; time.sleep(30)"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); print(p.pid,flush=True)'
        log, result = execute([sys.executable, '-c', script], timeout=3)
        self.save_witness('group-leader-exit', result)
        self.assertEqual(result['exitCode'], 0)
        self.assertFalse(result['timedOut'])
        self.assertIn(int(log.strip()), result['processGroup']['initial'])
        self.assertEqual(result['processGroup']['remaining'], [])
        self.assertTrue(result['processGroup']['verified'])
        self.assertEqual(group_members(result['pid']), [])

    def test_cleanup_on_timeout_with_live_descendant(self):
        script = 'import subprocess,sys,time; p=subprocess.Popen([sys.executable,"-c","import time; time.sleep(30)"]); print(p.pid,flush=True); time.sleep(30)'
        log, result = execute([sys.executable, '-c', script], timeout=0.3)
        self.save_witness('group-timeout', result)
        self.assertTrue(result['timedOut'])
        self.assertTrue(result['reaped'])
        self.assertIn(int(log.strip()), result['processGroup']['initial'])
        self.assertEqual(result['processGroup']['remaining'], [])
        self.assertTrue(result['processGroup']['verified'])
        self.assertEqual(group_members(result['pid']), [])

    def test_child_xcode_pin_does_not_change_parent_environment(self):
        with patch.dict(os.environ, {'DEVELOPER_DIR': '/unrelated-parent-toolchain'}):
            log, result = execute([sys.executable, '-c', 'import os; print(os.environ["DEVELOPER_DIR"])'], timeout=3)
            self.assertEqual(log.strip(), DEVELOPER_DIR)
            self.assertEqual(result['developerDir'], DEVELOPER_DIR)
            self.assertEqual(os.environ['DEVELOPER_DIR'], '/unrelated-parent-toolchain')
            self.assertTrue(result['processGroup']['verified'])

    def test_detached_descendant_after_reparenting_and_on_timeout(self):
        for timeout in [False, True]:
            with self.subTest(timeout=timeout), tempfile.TemporaryDirectory(
                    prefix='detached-', dir=os.environ.get('VISION_RUNNER_TEST_OUTPUT')) as directory:
                output = Path(directory)
                child_script = output / 'child.py'
                child_script.write_text('import time\ntime.sleep(30)\n')
                unrelated = subprocess.Popen([sys.executable, str(child_script), '-o', str(output / 'unrelated.o')],
                                             start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                pid = None
                try:
                    script = ('import subprocess,sys,time; '
                              f'p=subprocess.Popen([sys.executable,{str(child_script)!r}],start_new_session=True,'
                              'stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); '
                              'print(p.pid,flush=True); time.sleep(' + ('30' if timeout else '0.6') + ')')
                    log, result = execute([sys.executable, '-c', script], timeout=0.6 if timeout else 3,
                                          output=output)
                    pid = int(log.strip())
                    result['unrelatedPID'] = unrelated.pid
                    result['unrelatedAliveAfterCleanup'] = unrelated.poll() is None
                    self.save_witness('detached-timeout' if timeout else 'detached-leader-exit', result)
                    self.assertEqual(result['timedOut'], timeout)
                    self.assertTrue(result['reaped'])
                    cleanup = result['processGroup']
                    detached = next(p for p in cleanup['detachedInitial'] if p['pid'] == pid)
                    self.assertEqual(detached['group'], pid)
                    if not timeout:
                        self.assertEqual(detached['parent'], 1)
                    self.assertTrue(detached['started'])
                    self.assertIn(str(child_script), detached['command'])
                    self.assertTrue(cleanup['verified'])
                    self.assertEqual(cleanup['remaining'], [])
                    self.assertEqual(cleanup['detachedRemaining'], [])
                    self.assertEqual(group_members(pid), [])
                    self.assertIsNone(unrelated.poll())
                    self.assertNotIn(unrelated.pid, [p['pid'] for p in cleanup['ownedIdentities']])
                finally:
                    unrelated.terminate()
                    unrelated.wait(timeout=3)
                    if pid is not None and group_members(pid):
                        self.fail('detached witness left a live process; see identity receipt')

    def test_reparented_compiler_requires_exact_output_argument(self):
        output = Path('/unique-runner-output')
        compiler = DEVELOPER_DIR + '/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend'
        item = Process(12345, 1, 12345, 'S', 'Tue Oct 20 00:00:00 2026', compiler + ' -o /unique-runner-output/Network.o')
        self.assertTrue(compiler_output_bound(item, output))
        for args in [' -o /unique-runner-output-other/Network.o', ' /unique-runner-output/Network.swift',
                     ' -o /unique-runner-output/../other/Network.o', ' -Dprefix=/unique-runner-output/cache',
                     ' -o relative/unique-runner-output/Network.o']:
            self.assertFalse(compiler_output_bound(replace(item, command=compiler + args), output), args)
        self.assertFalse(compiler_output_bound(replace(item, command='/usr/bin/python3 -c "' + item.command + '"'), output))
        table = {item.pid: item}
        with patch('run.process_table', side_effect=[table, table, table, {}, {}]), patch('run.os.kill') as kill, patch('run.os.killpg') as killpg:
            result = cleanup_group(99999, {}, output)
        kill.assert_called_once_with(item.pid, 15)
        killpg.assert_not_called()
        self.assertTrue(result['verified'])
        self.assertEqual(result['detachedInitial'], [item.__dict__])
        self.save_witness('reparented-compiler-binding', result)

    def test_identity_is_rechecked_before_detached_signal(self):
        item = Process(12345, 1, 12345, 'S', 'Tue Oct 20 00:00:00 2026', '/owned-command')
        for changed in [replace(item, started='Tue Oct 20 00:00:01 2026'),
                        replace(item, command='/unrelated-command')]:
            with self.subTest(changed=changed), patch('run.process_table', side_effect=[{item.pid: item}, {item.pid: item},
                    {item.pid: changed}, {}, {}]), patch('run.os.kill') as kill, patch('run.os.killpg') as killpg:
                result = cleanup_group(99999, {item.identity: item}, None)
            kill.assert_not_called()
            killpg.assert_not_called()
            self.assertTrue(result['verified'])

    def test_ps_error_is_unknown_and_sends_no_signal(self):
        for error in [subprocess.CalledProcessError(1, 'ps'), subprocess.TimeoutExpired('ps', 5),
                      ValueError('incomplete process identity from ps')]:
            with self.subTest(error=error), patch('run.process_table', side_effect=error), patch('run.os.kill') as kill, patch('run.os.killpg') as killpg:
                result = cleanup_group(99999, {}, None)
            self.assertFalse(result['verified'])
            self.assertIsNone(result['remaining'])
            self.assertIsNone(result['detachedRemaining'])
            self.assertIn('error', result)
            kill.assert_not_called()
            killpg.assert_not_called()

    def test_cleanup_shares_one_deadline_across_slow_queries(self):
        clock = [0.0]
        requested = []
        snapshots = iter([True, True, True, False, False])

        def slow_query(command, **options):
            timeout = options['timeout']
            requested.append(timeout)
            clock[0] += min(4.0, timeout)
            if timeout < 4.0:
                raise subprocess.TimeoutExpired(command, timeout)
            live = next(snapshots)
            row = ('12345 1 12345 S Tue Oct 20 00:00:00 2026 /owned-command\n' if live else
                   '22222 1 22222 S Tue Oct 20 00:00:00 2026 /unrelated-command\n')
            return subprocess.CompletedProcess(command, 0, stdout=row)

        item = Process(12345, 1, 12345, 'S', 'Tue Oct 20 00:00:00 2026', '/owned-command')
        with patch('run.time.monotonic', side_effect=lambda: clock[0]), \
                patch('run.subprocess.run', side_effect=slow_query), \
                patch('run.os.kill'), patch('run.os.killpg'):
            result = cleanup_group(99999, {item.identity: item}, None)
        self.save_witness('cleanup-shared-deadline', {'virtualSeconds': clock[0],
                          'queryTimeouts': requested, 'processGroup': result})
        self.assertFalse(result['verified'])
        self.assertIsNone(result['remaining'])
        self.assertIsNone(result['detachedRemaining'])
        self.assertLessEqual(clock[0], 15.0)
        self.assertEqual(requested, [5, 5, 5, 3.0])

    def test_expired_shared_deadline_starts_no_query_or_signal(self):
        with patch('run.time.monotonic', return_value=100), patch('run.subprocess.run') as query, \
                patch('run.os.kill') as kill, patch('run.os.killpg') as killpg:
            result = cleanup_group(99999, {}, None, deadline=99)
        query.assert_not_called()
        kill.assert_not_called()
        killpg.assert_not_called()
        self.assertFalse(result['verified'])
        self.assertIsNone(result['remaining'])
        self.assertIn('deadline exhausted', result['error'])


if __name__ == '__main__':
    unittest.main()
