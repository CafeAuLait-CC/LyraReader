#!/usr/bin/env python3
"""Capture native visual candidates, or compare against an explicitly approved baseline.

macOS 14.4+, Command Line Tools, and a logged-in, awake desktop are required for capture.
Only the isolated debug application's own window is captured. No third-party Python packages.
"""
from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
from pathlib import Path
import plistlib
import runpy
import shutil
import signal
import subprocess
import sys
import tempfile
import uuid

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent.parent
EXPECTED_CAPTURES = [
    '01-default-100', '02-fixed-100', '03-sidebar-open', '04-sidebar-restored',
    '05-resize-small', '06-resize-restored', '07-fit-width', '08-zoom-in',
    '09-zoom-restored', '10-fullscreen', '11-fullscreen-restored',
    '12-fit-page-window', '13-fit-page-first', '14-fit-page-middle',
    '15-fit-page-last', '16-document-end-100',
]
CAPTURE_SUITES = {
    'paper': EXPECTED_CAPTURES,
    'reader-shell': [
        '01-home-empty', '02-one-tab', '03-three-tabs', '04-eight-tabs',
        '05-first-tab-active', '06-narrow-eight-tabs', '07-window-restored',
        '08-close-active-tab', '09-last-tab', '10-return-home',
    ],
    'toolbar-inspectors': [
        '01-document-idle', '02-annotate-row', '03-highlight-armed', '04-note-armed',
        '05-annotate-disarmed', '06-edit-row', '07-edit-text-inspector',
        '08-edit-link-inspector', '09-edit-tool-cleared', '10-fill-sign-row',
        '11-fill-text-inspector', '12-signature-inspector', '13-date-inspector',
        '14-checkmark-inspector', '15-cross-inspector', '16-stamp-inspector',
        '17-image-inspector', '18-fill-tool-cleared', '19-lyra-row',
        '20-edit-after-assistant', '21-fill-after-assistant',
        '22-sidebar-with-inspector', '23-narrow-with-inspector',
        '24-inspector-window-restored', '25-rows-closed-restored', '26-home-no-document',
    ],
}


def expected_captures(report: dict) -> list[str]:
    suite = report.get('suite', 'paper')
    if not isinstance(suite, str) or suite not in CAPTURE_SUITES:
        raise ValueError('Unsupported capture suite')
    return CAPTURE_SUITES[suite]


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n')


def command(arguments: list[str], **kwargs: object) -> str:
    return subprocess.run(arguments, check=True, text=True, capture_output=True, **kwargs).stdout.strip()


def fixture(path: Path, title: str = 'LyraReader paper alignment probe', identity: str | None = None,
            pages: int = 1) -> None:
    """Reuse the repository's PDF writer; registration patches have known PDF-space centers."""
    writer = runpy.run_path(str(ROOT / 'scripts/make-fixtures.py'))['build_pdf']
    content = [
        '1 1 1 rg 0 0 612 792 re f',
        '0.12 0.12 0.12 RG 0.6 w 6 6 600 780 re S',
        # Red marker center: (33, 762), or (33, 30) in page-local top-left points.
        '1 0 0 rg 24 756 18 12 re f',
        '0 0.2 1 rg 570 756 18 12 re f',
        '0 0.7 0.2 rg 24 24 18 12 re f',
        '1 0.6 0 rg 570 24 18 12 re f',
        f'0 0 0 rg BT /F1 18 Tf 60 754 Td ({title}) Tj ET',
        'BT /F1 11 Tf 60 732 Td (Synthetic fixture - no private document content) Tj ET',
    ]
    for y in range(80, 710, 30):
        content += [f'0.72 0.72 0.72 RG 0.3 w 24 {y} m 588 {y} l S',
                    f'0.15 0.15 0.15 rg BT /F1 10 Tf 32 {y + 5} Td (PDF y = {y}) Tj ET']
    for x in range(60, 600, 60):
        content += [f'0.8 0.8 0.8 RG 0.3 w {x} 48 m {x} 708 l S']
    colors = {'magenta': '1 0 1', 'cyan': '0 1 1', 'yellow': '1 1 0'}
    streams = []
    for index in range(pages):
        page = list(content)
        color = identity
        if pages > 1:
            page = [line.replace(title, f'{title} - page {index + 1}') for line in page]
            color = ['magenta', 'cyan', 'yellow'][index % 3]
        if color is not None:
            page.append(f'{colors[color]} rg 300 696 12 12 re f')
        streams.append(('\n'.join(page), 0))
    path.write_bytes(writer(streams, page_sizes=[(612, 792)] * pages))


def compile_comparer(directory: Path) -> Path:
    binary = directory / 'compare-visual'
    command(['xcrun', 'swiftc', '-O', str(ROOT / 'scripts/compare-visual.swift'), '-o', str(binary)])
    return binary


