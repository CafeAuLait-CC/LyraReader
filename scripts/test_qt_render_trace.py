"""Checks exact scene/content association and refusal of misleading Qt measurements."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('qt_render_trace', Path(__file__).with_name('analyze-qt-render-trace.py'))
trace = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trace)


def content(instance='one', sequence=1, time=1, source='page-raster'):
    draws = [] if source == 'none' else [{'rect': [10, 20, 100, 200], 'source': source}]
    count = len(draws)
    return {'kind': 'content', 'time': time, 'instance': instance, 'content_seq': sequence,
            'epoch': 1, 'page_count': 1, 'anchor_page': 0, 'anchor_source': source,
            'context_mismatch': False, 'geometry_unsupported': False, 'truncated': False,
            'duplicate_page_items': False, 'sharp': source in ('page-raster', 'tile'),
            'offset_pt': 0, 'mode': 'pdf-canvas', 'pages': [0], 'sources': [source],
            'content_pages': [0] if count else [], 'page_quads': count,
            'paper_quads': 1, 'tile_quads': count if 'tile' in source else 0,
            'anchor_page_quads': count, 'surface': {'width': 1200, 'height': 820,
            'dpr': 1, 'graphics_api': 1, 'exposed': True},
            'page_sources': [{'page': 0, 'source': source, 'quads': draws}]}


def frame(commit, sequence=1, time=1.1, stage='scene-queued'):
    fields = ('instance', 'content_seq', 'epoch', 'anchor_page', 'anchor_source',
              'page_quads', 'anchor_page_quads', 'paper_quads', 'tile_quads',
              'content_pages', 'surface', 'offset_pt', 'mode',
              'geometry_unsupported', 'truncated')
    result = {key: copy.deepcopy(commit[key]) for key in fields}
    result.update(kind='frame', frame_seq=sequence, time=time, stage=stage,
                  presented=False, presented_time='unavailable')
    return result


def capture(*records, pair_stages=True):
    # A complete fixture has both independent callbacks for each scene frame.
    # Deliberately truncated fixtures opt out below.
    records = list(records)
    if pair_stages:
        identities = {(r['instance'], r['frame_seq'], r['stage'])
                      for r in records if r.get('kind') == 'frame'}
        for record in list(records):
            if record.get('kind') != 'frame':
                continue
            other = 'scene-submitted' if record['stage'] == 'scene-queued' else 'scene-queued'
            if (record['instance'], record['frame_seq'], other) not in identities:
                counterpart = copy.deepcopy(record)
                counterpart['stage'] = other
                records.append(counterpart)
    return [{'kind': 'trace-start', 'time': 0, 'schema_version': 1, 'backend': 'qt-scene'},
            *records, {'kind': 'trace-end', 'time': 100, 'dropped_records': 0}]


class QtTraceTests(unittest.TestCase):
    def test_mid_frame_attachment_boundary_is_visible_and_has_no_fabricated_frame(self):
        commit = content()
        boundary = {'kind': 'trace-boundary', 'time': .5, 'instance': 'one',
                    'stage': 'scene-queued', 'reason': 'observer-attached-after-frame-start'}
        result = trace.summarize(capture(boundary, commit, frame(commit)))
        self.assertTrue(result['complete'])
        self.assertEqual(result['capture_boundaries'], [{key: boundary[key] for key in ('time', 'instance', 'stage', 'reason')}])
        self.assertEqual(result['instances']['one']['scene_queued'], 1)
        self.assertIsNone(result['presented_fps'])

    def test_missing_callbacks_and_misplaced_header_make_measurement_incomplete(self):
        commit = content()
        for stage in ('scene-queued', 'scene-submitted'):
            result = trace.summarize(capture(commit, frame(commit, stage=stage), pair_stages=False))
            self.assertFalse(result['complete'])
            self.assertTrue(any('missing a queue or submission' in issue for issue in result['issues']))
        records = capture(commit, frame(commit))
        records[0], records[1] = records[1], records[0]
        self.assertFalse(trace.summarize(records)['complete'])

    def test_paper_only_interval_uses_scene_queue_time_and_never_presentation(self):
        paper, pixels = content(source='none'), content(sequence=2, time=2, source='history')
        result = trace.summarize(capture(paper, frame(paper), pixels, frame(pixels, sequence=2, time=2.1)))
        self.assertTrue(result['complete'])
        self.assertIsNone(result['presented_fps'])
        self.assertIsNone(result['gpu_time_ms'])
        self.assertFalse(result['physical_presentation_available'])
        epoch = result['instances']['one']['epochs'][0]
        self.assertEqual(epoch['anchor_source'], 'history')
        self.assertAlmostEqual(epoch['scene_paper_only_to_content_ms'], 1000)
        self.assertEqual(epoch['source_labels'], ['low-res history fallback'])

    def test_later_content_cannot_relabel_a_frozen_earlier_frame(self):
        old, new = content(source='history'), content(sequence=2, time=1.01)
        result = trace.summarize(capture(old, new, frame(old, time=1.02), frame(new, sequence=2, time=1.03)))
        self.assertTrue(result['complete'])
        self.assertEqual(result['instances']['one']['epochs'][0]['anchor_source'], 'history')

    def test_content_sequence_numbers_are_scoped_to_the_window_instance(self):
        first, second = content(source='history'), content(instance='two', source='tile')
        result = trace.summarize(capture(first, second, frame(first), frame(second)))
        self.assertEqual(result['instances']['one']['epochs'][0]['anchor_source'], 'history')
        self.assertEqual(result['instances']['two']['epochs'][0]['anchor_source'], 'tile')

    def test_queued_and_submitted_stages_must_keep_the_same_content(self):
        first, second = content(), content(sequence=2, time=1.01)
        with self.assertRaisesRegex(ValueError, 'different content'):
            trace.summarize(capture(first, second, frame(first), frame(second, stage='scene-submitted', time=1.2)))

    def test_missing_or_future_content_and_mutated_epoch_are_rejected(self):
        commit = content()
        for key, value in [('content_seq', 77), ('time', .1), ('epoch', 2), ('page_quads', 2)]:
            event = frame(commit)
            event[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                trace.summarize(capture(commit, event))

    def test_duplicate_commits_and_terminal_callbacks_are_rejected(self):
        commit = content()
        for records in [(commit, commit, frame(commit)), (commit, frame(commit), frame(commit))]:
            with self.assertRaisesRegex(ValueError, 'duplicate'):
                trace.summarize(capture(*records))

    def test_fake_presentation_is_rejected_even_with_a_valid_scene_frame(self):
        commit = content()
        for patch in [{'presented': True}, {'presented_time': 1.1}]:
            event = frame(commit)
            event.update(patch)
            with self.assertRaisesRegex(ValueError, 'presentation'):
                trace.summarize(capture(commit, event))

    def test_empty_or_nonfinite_geometry_cannot_prove_sharp_content(self):
        bad = content(source='none')
        bad['sharp'] = True
        with self.assertRaises(ValueError):
            trace.summarize(capture(bad, frame(bad)))
        for value in [0, -1, float('nan'), float('inf')]:
            bad = content()
            bad['page_sources'][0]['quads'][0]['rect'][2] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                trace.summarize(capture(bad, frame(bad)))

    def test_gaps_missing_end_and_unattributed_frames_are_incomplete(self):
        commit = content()
        normal = capture(commit, frame(commit))
        self.assertFalse(trace.summarize(normal[:-1])['complete'])
        lost = normal[:-1] + [{'kind': 'trace-gap', 'time': 2, 'dropped_records': 2}, normal[-1]]
        self.assertFalse(trace.summarize(lost)['complete'])
        unknown = {'kind': 'frame', 'time': 2, 'frame_seq': 2, 'instance': 'one',
                   'stage': 'scene-queued', 'unattributed': True,
                   'presented': False, 'presented_time': 'unavailable'}
        self.assertFalse(trace.summarize(capture(commit, frame(commit), unknown))['complete'])
        self.assertFalse(trace.summarize(capture())['complete'])

    def test_invalid_time_surface_and_quad_counts_are_rejected(self):
        for patch in [{'time': -1}, {'time': float('nan')}, {'anchor_page': 2}, {'anchor_page_quads': 2}]:
            commit = content()
            commit.update(patch)
            with self.subTest(patch=patch), self.assertRaises(ValueError):
                trace.summarize(capture(commit, frame(commit)))
        commit = content()
        commit['surface']['dpr'] = 0
        with self.assertRaises(ValueError):
            trace.summarize(capture(commit, frame(commit)))

    def test_stream_loader_bounds_nesting_arrays_and_string_allocation(self):
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / 'capture.jsonl'
            for value in [{'data': list(range(4097))}, {'data': 'x'*2049}]:
                path.write_text(trace._common.PREFIX + json.dumps(value) + '\n')
                with self.assertRaises(ValueError):
                    trace.load(path)
            nested = 0
            for _ in range(18):
                nested = {'nested': nested}
            path.write_text(trace._common.PREFIX + json.dumps(nested) + '\n')
            with self.assertRaisesRegex(ValueError, 'depth'):
                trace.load(path)
            path.write_bytes(trace._common.PREFIX.encode() + b' '* (trace.MAX_EVENT_BYTES+1))
            with self.assertRaisesRegex(ValueError, '1 MiB'):
                trace.load(path)

    def test_report_creation_never_overwrites_an_existing_file(self):
        commit = content()
        with tempfile.TemporaryDirectory() as scratch:
            path, output = Path(scratch)/'capture.jsonl', Path(scratch)/'protected.pdf'
            path.write_text(''.join(trace._common.PREFIX + json.dumps(r) + '\n' for r in capture(commit, frame(commit))))
            output.write_bytes(b'original bytes')
            result = subprocess.run([sys.executable, str(Path(__file__).with_name('analyze-qt-render-trace.py')), str(path), '--output', str(output)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(output.read_bytes(), b'original bytes')
            self.assertTrue(trace.summarize(trace.load(path))['complete'])


if __name__ == '__main__':
    unittest.main()
