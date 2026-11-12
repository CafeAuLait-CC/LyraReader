"""Regression coverage for baseline approval and capture-set integrity; no desktop required."""
import importlib.util
import argparse
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import sys

sys.dont_write_bytecode = True


spec = importlib.util.spec_from_file_location('visual_check', Path(__file__).with_name('check-visual.py'))
visual = importlib.util.module_from_spec(spec)
spec.loader.exec_module(visual)


class BaselineIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='lyra-visual-approval-')
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.report = {'schema_version': 1, 'status': 'candidate', 'environment': {}, 'captures': []}
        for sid in visual.EXPECTED_CAPTURES:
            name = sid + '.png'
            (self.directory / name).write_bytes(b'synthetic image bytes')
            self.report['captures'].append({'id': sid, 'file': name})
        self.write_report()

    def write_report(self):
        visual.write_json(self.directory / 'capture.json', self.report)

    def approve(self):
        visual.write_json(self.directory / 'approval.json', {
            'schema_version': 1, 'approved': True,
            'capture_manifest_sha256': visual.digest(self.directory / 'capture.json'),
            'sha256': {row['file']: visual.digest(self.directory / row['file']) for row in self.report['captures']},
        })

    def test_candidates_do_not_implicitly_become_baselines(self):
        visual.load_capture(self.directory)
        with self.assertRaisesRegex(ValueError, 'no explicit approval'):
            visual.verify_approval(self.directory, self.report)

    def test_approval_binds_image_bytes(self):
        self.approve()
        visual.verify_approval(self.directory, self.report)
        (self.directory / self.report['captures'][0]['file']).write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'does not match'):
            visual.verify_approval(self.directory, self.report)

    def test_approval_binds_environment_and_geometry_manifest(self):
        self.approve()
        self.report['environment']['backing_scale'] = 2
        self.write_report()
        with self.assertRaisesRegex(ValueError, 'does not match'):
            visual.verify_approval(self.directory, self.report)

    def test_failed_capture_cannot_pass_as_comparison_input(self):
        self.report['status'] = 'failed'
        self.write_report()
        with self.assertRaisesRegex(ValueError, 'failed or unsupported'):
            visual.load_capture(self.directory)

    def test_incomplete_and_duplicate_sets_are_rejected(self):
        self.report['captures'].pop()
        self.write_report()
        with self.assertRaisesRegex(ValueError, 'Missing, duplicated'):
            visual.load_capture(self.directory)
        self.report['captures'].append(self.report['captures'][0])
        self.write_report()
        with self.assertRaisesRegex(ValueError, 'Missing, duplicated'):
            visual.load_capture(self.directory)

    def test_missing_image_is_not_a_pass(self):
        (self.directory / self.report['captures'][0]['file']).unlink()
        with self.assertRaisesRegex(ValueError, 'Missing or invalid'):
            visual.load_capture(self.directory)

    def test_manifest_cannot_escape_capture_directory(self):
        self.report['captures'][0]['file'] = '../outside.png'
        self.write_report()
        with self.assertRaisesRegex(ValueError, 'Missing or invalid'):
            visual.load_capture(self.directory)

    def test_capture_refuses_to_overwrite_an_existing_directory(self):
        sentinel = self.directory / 'keep.txt'
        sentinel.write_text('existing results')
        args = argparse.Namespace(output=self.directory)
        with self.assertRaises(FileExistsError):
            visual.capture(args)
        self.assertEqual(sentinel.read_text(), 'existing results')

    def test_timeout_cannot_terminate_a_reused_pid(self):
        (self.directory / 'capture.pid').write_text('12345')
        with patch.object(visual.subprocess, 'run') as process, patch.object(visual.os, 'kill') as kill:
            process.return_value.returncode = 0
            process.return_value.stdout = '/unrelated/application\n'
            with self.assertRaisesRegex(ValueError, 'refusing to terminate'):
                visual.terminate_own_capture(self.directory)
            kill.assert_not_called()

    def test_unknown_suite_is_not_an_unvalidated_capture_set(self):
        self.report['suite'] = 'unknown'
        self.write_report()
        with self.assertRaisesRegex(ValueError, 'Unsupported capture suite'):
            visual.load_capture(self.directory)

    def test_reader_suite_requires_its_complete_distinct_set(self):
        self.report['suite'] = 'reader-shell'
        self.report['captures'] = []
        for sid in visual.CAPTURE_SUITES['reader-shell']:
            name = sid + '.png'
            (self.directory / name).write_bytes(b'synthetic reader image bytes')
            self.report['captures'].append({'id': sid, 'file': name})
        self.write_report()
        visual.load_capture(self.directory)
        self.report['captures'][-1] = {'id': '11-fullscreen-restored', 'file': '11-fullscreen-restored.png'}
        self.write_report()
        with self.assertRaisesRegex(ValueError, 'Missing, duplicated'):
            visual.load_capture(self.directory)

    def test_cross_suite_comparison_cannot_reuse_a_paper_baseline(self):
        reader = self.directory / 'reader'
        reader.mkdir()
        captures = []
        for sid in visual.CAPTURE_SUITES['reader-shell']:
            name = sid + '.png'
            (reader / name).write_bytes(b'reader pixels')
            captures.append({'id': sid, 'file': name})
        visual.write_json(reader / 'capture.json', {
            'schema_version': 1, 'suite': 'reader-shell', 'status': 'candidate', 'captures': captures,
        })
        args = argparse.Namespace(baseline=self.directory, actual=reader, output=self.directory / 'diff',
                                  allow_unreviewed=True, channel_tolerance=0)
        with patch.object(visual, 'compile_comparer') as compile_comparer:
            with self.assertRaisesRegex(ValueError, 'Capture suites differ'):
                visual.compare_runs(args)
            compile_comparer.assert_not_called()


class CommittedPaperBaselineTests(unittest.TestCase):
    def test_adopted_baselines_retain_their_reviewed_images_and_manifest(self):
        root = visual.ROOT / 'tests/visual-baselines/paper/macos-15.7.9-2560x1440-2x'
        for theme in ['en-light', 'en-dark']:
            with self.subTest(theme=theme):
                directory = root / theme
                report = visual.load_capture(directory)
                visual.verify_approval(directory, report)


if __name__ == '__main__':
    unittest.main()
