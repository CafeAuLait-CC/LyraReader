#!/usr/bin/env python3
"""Derive the P0 performance metrics from a `LYRA_READER_PERF_TRACE=1` run.

Build first: ./scripts/build-rust.sh && (cd apps/macos && swift build -c release --product LyraReader)
Run:        scripts/measure-perf-trace.py path/to/document.pdf
            scripts/measure-perf-trace.py path/to/document.pdf --jumps 3000:0.02,6000:0.98,9000:0.50,12000:0.02

The app is launched with `LYRA_READER_PERF_TRACE=1` and
`LYRA_READER_PERF_SCROLLS=<n>`, which performs n discrete wheel gestures through the real
`AppState.scroll(byScreenPoints:)` path (each followed by a full stop). Every number comes from
the trace; nothing is estimated here.

With `--jumps`, the harness instead sets `LYRA_READER_PERF_JUMPS=<ms:fraction,...>` and derives
the far-jump metrics from the same trace: the first presented frame that shows on-screen page
content (and which source it came from), the paper-blank/paper-only window, same-page revisit
hits, and tasks left over from the page the jump left. The hook calls
`AppState.scroll(toFraction:)`, the exact method a scroll-indicator thumb drag calls, but it is
not a synthesized pointer event; the output labels it as a model-path substitute.

What is real and what is model-level is kept apart on purpose:

* `first_present_ms` and any `*_presented_ms` use Metal's host presentation timestamp from a
  frame the compositor actually presented. When the display link reports nothing (asleep display,
  occluded window) the field is `null` with a reason — never 0, and never the CPU submit time
  standing in for the presentation time.
* `first_sharp_ms` and `scroll_stop_to_sharp_ms` are model-level: the moment the committed page
  list is fully sharp (every visible page covered at target LOD by a drawn sharp source). The
  matching presented frame is reported separately as `scroll_stop_to_sharp_presented_ms` and is
  `null` when Metal did not report a timestamp for it.
* `queue` wait/exec are wall-clock milliseconds around the shell's own task boundaries; they
  include main-actor scheduling but no GPU work.
"""
import argparse
import ctypes
import ctypes.util
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
PREFIX = 'lyra-reader-perf-trace: '


def percentile(values, fraction):
    values = sorted(values)
    return values[max(0, math.ceil(len(values) * fraction) - 1)] if values else None


def stats(values):
    if not values:
        return {'n': 0, 'p50': None, 'p95': None, 'max': None, 'mean': None}
    return {
        'n': len(values),
        'p50': percentile(values, .50),
        'p95': percentile(values, .95),
        'max': max(values),
        'mean': sum(values) / len(values),
    }


def load_records(log):
    records = []
    for line in Path(log).read_text().splitlines():
        if not line.startswith(PREFIX):
            continue
        try:
            record = json.loads(line[len(PREFIX):])
        except json.JSONDecodeError as error:
            raise ValueError(f'unparseable trace line: {error}: {line[:200]}') from error
        if 'time' in record and isinstance(record['time'], (int, float)):
            if not math.isfinite(record['time']) or record['time'] < 0:
                raise ValueError(f'record {record.get("kind")} has an invalid time')
        records.append(record)
    if not records:
        raise ValueError('trace contains no perf records (was LYRA_READER_PERF_TRACE=1 set?)')
    return records


def inputs_by_gesture(inputs, idle_ms):
    """Split the ordered input stream into gestures.

    A gesture ends at an input followed by more than `idle_ms` of silence (or the end of the
    run). The last input of a gesture is the "scroll stop" the sharp measurement starts from.
    """
    gestures = []
    current = []
    for index, record in enumerate(inputs):
        if current:
            gap_ms = (record['time'] - current[-1]['time']) * 1000
            if gap_ms > idle_ms:
                gestures.append(current)
                current = []
        current.append(record)
    if current:
        gestures.append(current)
    return [(gesture, gesture[-1]) for gesture in gestures]


def first_after(records, predicate, after):
    for record in records:
        if record['time'] >= after and predicate(record):
            return record
    return None


def presented_frames(records):
    return [r for r in records
            if r.get('kind') == 'frame' and r.get('presented') is True
            and isinstance(r.get('presented_time'), (int, float))
            and math.isfinite(r['presented_time']) and r['presented_time'] > 0]


def stages(records, name=None):
    return [r for r in records if r.get('kind') == 'stage'
            and (name is None or r.get('name') == name)]


def first_frame_attribution(records, first_document_frame, first_present):
    """Split the first document frame's latency into its stages, from trace timestamps alone.

    Answers the three-way question directly: (a) the raster task had not started, (b) it started
    but its result took long to reach the main actor, (c) the canvas/draw/present after the result
    dominates. Every number comes from a recorded event; a missing stage is reported as missing,
    never guessed. For a tile-path first frame the start/enqueue side is the latest tile of the
    same page before that completion (tiles share a page in the lifecycle records), while the
    dispatch/core/resume stages are exact per generation.
    """
    if not first_document_frame:
        return {'reason': 'no document frame was submitted'}
    submit = first_document_frame['time']
    upload = None
    for stage in stages(records, 'upload'):
        if stage['time'] <= submit:
            upload = stage
    if upload is None:
        return {'reason': 'no upload stage before the first document frame (trace has no stage records?)'}
    generation = upload.get('generation')
    group = {stage['name']: stage for stage in stages(records)
             if stage.get('generation') == generation}
    dispatch, core = group.get('raster_dispatch'), group.get('raster_core')
    scheduled, resumed = group.get('raster_resume_scheduled'), group.get('raster_resumed')
    if not (dispatch and core and scheduled and resumed):
        return {'generation': generation,
                'reason': 'the raster split is incomplete for the bitmap this frame drew'}
    page = upload.get('page')
    # The canvas labels every whole-page upload `page-raster`, while the raster stage knows
    # whether that bitmap was rendered as the sharp page raster or as a preview backdrop.
    source = dispatch.get('source', upload.get('source'))
    # Page rasters have one task per page/scale; tiles share a page, so the tile that this frame
    # uploaded is identified by the `done` record nearest after the resume. In both cases the
    # start/enqueue records are the latest before that completion.
    done = None
    for tile in records:
        if (tile.get('kind') == 'tile' and tile.get('phase') == 'done'
                and tile.get('source') == source and tile.get('page') == page
                and tile['time'] >= resumed['time'] and tile['time'] <= submit):
            if done is None or tile['time'] < done['time']:
                done = tile
    start = None
    for tile in records:
        if (tile.get('kind') == 'tile' and tile.get('phase') == 'start'
                and tile.get('source') == source and tile.get('page') == page
                and tile['time'] <= (done['time'] if done else resumed['time'])):
            start = tile
    enqueue = None
    if start is not None:
        for tile in records:
            if (tile.get('kind') == 'tile' and tile.get('phase') == 'enqueue'
                    and tile.get('source') == source and tile.get('page') == page
                    and tile['time'] <= start['time']):
                enqueue = tile
    wait_to_start = ((start['time'] - enqueue['time']) * 1000) if start and enqueue else None
    start_to_resumed = ((resumed['time'] - start['time']) * 1000) if start else None
    main_resume = (resumed['time'] - scheduled['time']) * 1000
    resumed_to_submit = (submit - resumed['time']) * 1000
    present_after_submit = ((first_present['presented_time'] - submit) * 1000
                            if first_present else None)
    task_after_start = start_to_resumed
    draw_present = ((present_after_submit or 0) + resumed_to_submit) if start else None
    buckets = {'a_task_not_started': wait_to_start, 'b_task_after_start': task_after_start,
               'c_draw_present': draw_present}
    measured = {key: value for key, value in buckets.items() if value is not None}
    dominant = max(measured, key=measured.get) if measured else None
    return {
        'generation': generation,
        'page': page,
        'wait_task_start_ms': wait_to_start,
        'task_after_start_ms': task_after_start,
        'dispatch_ms': dispatch.get('ms'),
        'raster_core_ms': core.get('ms'),
        'main_actor_resume_ms': main_resume,
        'start_to_resumed_other_ms': (None if start_to_resumed is None else
                                      start_to_resumed - (dispatch.get('ms') or 0)
                                      - (core.get('ms') or 0) - main_resume),
        'upload_ms': upload.get('ms'),
        'resumed_to_submit_ms': resumed_to_submit,
        'submit_to_present_ms': present_after_submit,
        'dominant': dominant,
        'dominant_bucket': {'a_task_not_started': 'a', 'b_task_after_start': 'b',
                            'c_draw_present': 'c'}.get(dominant),
    }


