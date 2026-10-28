#!/usr/bin/env python3
"""Derive the P0 performance metrics from a `LYRA_READER_PERF_TRACE=1` run.

Build first: ./scripts/build-rust.sh && (cd apps/macos && swift build -c release --product LyraReader)
Run:        scripts/measure-perf-trace.py path/to/document.pdf

The app is launched with `LYRA_READER_PERF_TRACE=1` and
`LYRA_READER_PERF_SCROLLS=<n>`, which performs n discrete wheel gestures through the real
`AppState.scroll(byScreenPoints:)` path (each followed by a full stop). Every number comes from
the trace; nothing is estimated here.

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


def summarize_run(records, idle_ms):
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
    p.add_argument('--output', type=Path, default=ROOT / 'build/perf-trace')
    args = p.parse_args()
    if platform.system() != 'Darwin':
        p.error('native macOS measurement only')
    if not 0 < args.runs <= 20 or not 1 <= args.scrolls <= 50 or not 0 <= args.control_runs <= 10:
        p.error('runs 1..20, scrolls 1..50, control-runs 0..10 required')
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
        'scrolls_per_run': args.scrolls, 'steps_per_gesture': args.steps,
        'step_pt': args.step_pt, 'step_ms': args.step_ms, 'settle_ms': args.settle_ms,
        'control_runs': args.control_runs,
        'method': 'LYRA_READER_PERF_TRACE=1; discrete wheel gestures through '
                  'AppState.scroll(byScreenPoints:), each followed by a full stop. presented *'
                  ' times are Metal host presentation timestamps of frames the compositor '
                  'presented; sharp times are model-level commits of a fully sharp page list; '
                  'no display link means presented fields are null with a reason',
    }
    gesture_ms = args.steps * args.step_ms
    total_ms = (args.start_ms + args.scrolls * gesture_ms
                + (args.scrolls - 1) * args.settle_ms + 2000)

    def environment(doc, trace):
        env = {k: v for k, v in os.environ.items() if not k.startswith('LYRA_READER_')}
        env.update(
            LYRA_READER_OPEN=str(doc),
            LYRA_READER_PDFIUM_PATH=str(args.pdfium.resolve()),
            LYRA_READER_ZOOM=str(args.zoom),
            LYRA_READER_CACHE_BUDGET_MB='48',
            LYRA_READER_SPIKE_FORCE_FRONT='1',
            LYRA_READER_INDEX_CACHE='disabled',
            LYRA_READER_PERF_SCROLLS=str(args.scrolls),
            LYRA_READER_PERF_SCROLL_STEPS=str(args.steps),
            LYRA_READER_PERF_SCROLL_STEP_PT=str(args.step_pt),
            LYRA_READER_PERF_SCROLL_STEP_MS=str(args.step_ms),
            LYRA_READER_PERF_SCROLL_SETTLE_MS=str(args.settle_ms),
            LYRA_READER_PERF_SCROLL_START_MS=str(args.start_ms),
            LYRA_READER_PERF_CLOSE='1',
            LYRA_READER_QUIT_AFTER=str(total_ms + 4000),
        )
        if trace:
            env['LYRA_READER_PERF_TRACE'] = '1'
        else:
            env.pop('LYRA_READER_PERF_TRACE', None)
        return env

    def run_process(doc, env, log):
        with log.open('w') as output:
            proc = subprocess.Popen([str(args.app.resolve())], env=env,
                                    stdout=output, stderr=subprocess.STDOUT)
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
        return usage

    runs = []
    for run in range(args.runs):
        with tempfile.TemporaryDirectory(prefix='lyra-perf-trace-') as directory:
            doc = Path(directory) / 'document.pdf'
            shutil.copyfile(args.pdf, doc)
            log = args.output / f'run-{run + 1}.log'
            usage = run_process(doc, environment(doc, trace=True), log)
            records = load_records(log)
            result = dict(run=run + 1, peak_rss_bytes=usage.ru_maxrss,
                          **summarize_run(records, args.idle_ms))
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
            usage = run_process(doc, environment(doc, trace=False), log)
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
    (args.output / 'results.json').write_text(
        json.dumps(dict(identity=identity, runs=runs, controls=controls,
                        trace_overhead=overhead), indent=2) + '\n')
    print(json.dumps({'aggregate': merge_runs(runs), 'trace_overhead': overhead}, indent=2))


if __name__ == '__main__':
    main()
