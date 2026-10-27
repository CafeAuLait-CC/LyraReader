"""Checks that measurement summaries reject incomplete or vacuous traces.

Includes the unmeasurable-presentation case: a trace whose callbacks all carry a zero Metal
timestamp must report `unavailable`, never `presented_fps: 0.0` with status "complete".
"""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('measure_native_scroll', Path(__file__).with_name('measure-native-scroll.py'))
measurement = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measurement)

perf_spec = importlib.util.spec_from_file_location(
    'measure_perf_trace', Path(__file__).with_name('measure-perf-trace.py'))
perf_trace = importlib.util.module_from_spec(perf_spec)
perf_spec.loader.exec_module(perf_trace)


class SummaryTests(unittest.TestCase):
    def trace(self):
        return [dict(kind='start', time=0),
                dict(kind='tick', time=.1, y=10, pending=2),
                dict(kind='frame', time=.2, surface=1, presented=1, cpu_us=1000),
                dict(kind='tick', time=.9, y=90, pending=1),
                dict(kind='frame', time=.9, surface=1, presented=1, cpu_us=2000),
                dict(kind='end', time=1)]

    def test_intervals_include_start_and_end_stalls(self):
        trace = self.trace()
        trace[2]['time'] = .8
        result = measurement.summarize(trace)
        self.assertEqual(result['submission_gap_max_ms'], 800)
        self.assertEqual(result['pending_tiles_max'], 2)
        self.assertEqual(result['draw_cpu_p95_ms'], 2)

    def test_incomplete_or_stalled_trace_is_not_a_measurement(self):
        with self.assertRaises(ValueError): measurement.summarize(self.trace()[:-1])
        trace = self.trace()
        trace[3]['y'] = 10
        with self.assertRaises(ValueError): measurement.summarize(trace)

    def test_reaching_the_end_early_does_not_measure_idle_time_as_scrolling(self):
        with self.assertRaises(ValueError): measurement.summarize(self.trace(), expected_distance=1000)

    def test_occlusion_cannot_be_counted_as_presented(self):
        trace = self.trace()
        trace[2]['presented'] = 0
        with self.assertRaises(ValueError): measurement.summarize(trace)

    def presentation_trace(self):
        trace = self.trace()
        trace[2].update(sequence=1, y=10)
        trace[4].update(sequence=2, y=90)
        # Callback arrival order differs from presentation order.
        trace.extend([dict(kind='presentation', time=.95, callback_time=1.2, surface=1, sequence=2, y=90),
                      dict(kind='presentation', time=.25, callback_time=1.3, surface=1, sequence=1, y=10)])
        return trace

    def test_actual_presentation_uses_host_times_and_full_window(self):
        result = measurement.summarize(self.presentation_trace())
        self.assertEqual(result['presented_fps'], 2)
        self.assertEqual(result['presentation_gap_max_ms'], 700)
        self.assertEqual(result['motion_presented_frames'], 2)
        self.assertEqual(result['presentation_measurement'], 'complete')

    def test_missing_callback_is_unknown_and_never_claims_fps_or_drop(self):
        result = measurement.summarize(self.presentation_trace()[:-1])
        self.assertEqual(result['presentation_measurement'], 'incomplete')
        self.assertIn('1 of 2', result['presentation_measurement_reason'])
        self.assertEqual(result['presentation_callbacks_missing'], 1)
        self.assertEqual(result['presentation_drops_reported'], 0)
        self.assertIsNone(result['presented_fps'])
        self.assertIsNone(result['presentation_gap_max_ms'])

    def test_zero_timestamp_is_reported_drop_not_presentation(self):
        trace = self.presentation_trace()
        trace[-1]['time'] = 0
        result = measurement.summarize(trace)
        self.assertEqual(result['presentation_drops_reported'], 1)
        self.assertEqual(result['presentation_zero_timestamps'], 1)
        self.assertEqual(result['presented_frames'], 1)
        self.assertEqual(result['presented_fps'], 1)
        self.assertEqual(result['presentation_gap_max_ms'], 950)

    def test_all_zero_timestamps_are_unavailable_not_zero_fps_or_all_drops(self):
        # The machine that produced this defect reported all 436 callbacks as zero:
        # `presented_fps: 0.0` with status "complete" reads as "rendered nothing".
        trace = self.presentation_trace()
        trace[-1]['time'] = trace[-2]['time'] = 0
        result = measurement.summarize(trace)
        self.assertEqual(result['presentation_measurement'], 'unavailable')
        self.assertIn('2 presentation callbacks reported a zero Metal timestamp',
                      result['presentation_measurement_reason'])
        self.assertIn('display asleep or window occluded',
                      result['presentation_measurement_reason'])
        self.assertEqual(result['presentation_zero_timestamps'], 2)
        for key in ('presentation_drops_reported', 'presented_frames', 'presented_fps',
                    'presentation_gap_p95_ms', 'presentation_gap_max_ms',
                    'presentation_gaps_over_33ms', 'motion_presented_frames'):
            self.assertIsNone(result[key], key)
        # Raw counts stay real, and so do the submission and draw-CPU figures.
        self.assertEqual(result['presentation_callbacks'], 2)
        self.assertEqual(result['presentation_callbacks_missing'], 0)
        self.assertEqual(result['submissions'], 2)
        self.assertEqual(result['submission_gap_max_ms'], 700)
        self.assertEqual(result['draw_cpu_p95_ms'], 2)

    def test_all_zero_timestamps_do_not_hide_missing_callbacks(self):
        trace = self.presentation_trace()[:-1]
        trace[-1]['time'] = 0
        result = measurement.summarize(trace)
        self.assertEqual(result['presentation_measurement'], 'unavailable')
        self.assertEqual(result['presentation_callbacks_missing'], 1)
        self.assertIsNone(result['presented_fps'])

    def test_duplicate_callback_rejected_and_wrong_surface_ignored(self):
        trace = self.presentation_trace()
        trace.append(dict(trace[-1], surface=2))
        self.assertEqual(measurement.summarize(trace)['presented_frames'], 2)
        trace.append(dict(trace[-2]))
        with self.assertRaises(ValueError): measurement.summarize(trace)

    def test_late_presentation_is_covered_but_not_counted_in_window(self):
        trace = self.presentation_trace()
        trace[-2]['time'] = 1.05
        result = measurement.summarize(trace)
        self.assertEqual(result['presentation_measurement'], 'complete')
        self.assertEqual(result['presentations_outside_window'], 1)
        self.assertEqual(result['presented_fps'], 1)

    def test_submission_only_trace_never_claims_actual_fps(self):
        result = measurement.summarize(self.trace())
        self.assertEqual(result['presentation_measurement'], 'unavailable')
        self.assertIn('legacy', result['presentation_measurement_reason'])
        self.assertNotIn('presented_fps', result)