def scroll_stop_breakdown(records, inputs, sharps, idle_ms, presented, epoch_filter=None):
    """Split the last-input → sharp window of tile-path gestures into queue/raster/upload/draw.

    Only gestures where at least one pyramid tile finished inside the window are included (the
    page-raster path has its own `first_frame_attribution`). Queue-context entries say what else
    was consuming the queue in that window, so a "wait dominates" answer is actionable.
    """
    by_generation = {}
    for stage in stages(records):
        generation = stage.get('generation')
        if generation is not None:
            by_generation.setdefault(generation, []).append(stage)
    gestures = []
    all_wait, all_exec, all_core, all_dispatch, all_resume, all_sharp_present = [], [], [], [], [], []
    for _, stop in inputs_by_gesture(inputs, idle_ms):
        stop_offset = stop.get('destination_pt')
        if not isinstance(stop_offset, (int, float)):
            stop_offset = stop.get('offset_pt')
        if not isinstance(stop_offset, (int, float)):
            continue
        candidates = [sharp for sharp in sharps
                      if sharp['time'] >= stop['time']
                      and abs(sharp.get('offset_pt', -1e9) - stop_offset) <= 0.6
                      and sharp.get('after_input_seq', -1) >= stop.get('seq', 0)
                      and sharp.get('epoch') == stop.get('epoch')]
        if not candidates:
            continue
        sharp = candidates[0]
        tiles_done = [r for r in records
                      if r.get('kind') == 'tile' and r.get('phase') == 'done'
                      and r.get('source') == 'tile'
                      and stop['time'] < r['time'] <= sharp['time']]
        if not tiles_done:
            continue
        queue_in_window = [r for r in records if r.get('kind') == 'queue'
                           and stop['time'] < r['time'] <= sharp['time']]
        queue_tiles = [r for r in queue_in_window if r.get('category') == 'tile']
        resumed = [s for s in stages(records, 'raster_resumed')
                   if s.get('source') == 'tile' and stop['time'] < s['time'] <= sharp['time']]
        core_ms, dispatch_ms, main_resume_ms = [], [], []
        for stage in resumed:
            group = {s['name']: s for s in by_generation.get(stage.get('generation'), [])}
            if 'raster_core' in group and isinstance(group['raster_core'].get('ms'), (int, float)):
                core_ms.append(group['raster_core']['ms'])
            if 'raster_dispatch' in group and isinstance(group['raster_dispatch'].get('ms'), (int, float)):
                dispatch_ms.append(group['raster_dispatch']['ms'])
            if 'raster_resume_scheduled' in group:
                main_resume_ms.append((stage['time'] - group['raster_resume_scheduled']['time']) * 1000)
        uploads = [s for s in stages(records, 'upload') if s.get('source') == 'tile'
                   and stop['time'] < s['time'] <= sharp['time']]
        presented_frame = next((f for f in presented
                                if f.get('token', 0) >= sharp.get('token', 0)
                                and f['presented_time'] >= sharp['time']
                                and f.get('epoch') == sharp.get('epoch')
                                and abs(f.get('offset_pt', -1e9) - stop_offset) <= 0.6), None)
        context = {}
        for record in queue_in_window:
            category = record.get('category')
            entry = context.setdefault(category, {'count': 0, 'wait_ms_sum': 0.0})
            entry['count'] += 1
            if isinstance(record.get('wait_ms'), (int, float)):
                entry['wait_ms_sum'] += record['wait_ms']
        waits = [r['wait_ms'] for r in queue_tiles if isinstance(r.get('wait_ms'), (int, float))]
        execs = [r['exec_ms'] for r in queue_tiles if isinstance(r.get('exec_ms'), (int, float))]
        all_wait.extend(waits)
        all_exec.extend(execs)
        all_core.extend(core_ms)
        all_dispatch.extend(dispatch_ms)
        all_resume.extend(main_resume_ms)
        if presented_frame:
            all_sharp_present.append((presented_frame['presented_time'] - sharp['time']) * 1000)
        gestures.append({
            'offset_pt': stop_offset,
            'tiles': len(tiles_done),
            'queue_wait_ms': stats(waits),
            'task_exec_ms': stats(execs),
            'raster_core_ms': stats(core_ms),
            'main_actor_resume_ms': stats(main_resume_ms),
            'upload_ms_sum': sum(s.get('ms') or 0 for s in uploads),
            'sharp_to_presented_ms': ((presented_frame['presented_time'] - sharp['time']) * 1000)
                                     if presented_frame else None,
            'queue_context': context,
        })
    if not gestures:
        return {'gestures': 0, 'reason': 'no tile-path gesture produced a sharp commit in this run'}
    context = {}
    for gesture in gestures:
        for category, entry in gesture['queue_context'].items():
            target = context.setdefault(category, {'count': 0, 'wait_ms_sum': 0.0})
            target['count'] += entry['count']
            target['wait_ms_sum'] += entry['wait_ms_sum']
    return {
        'gestures': len(gestures),
        'tiles': sum(g['tiles'] for g in gestures),
        'queue_wait_ms': stats(all_wait),
        'task_exec_ms': stats(all_exec),
        'raster_core_ms': stats(all_core),
        'raster_dispatch_ms': stats(all_dispatch),
        'main_actor_resume_ms': stats(all_resume),
        'raw': {'queue_wait_ms': all_wait, 'task_exec_ms': all_exec,
                'raster_core_ms': all_core, 'raster_dispatch_ms': all_dispatch,
                'main_actor_resume_ms': all_resume},
        'upload_ms_sum': sum(g['upload_ms_sum'] for g in gestures),
        'sharp_to_presented_ms': stats(all_sharp_present),
        'queue_context': context,
        'per_gesture': gestures,
    }


class _CGPoint(ctypes.Structure):
    _fields_ = [('x', ctypes.c_double), ('y', ctypes.c_double)]


def _quartz():
    """CoreGraphics mouse posting, used only to drive the real scroll-indicator thumb."""
    cg = ctypes.CDLL(ctypes.util.find_library('CoreGraphics'))
    cf = ctypes.CDLL(ctypes.util.find_library('CoreFoundation'))
    cg.CGEventCreateMouseEvent.restype = ctypes.c_void_p
    cg.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, _CGPoint,
                                            ctypes.c_uint32]
    cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
    cf.CFRelease.argtypes = [ctypes.c_void_p]
    return cg, cf


def parse_slider_plan(raw):
    """Parse `ms:fraction,...` targets for real scroll-indicator drags.

    Each entry is the time (ms after process launch) to start a thumb drag and the scroll
    fraction to release it at. The drag starts where the previous one ended (0 for the first).
    """
    targets = []
    for item in raw.split(','):
        item = item.strip()
        if not item:
            continue
        parts = item.split(':')
        if len(parts) != 2:
            raise ValueError(f'slider entry "{item}" is not ms:fraction')
        try:
            milliseconds = int(parts[0])
            fraction = float(parts[1])
        except ValueError as error:
            raise ValueError(f'slider entry "{item}" is not ms:fraction') from error
        if milliseconds < 0 or not math.isfinite(fraction) or not 0 <= fraction <= 1:
            raise ValueError(f'slider entry "{item}" needs ms >= 0 and a fraction in 0..1')
        targets.append((milliseconds, fraction))
    if not targets:
        raise ValueError('the slider plan is empty')
    for (before, _), (after, _) in zip(targets, targets[1:]):
        if after <= before:
            raise ValueError('slider times must increase')
    return targets


def drive_scroll_indicator_drag(bounds, start_fraction, end_fraction):
    """Post a real mouse drag on the indicator's thumb.

    `bounds` is the window's `x,y,width,height` in screen points, as reported by the
    Accessibility helper. The lane is 13 pt wide at the canvas's trailing edge; the tab row and
    toolbar above it are 44 pt each. For CR1 at 100%/400% the thumb is the 44 pt minimum, so a
    press 20 pt below the thumb's top and the same offset during the drag gives an exact
    fraction mapping. No product hook is involved: AppKit delivers these events to SwiftUI's
    DragGesture, which calls `AppState.scroll(toFraction:)` exactly as a hand would.
    """
    x, y, width, height = (float(value) for value in bounds.split(','))
    lane_x = x + width - 6.5
    content_top = y + 88.0
    track = height - 88.0
    thumb = max(44.0, track * 0.0081)
    travel = max(0.0, track - thumb)
    grab = min(20.0, thumb / 2)
    start_y = content_top + start_fraction * travel + grab
    end_y = content_top + end_fraction * travel + grab
    cg, cf = _quartz()

    def post(kind, point_y):
        event = cg.CGEventCreateMouseEvent(None, kind, _CGPoint(lane_x, point_y), 0)
        cg.CGEventPost(0, event)
        cf.CFRelease(event)

    post(5, start_y)       # move to the thumb
    time.sleep(0.03)
    post(1, start_y)       # left mouse down
    time.sleep(0.05)
    steps = 40
    for step in range(1, steps + 1):
        fraction = start_fraction + (end_fraction - start_fraction) * step / steps
        post(6, content_top + fraction * travel + grab)  # left mouse dragged
        time.sleep(0.02)
    post(2, end_y)         # left mouse up
    return {'lane_x': lane_x, 'start_y': start_y, 'end_y': end_y,
            'track_height': track, 'thumb_height': thumb, 'travel': travel,
            'grab_offset': grab, 'steps': steps}


CONTENT_SOURCES = ('tile', 'page-raster', 'preview', 'history', 'thumbnail',
                   'previous-tile', 'previous-raster', 'partial-tile', 'none')


def parse_jump_plan(raw):
    """Parse `LYRA_READER_PERF_JUMPS` syntax (`ms:fraction,...`) into a validated plan."""
    jumps = []
    for item in raw.split(','):
        item = item.strip()
        if not item:
            continue
        parts = item.split(':')
        if len(parts) != 2:
            raise ValueError(f'jump "{item}" is not ms:fraction')
        try:
            milliseconds = int(parts[0])
            fraction = float(parts[1])
        except ValueError as error:
            raise ValueError(f'jump "{item}" is not ms:fraction') from error
        if milliseconds < 0 or not math.isfinite(fraction) or not 0 <= fraction <= 1:
            raise ValueError(f'jump "{item}" needs ms >= 0 and a finite fraction in 0..1')
        jumps.append((milliseconds, fraction))
    if not jumps:
        raise ValueError('the jump plan is empty')
    for (before, _), (after, _) in zip(jumps, jumps[1:]):
        if after <= before:
            raise ValueError('jump times must increase')
    return jumps


def source_label(page, source, anchor):
    """A reader-facing name for one content source, tied to the page it belongs to."""
    if source == 'none':
        return 'none'
    target = page == anchor
    if source in ('page-raster', 'tile'):
        return ('target-page sharp ' if target else 'adjacent-page sharp ') + source
    if source == 'history':
        return 'low-res history fallback'
    if source == 'thumbnail':
        return 'thumbnail backdrop'
    if source == 'preview':
        return 'page preview'
    if source == 'previous-tile':
        return 'previous-LOD tile'
    if source == 'previous-raster':
        return 'previous page raster'
    if source == 'partial-tile':
        return 'partial target-LOD tile'
    return source


def _pages_of(record):
    return record.get('pages') if isinstance(record.get('pages'), list) else []


def _sources_of(record):
    return record.get('sources') if isinstance(record.get('sources'), list) else []


def _content_after(contents, after, offset, epoch, require_content=False):
    for record in contents:
        if record['time'] < after or record.get('epoch') != epoch:
            continue
        if not isinstance(record.get('offset_pt'), (int, float)):
            continue
        if abs(record['offset_pt'] - offset) > 0.6:
            continue
        if require_content and all(source == 'none' for source in _sources_of(record)):
            continue
        return record
    return None


def _presented_at(frames, after, offset, epoch):
    """Presented frames at the jumped-to offset, in presentation order."""
    return sorted(
        (frame for frame in frames
         if frame['presented_time'] >= after
         and frame.get('epoch') == epoch
         and isinstance(frame.get('offset_pt'), (int, float))
         and abs(frame['offset_pt'] - offset) <= 0.6),
        key=lambda frame: frame['presented_time'])


