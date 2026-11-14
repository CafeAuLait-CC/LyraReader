#!/usr/bin/env python3
"""Analyze an existing Qt scene trace. This tool never starts or controls a desktop.

Scene submission/queue callbacks provide no compositor presentation timestamp. Their
intervals and content associations are reported separately from unavailable presentation.
"""
import argparse
import importlib.util
import json
import math
from pathlib import Path
import stat
import sys

_spec = importlib.util.spec_from_file_location(
    'lyra_perf_trace', Path(__file__).with_name('measure-perf-trace.py'))
_common = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_common)
SOURCES = {'none', 'unattributed', 'page-raster', 'tile', 'partial-tile',
           'previous-tile', 'previous-raster', 'preview', 'history'}
STAGES = {'scene-queued', 'scene-submitted'}
MAX_LOG_BYTES = 64 * 1024 * 1024
MAX_EVENT_BYTES = 1024 * 1024


def integer(value, name, minimum=0, maximum=2**63-1):
    if type(value) is not int or not minimum <= value <= maximum:
        raise ValueError(f'{name} must be an integer in {minimum}..{maximum}')
    return value


def finite(value, name):
    if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
        raise ValueError(f'{name} must be a finite, nonnegative time')
    return value


def load(log):
    info = log.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_LOG_BYTES:
        raise ValueError('the trace must be a regular file no larger than 64 MiB')
    # Decode one bounded line at a time. Bound the retained JSON shape too; a small
    # file full of tiny arrays must not expand into an unbounded object graph.
    records, nodes, characters = [], 0, 0
    with log.open('rb') as source:
        count = 0
        while True:
            line = source.readline(MAX_EVENT_BYTES + len(_common.PREFIX) + 2)
            if not line:
                break
            if len(line) > MAX_EVENT_BYTES + len(_common.PREFIX) + int(line.endswith(b'\n')):
                raise ValueError('a trace line exceeds the 1 MiB event limit')
            line = line.decode('utf-8')
            if line.startswith(_common.PREFIX):
                count += 1
                if count > 100000:
                    raise ValueError('the trace exceeds 100,000 records; use a shorter capture')
                try:
                    record = _common.parse_record_line(line, include_excerpt=False)
                except RecursionError as error:
                    raise ValueError('trace JSON nesting is too deep') from error
                pending = [(record, 0)]
                while pending:
                    value, depth = pending.pop()
                    nodes += 1
                    if nodes > 2000000 or depth > 16:
                        raise ValueError('trace JSON exceeds the retained node/depth budget')
                    if isinstance(value, dict):
                        if len(value) > 128 or any(not isinstance(key, str) or len(key) > 128 for key in value):
                            raise ValueError('a trace object has too many fields')
                        characters += sum(len(key) for key in value)
                        pending.extend((child, depth+1) for child in value.values())
                    elif isinstance(value, list):
                        if len(value) > 4096:
                            raise ValueError('a trace array is too large')
                        pending.extend((child, depth+1) for child in value)
                    elif isinstance(value, str):
                        characters += len(value)
                        if len(value) > 2048 or characters > 8*1024*1024:
                            raise ValueError('trace strings exceed the bounded metadata budget')
                    if characters > 8*1024*1024:
                        raise ValueError('trace keys and values exceed the metadata budget')
                records.append(record)
    if not records:
        raise ValueError('trace contains no perf records')
    return records


def content_key(record):
    instance = record.get('instance')
    if not isinstance(instance, str) or not instance or len(instance) > 128:
        raise ValueError('content/frame instance must be a nonempty, bounded string')
    return instance, integer(record.get('content_seq'), 'content_seq', 1)