def render_report(directory: Path, report: dict, comparisons: list[dict] | None = None) -> None:
    """A local review artifact; images keep native pixels and are scaled only for viewing."""
    status = report.get('status', 'failed')
    title = {'reader-shell': 'LyraReader reader shell review',
             'toolbar-inspectors': 'LyraReader toolbar and inspector review'}.get(
                 report.get('suite'), 'LyraReader paper visual review')
    parts = ['<!doctype html><html lang="en"><meta charset="utf-8">',
             '<meta name="viewport" content="width=device-width, initial-scale=1">',
             '<title>LyraReader visual review</title>',
             '<style>body{font:15px system-ui;margin:24px;max-width:1400px;color:#24211d;background:#fafafa}',
             'img{max-width:100%;height:auto}figure{margin:24px 0}pre{white-space:pre-wrap;overflow-wrap:anywhere}',
             '.pair{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,360px),1fr));gap:20px}',
             'figcaption{font-weight:600;margin-bottom:8px}a{color:#725014}</style>',
             '<h1>' + title + '</h1>',
             f'<p>Status: <strong>{html.escape(status)}</strong>. Candidates are unreviewed; capture success is not baseline approval.</p>',
             '<pre>' + html.escape(json.dumps(report.get('environment', {}), indent=2, ensure_ascii=False)) + '</pre>']
    if report.get('error'):
        parts.append('<p>' + html.escape(str(report['error'])) + '</p>')
    for capture in report.get('captures', []) + report.get('deferred_captures', []):
        name = capture['file']
        if Path(name).name != name:
            raise ValueError('Capture filename must be a basename')
        label = capture['id'] + (' (deferred reference)' if capture.get('deferred_reason') else '')
        parts.append(f'<figure><figcaption>{html.escape(label)}</figcaption>'
                     f'<a href="{html.escape(name, quote=True)}"><img src="{html.escape(name, quote=True)}" '
                     f'alt="{html.escape(capture["id"], quote=True)}"></a></figure>')
    for comparison in comparisons or []:
        parts.append('<section><h2>' + html.escape(comparison['id']) + '</h2><pre>'
                     + html.escape(json.dumps(comparison, ensure_ascii=False, indent=2)) + '</pre><div class="pair">')
        for role in ['reference', 'actual', 'difference']:
            name = comparison.get(role)
            if name:
                parts.append(f'<figure><figcaption>{role}</figcaption><a href="{html.escape(name, quote=True)}">'
                             f'<img src="{html.escape(name, quote=True)}" alt="{role}"></a></figure>')
        parts.append('</div></section>')
    parts.append('</html>')
    (directory / 'index.html').write_text('\n'.join(parts))


def terminate_own_capture(directory: Path) -> None:
    pid_file = directory / 'capture.pid'
    if not pid_file.exists():
        return
    pid = int(pid_file.read_text())
    if pid <= 1:
        raise ValueError('Invalid capture process id')
    # A stale pid file alone cannot prove ownership after a timeout.
    running = subprocess.run(['ps', '-ww', '-p', str(pid), '-o', 'comm='],
                             text=True, capture_output=True, check=False)
    if running.returncode != 0:
        return
    expected = directory / 'scratch/LyraReaderVisual.app/Contents/MacOS/LyraReader'
    if running.stdout.strip() != str(expected):
        raise ValueError('Timed-out process identity differs; refusing to terminate it')
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return