def _stale_tasks(records, input_time, window_end, destination_band):
    """Work that was already queued when the jump input landed and finished afterwards for pages
    the new band does not show. Cost is task latency (`exec_ms`), not pure raster."""
    work = {}
    for record in records:
        if record.get('kind') != 'tile':
            continue
        key = (record.get('source'), record.get('page'), record.get('lod'),
               record.get('x'), record.get('y'))
        work.setdefault(key, {})[record.get('phase')] = record
    stale, stale_pages = [], set()
    for phases in work.values():
        enqueue, done = phases.get('enqueue'), phases.get('done')
        page = (enqueue or done or {}).get('page')
        if enqueue is None or done is None or page is None:
            continue
        if enqueue['time'] >= input_time or done['time'] < input_time:
            continue
        if done['time'] > window_end:
            continue
        if page in destination_band:
            continue
        stale.append(done)
        stale_pages.add(page)
    # An upload of a page outside the new band is background work, not evidence of a stale
    # visible upload; it is reported separately rather than folded into "stale tasks".
    uploads = [record for record in records
               if record.get('kind') == 'stage' and record.get('name') == 'upload'
               and input_time < record['time'] <= window_end
               and isinstance(record.get('page'), int)
               and record['page'] not in destination_band]
    return {
        'task_count': len(stale),
        'pages': sorted(stale_pages),
        'sources': sorted({record.get('source') for record in stale}),
        'exec_ms': sum(record.get('exec_ms') or 0 for record in stale),
        'outside_band_upload_count': len(uploads),
        'outside_band_upload_pages': sorted({record['page'] for record in uploads}),
    }


def far_jump_metrics(records, jumps):
    """Metric 1 (first non-empty content), 2 (paper-only window) and 3 (same-page revisit).

    Every number is trace-derived. Presented durations use Metal host presentation timestamps of
    frames whose page list carries the jumped-to offset; the model-level first content commit is
    reported separately and never substituted for a presentation time. A frame shows content
    only when at least one **on-screen page bitmap quad** was submitted: paper, the clear surface,
    selection tints and annotation overlays do not count. The paper-only sub-window uses presented
    timestamps when the paper frame has one; when Metal returned a zero host timestamp for that
    frame the duration is `null` with the model-level submit-to-content number reported separately.
    """
    fraction_inputs = [record for record in records
                       if record.get('kind') == 'input' and record.get('source') == 'fraction']
    contents = [record for record in records if record.get('kind') == 'content']
    contents.sort(key=lambda record: record['time'])
    contents_by_seq = {record.get('content_seq'): record for record in contents
                       if isinstance(record.get('content_seq'), int)}
    frames = [record for record in records if record.get('kind') == 'frame']
    numeric_frames = presented_frames(records)
    sharps = [record for record in records if record.get('kind') == 'sharp']
    raster = [record for record in records if record.get('kind') == 'raster']
    opened = next((record for record in records if record.get('kind') == 'document'
                   and record.get('phase') == 'opened'), None)
    start_pages = set()
    if opened is not None:
        first_open_content = next((record for record in contents
                                   if record['time'] >= opened['time']), None)
        if first_open_content is not None:
            start_pages = set(_pages_of(first_open_content))

    def source_labels(page_sources, anchor):
        return [source_label(page, source, anchor)
                for page, source in page_sources if source != 'none']

    def frame_sources(frame, anchor):
        content = contents_by_seq.get(frame.get('content_seq'))
        if content is None:
            return {}, 'unavailable'
        mapping = dict(zip(_pages_of(content), _sources_of(content)))
        pages = frame.get('content_pages') or []
        selected = {page: mapping.get(page, 'unavailable') for page in pages}
        return selected, mapping.get(anchor, 'none')

    seen_pages = set(start_pages)
    jumps_out = []
    previous_anchor = min(start_pages) if start_pages else 0
    previous_pages = set(start_pages)
    previous_offset = 0.0
    for index, ((planned_ms, planned_fraction), input_record) in enumerate(zip(jumps, fraction_inputs)):
        offset = input_record.get('destination_pt')
        if not isinstance(offset, (int, float)):
            offset = input_record.get('offset_pt')
        epoch = input_record.get('epoch')
        input_time = input_record['time']
        commit = _content_after(contents, input_time, offset, epoch)
        content_commit = _content_after(contents, input_time, offset, epoch, require_content=True)
        paper_commit = next(
            (record for record in contents
             if record['time'] >= input_time
             and record.get('epoch') == epoch
             and isinstance(record.get('offset_pt'), (int, float))
             and abs(record['offset_pt'] - offset) <= 0.6
             and all(source == 'none' for source in _sources_of(record))), None)
        destination_pages = set(_pages_of(commit)) if commit else set()
        destination_band = set(commit.get('band_pages') or commit.get('pages') or []) if commit else set()
        anchor = commit.get('anchor_page') if commit else None
        frames_at_offset = sorted(
            (frame for frame in frames
             if frame['time'] >= input_time
             and frame.get('epoch') == epoch
             and isinstance(frame.get('offset_pt'), (int, float))
             and abs(frame['offset_pt'] - offset) <= 0.6),
            key=lambda frame: frame['time'])
        timed_at_offset = [frame for frame in frames_at_offset
                           if isinstance(frame.get('presented_time'), (int, float))
                           and frame['presented_time'] > 0]

        def first_timed(predicate):
            return next((frame for frame in timed_at_offset if predicate(frame)), None)

        first_any = first_timed(lambda frame: (frame.get('page_quads') or 0) > 0)
        first_anchor = first_timed(lambda frame: (frame.get('anchor_page_quads') or 0) > 0)
        first_paper = next(
            (frame for frame in frames_at_offset
             if frame.get('presented') is True
             and (frame.get('page_quads') or 0) == 0
             and (frame.get('paper_quads') or 0) > 0), None)
        first_blank = next(
            (frame for frame in frames_at_offset
             if frame.get('presented') is True and (frame.get('page_quads') or 0) == 0), None)

        def presented_ms(frame):
            if frame is None or not isinstance(frame.get('presented_time'), (int, float)):
                return None
            return (frame['presented_time'] - input_time) * 1000

        presented_sources, presented_anchor_source = (
            frame_sources(first_any, anchor) if first_any is not None else ({}, 'none'))
        if content_commit is not None:
            commit_sources = {page: source for page, source in
                              zip(_pages_of(content_commit), _sources_of(content_commit))}
            commit_anchor_source = commit_sources.get(anchor, 'none')
        else:
            commit_sources, commit_anchor_source = {}, 'none'
        paper_available = bool(first_paper is not None and isinstance(
            first_paper.get('presented_time'), (int, float)))
        paper_subwindow = None
        if paper_available and first_any is not None:
            paper_subwindow = max(0.0, (first_any['presented_time']
                                        - first_paper['presented_time']) * 1000)
        paper_submit_window = None
        if first_paper is not None and first_any is not None:
            paper_submit_window = (first_any['presented_time'] - first_paper['time']) * 1000

        sharp = next((record for record in sharps
                      if record['time'] >= input_time
                      and record.get('epoch') == epoch
                      and isinstance(record.get('offset_pt'), (int, float))
                      and abs(record['offset_pt'] - offset) <= 0.6
                      and record.get('after_input_seq', -1) >= input_record.get('seq', 0)),
                     None)
        sharp_frame = None
        if sharp is not None:
            sharp_frame = next((frame for frame in numeric_frames
                                if frame.get('token', 0) >= sharp.get('token', 0)
                                and frame['presented_time'] >= sharp['time']
                                and frame.get('epoch') == epoch
                                and isinstance(frame.get('offset_pt'), (int, float))
                                and abs(frame['offset_pt'] - offset) <= 0.6), None)

        revisit = bool(anchor is not None and anchor in seen_pages
                       and anchor not in previous_pages and anchor != previous_anchor)
        distance = abs(anchor - previous_anchor) if anchor is not None else None
        next_input_time = (fraction_inputs[index + 1]['time']
                           if index + 1 < len(fraction_inputs) else None)
        window_end = next_input_time if next_input_time is not None else (
            (first_any['presented_time'] + 1.0) if first_any is not None else input_time + 3.0)
        window_end = max(window_end, input_time)

        anchor_events = [record for record in raster
                         if record.get('page') == anchor
                         and input_time < record['time'] <= window_end]
        anchor_page_raster_enqueues = [record for record in records
                                       if record.get('kind') == 'tile'
                                       and record.get('phase') == 'enqueue'
                                       and record.get('source') in ('page-raster', 'preview')
                                       and record.get('page') == anchor
                                       and input_time < record['time'] <= window_end]
        anchor_page_raster_before = [record for record in records
                                     if record.get('kind') == 'tile'
                                     and record.get('phase') == 'done'
                                     and record.get('source') in ('page-raster', 'preview')
                                     and record.get('page') == anchor
                                     and record['time'] < input_time]
        anchor_uploads = [record for record in records
                          if record.get('kind') == 'stage' and record.get('name') == 'upload'
                          and record.get('page') == anchor
                          and input_time < record['time'] <= window_end]
        stale = _stale_tasks(records, input_time, window_end, destination_band)

        jumps_out.append({
            'index': index,
            'planned_ms': planned_ms,
            'planned_fraction': planned_fraction,
            'input_time': input_time,
            'from_offset_pt': previous_offset,
            'destination_offset_pt': offset,
            'anchor_page': anchor,
            'distance_pages': distance,
            'destination_pages': sorted(destination_pages),
            'destination_band_pages': sorted(destination_band),
            'revisit': revisit,
            'initial_visit': bool(anchor is not None and anchor in start_pages),
            'first_content_presented_ms': presented_ms(first_any),
            'first_content_presented_sources': source_labels(
                sorted(presented_sources.items()), anchor),
            'first_content_presented_anchor_source': presented_anchor_source,
            'first_anchor_content_presented_ms': presented_ms(first_anchor),
            'first_content_commit_ms': ((content_commit['time'] - input_time) * 1000)
                                       if content_commit else None,
            'first_content_commit_sources': source_labels(
                sorted(commit_sources.items()), anchor),
            'first_content_commit_anchor_source': commit_anchor_source,
            'paper_drawn': first_paper is not None,
            'paper_frame_presented_time_available': paper_available,
            'first_paper_presented_ms': presented_ms(first_paper),
            'first_blank_presented_ms': presented_ms(first_blank),
            'paper_submit_to_content_presented_ms': paper_submit_window,
            'paper_only_subwindow_ms': paper_subwindow,
            'paper_commit_ms': ((paper_commit['time'] - input_time) * 1000)
                               if paper_commit else None,
            'paper_commit_to_content_presented_ms':
                ((first_any['presented_time'] - paper_commit['time']) * 1000)
                if paper_commit is not None and first_any is not None else None,
            'paper_quads_on_first_content_frame': first_any.get('paper_quads') if first_any else None,
            'paper_blank_ms': presented_ms(first_any),
            'sharp_commit_ms': ((sharp['time'] - input_time) * 1000) if sharp else None,
            'sharp_presented_ms': presented_ms(sharp_frame),
            'sharp_sources': sharp.get('sources') if sharp else None,
            'frames_at_offset': len(frames_at_offset),
            'frames_presented_at_offset': len(timed_at_offset),
            'frames_without_presented_timestamp': sum(
                1 for frame in frames_at_offset
                if frame.get('presented') is True
                and not (isinstance(frame.get('presented_time'), (int, float))
                         and frame['presented_time'] > 0)),
            'frames_occluded_at_offset': sum(1 for frame in frames_at_offset
                                             if frame.get('presented') is False),
            'stale_tasks': stale,
            'cache': {
                'raster_events': len(anchor_events),
                'repeat_after_eviction': sum(1 for record in anchor_events
                                             if record.get('class') == 'repeat-after-eviction'),
                'upload_after_cache_hit': sum(1 for record in anchor_events
                                              if record.get('class') == 'upload-after-cache-hit'),
                'new_page_raster_tasks': len(anchor_page_raster_enqueues),
                'page_raster_rastered_before_jump': bool(anchor_page_raster_before),
                'page_raster_rerasterized': bool(anchor_page_raster_before
                                                 and anchor_page_raster_enqueues),
                'anchor_uploads': len(anchor_uploads),
            },
            'content_seq': commit.get('content_seq') if commit else None,
            'first_content_frame_content_seq': first_any.get('content_seq') if first_any else None,
        })
        previous_offset = offset
        previous_anchor = anchor if anchor is not None else previous_anchor
        previous_pages = destination_pages
        seen_pages |= destination_pages

    return {
        'planned_jumps': len(jumps),
        'fraction_inputs': len(fraction_inputs),
        'jumps': jumps_out,
        'metric': 'first_content_presented_ms = jump input to the first presented frame whose '
                  'page list submitted at least one on-screen page bitmap quad at the jumped-to '
                  'offset; the source is classified (sharp page-raster/tile, page preview, '
                  'low-res history, thumbnail). Model-level first_content_commit_ms is the commit '
                  'that put that content into the drawn list, never a presentation time. '
                  'paper_blank_ms is the same presented window; paper_only_subwindow_ms needs a '
                  'host timestamp on the paper-only frame and is null when Metal returned zero '
                  '(the model-level paper_submit_to_content_presented_ms is reported instead).',
    }