def check_content(record):
    key = content_key(record)
    finite(record.get('time'), 'content.time')
    integer(record.get('epoch'), 'epoch', 1)
    surface = record.get('surface')
    if not isinstance(surface, dict):
        raise ValueError('content requires its actual surface metadata')
    integer(surface.get('width'), 'surface.width', 1, 2**31-1)
    integer(surface.get('height'), 'surface.height', 1, 2**31-1)
    if finite(surface.get('dpr'), 'surface.dpr') <= 0:
        raise ValueError('surface DPR must be positive')
    integer(surface.get('graphics_api'), 'surface.graphics_api', 0, 32)
    if type(surface.get('exposed')) is not bool:
        raise ValueError('surface exposure must be explicit')
    page_count = integer(record.get('page_count'), 'page_count', 0, 2**32-1)
    pages, sources = record.get('pages'), record.get('sources')
    if not isinstance(pages, list) or len(pages) > 512 or not isinstance(sources, list) or len(pages) != len(sources):
        raise ValueError('content pages and sources must have equal, bounded lengths')
    for page in pages:
        integer(page, 'page', 0, page_count-1)
    if pages != sorted(set(pages)) or any(not isinstance(source, str) or source not in SOURCES for source in sources):
        raise ValueError('content pages must be unique/sorted and source roles must be known')
    for name in ('geometry_unsupported', 'truncated', 'duplicate_page_items', 'context_mismatch', 'sharp'):
        if type(record.get(name)) is not bool:
            raise ValueError(f'{name} must explicitly be true or false')
    count = integer(record.get('page_quads'), 'page_quads', 0, 4096)
    integer(record.get('paper_quads'), 'paper_quads', 0, 512)
    integer(record.get('tile_quads'), 'tile_quads', 0, count)
    anchor = integer(record.get('anchor_page'), 'anchor_page', -1, max(-1, page_count-1))
    integer(record.get('anchor_page_quads'), 'anchor_page_quads', 0, count)
    expected_source = dict(zip(pages, sources)).get(anchor, 'none') if anchor >= 0 else 'unavailable'
    if record.get('anchor_source') != expected_source:
        raise ValueError('anchor_source does not match this content commit')
    details = record.get('page_sources')
    if not isinstance(details, list) or len(details) > 512:
        raise ValueError('page_sources must be a bounded array')
    drawn, actual_count, actual_tiles, actual_anchor = set(), 0, 0, 0
    for detail in details:
        if not isinstance(detail, dict):
            raise ValueError('page_sources entries must be objects')
        page = integer(detail.get('page'), 'page_sources.page', 0, page_count-1)
        quads = detail.get('quads')
        if not isinstance(quads, list) or len(quads) > 4096-actual_count:
            raise ValueError('quads must be a bounded array')
        for quad in quads:
            if not isinstance(quad, dict):
                raise ValueError('quad entries must be objects')
            rect, role = quad.get('rect'), quad.get('source')
            if not isinstance(rect, list) or len(rect) != 4 or any(type(v) not in (int, float) or not math.isfinite(v) for v in rect) or rect[2] <= 0 or rect[3] <= 0:
                raise ValueError('a visible quad must have four finite coordinates and positive extent')
            if not isinstance(role, str) or role not in SOURCES or role == 'none':
                raise ValueError('a visible quad has an unknown source role')
            actual_count += 1
            actual_tiles += int('tile' in role)
            actual_anchor += int(page == anchor)
            drawn.add(page)
    if actual_count != count or actual_tiles != record['tile_quads'] or actual_anchor != record['anchor_page_quads']:
        raise ValueError('content quad counts disagree with the committed geometry')
    if record.get('content_pages') != sorted(drawn):
        raise ValueError('content_pages disagree with the nonempty geometry')
    if record['paper_quads'] != len(details):
        raise ValueError('paper_quads disagree with the visible page items')
    if record['sharp'] and (not count or not pages or any(record[name] for name in ('context_mismatch', 'geometry_unsupported', 'truncated', 'duplicate_page_items'))):
        raise ValueError('empty, ambiguous or unsupported content cannot be sharp')
    return key