def capture(args: argparse.Namespace) -> int:
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    args.created_output = True
    scratch = output / 'scratch'
    scratch.mkdir()
    suite = args.suite
    if suite == 'paper':
        fixture_path = output / 'paper-alignment.pdf'
        fixture(fixture_path)
        multipage = output / 'paper-multipage.pdf'
        fixture(multipage, pages=3)
        fixtures = [fixture_path, multipage]
    elif suite == 'toolbar-inspectors':
        fixture_path = output / 'toolbar-inspectors.pdf'
        fixture(fixture_path, title='LyraReader toolbar and inspector probe')
        fixtures = [fixture_path]
    else:
        fixtures = []
        for index, letter in enumerate('abcdefgh'):
            path = output / f'reader-{letter}.pdf'
            fixture(path, title=f'Reader tab {letter.upper()}', identity=['magenta', 'cyan', 'yellow'][index % 3])
            fixtures.append(path)
        fixture_path = fixtures[0]
    app = scratch / 'LyraReaderVisual.app'
    source = (args.app or ROOT / 'build/LyraReader.app').resolve()
    if not (source / 'Contents/MacOS/LyraReader').is_file():
        raise ValueError('Build the debug application with scripts/make-app-bundle.sh --debug first')
    source_info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    if source_info.get('LyraReaderVisualCapture') is not True:
        raise ValueError('Visual capture requires a debug bundle built with the visual capture capability')
    shutil.copytree(source, app, symlinks=True)
    info_path = app / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info['CFBundleIdentifier'] = 'com.lyrareader.visual-checks.' + uuid.uuid4().hex
    info['CFBundleName'] = 'LyraReaderVisual'
    info['CFBundleDisplayName'] = 'LyraReader Visual Capture'
    info_path.write_bytes(plistlib.dumps(info))
    command(['codesign', '--force', '--sign', '-', str(app)])
    metadata = {
        'commit': command(['git', '-C', str(ROOT), 'rev-parse', 'HEAD']),
        'working_tree_dirty': bool(command(['git', '-C', str(ROOT), 'status', '--porcelain'])),
        'os_build': command(['sw_vers', '-buildVersion']),
        'swift': command(['xcrun', 'swift', '--version']),
        'hardware_model': command(['sysctl', '-n', 'hw.model']),
        'executable_sha256': digest(source / 'Contents/MacOS/LyraReader'),
        'fixture_sha256': digest(fixture_path),
        'pdfium_sha256': digest(source / 'Contents/Frameworks/libpdfium.dylib'),
        'baseline_status': 'unreviewed',
    }
    if len(fixtures) > 1:
        hashes = {path.name: digest(path) for path in fixtures}
        metadata['fixtures_sha256'] = hashes
        metadata['fixture_sha256'] = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
    write_json(output / 'run.json', metadata)
    request = {'fixture': str(fixture_path), 'output': str(output), 'suite': suite,
               'language': args.language, 'appearance': args.appearance}
    if args.mutation:
        request['mutation'] = args.mutation
    write_json(output / 'request.json', request)
    environment = {key: value for key, value in os.environ.items() if not key.startswith('LYRA_READER_')}
    launch = ['open', '-n', '-W', '--stdout', str(output / 'app.stdout.log'),
              '--stderr', str(output / 'app.stderr.log'), '--env',
              'LYRA_READER_VISUAL_REQUEST=' + str(output / 'request.json'), '-a', str(app),
              '--args', '-AppleLanguages', '(' + args.language + ')',
              '-AppleLocale', 'en_US' if args.language == 'en' else 'zh_CN']
    with (output / 'launcher.log').open('w') as log:
        process = subprocess.Popen(launch, stdout=log, stderr=subprocess.STDOUT, env=environment)
        try:
            process.wait(timeout=180)
        except subprocess.TimeoutExpired:
            terminate_own_capture(output)
            process.terminate()
            process.wait(timeout=10)
            raise ValueError('Capture timed out; see launcher and application logs')
    report_path = output / 'capture.json'
    if not report_path.is_file():
        raise ValueError('Application produced no capture manifest; check that the bundle is debug and the desktop is awake')
    report = json.loads(report_path.read_text())
    report['environment'].update(metadata)
    write_json(report_path, report)
    render_report(output, report)
    if report['status'] != 'candidate':
        print(f'FAIL: {report.get("error", "capture failed")}; report: {output / "index.html"}', file=sys.stderr)
        return 1
    if report.get('suite', 'paper') != suite or [item['id'] for item in report['captures']] != expected_captures(report):
        raise ValueError('Incomplete or unexpected capture set')
    # Only the random domain and bundle created by this run are eligible for cleanup.
    subprocess.run(['defaults', 'delete', info['CFBundleIdentifier']], stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, check=False)
    shutil.rmtree(app)
    print(f'UNREVIEWED CANDIDATES: {len(report["captures"])} images; {output / "index.html"}')
    return 0


def load_capture(directory: Path) -> dict:
    report = json.loads((directory / 'capture.json').read_text())
    if report.get('schema_version') != 1 or report.get('status') != 'candidate':
        raise ValueError('A failed or unsupported capture cannot be a comparison input')
    captures = report.get('captures', [])
    if [item['id'] for item in captures] != expected_captures(report):
        raise ValueError('Missing, duplicated, or unexpected captures')
    for item in captures:
        if item['file'] != item['id'] + '.png' or not (directory / item['file']).is_file():
            raise ValueError('Missing or invalid capture file')
    return report


def verify_approval(directory: Path, report: dict) -> None:
    path = directory / 'approval.json'
    if not path.is_file():
        raise ValueError('Baseline has no explicit approval.json; candidates are not automatically accepted')
    approval = json.loads(path.read_text())
    expected = {item['file']: digest(directory / item['file']) for item in report['captures']}
    if approval.get('schema_version') != 1 or approval.get('approved') is not True \
            or approval.get('capture_manifest_sha256') != digest(directory / 'capture.json') \
            or approval.get('sha256') != expected:
        raise ValueError('Baseline approval is absent or does not match the image bytes')