def slider_gesture_metrics(records, plan):
    """Metric 4 for real scroll-indicator thumb drags.

    A drag emits one `scroll(toFraction:)` input per pointer tick. The "stop" is the last input
    of the gesture (the mouse-up itself changes no scroll position), so `*_after_stop` starts at
    the last real scroll input. `first_target_content_since_drag_start_ms` is the longer window
    that includes the drag, because the destination page changes continuously while the thumb
    moves. Timings are Metal presentation timestamps; model-level commits are reported apart.
    """
    fraction_inputs = [record for record in records
                       if record.get('kind') == 'input' and record.get('source') == 'fraction']
    gestures = inputs_by_gesture(fraction_inputs, 120)
    contents = [record for record in records if record.get('kind') == 'content']
    contents.sort(key=lambda record: record['time'])
    contents_by_seq = {record.get('content_seq'): record for record in contents
                       if isinstance(record.get('content_seq'), int)}
    frames = [record for record in records if record.get('kind') == 'frame']
    timed = presented_frames(records)
    sharps = [record for record in records if record.get('kind') == 'sharp']
    raster = [record for record in records if record.get('kind') == 'raster']

    def content_at(time_value, offset):
        return next((record for record in contents
                     if record['time'] >= time_value
                     and abs(record.get('offset_pt', -1e9) - offset) <= 0.6
                     and any(source != 'none' for source in _sources_of(record))), None)

    def frames_at(offset):
        return sorted((frame for frame in frames
                       if isinstance(frame.get('offset_pt'), (int, float))
                       and abs(frame['offset_pt'] - offset) <= 0.6),
                      key=lambda frame: frame['time'])

    seen_pages = set()
    previous_pages = set()
    out = []
    for index, ((planned_ms, target), (gesture, stop)) in enumerate(zip(plan, gestures)):
        start = gesture[0]
        stop_offset = stop.get('destination_pt')
        if not isinstance(stop_offset, (int, float)):
            stop_offset = stop.get('offset_pt')
        final_commit = content_at(stop['time'], stop_offset)
        anchor = final_commit.get('anchor_page') if final_commit else None
        band = set(final_commit.get('band_pages') or final_commit.get('pages') or []) \
            if final_commit else set()
        before = [record for record in contents if record['time'] < start['time']]
        start_anchor = before[-1].get('anchor_page') if before else None
        if start_anchor is None and before:
            pages = _pages_of(before[-1])
            start_anchor = min(pages) if pages else None
        distance = abs(anchor - start_anchor) if anchor is not None and start_anchor is not None else None
        revisit = bool(anchor is not None and anchor in seen_pages
                       and anchor not in previous_pages)
        window_end = (gestures[index + 1][0][0]['time']
                      if index + 1 < len(gestures) else stop['time'] + 2.0)
        frames_window = [frame for frame in timed
                         if frame['presented_time'] >= stop['time']
                         and abs(frame.get('offset_pt', -1e9) - stop_offset) <= 0.6]
        first_after_stop = next((frame for frame in frames_window
                                 if (frame.get('page_quads') or 0) > 0), None)
        first_target_since_start = next(
            (frame for frame in timed
             if frame['presented_time'] >= start['time']
             and anchor is not None
             and anchor in (frame.get('content_pages') or [])), None)
        stop_to_target_gap = ((first_target_since_start['presented_time'] - stop['time']) * 1000
                              if first_target_since_start is not None else None)
        sharp = next((record for record in sharps
                      if record['time'] >= stop['time']
                      and isinstance(record.get('offset_pt'), (int, float))
                      and abs(record['offset_pt'] - stop_offset) <= 0.6
                      and record.get('after_input_seq', -1) >= stop.get('seq', 0)), None)
        sharp_frame = None
        if sharp is not None:
            sharp_frame = next((frame for frame in timed
                                if frame.get('token', 0) >= sharp.get('token', 0)
                                and frame['presented_time'] >= sharp['time']
                                and abs(frame.get('offset_pt', -1e9) - stop_offset) <= 0.6),
                               None)
        sources = []
        if first_after_stop is not None:
            content = contents_by_seq.get(first_after_stop.get('content_seq'))
            if content is not None:
                mapping = dict(zip(_pages_of(content), _sources_of(content)))
                sources = [source_label(page, mapping.get(page, 'unavailable'), anchor)
                           for page in (first_after_stop.get('content_pages') or [])]
        anchor_events = [record for record in raster
                         if record.get('page') == anchor
                         and stop['time'] < record['time'] <= window_end]
        stop_commit = content_at(stop['time'], stop_offset)
        stop_sources = []
        stop_anchor_source = 'none'
        if stop_commit is not None:
            mapping = dict(zip(_pages_of(stop_commit), _sources_of(stop_commit)))
            stop_sources = [source_label(page, mapping.get(page, 'unavailable'), anchor)
                            for page in _pages_of(stop_commit) if mapping.get(page) != 'none']
            stop_anchor_source = mapping.get(anchor, 'none')
        frames_after_stop = [frame for frame in frames_at(stop_offset)
                             if frame['time'] >= stop['time']]
        first_paper = next(
            (frame for frame in frames_after_stop
             if frame.get('presented') is True
             and (frame.get('page_quads') or 0) == 0
             and (frame.get('paper_quads') or 0) > 0), None)
        paper_available = bool(first_paper is not None
                               and isinstance(first_paper.get('presented_time'), (int, float)))
        paper_subwindow = None
        if paper_available and first_after_stop is not None:
            paper_subwindow = max(0.0, (first_after_stop['presented_time']
                                        - first_paper['presented_time']) * 1000)
        paper_submit_window = None
        if first_paper is not None and first_after_stop is not None:
            paper_submit_window = (first_after_stop['presented_time']
                                   - first_paper['time']) * 1000
        paper_commit = next(
            (record for record in contents
             if record['time'] >= stop['time']
             and abs(record.get('offset_pt', -1e9) - stop_offset) <= 0.6
             and all(source == 'none' for source in _sources_of(record))), None)
        anchor_page_raster_enqueues = [record for record in records
                                       if record.get('kind') == 'tile'
                                       and record.get('phase') == 'enqueue'
                                       and record.get('source') in ('page-raster', 'preview')
                                       and record.get('page') == anchor
                                       and stop['time'] < record['time'] <= window_end]
        anchor_page_raster_before = [record for record in records
                                     if record.get('kind') == 'tile'
                                     and record.get('phase') == 'done'
                                     and record.get('source') in ('page-raster', 'preview')
                                     and record.get('page') == anchor
                                     and record['time'] < stop['time']]
        anchor_uploads = [record for record in records
                          if record.get('kind') == 'stage' and record.get('name') == 'upload'
                          and record.get('page') == anchor
                          and stop['time'] < record['time'] <= window_end]
        stale = _stale_tasks(records, stop['time'], window_end, band)
        out.append({
            'index': index,
            'planned_ms': planned_ms,
            'target_fraction': target,
            'start_input_time': start['time'],
            'stop_input_time': stop['time'],
            'input_count': len(gesture),
            'drag_duration_ms': (stop['time'] - start['time']) * 1000,
            'start_anchor_page': start_anchor,
            'final_anchor_page': anchor,
            'distance_pages': distance,
            'final_offset_pt': stop_offset,
            'final_pages': sorted(set(_pages_of(final_commit))) if final_commit else [],
            'final_band_pages': sorted(band),
            'revisit': revisit,
            'content_committed_at_stop': stop_commit is not None,
            'content_at_stop_sources': stop_sources,
            'content_at_stop_anchor_source': stop_anchor_source,
            'first_content_after_stop_presented_ms': (
                (first_after_stop['presented_time'] - stop['time']) * 1000
                if first_after_stop is not None else None),
            'first_content_after_stop_sources': sources,
            'first_target_content_since_drag_start_ms': (
                (first_target_since_start['presented_time'] - start['time']) * 1000
                if first_target_since_start is not None else None),
            'first_target_content_gap_from_stop_ms': stop_to_target_gap,
            'blank_after_stop_ms': (
                (first_after_stop['presented_time'] - stop['time']) * 1000
                if first_after_stop is not None else None),
            'paper_drawn': first_paper is not None,
            'paper_frame_presented_time_available': paper_available,
            'paper_only_subwindow_ms': paper_subwindow,
            'paper_submit_to_content_presented_ms': paper_submit_window,
            'paper_commit_ms': ((paper_commit['time'] - stop['time']) * 1000)
                               if paper_commit else None,
            'paper_commit_to_content_presented_ms':
                ((first_after_stop['presented_time'] - paper_commit['time']) * 1000)
                if paper_commit is not None and first_after_stop is not None else None,
            'paper_quads_on_first_content_frame': (first_after_stop.get('paper_quads')
                                                   if first_after_stop else None),
            'sharp_commit_ms': ((sharp['time'] - stop['time']) * 1000) if sharp else None,
            'sharp_presented_ms': (
                (sharp_frame['presented_time'] - stop['time']) * 1000
                if sharp_frame is not None else None),
            'frames_without_presented_timestamp_at_offset': sum(
                1 for frame in frames_at(stop_offset)
                if frame.get('presented') is True
                and not (isinstance(frame.get('presented_time'), (int, float))
                         and frame['presented_time'] > 0)),
            'stale_tasks': stale,
            'cache': {
                'raster_events': len(anchor_events),
                'repeat_after_eviction': sum(1 for record in anchor_events
                                             if record.get('class') == 'repeat-after-eviction'),
                'upload_after_cache_hit': sum(1 for record in anchor_events
                                              if record.get('class') == 'upload-after-cache-hit'),
                'new_page_raster_tasks': len(anchor_page_raster_enqueues),
                'page_raster_rastered_before_stop': bool(anchor_page_raster_before),
                'page_raster_rerasterized': bool(anchor_page_raster_before
                                                 and anchor_page_raster_enqueues),
                'anchor_uploads': len(anchor_uploads),
            },
        })
        seen_pages |= band
        previous_pages = band
    return {
        'planned_drags': len(plan),
        'gestures': len(gestures),
        'drags': out,
        'metric': 'real scroll-indicator thumb drag: CGEvent mouse events are delivered to the '
                  'app window and SwiftUI DragGesture calls AppState.scroll(toFraction:). The '
                  'stop is the last scroll input (mouse-up changes no position). '
                  'first_content_after_stop_presented_ms = last input to the first presented '
                  'frame with an on-screen page bitmap at the release offset; '
                  'first_target_content_since_drag_start_ms includes the drag itself; '
                  'sharp_presented_ms = stop to the presented frame carrying the sharp commit.',
    }


