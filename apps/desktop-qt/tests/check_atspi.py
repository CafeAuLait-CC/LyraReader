#!/usr/bin/env python3
"""Exercise only a child LyraReader's real AT-SPI bridge; never the user's apps.

Requires the optional system PyGObject/Atspi typelibs and an accessibility bus.
Returns 77 if those prerequisites are unavailable. Does not claim Orca coverage.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    root = Path(__file__).resolve().parents[3]
    parser.add_argument('--binary', type=Path, default=root / 'build/desktop-qt-debug/LyraReader')
    parser.add_argument('--platform', choices=['wayland', 'xcb', 'offscreen'], default='wayland')
    parser.add_argument('--graphics', choices=['vulkan', 'opengl', 'software'], default='vulkan')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--forms', action='store_true', help='Also exercise draft-only form actions')
    parser.add_argument('--overview', action='store_true', help='Also exercise thumbnail and overview actions')
    args = parser.parse_args()
    try:
        import gi
        gi.require_version('Atspi', '2.0')
        from gi.repository import Atspi, Gio, GLib
    except (ImportError, ValueError) as error:
        print(f'SKIP: optional AT-SPI Python runtime unavailable: {error}', file=sys.stderr)
        return 77

    try:
        session = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        address = session.call_sync('org.a11y.Bus', '/org/a11y/bus', 'org.a11y.Bus',
                                    'GetAddress', None, None, 0, 3000, None).unpack()[0]
        bus = Gio.DBusConnection.new_for_address_sync(
            address, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT |
            Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
    except GLib.Error as error:
        print(f'SKIP: accessibility bus unavailable: {error}', file=sys.stderr)
        return 77

    accessible = 'org.a11y.atspi.Accessible'
    properties = 'org.freedesktop.DBus.Properties'
    app_root = '/org/a11y/atspi/accessible/root'
    name = None

    def call(destination, obj, interface, method, signature=None, values=()):
        params = GLib.Variant(signature, values) if signature else None
        return bus.call_sync(destination, obj, interface, method, params,
                             None, 0, 3000, None).unpack()

    def get(obj, interface, prop):
        return call(name, obj, properties, 'Get', '(ss)', (interface, prop))[0]

    def state(obj, flag):
        if not obj:
            return False
        words = call(name, obj, accessible, 'GetState')[0]
        bit = int(flag)
        return bool(words[bit // 32] & (1 << (bit % 32)))

    def showing(obj):
        return state(obj, Atspi.StateType.VISIBLE) and state(obj, Atspi.StateType.SHOWING)

    def tree(start=None):
        pending, seen, nodes = [start or app_root], set(), []
        while pending:
            obj = pending.pop()
            if obj in seen:
                continue
            seen.add(obj)
            if len(seen) > 1000:
                raise AssertionError('Unexpectedly large fixture accessibility tree')
            nodes.append((obj, get(obj, accessible, 'Name')))
            pending.extend(child for owner, child in call(name, obj, accessible, 'GetChildren')[0]
                           if owner == name)
        return nodes

    def wait(description, predicate, seconds=45):
        print(f'Checking: {description}', flush=True)
        end, last_error = time.monotonic() + seconds, None
        while time.monotonic() < end:
            if process.poll() is not None:
                raise AssertionError(f'Reader exited before {description}: {process.returncode}')
            try:
                value = predicate()
                if value:
                    return value
            except GLib.Error as error:
                last_error = error
            time.sleep(.1)
        raise AssertionError(f'Timed out: {description}; last D-Bus error: {last_error}')

    def find(label, role=None, within=None):
        for obj, text in tree(within):
            if (label is None or text == label) and showing(obj) and (role is None or
                    call(name, obj, accessible, 'GetRole')[0] == int(role)):
                return obj
        return None

    def press(obj, preferred='press'):
        actions = call(name, obj, 'org.a11y.atspi.Action', 'GetActions')[0]
        index = next((i for i, action in enumerate(actions) if action[0].lower() == preferred), None)
        if index is None:
            index = next((i for i, action in enumerate(actions) if action[0].lower() == 'toggle'), None)
        assert index is not None, f'No press action for {get(obj, accessible, "Name")}: {actions}'
        print(f'Action: {get(obj, accessible, "Name")} {actions[index][0]}', flush=True)
        assert call(name, obj, 'org.a11y.atspi.Action', 'DoAction', '(i)', (index,))[0]

    report = {'platform': args.platform, 'graphics': args.graphics,
              'coverage': 'AT-SPI actions, states, text and selection; no Orca/global-key claim'}
    with tempfile.TemporaryDirectory(prefix='lyra-atspi-') as temp:
        folder = Path(temp)
        first, second = folder / 'first.pdf', folder / 'second.pdf'
        shutil.copyfile(root / 'tests/fixtures/multipage.pdf', first)
        shutil.copyfile(root / 'tests/fixtures/text-page.pdf', second)
        inputs = [str(first), str(second)]
        if args.forms:
            form = folder / 'forms.pdf'
            shutil.copyfile(root / 'tests/fixtures/form-fields.pdf', form)
            form_bytes = form.read_bytes()
            inputs.append(str(form))
        env = dict(os.environ, QT_QPA_PLATFORM=args.platform,
                   QT_LINUX_ACCESSIBILITY_ALWAYS_ON='1', XDG_CONFIG_HOME=str(folder / 'config'))
        with (folder / 'reader.log').open('w+') as log:
            process = subprocess.Popen([str(args.binary.resolve()), *inputs,
                                        '--graphics', args.graphics, '--quit-after', '180000'],
                                       env=env, stdout=log, stderr=subprocess.STDOUT)
            try:
                def own_name():
                    for owner, _ in call('org.a11y.atspi.Registry', app_root, accessible, 'GetChildren')[0]:
                        try:
                            pid = call('org.freedesktop.DBus', '/org/freedesktop/DBus',
                                       'org.freedesktop.DBus', 'GetConnectionUnixProcessID', '(s)', (owner,))[0]
                        except GLib.Error:
                            continue  # A registry entry can disappear during enumeration.
                        if pid == process.pid:
                            return owner
                    return None
                name = wait('child accessibility registration', own_name)
                assert get(app_root, accessible, 'Name') == 'LyraReader'
                tab = wait('first document tab', lambda: find('first.pdf', Atspi.Role.PAGE_TAB))
                press(tab)
                wait('AT-SPI tab activation', lambda: state(tab, Atspi.StateType.SELECTED))
                press(wait('view settings', lambda: find('View settings')))
                press(wait('text reading menu', lambda: find('Read Page Text (Ctrl+Shift+R)')))
                text = wait('visible page text', lambda: find('Page 1 text', Atspi.Role.TEXT))
                contents = wait('extracted text', lambda: call(name, text, 'org.a11y.atspi.Text', 'GetText', '(ii)', (0, -1))[0])
                assert 'Page 1 of 3' in contents, contents
                assert state(text, Atspi.StateType.READ_ONLY)
                assert not state(text, Atspi.StateType.EDITABLE)
                assert get(text, 'org.a11y.atspi.Text', 'CharacterCount') == len(contents)
                assert call(name, text, 'org.a11y.atspi.Text', 'AddSelection', '(ii)', (0, 4))[0]
                assert call(name, text, 'org.a11y.atspi.Text', 'GetSelection', '(i)', (0,)) == (0, 4)
                assert call(name, text, 'org.a11y.atspi.Text', 'RemoveSelection', '(i)', (0,))[0]
                press(wait('next page', lambda: find('Next page')))
                text2 = wait('second page text', lambda: find('Page 2 text', Atspi.Role.TEXT))
                contents2 = wait('second extracted text', lambda: call(name, text2, 'org.a11y.atspi.Text', 'GetText', '(ii)', (0, -1))[0])
                assert 'Page 2 of 3' in contents2, contents2
                press(wait('return to canvas', lambda: find('Return to page view (Ctrl+Shift+R)')))
                wait('text view no longer showing', lambda: not showing(text2))
                report.update(passed=True, assertions=['tab activation', 'menu action', 'read-only text',
                              'character count', 'selection round trip', 'page action', 'hidden state'],
                              firstPageCharacters=len(contents), secondPageCharacters=len(contents2))
                if args.overview:
                    thumbnail = wait('named thumbnail', lambda: find('Page 1 thumbnail', Atspi.Role.LIST_ITEM))
                    press(thumbnail)
                    wait('thumbnail selection', lambda: state(thumbnail, Atspi.StateType.SELECTED))
                    press(wait('overview action', lambda: find('Page overview')))
                    page = wait('overview page', lambda: find('Overview page 3', Atspi.Role.LIST_ITEM))
                    press(page)
                    wait('overview selection', lambda: state(page, Atspi.StateType.SELECTED))
                    press(wait('leave overview', lambda: find('Close Page Overview')))
                    wait('overview no longer showing', lambda: not showing(page))
                    report['assertions'].append('thumbnail and overview actions/states')
                if args.forms:
                    press(wait('form tab', lambda: find('forms.pdf', Atspi.Role.PAGE_TAB)))
                    press(wait('inline form mode', lambda: find('Fill & Sign')))
                    check = wait('editable checkbox', lambda: find('agree', Atspi.Role.CHECK_BOX))
                    reset = wait('form draft reset', lambda: find('Reset Form Edits'))
                    assert not state(reset, Atspi.StateType.ENABLED)
                    press(check, 'toggle')
                    wait('checkbox action recorded as a draft', lambda: state(reset, Atspi.StateType.ENABLED))
                    press(reset)
                    wait('checkbox draft reset', lambda: not state(check, Atspi.StateType.CHECKED))
                    wait('no draft after reset', lambda: not state(reset, Atspi.StateType.ENABLED))
                    report['assertions'].append('form checkbox draft/reset')
                    radio = wait('radio option', lambda: find('color: Red', Atspi.Role.RADIO_BUTTON))
                    press(radio, 'toggle')
                    wait('radio action recorded as a draft', lambda: state(reset, Atspi.StateType.ENABLED))
                    assert state(radio, Atspi.StateType.CHECKED)
                    press(reset)
                    wait('radio draft reset', lambda: not state(radio, Atspi.StateType.CHECKED))
                    report['assertions'].append('form radio draft/reset')
                    entry = wait('form text field', lambda: find('fullName', Atspi.Role.TEXT))
                    interfaces = call(name, entry, accessible, 'GetInterfaces')[0]
                    report['formEditableTextInterface'] = 'org.a11y.atspi.EditableText' in interfaces
                    print('Form text interfaces:', interfaces, flush=True)
                    if report['formEditableTextInterface']:
                        assert call(name, entry, 'org.a11y.atspi.EditableText', 'SetTextContents', '(s)', ('Assistive form text',))[0]
                        wait('text action recorded as a draft', lambda: state(reset, Atspi.StateType.ENABLED))
                        press(reset)
                        wait('text draft reset', lambda: not call(name, entry, 'org.a11y.atspi.Text', 'GetText', '(ii)', (0, -1))[0])
                        report['assertions'].append('form text draft/reset')
                    press(wait('all fields', lambda: find('All Fields…')))
                    dialog = wait('fields dialog', lambda: find(None, Atspi.Role.DIALOG))
                    dialog_check = wait('dialog checkbox', lambda: find('agree', Atspi.Role.CHECK_BOX, dialog))
                    press(dialog_check, 'toggle')
                    wait('dialog action recorded as a draft', lambda: state(reset, Atspi.StateType.ENABLED))
                    press(reset)
                    wait('dialog checkbox draft reset', lambda: not state(dialog_check, Atspi.StateType.CHECKED))
                    report['assertions'].append('form dialog draft/reset')
                    assert form.read_bytes() == form_bytes, 'Draft actions must leave the source unchanged'
                    press(wait('close fields dialog', lambda: find('Close', Atspi.Role.PUSH_BUTTON, dialog)))
                    press(wait('leave form mode', lambda: find('Fill & Sign')))
                if args.overview:
                    for filename in reversed(inputs):
                        press(wait('close copied document', lambda f=filename: find('Close ' + Path(f).name)))
                    recent = wait('recent document', lambda: find('Open recent document first.pdf', Atspi.Role.LIST_ITEM))
                    press(recent)
                    wait('reopened document', lambda: find('Page 1 thumbnail', Atspi.Role.LIST_ITEM))
                    report['assertions'].append('recent document activation')
            except Exception:
                try:
                    print('Own page-related accessibility states:', [
                        (label, call(name, obj, accessible, 'GetState')[0])
                        for obj, label in tree() if 'page' in label.lower() or 'text' in label.lower() or label in ('agree', 'Reset Form Edits')
                    ], file=sys.stderr)
                except GLib.Error:
                    pass
                log.seek(0)
                print(log.read(), file=sys.stderr)
                raise
            finally:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                log.seek(0)
                if args.output:
                    args.output.parent.mkdir(parents=True, exist_ok=True)
                    args.output.with_suffix('.reader.log').write_text(log.read())
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))
    return 0


if __name__ == '__main__':
    sys.exit(main())