def compare_runs(args: argparse.Namespace) -> int:
    reference_dir = args.baseline.resolve()
    actual_dir = args.actual.resolve()
    reference = load_capture(reference_dir)
    actual = load_capture(actual_dir)
    if reference.get('suite', 'paper') != actual.get('suite', 'paper'):
        raise ValueError('Capture suites differ; each suite requires its own baseline')
    if not args.allow_unreviewed:
        verify_approval(reference_dir, reference)
    # Different valid environments require separate baselines, rather than a looser threshold.
    keys = ['os', 'os_build', 'language', 'appearance', 'locale', 'system_font', 'gpu',
            'capture', 'screen_points', 'display_mode_points', 'display_backing_pixels', 'hardware_model', 'swift', 'pdfium_sha256', 'fixture_sha256']
    if reference.get('suite') == 'toolbar-inspectors':
        keys.extend(['date_preview_clock', 'capture_color_space'])
    for key in keys:
        if key not in reference['environment'] or reference['environment'][key] != actual['environment'].get(key):
            raise ValueError(f'Baseline environment differs or is missing: {key}')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    comparer = compile_comparer(output)
    comparisons = []
    failed = False
    for before, after in zip(reference['captures'], actual['captures'], strict=True):
        for key in ['pixel_width', 'pixel_height', 'backing_scale', 'calibration', 'zoom_percent']:
            if before[key] != after[key]:
                raise ValueError(f'Capture geometry/environment differs for {before["id"]}: {key}')
        sid = before['id']
        reference_name, actual_name, difference_name = f'{sid}-reference.png', f'{sid}-actual.png', f'{sid}-difference.png'
        shutil.copyfile(reference_dir / before['file'], output / reference_name)
        shutil.copyfile(actual_dir / after['file'], output / actual_name)
        result = subprocess.run([str(comparer), str(output / reference_name), str(output / actual_name),
                                 str(output / difference_name), str(args.channel_tolerance)], text=True, capture_output=True)
        record = {'id': sid, 'reference': reference_name, 'actual': actual_name}
        if result.returncode in [0, 1]:
            record.update(json.loads(result.stdout))
            record['difference'] = difference_name
        else:
            record['error'] = result.stderr.strip()
        failed |= result.returncode != 0
        comparisons.append(record)
    report = {'schema_version': 1, 'suite': actual.get('suite', 'paper'),
              'status': 'different' if failed else 'matching',
              'regression_gate': not args.allow_unreviewed, 'environment': actual['environment'], 'comparisons': comparisons}
    write_json(output / 'comparison.json', report)
    render_report(output, report, comparisons)
    print(('FAIL' if failed else 'MATCH') + (': regression gate' if not args.allow_unreviewed else ': unreviewed repeatability comparison')
          + f'; {output / "index.html"}')
    return 1 if failed else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='mode', required=True)
    record = sub.add_parser('capture', help='Capture candidates; does not approve or overwrite a baseline')
    record.add_argument('--output', type=Path, required=True)
    record.add_argument('--app', type=Path)
    record.add_argument('--language', choices=['en', 'zh-Hans'], default='en')
    record.add_argument('--appearance', choices=['light', 'dark'], default='light')
    record.add_argument('--suite', choices=CAPTURE_SUITES, default='paper')
    record.add_argument('--mutation', choices=['scale', 'chrome'])
    check = sub.add_parser('compare', help='Compare against a reviewed, hash-bound baseline')
    check.add_argument('--baseline', type=Path, required=True)
    check.add_argument('--actual', type=Path, required=True)
    check.add_argument('--output', type=Path, required=True)
    check.add_argument('--channel-tolerance', type=int, choices=range(17), default=0)
    check.add_argument('--allow-unreviewed', action='store_true', help='Developer repeatability probe only; not a regression gate')
    sub.add_parser('self-test', help='Exercise image comparison without launching an application')
    args = parser.parse_args()
    if args.mode == 'capture':
        try:
            return capture(args)
        except (ValueError, OSError, subprocess.SubprocessError) as error:
            if getattr(args, 'created_output', False) and not (args.output / 'capture.json').exists():
                report = {'schema_version': 1, 'status': 'failed', 'captures': [], 'error': str(error)}
                write_json(args.output / 'capture.json', report)
                render_report(args.output, report)
            raise
    if args.mode == 'compare':
        return compare_runs(args)
    with tempfile.TemporaryDirectory(prefix='lyra-visual-compare-') as directory:
        print(command([str(compile_comparer(Path(directory))), '--self-test']))
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f'visual-check: {error}', file=sys.stderr)
        raise SystemExit(2)