def summarize_run(records, idle_ms, jumps=None, slider=None):
    instances = {r.get('instance') for r in records
                 if r.get('kind') in {'document', 'input', 'viewport', 'sharp', 'frame'}
                 and r.get('instance')}
    if len(instances) > 1:
        raise ValueError('trace contains multiple reader instances; select one instance before summarizing')
    launch = next((r for r in records if r.get('kind') == 'launch'), None)
    opened = next((r for r in records if r.get('kind') == 'document'
                   and r.get('phase') == 'opened'), None)
    open_start = next((r for r in records if r.get('kind') == 'document'
                       and r.get('phase') == 'open_start'), None)
    t0 = launch['time'] if launch else (open_start['time'] if open_start else records[0]['time'])

    frames = [r for r in records if r.get('kind') == 'frame']
    presented = presented_frames(records)
    unavailable = [r for r in frames if r.get('presented') is True
                   and not isinstance(r.get('presented_time'), (int, float))]
    occluded = [r for r in frames if r.get('presented') is False]
    # The first presented frame that shows document pixels (a clearing frame has quad 0). When
    # Metal reported no host time for that frame, the first *timed* document frame is the first
    # honest presentation measurement; the CPU submit instant of the first document frame is
    # reported separately as model-level evidence, never as a presentation time.
    first_present = None
    first_document_frame = None
    document_epoch = (opened or {}).get('epoch')
    for frame in frames:
        if frame.get('document_quads', frame.get('quads', 0)) > 0 and frame['time'] >= (open_start or launch or frames[0])['time']:
            if document_epoch is not None and frame.get('epoch') != document_epoch:
                continue  # another surface (the floating preview) draws its own document state
            if first_document_frame is None:
                first_document_frame = frame
            if isinstance(frame.get('presented_time'), (int, float)) \
                    and frame['presented_time'] > 0:
                first_present = frame
                break
    first_sharp = next((r for r in records if r.get('kind') == 'sharp'), None)

    inputs = [r for r in records if r.get('kind') == 'input']
    viewports = [r for r in records if r.get('kind') == 'viewport']
    sharps = [r for r in records if r.get('kind') == 'sharp']
    viewport_seq_by_time = [(r['time'], r.get('seq', 0)) for r in viewports]

    scroll_stop_to_sharp = []
    scroll_stop_to_sharp_presented = []
    unsettled = 0
    for gesture, stop in inputs_by_gesture(inputs, idle_ms):
        # The resting offset is the offset of the last input; a later input would have started a
        # new gesture. A sharp record only counts when it was committed after this input
        # (`after_input_seq`) and at the same offset.
        stop_offset = stop.get('destination_pt')
        if not isinstance(stop_offset, (int, float)):
            stop_offset = stop.get('offset_pt')
        if not isinstance(stop_offset, (int, float)):
            unsettled += 1
            continue
        candidates = [
            sharp for sharp in sharps
            if sharp['time'] >= stop['time']
            and abs(sharp.get('offset_pt', -1e9) - stop_offset) <= 0.6
            and sharp.get('after_input_seq', -1) >= stop.get('seq', 0)
            and sharp.get('epoch') == stop.get('epoch')
        ]
        if not candidates:
            unsettled += 1
            continue
        sharp = candidates[0]
        scroll_stop_to_sharp.append((sharp['time'] - stop['time']) * 1000)
        # The presented frame that carries this sharp commit: its token was captured from the
        # page list the drawable was drawn from, so token equality is a real correlation, not a
        # time-adjacency proxy.
        frame = next((f for f in presented
                      if f.get('token', 0) >= sharp.get('token', 0)
                      and f['presented_time'] >= sharp['time']
                      and f.get('epoch') == sharp.get('epoch')
                      and abs(f.get('offset_pt', -1e9) - stop_offset) <= 0.6), None)
        if frame is not None:
            scroll_stop_to_sharp_presented.append((frame['presented_time'] - stop['time']) * 1000)

    queue = [r for r in records if r.get('kind') == 'queue']
    queue_by_category = {}
    queue_raw = {}
    for category in ('tile', 'page-raster', 'thumbnail', 'text', 'index'):
        entries = [r for r in queue if r.get('category') == category]
        waits = [r['wait_ms'] for r in entries if isinstance(r.get('wait_ms'), (int, float))]
        execs = [r['exec_ms'] for r in entries if isinstance(r.get('exec_ms'), (int, float))]
        queue_by_category[category] = {
            'wait_ms': stats(waits),
            'exec_ms': stats(execs),
        }
        queue_raw[category] = {'wait_ms': waits, 'exec_ms': execs}

    summary = next((r for r in records if r.get('kind') == 'summary'), None)
    raster = [r for r in records if r.get('kind') == 'raster']
    classifications = {
        'first': sum(1 for r in raster if r.get('class') == 'first'),
        'repeat_after_eviction': sum(1 for r in raster if r.get('class') == 'repeat-after-eviction'),
        'upload_after_cache_hit': sum(1 for r in raster if r.get('class') == 'upload-after-cache-hit'),
        'prefetch_rastered_never_drawn': summary.get('prefetch_rastered_never_drawn') if summary else None,
        'summary': summary,
    }

    memory = [r for r in records if r.get('kind') == 'memory']
    rss = [r['rss_bytes'] for r in memory if isinstance(r.get('rss_bytes'), (int, float))]
    tile_bytes = [r['tile_cache_bytes'] for r in memory
                  if isinstance(r.get('tile_cache_bytes'), (int, float))]
    page_bytes = [r['page_raster_bytes'] for r in memory
                  if isinstance(r.get('page_raster_bytes'), (int, float))]
    backdrop_bytes = [r['page_backdrop_bytes'] for r in memory
                      if isinstance(r.get('page_backdrop_bytes'), (int, float))]

    def frame_reason():
        if not frames:
            return 'no frame records: the canvas never submitted (no surface?)'
        if not presented:
            if occluded:
                return (f'all {len(occluded)} submitted frames were skipped by the compositor '
                        '(window occluded or display asleep)')
            return 'no frame carried a positive Metal presentation timestamp'
        return None

    presentation = {
        'frames_submitted': len(frames),
        'frames_presented': len(presented),
        'frames_presented_unavailable_timestamp': len(unavailable),
        'frames_occluded': len(occluded),
        'surfaces': sorted({r.get('surface') for r in frames if 'surface' in r}),
        'first_present_ms': ((first_present['presented_time'] - t0) * 1000) if first_present else None,
        'first_present_reason': None if first_present else frame_reason() or 'no presented frame showed document pixels with a usable host timestamp',
        'first_present_since_open_ms': ((first_present['presented_time'] - open_start['time']) * 1000)
                                       if first_present and open_start else None,
        # CPU submit of the first document frame (model-level): the earliest instant the app had
        # pixels ready to show. It is not a presentation time and is labelled as such.
        'first_document_submit_ms': ((first_document_frame['time'] - t0) * 1000) if first_document_frame else None,
    }
    if presented:
        times = [r['presented_time'] for r in presented]
        gaps = [(b - a) * 1000 for a, b in zip(times, times[1:])]
        presentation['presented_gap_ms'] = stats(gaps)
    return {
        'launch_time': launch['time'] if launch else None,
        'open_start_time': open_start['time'] if open_start else None,
        'opened_time': opened['time'] if opened else None,
        'first_present_ms': presentation['first_present_ms'],
        'first_sharp_ms': ((first_sharp['time'] - t0) * 1000) if first_sharp else None,
        'first_sharp_since_open_ms': ((first_sharp['time'] - open_start['time']) * 1000)
                                     if first_sharp and open_start else None,
        'first_sharp': first_sharp,
        'inputs': len(inputs),
        'gestures': len(inputs_by_gesture(inputs, idle_ms)),
        'unsettled_gestures': unsettled,
        'scroll_stop_to_sharp_ms': stats(scroll_stop_to_sharp),
        'scroll_stop_to_sharp_raw_ms': scroll_stop_to_sharp,
        'scroll_stop_to_sharp_presented_ms': {
            **stats(scroll_stop_to_sharp_presented),
            'raw_ms': scroll_stop_to_sharp_presented,
            'measured': len(scroll_stop_to_sharp_presented),
            'sharp_commits': len(scroll_stop_to_sharp),
            'reason': None if len(scroll_stop_to_sharp_presented) == len(scroll_stop_to_sharp) else
                      f'{len(scroll_stop_to_sharp) - len(scroll_stop_to_sharp_presented)} of '
                      f'{len(scroll_stop_to_sharp)} sharp commits had no presented frame with a '
                      'usable Metal timestamp',
        },
        'viewports': len(viewports),
        'sharp_events': len(sharps),
        'presentation': presentation,
        'far_jumps': far_jump_metrics(records, jumps) if jumps else None,
        'slider': slider_gesture_metrics(records, slider) if slider else None,
        'first_frame_attribution': first_frame_attribution(records, first_document_frame,
                                                           first_present),
        'scroll_stop_breakdown': scroll_stop_breakdown(records, inputs, sharps, idle_ms,
                                                       presented),
        'queue': queue_by_category,
        'queue_raw': queue_raw,
        'raster_classification': classifications,
        'memory': {
            'samples': len(memory),
            'rss_first_bytes': rss[0] if rss else None,
            'rss_last_bytes': rss[-1] if rss else None,
            'rss_peak_bytes': max(rss) if rss else None,
            'tile_cache_peak_bytes': max(tile_bytes) if tile_bytes else None,
            'page_raster_peak_bytes': max(page_bytes) if page_bytes else None,
            'page_backdrop_peak_bytes': max(backdrop_bytes) if backdrop_bytes else None,
            'phases': sorted({r.get('phase') for r in memory}),
            'scroll_stop_samples': [r for r in memory if r.get('phase') == 'scroll_stop'],
            'document_close_samples': [r for r in memory
                                       if r.get('phase') in ('document_close_before', 'document_close')],
        },
    }