class PerfTraceMetricTests(unittest.TestCase):
    """The P0 metrics: a presented time that was not reported must not become 0, a scroll stop
    pairs with the sharp commit at its own resting offset, and the first-frame attribution keeps
    main-actor wait apart from raster time."""

    def base(self):
        return [dict(kind='launch', time=100.0),
                dict(kind='document', phase='open_start', time=100.05, epoch=0),
                dict(kind='document', phase='opened', time=100.2, epoch=1, pages=115)]

    def test_unreported_presentation_time_is_null_not_zero(self):
        records = self.base() + [
            dict(kind='tile', phase='enqueue', source='thumbnail', page=0, lod=0, x=0, y=0,
                 time=100.4, epoch=1),
            dict(kind='tile', phase='start', source='thumbnail', page=0, lod=0, x=0, y=0,
                 time=100.5, epoch=1),
            dict(kind='tile', phase='done', source='thumbnail', page=0, lod=0, x=0, y=0,
                 time=100.6, epoch=1),
            dict(kind='frame', presented=True, presented_time='unavailable', time=100.7,
                 quads=1, epoch=1, token=0, offset_pt=0.0),
            dict(kind='viewport', seq=1, time=100.8, offset_pt=0.0, epoch=1,
                 path='page-raster', sharp=True),
            dict(kind='sharp', token=1, viewport_seq=1, offset_pt=0.0, epoch=1, time=100.9,
                 pages=[0], sources=['page-raster'], after_input_seq=1),
        ]
        result = perf_trace.summarize_run(records, 120)
        self.assertIsNone(result['first_present_ms'])
        self.assertTrue(result['presentation']['first_present_reason'])
        self.assertEqual(result['presentation']['frames_presented'], 0)
        self.assertEqual(result['presentation']['frames_presented_unavailable_timestamp'], 1)

    def test_scroll_stop_pairs_with_sharp_at_its_resting_offset(self):
        records = self.base() + [
            dict(kind='input', seq=1, time=101.0, offset_pt=50.0, destination_pt=50.0, epoch=1),
            dict(kind='viewport', seq=1, time=101.01, offset_pt=50.0, epoch=1,
                 path='page-raster', sharp=True),
            # A sharp commit at the old offset must not be paired with the new input.
            dict(kind='sharp', token=1, viewport_seq=1, offset_pt=0.0, epoch=1, time=101.02,
                 pages=[0], sources=['page-raster'], after_input_seq=1),
            dict(kind='sharp', token=2, viewport_seq=1, offset_pt=50.0, epoch=1, time=101.06,
                 pages=[1], sources=['page-raster'], after_input_seq=1),
        ]
        result = perf_trace.summarize_run(records, 120)
        self.assertEqual(result['gestures'], 1)
        self.assertEqual(result['unsettled_gestures'], 0)
        self.assertAlmostEqual(result['scroll_stop_to_sharp_ms']['p50'], 60.0)

    def test_first_frame_attribution_separates_raster_from_main_actor_wait(self):
        records = self.base() + [
            dict(kind='tile', phase='enqueue', source='page-raster', page=0, lod=0, x=0, y=0,
                 scale=2.0, time=100.4, epoch=1),
            dict(kind='tile', phase='start', source='page-raster', page=0, lod=0, x=0, y=0,
                 scale=2.0, time=100.9, epoch=1),
            dict(kind='stage', name='raster_dispatch', source='page-raster', page=0,
                 generation=7, ms=5.0, time=100.91),
            dict(kind='stage', name='raster_core', source='page-raster', page=0,
                 generation=7, ms=25.0, time=100.94),
            dict(kind='stage', name='raster_resume_scheduled', source='page-raster', page=0,
                 generation=7, time=100.95),
            dict(kind='stage', name='raster_resumed', source='page-raster', page=0,
                 generation=7, time=101.95),
            dict(kind='tile', phase='done', source='page-raster', page=0, lod=0, x=0, y=0,
                 scale=2.0, time=101.96, epoch=1),
            dict(kind='stage', name='upload', source='page-raster', page=0, generation=7,
                 ms=3.0, time=101.97),
            dict(kind='frame', presented=True, presented_time=102.06, quads=1, time=101.98,
                 epoch=1, token=0, offset_pt=0.0),
        ]
        result = perf_trace.summarize_run(records, 120)
        attribution = result['first_frame_attribution']
        self.assertEqual(attribution['dominant_bucket'], 'b')
        self.assertAlmostEqual(attribution['wait_task_start_ms'], 500.0)
        self.assertAlmostEqual(attribution['raster_core_ms'], 25.0)
        self.assertAlmostEqual(attribution['main_actor_resume_ms'], 1000.0)


if __name__ == '__main__': unittest.main()
