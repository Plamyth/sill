import ast
from pathlib import Path
import sys
import unittest

from extract import fixture
from run import execute, group_members


class RunnerContract(unittest.TestCase):
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
        self.assertEqual(result['exitCode'], 0)
        self.assertFalse(result['timedOut'])
        self.assertIn(int(log.strip()), result['processGroup']['initial'])
        self.assertEqual(result['processGroup']['remaining'], [])
        self.assertEqual(group_members(result['pid']), [])

    def test_cleanup_on_timeout_with_live_descendant(self):
        script = 'import subprocess,sys,time; p=subprocess.Popen([sys.executable,"-c","import time; time.sleep(30)"]); print(p.pid,flush=True); time.sleep(30)'
        log, result = execute([sys.executable, '-c', script], timeout=0.3)
        self.assertTrue(result['timedOut'])
        self.assertTrue(result['reaped'])
        self.assertIn(int(log.strip()), result['processGroup']['initial'])
        self.assertEqual(result['processGroup']['remaining'], [])
        self.assertEqual(group_members(result['pid']), [])


if __name__ == '__main__':
    unittest.main()