def aggregate_far_jumps(runs):
    """Group the far-jump metrics by distance and report the revisit/cache evidence."""
    def bucket(jump):
        if jump.get('revisit'):
            return 'revisit'
        distance = jump.get('distance_pages')
        if distance is None:
            return 'initial'
        if distance >= 100:
            return '100+'
        if 30 <= distance <= 60:
            return '30-60'
        return 'other'

    jumps = [jump for run in runs for jump in ((run.get('far_jumps') or {}).get('jumps') or [])]
    if not jumps:
        return {'jumps': 0,
                'reason': 'no far jumps ran (LYRA_READER_PERF_JUMPS was not set)'}

    def collect(selection):
        def numeric(field):
            return stats([jump[field] for jump in selection
                          if isinstance(jump.get(field), (int, float))])
        presented_sources = {}
        commit_sources = {}
        anchor_sources = {}
        for jump in selection:
            for label in jump.get('first_content_presented_sources') or []:
                presented_sources[label] = presented_sources.get(label, 0) + 1
            for label in jump.get('first_content_commit_sources') or []:
                commit_sources[label] = commit_sources.get(label, 0) + 1
            label = jump.get('first_content_presented_anchor_source')
            if label and label != 'none':
                anchor_sources[label] = anchor_sources.get(label, 0) + 1
        return {
            'jumps': len(selection),
            'distance_pages': stats([jump['distance_pages'] for jump in selection
                                     if isinstance(jump.get('distance_pages'), (int, float))]),
            'first_content_presented_ms': numeric('first_content_presented_ms'),
            'first_anchor_content_presented_ms': numeric('first_anchor_content_presented_ms'),
            'paper_blank_ms': numeric('paper_blank_ms'),
            'paper_only_subwindow_ms': numeric('paper_only_subwindow_ms'),
            'paper_submit_to_content_presented_ms': numeric(
                'paper_submit_to_content_presented_ms'),
            'paper_commit_to_content_presented_ms': numeric(
                'paper_commit_to_content_presented_ms'),
            'first_content_commit_ms': numeric('first_content_commit_ms'),
            'sharp_presented_ms': numeric('sharp_presented_ms'),
            'sharp_commit_ms': numeric('sharp_commit_ms'),
            'first_content_presented_sources': presented_sources,
            'first_content_commit_sources': commit_sources,
            'anchor_sources': anchor_sources,
            'paper_drawn_jumps': sum(1 for jump in selection if jump.get('paper_drawn')),
            'paper_timestamp_unavailable_jumps': sum(
                1 for jump in selection if jump.get('paper_drawn')
                and not jump.get('paper_frame_presented_time_available')),
            'frames_without_presented_timestamp': sum(
                jump.get('frames_without_presented_timestamp') or 0 for jump in selection),
            'frames_occluded_at_offset': sum(jump.get('frames_occluded_at_offset') or 0
                                             for jump in selection),
            'stale_task_count_sum': sum((jump.get('stale_tasks') or {}).get('task_count') or 0
                                        for jump in selection),
            'stale_task_exec_ms_sum': sum((jump.get('stale_tasks') or {}).get('exec_ms') or 0
                                          for jump in selection),
            'outside_band_upload_count_sum': sum(
                (jump.get('stale_tasks') or {}).get('outside_band_upload_count') or 0
                for jump in selection),
            'page_raster_rerasterized_jumps': sum(
                1 for jump in selection if (jump.get('cache') or {}).get('page_raster_rerasterized')),
            'tile_repeat_after_eviction_sum': sum(
                (jump.get('cache') or {}).get('repeat_after_eviction') or 0 for jump in selection),
        }

    by_distance = {}
    for name in ('initial', 'other', '30-60', '100+', 'revisit'):
        selection = [jump for jump in jumps if bucket(jump) == name]
        if selection:
            by_distance[name] = collect(selection)
    revisits = [jump for jump in jumps if jump.get('revisit')]
    revisit = None
    if revisits:
        cached_fallback = [jump for jump in revisits
                           if any(label in ('low-res history fallback', 'thumbnail backdrop')
                                  for label in (jump.get('first_content_commit_sources') or []))]
        no_new_raster = [jump for jump in revisits
                         if (jump.get('cache') or {}).get('new_page_raster_tasks') == 0]
        revisit = {
            'jumps': len(revisits),
            'pages': [jump.get('anchor_page') for jump in revisits],
            'distance_pages': stats([jump['distance_pages'] for jump in revisits
                                     if isinstance(jump.get('distance_pages'), (int, float))]),
            'first_content_presented_ms': stats([
                jump['first_content_presented_ms'] for jump in revisits
                if isinstance(jump.get('first_content_presented_ms'), (int, float))]),
            'first_content_commit_ms': stats([
                jump['first_content_commit_ms'] for jump in revisits
                if isinstance(jump.get('first_content_commit_ms'), (int, float))]),
            'sharp_presented_ms': stats([
                jump['sharp_presented_ms'] for jump in revisits
                if isinstance(jump.get('sharp_presented_ms'), (int, float))]),
            'first_content_presented_sources': dict(
                (label, sum(1 for jump in revisits
                            if label in (jump.get('first_content_presented_sources') or [])))
                for label in sorted({label for jump in revisits
                                     for label in (jump.get('first_content_presented_sources') or [])})),
            'first_content_commit_sources': dict(
                (label, sum(1 for jump in revisits
                            if label in (jump.get('first_content_commit_sources') or [])))
                for label in sorted({label for jump in revisits
                                     for label in (jump.get('first_content_commit_sources') or [])})),
            'cached_fallback_jumps': len(cached_fallback),
            'no_new_page_raster_jumps': len(no_new_raster),
            'page_raster_rerasterized_jumps': sum(
                1 for jump in revisits if (jump.get('cache') or {}).get('page_raster_rerasterized')),
            'new_page_raster_tasks_sum': sum(
                (jump.get('cache') or {}).get('new_page_raster_tasks') or 0 for jump in revisits),
            'anchor_upload_after_cache_hit_sum': sum(
                (jump.get('cache') or {}).get('upload_after_cache_hit') or 0 for jump in revisits),
            'anchor_repeat_after_eviction_sum': sum(
                (jump.get('cache') or {}).get('repeat_after_eviction') or 0 for jump in revisits),
            'anchor_raster_events_sum': sum((jump.get('cache') or {}).get('raster_events') or 0
                                            for jump in revisits),
        }
    return {
        'jumps': len(jumps),
        'planned_per_run': [(run.get('far_jumps') or {}).get('planned_jumps') for run in runs],
        'observed_per_run': [(run.get('far_jumps') or {}).get('fraction_inputs') for run in runs],
        'by_distance': by_distance,
        'revisit': revisit,
        'per_jump': jumps,
        'metric_note': (jumps[0].get('metric') if jumps else None),
    }