def summarize(records):
    if not records or any(not isinstance(record, dict) for record in records):
        raise ValueError('a Qt trace must contain object records')
    starts = [r for r in records if r.get('kind') == 'trace-start']
    ends = [r for r in records if r.get('kind') == 'trace-end']
    if len(starts) != 1 or type(starts[0].get('schema_version')) is not int or starts[0].get('schema_version') != 1 or starts[0].get('backend') != 'qt-scene':
        raise ValueError('expected one schema-1 Qt trace-start record')
    issues = []
    if len(ends) != 1 or records[-1].get('kind') != 'trace-end':
        issues.append('missing or misplaced trace-end')
    if records[0].get('kind') != 'trace-start':
        issues.append('misplaced trace-start')
    if any(r.get('kind') in ('trace-gap', 'trace-error') or r.get('dropped_records', 0) for r in records):
        issues.append('diagnostic records were lost or recording failed')
    contents = {}
    for record in records:
        finite(record.get('time'), 'record.time')
        if 'dropped_records' in record:
            integer(record['dropped_records'], 'dropped_records')
        if record.get('kind') == 'content':
            key = check_content(record)
            if key in contents:
                raise ValueError('duplicate (instance, content_seq)')
            contents[key] = record
            if any(record[name] for name in ('context_mismatch', 'geometry_unsupported', 'truncated', 'duplicate_page_items')):
                issues.append('some content commits have unavailable context or geometry')
            if 'unattributed' in record['sources']:
                issues.append('some scene assets have no recorded admission provenance')
    frames, frame_keys, associations = [], set(), {}
    for record in records:
        if record.get('kind') != 'frame':
            continue
        if record.get('presented') is not False or record.get('presented_time') not in (None, 'unavailable'):
            raise ValueError('a Qt scene trace must not claim a presentation timestamp')
        stage = record.get('stage')
        if stage not in STAGES:
            raise ValueError('unknown Qt frame stage')
        if record.get('unattributed') is True:
            issues.append('some terminal frames have no synchronized content stamp')
            continue
        key = content_key(record)
        content = contents.get(key)
        if content is None or record['time'] < content['time']:
            raise ValueError('frame refers to missing or future content')
        sequence = integer(record.get('frame_seq'), 'frame_seq', 1)
        identity = (key[0], sequence)
        terminal = (*identity, stage)
        if terminal in frame_keys:
            raise ValueError('duplicate terminal stage for one scene frame')
        frame_keys.add(terminal)
        if identity in associations and associations[identity] != key:
            raise ValueError('one scene frame refers to different content commits')
        associations[identity] = key
        for name in ('epoch', 'anchor_page', 'anchor_source', 'page_quads', 'anchor_page_quads', 'paper_quads', 'tile_quads', 'content_pages', 'surface', 'offset_pt', 'mode', 'geometry_unsupported', 'truncated'):
            if record.get(name) != content.get(name):
                raise ValueError(f'frame {name} differs from its frozen content stamp')
        frames.append(record)
    if not contents or not frames:
        issues.append('no attributed scene frames')
    stages = {}
    for instance, sequence, stage in frame_keys:
        stages.setdefault((instance, sequence), set()).add(stage)
    if any(observed != STAGES for observed in stages.values()):
        issues.append('some scene frames are missing a queue or submission callback')
    instances = {}
    for instance in sorted({key[0] for key in contents}):
        selected = sorted((r for r in frames if r['instance'] == instance), key=lambda r: r['time'])
        queued = [r for r in selected if r['stage'] == 'scene-queued']
        submitted = [r for r in selected if r['stage'] == 'scene-submitted']
        intervals = [(right['time']-left['time'])*1000 for left, right in zip(queued, queued[1:])]
        epochs = []
        for epoch in sorted({r['epoch'] for r in queued}):
            group = [r for r in queued if r['epoch'] == epoch]
            first = next((r for r in group if r['page_quads'] > 0), None)
            paper = next((r for r in group if r['paper_quads'] > 0 and r['page_quads'] == 0), None)
            commit = contents[(instance, first['content_seq'])] if first else None
            epochs.append({'epoch': epoch, 'first_content_seq': first['content_seq'] if first else None,
                           'first_scene_queue_time': first['time'] if first else None,
                           'anchor_source': commit['anchor_source'] if commit else 'unavailable',
                           'source_labels': [_common.source_label(page, role, commit['anchor_page']) for page, role in zip(commit['pages'], commit['sources'])] if commit else [],
                           'scene_paper_only_to_content_ms': (first['time']-paper['time'])*1000 if first and paper and paper['time'] <= first['time'] else None})
        surfaces = {json.dumps(r['surface'], sort_keys=True): r['surface']
                    for key, r in contents.items() if key[0] == instance}
        instances[instance] = {'scene_queued': len(queued), 'scene_submitted': len(submitted),
                               'surfaces': list(surfaces.values()),
                               'queue_interval_ms': _common.stats(intervals), 'epochs': epochs}
    return {'schema_version': 1, 'complete': not issues, 'issues': sorted(set(issues)),
            'capture_boundaries': [{name: r.get(name) for name in ('time', 'instance', 'stage', 'reason')}
                                   for r in records if r.get('kind') == 'trace-boundary'],
            'dropped_records': max((r.get('dropped_records', 0) for r in records), default=0),
            'basis': 'Qt scene geometry and queue/submit callbacks, before renderer/compositor occlusion',
            'physical_presentation_available': False, 'presented_fps': None, 'gpu_time_ms': None,
            'presentation_reason': 'No compositor presentation timestamps were collected.',
            'instances': instances}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('--output', type=Path, help='write a new report file; existing files are protected')
    args = parser.parse_args()
    try:
        result = summarize(load(args.log))
        encoded = json.dumps(result, indent=2, allow_nan=False) + '\n'
        if args.output:
            with args.output.open('x', encoding='utf-8') as output:
                output.write(encoded)
        else:
            sys.stdout.write(encoded)
        return 0 if result['complete'] else 1
    except (OSError, UnicodeError, ValueError, TypeError, KeyError) as error:
        parser.error(str(error))


if __name__ == '__main__':
    sys.exit(main())
