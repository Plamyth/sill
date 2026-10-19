import hashlib
from pathlib import Path
import unittest

from extract import ROOT, block, fixture


class ExtractionContract(unittest.TestCase):
    def test_worktree_anchor(self):
        self.assertEqual(ROOT, Path(__file__).resolve().parents[3])
        self.assertTrue((ROOT / 'visionOSClient/VisionSpatialInput.swift').is_file())

    def test_marker_must_be_unique(self):
        for source in ['', '.onEnded {} .onEnded {}']:
            with self.assertRaisesRegex(ValueError, 'expected one extraction marker'):
                block(source, '.onEnded {')

    def test_verbatim_callbacks(self):
        source = (ROOT / 'visionOSClient/VisionSpatialInput.swift').read_text()
        files, manifest = fixture()
        for name, marker in {
            'CHANGED': '.onChanged {', 'ENDED': '.onEnded {',
            'RECOGNIZING': '.onChange(of: recognizing) {',
            'GEOMETRY': '.onChange(of: geometry, initial: true) {', 'DISAPPEAR': '.onDisappear {',
        }.items():
            with self.subTest(callback=name):
                extracted = block(source, marker)
                closure = extracted[extracted.index('{'):]
                self.assertEqual(files['SpatialCallbacks.swift'].count(closure), 1)
                self.assertEqual(manifest['callback.' + name], hashlib.sha256(closure.encode()).hexdigest())
        self.assertNotIn('CALLBACK_', files['SpatialCallbacks.swift'])

    def test_verbatim_scroll_momentum(self):
        source = (ROOT / 'iOSClient/InputOverlay.swift').read_text()
        files, manifest = fixture()
        expected = 'import Foundation\nimport CoreFoundation\n' + block(source, 'final class ScrollMomentum: NSObject {') + '\n'
        self.assertEqual(files['ScrollMomentum.swift'], expected)
        self.assertEqual(manifest['scrollMomentum'], hashlib.sha256(expected.encode()).hexdigest())


if __name__ == '__main__':
    unittest.main()