def aggregate_slider(runs):
    drags = [drag for run in runs for drag in ((run.get('slider') or {}).get('drags') or [])]
    if not drags:
        return {'drags': 0, 'reason': 'no real slider drags ran'}
    def bucket(drag):
        if drag.get('revisit'):
            return 'revisit'
        distance = drag.get('distance_pages')
        if distance is None:
            return 'unknown'
        if distance >= 100:
            return '100+'
        if 30 <= distance <= 60:
            return '30-60'
        return 'other'
    def collect(selection):
        def numeric(field):
            return stats([drag[field] for drag in selection
                          if isinstance(drag.get(field), (int, float))])
        sources = {}
        stop_sources = {}
        for drag in selection:
            for label in drag.get('first_content_after_stop_sources') or []:
                sources[label] = sources.get(label, 0) + 1
            for label in drag.get('content_at_stop_sources') or []:
                stop_sources[label] = stop_sources.get(label, 0) + 1
        return {
            'drags': len(selection),
            'distance_pages': stats([drag['distance_pages'] for drag in selection
                                     if isinstance(drag.get('distance_pages'), (int, float))]),
            'input_count': stats([drag['input_count'] for drag in selection]),
            'drag_duration_ms': numeric('drag_duration_ms'),
            'first_content_after_stop_presented_ms': numeric(
                'first_content_after_stop_presented_ms'),
            'first_target_content_since_drag_start_ms': numeric(
                'first_target_content_since_drag_start_ms'),
            'blank_after_stop_ms': numeric('blank_after_stop_ms'),
            'sharp_presented_ms': numeric('sharp_presented_ms'),
            'sharp_commit_ms': numeric('sharp_commit_ms'),
            'sources': sources,
            'content_at_stop_sources': stop_sources,
            'paper_only_subwindow_ms': numeric('paper_only_subwindow_ms'),
            'paper_submit_to_content_presented_ms': numeric(
                'paper_submit_to_content_presented_ms'),
            'paper_commit_to_content_presented_ms': numeric(
                'paper_commit_to_content_presented_ms'),
            'paper_drawn_drags': sum(1 for drag in selection if drag.get('paper_drawn')),
            'paper_timestamp_unavailable_drags': sum(
                1 for drag in selection if drag.get('paper_drawn')
                and not drag.get('paper_frame_presented_time_available')),
            'page_raster_rerasterized_drags': sum(
                1 for drag in selection
                if (drag.get('cache') or {}).get('page_raster_rerasterized')),
            'new_page_raster_tasks_sum': sum(
                (drag.get('cache') or {}).get('new_page_raster_tasks') or 0
                for drag in selection),
            'stale_task_count_sum': sum((drag.get('stale_tasks') or {}).get('task_count') or 0
                                        for drag in selection),
            'stale_task_exec_ms_sum': sum((drag.get('stale_tasks') or {}).get('exec_ms') or 0
                                          for drag in selection),
            'frames_without_presented_timestamp_sum': sum(
                drag.get('frames_without_presented_timestamp_at_offset') or 0
                for drag in selection),
            'repeat_after_eviction_sum': sum(
                (drag.get('cache') or {}).get('repeat_after_eviction') or 0 for drag in selection),
        }
    by_distance = {}
    for name in ('other', '30-60', '100+', 'revisit', 'unknown'):
        selection = [drag for drag in drags if bucket(drag) == name]
        if selection:
            by_distance[name] = collect(selection)
    per_index = {}
    for index in sorted({drag['index'] for drag in drags}):
        per_index[str(index)] = collect([drag for drag in drags if drag['index'] == index])
    return {
        'drags': len(drags),
        'by_distance': by_distance,
        'per_index': per_index,
        'per_drag': drags,
        'verification': {
            'min_inputs_per_drag': min(drag['input_count'] for drag in drags),
            'max_inputs_per_drag': max(drag['input_count'] for drag in drags),
            'final_anchor_pages': [drag.get('final_anchor_page') for drag in drags],
            'distances_pages': [drag.get('distance_pages') for drag in drags],
        },
        'metric_note': (drags[0].get('metric') if drags else None),
    }


def merge_runs(runs):
    """Aggregate per-run derived numbers across repetitions (each run is a fresh process)."""
    def values(key):
        out = []
        for run in runs:
            value = run.get(key)
            if isinstance(value, (int, float)):
                out.append(value)
        return out

    scroll = []
    presented = []
    for run in runs:
        scroll.extend(run.get('scroll_stop_to_sharp_raw_ms', []))
        presented.extend(run.get('scroll_stop_to_sharp_presented_ms', {}).get('raw_ms', []))
    queue = {}
    for category in ('tile', 'page-raster', 'thumbnail', 'text', 'index'):
        waits, execs = [], []
        for run in runs:
            raw = run.get('queue_raw', {}).get(category, {})
            waits.extend(raw.get('wait_ms', []))
            execs.extend(raw.get('exec_ms', []))
        queue[category] = {'wait_ms': stats(waits), 'exec_ms': stats(execs)}
    classification = {
        'first': sum(r['raster_classification'].get('first') or 0 for r in runs),
        'repeat_after_eviction': sum(r['raster_classification'].get('repeat_after_eviction') or 0
                                     for r in runs),
        'upload_after_cache_hit': sum(r['raster_classification'].get('upload_after_cache_hit') or 0
                                      for r in runs),
        'prefetch_rastered_never_drawn': sum(
            r['raster_classification'].get('prefetch_rastered_never_drawn') or 0 for r in runs),
    }
    rss = [r['memory']['rss_peak_bytes'] for r in runs
           if isinstance(r['memory'].get('rss_peak_bytes'), (int, float))]
    tiles = [r['memory']['tile_cache_peak_bytes'] for r in runs
             if isinstance(r['memory'].get('tile_cache_peak_bytes'), (int, float))]
    pages = [r['memory']['page_raster_peak_bytes'] for r in runs
             if isinstance(r['memory'].get('page_raster_peak_bytes'), (int, float))]
    attribution_fields = ('wait_task_start_ms', 'task_after_start_ms', 'dispatch_ms',
                          'raster_core_ms', 'main_actor_resume_ms', 'start_to_resumed_other_ms',
                          'upload_ms', 'resumed_to_submit_ms', 'submit_to_present_ms')
    attribution = {}
    for field in attribution_fields:
        attribution[field] = stats([r['first_frame_attribution'][field] for r in runs
                                    if isinstance((r.get('first_frame_attribution') or {}).get(field),
                                                  (int, float))])
    attribution['dominant_buckets'] = [r.get('first_frame_attribution', {}).get('dominant_bucket')
                                       for r in runs]
    raw = {'queue_wait_ms': [], 'task_exec_ms': [], 'raster_core_ms': [],
           'raster_dispatch_ms': [], 'main_actor_resume_ms': []}
    tile_gestures = tile_tiles = 0
    for run in runs:
        breakdown = run.get('scroll_stop_breakdown') or {}
        tile_gestures += breakdown.get('gestures') or 0
        tile_tiles += breakdown.get('tiles') or 0
        for key in raw:
            raw[key].extend((breakdown.get('raw') or {}).get(key, []))
    return {
        'first_present_ms': stats(values('first_present_ms')),
        'first_sharp_ms': stats(values('first_sharp_ms')),
        'first_frame_attribution': attribution,
        'scroll_stop_breakdown': {
            'gestures': tile_gestures, 'tiles': tile_tiles,
            'queue_wait_ms': stats(raw['queue_wait_ms']),
            'task_exec_ms': stats(raw['task_exec_ms']),
            'raster_core_ms': stats(raw['raster_core_ms']),
            'raster_dispatch_ms': stats(raw['raster_dispatch_ms']),
            'main_actor_resume_ms': stats(raw['main_actor_resume_ms']),
        },
        'scroll_stop_to_sharp_ms': stats(scroll),
        'scroll_stop_to_sharp_presented_ms': {
            **stats(presented),
            'measured': len(presented),
            'sharp_commits': sum((r.get('scroll_stop_to_sharp_ms') or {}).get('n') or 0
                                 for r in runs),
        },
        'presented_frames': sum(r['presentation']['frames_presented'] for r in runs),
        'frames_submitted': sum(r['presentation']['frames_submitted'] for r in runs),
        'queue': queue,
        'raster_classification': classification,
        'far_jumps': aggregate_far_jumps(runs),
        'slider': aggregate_slider(runs),
        'memory_peak': {
            'rss_peak_mib': max(rss) / 2**20 if rss else None,
            'tile_cache_peak_mib': max(tiles) / 2**20 if tiles else None,
            'page_raster_peak_mib': max(pages) / 2**20 if pages else None,
        },
    }


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('pdf', type=Path)
    p.add_argument('--app', type=Path, default=ROOT / 'apps/macos/.build/release/LyraReader')
    p.add_argument('--pdfium', type=Path, default=ROOT / 'vendor/pdfium/lib/libpdfium.dylib')
    p.add_argument('--runs', type=int, default=3)
    p.add_argument('--jumps', default=None,
                   help='far-jump plan "ms:fraction,..." using LYRA_READER_PERF_JUMPS; replaces '
                        'the wheel-gesture workload')
    p.add_argument('--slider-drags', default=None,
                   help='real scroll-indicator drag plan "ms:fraction,...": at each time a thumb '
                        'drag is driven from the previous target to this fraction; replaces the '
                        'wheel/jump workload and needs Accessibility permission')
    p.add_argument('--scrolls', type=int, default=5, help='discrete scroll gestures per run')
    p.add_argument('--steps', type=int, default=8, help='wheel events per gesture')
    p.add_argument('--step-pt', type=float, default=80)
    p.add_argument('--step-ms', type=int, default=16)
    p.add_argument('--settle-ms', type=int, default=900, help='stop after each gesture')
    p.add_argument('--start-ms', type=int, default=3000, help='wait before the first gesture')
    p.add_argument('--idle-ms', type=float, default=120, help='silence that ends a gesture')
    p.add_argument('--zoom', type=int, choices=[100, 140, 200, 400], default=100)
    p.add_argument('--control-runs', type=int, default=1,
                   help='same workload with LYRA_READER_PERF_TRACE unset, to measure the trace RSS cost')
    p.add_argument('--focus-window', dest='focus_window', action='store_true', default=None,
                   help='activate and place the reader window (default: on for --jumps), so Metal '
                        'reports presentation timestamps instead of occluded frames')
    p.add_argument('--no-focus-window', dest='focus_window', action='store_false')
    p.add_argument('--output', type=Path, default=ROOT / 'build/perf-trace')
    args = p.parse_args()
    if platform.system() != 'Darwin':
        p.error('native macOS measurement only')
    if not 0 < args.runs <= 20 or not 1 <= args.scrolls <= 50 or not 0 <= args.control_runs <= 10:
        p.error('runs 1..20, scrolls 1..50, control-runs 0..10 required')
    try:
        jumps = parse_jump_plan(args.jumps) if args.jumps else None
        slider = parse_slider_plan(args.slider_drags) if args.slider_drags else None
    except ValueError as error:
        p.error(str(error))
    if jumps is not None and not 1 <= len(jumps) <= 20:
        p.error('1..20 jumps required')
    if jumps is not None and slider is not None:
        p.error('--jumps and --slider-drags are separate workloads; pass one')
    if slider is not None and not 1 <= len(slider) <= 20:
        p.error('1..20 slider drags required')
    if slider is not None:
        args.focus_window = True
    if args.focus_window is None:
        args.focus_window = jumps is not None
    for path in [args.pdf, args.app, args.pdfium]:
        if not path.is_file():
            p.error(f'missing input: {path}')
    args.output.mkdir(parents=True, exist_ok=True)
    identity = {
        'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT)),
        'platform': platform.platform(),
        'machine': subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'],
                                           text=True).strip(),
        'pdf_sha256': hashlib.sha256(args.pdf.read_bytes()).hexdigest(),
        'app_sha256': hashlib.sha256(args.app.read_bytes()).hexdigest(),
        'pdfium_sha256': hashlib.sha256(args.pdfium.read_bytes()).hexdigest(),
        'zoom_percent': args.zoom, 'cache_mib': 48,
        'jump_plan': args.jumps,
        'slider_plan': args.slider_drags,
        'focus_window': args.focus_window,
        'scrolls_per_run': None if (jumps or slider) else args.scrolls,
        'steps_per_gesture': None if (jumps or slider) else args.steps,
        'step_pt': None if (jumps or slider) else args.step_pt,
        'step_ms': None if (jumps or slider) else args.step_ms,
        'settle_ms': args.settle_ms,
        'control_runs': args.control_runs,
        'method': ('real scroll-indicator thumb drags: CGEvent mouse-down/dragged/up events are '
                   'delivered to the app window and SwiftUI DragGesture calls '
                   'AppState.scroll(toFraction:), the production slider path'
                   if slider else
                   'LYRA_READER_PERF_JUMPS; AppState.scroll(toFraction:) at the planned times '
                   '(the model method a scroll-indicator thumb drag calls, not synthesized '
                   'pointer events)'
                   if jumps else
                   'LYRA_READER_PERF_TRACE=1; discrete wheel gestures through '
                   'AppState.scroll(byScreenPoints:), each followed by a full stop') +
                  '. presented * times are Metal host presentation timestamps of frames the '
                  'compositor presented; sharp times are model-level commits of a fully sharp '
                  'page list; no display link means presented fields are null with a reason',
    }
    gesture_ms = args.steps * args.step_ms
    total_ms = ((jumps[-1][0] + 5000 + 2000) if jumps else
                (slider[-1][0] + 5000 + 2000) if slider else
                (args.start_ms + args.scrolls * gesture_ms
                 + (args.scrolls - 1) * args.settle_ms + 2000))

    def focus_tool():
        """Compile the Accessibility window helper once; it places the measured window."""
        source = ROOT / 'scripts/focus-reader-window.swift'
        tool = ROOT / 'build/perf-tools/focus-reader-window'
        tool.parent.mkdir(parents=True, exist_ok=True)
        if not tool.exists() or tool.stat().st_mtime < source.stat().st_mtime:
            subprocess.run(['swiftc', '-module-cache-path',
                            str(tool.parent / 'modulecache'), str(source), '-o', str(tool)],
                           check=True, capture_output=True, text=True)
        return tool

    focus = focus_tool() if args.focus_window else None

    def environment(doc, trace):
        env = {k: v for k, v in os.environ.items() if not k.startswith('LYRA_READER_')}
        env.update(
            LYRA_READER_OPEN=str(doc),
            LYRA_READER_PDFIUM_PATH=str(args.pdfium.resolve()),
            LYRA_READER_ZOOM=str(args.zoom),
            LYRA_READER_CACHE_BUDGET_MB='48',
            LYRA_READER_SPIKE_FORCE_FRONT='1',
            LYRA_READER_INDEX_CACHE='disabled',
            LYRA_READER_PERF_CLOSE='1',
            LYRA_READER_QUIT_AFTER=str(total_ms + 4000),
        )
        if jumps:
            env['LYRA_READER_PERF_JUMPS'] = ','.join(
                f'{milliseconds}:{fraction}' for milliseconds, fraction in jumps)
        elif slider is None:
            env.update(
                LYRA_READER_PERF_SCROLLS=str(args.scrolls),
                LYRA_READER_PERF_SCROLL_STEPS=str(args.steps),
                LYRA_READER_PERF_SCROLL_STEP_PT=str(args.step_pt),
                LYRA_READER_PERF_SCROLL_STEP_MS=str(args.step_ms),
                LYRA_READER_PERF_SCROLL_SETTLE_MS=str(args.settle_ms),
                LYRA_READER_PERF_SCROLL_START_MS=str(args.start_ms),
            )
        if trace:
            env['LYRA_READER_PERF_TRACE'] = '1'
        else:
            env.pop('LYRA_READER_PERF_TRACE', None)
        return env

    def run_process(doc, env, log):
        window = None
        drags = []
        with log.open('w') as output:
            started = time.monotonic()
            proc = subprocess.Popen([str(args.app.resolve())], env=env,
                                    stdout=output, stderr=subprocess.STDOUT)
            if focus is not None:
                # The window appears asynchronously; retry until the app has one. This is not
                # part of the workload: it moves no document offset and touches no render path.
                for _ in range(24):
                    if proc.poll() is not None:
                        break
                    result = subprocess.run([str(focus), str(proc.pid), '120', '100',
                                             '1200', '800'],
                                            capture_output=True, text=True)
                    if result.returncode == 0:
                        line = next((line for line in result.stdout.splitlines()
                                     if line.startswith('lyra-perf-window: ')), None)
                        if line:
                            fields = {}
                            for token in line.split(' ', 1)[1].split(' '):
                                if '=' in token:
                                    key, value = token.split('=', 1)
                                    fields[key] = value
                            window = fields
                        break
                    time.sleep(0.25)
            if slider is not None:
                if window is None or 'bounds' not in window:
                    raise SystemExit('real slider workload needs the focused window bounds; '
                                     'the Accessibility helper did not report them')
                previous_target = 0.0
                for milliseconds, target in slider:
                    delay = started + milliseconds / 1000.0 - time.monotonic()
                    if delay > 0:
                        time.sleep(delay)
                    if proc.poll() is not None:
                        break
                    # Re-assert the frontmost window right before the pointer events: another
                    # application can take focus while the harness sleeps between drags.
                    subprocess.run([str(focus), str(proc.pid), '120', '100', '1200', '800'],
                                   capture_output=True, text=True)
                    time.sleep(1.0)
                    drags.append(drive_scroll_indicator_drag(
                        window['bounds'], previous_target, target))
                    previous_target = target
            deadline = time.monotonic() + total_ms / 1000 + 35
            timed_out = False
            while True:
                pid, status, usage = os.wait4(proc.pid, os.WNOHANG)
                if pid:
                    break
                if time.monotonic() > deadline:
                    timed_out = True
                    proc.kill()
                    _, status, usage = os.wait4(proc.pid, 0)
                    break
                time.sleep(.1)
            proc.returncode = os.waitstatus_to_exitcode(status)
        if timed_out or proc.returncode:
            raise SystemExit(f'run failed (timeout={timed_out}, exit={proc.returncode}); see {log}')
        return usage, window, drags

    runs = []
    for run in range(args.runs):
        with tempfile.TemporaryDirectory(prefix='lyra-perf-trace-') as directory:
            doc = Path(directory) / 'document.pdf'
            shutil.copyfile(args.pdf, doc)
            log = args.output / f'run-{run + 1}.log'
            usage, window, drags = run_process(doc, environment(doc, trace=True), log)
            records = load_records(log)
            result = dict(run=run + 1, peak_rss_bytes=usage.ru_maxrss, window=window,
                          slider_driver=drags,
                          **summarize_run(records, args.idle_ms, jumps=jumps, slider=slider))
            runs.append(result)
            (args.output / 'results.json').write_text(
                json.dumps(dict(identity=identity, runs=runs), indent=2) + '\n')
            print(json.dumps({k: v for k, v in result.items() if k != 'first_sharp'}))

    controls = []
    for run in range(args.control_runs):
        with tempfile.TemporaryDirectory(prefix='lyra-perf-control-') as directory:
            doc = Path(directory) / 'document.pdf'
            shutil.copyfile(args.pdf, doc)
            log = args.output / f'control-{run + 1}.log'
            usage, _, _ = run_process(doc, environment(doc, trace=False), log)
            leaves = [line for line in log.read_text().splitlines()
                      if line.startswith(PREFIX)]
            if leaves:
                raise SystemExit(f'control run {run + 1} emitted perf records with the trace unset')
            controls.append({'run': run + 1, 'peak_rss_bytes': usage.ru_maxrss})
    overhead = None
    if controls:
        def mib(values):
            return percentile([v / 2**20 for v in values], .50)
        traced_peak = mib([r['peak_rss_bytes'] for r in runs])
        control_peak = mib([r['peak_rss_bytes'] for r in controls])
        overhead = {
            'traced_peak_rss_mib_p50': traced_peak,
            'control_peak_rss_mib_p50': control_peak,
            'delta_mib': traced_peak - control_peak,
            'delta_percent': ((traced_peak - control_peak) / control_peak * 100)
                             if control_peak else None,
            'control_runs': len(controls),
            'note': 'ru_maxrss of the whole process for the identical gesture workload; the '
                    'traced run also writes its JSONL to the redirected log',
        }
    aggregate = merge_runs(runs)
    (args.output / 'results.json').write_text(
        json.dumps(dict(identity=identity, runs=runs, controls=controls,
                        trace_overhead=overhead, aggregate=aggregate), indent=2) + '\n')
    print(json.dumps({'aggregate': aggregate, 'trace_overhead': overhead}, indent=2))


if __name__ == '__main__':
    main()
