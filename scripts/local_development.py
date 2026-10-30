#!/usr/bin/env python3
"""Install/remove one frozen local test build with native macOS administrator consent.
No password is read by Python. System settings are never modified by this installer.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import subprocess

BASE = Path('/Library/Application Support/LocaleShiftLocalDevelopment')
ROLES = {'LocaleShift': 'app', 'LocaleShiftUserAgent': 'user-agent', 'LocaleShiftTimezoneService': 'timezone-service'}


def q(value):
    return shlex.quote(str(value))


def administrator(script):
    # AppleScript string escaping and shell quoting are independent layers.
    literal = '"' + script.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'
    subprocess.run(['/usr/bin/osascript', '-e', 'do shell script ' + literal + ' with administrator privileges'], check=True)


def inspect(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    build = info.get('LocaleShiftDevelopmentBuild', '')
    if not re.fullmatch('[0-9a-f]{32}', build) or info['CFBundleIdentifier'] != f'com.localeshift.localdev.{build}.app':
        raise SystemExit('Not an explicitly built local development package.')
    if os.getuid() < 500:
        raise SystemExit('Run as the local user, not root.')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    hashes = {}
    for name, role in ROLES.items():
        executable = app / 'Contents/MacOS' / name
        signature = subprocess.run(['/usr/bin/codesign', '-dv', '--verbose=4', str(executable)], text=True, capture_output=True, check=True).stderr
        identifier = f'com.localeshift.localdev.{build}.{role}'
        if f'Identifier={identifier}\n' not in signature:
            raise SystemExit(f'Unexpected signing identifier for {name}.')
        match = re.search(r'^CDHash=([0-9a-f]{40})$', signature, re.MULTILINE)
        if not match:
            raise SystemExit(f'Missing code hash for {name}.')
        hashes[name] = match.group(1)
    destination = BASE / 'Builds' / build / 'LocaleShift.app'
    manifest = {'version': 1, 'build': build, 'uid': os.getuid(), 'bundle': str(destination), 'hashes': hashes}
    return manifest


# Never normalize an existing untrusted directory into a trusted one.
PROTECTED_DIRECTORY = '''
protected_directory() {
  [ -d "$1" ] && [ ! -L "$1" ] && [ "$(/usr/bin/stat -f %u "$1")" = 0 ] || exit 70
  mode=$(/usr/bin/stat -f %Lp "$1")
  [ "$((0$mode & 022))" = 0 ] || exit 70
}
protected_directory /Library
protected_directory '/Library/Application Support'
'''


def install(app, dry_run):
    manifest = inspect(app)
    dest = Path(manifest['bundle'])
    if (BASE / 'trust.json').exists():
        raise SystemExit('A local test version is already installed. Restore and unregister it before removing/updating; it will not be overwritten.')
    lines = ['set -eu', 'umask 022', PROTECTED_DIRECTORY,
             f'base={q(BASE)}', f'dest={q(dest)}',
             '[ -e "$base" ] || /bin/mkdir "$base"', 'protected_directory "$base"',
             '[ -e "$base/Builds" ] || /bin/mkdir "$base/Builds"', 'protected_directory "$base/Builds"',
             '/bin/mkdir "$base/.install-lock"',
             'trap \'/bin/rmdir "$base/.install-lock"\' EXIT',
             '[ ! -e "$base/trust.json" ] && [ ! -L "$base/trust.json" ]',
             f'[ -e {q(dest.parent)} ] || /bin/mkdir {q(dest.parent)}',
             f'protected_directory {q(dest.parent)}',
             f'[ -e "$dest" ] || /usr/bin/ditto {q(app)} "$dest"',
             '[ -d "$dest" ] && [ ! -L "$dest" ]',
             '[ -z "$(/usr/bin/find "$dest" -type l -print -quit)" ]',
             '/usr/sbin/chown -R root:wheel "$dest"',
             '/usr/bin/find "$dest" -type d -exec /bin/chmod 755 {} +',
             '/usr/bin/find "$dest" -type f -exec /bin/chmod 644 {} +']
    lines += ['protected_directory "$dest"',
              '[ -z "$(/usr/bin/find "$dest" ! -user root -print -quit)" ]',
              '[ -z "$(/usr/bin/find "$dest" -type l -print -quit)" ]',
              '[ -z "$(/usr/bin/find "$dest" ! -type f ! -type d -print -quit)" ]',
              '[ -z "$(/usr/bin/find "$dest" -perm +022 -print -quit)" ]']
    lines += [f'/bin/chmod 755 {q(dest / "Contents/MacOS" / name)}' for name in ROLES]
    lines.append('/usr/bin/codesign --verify --deep --strict "$dest"')
    for name, role in ROLES.items():
        req = f'identifier "com.localeshift.localdev.{manifest["build"]}.{role}" and cdhash H"{manifest["hashes"][name]}"'
        lines.append(f'/usr/bin/codesign --verify --strict -R {q("=" + req)} {q(dest / "Contents/MacOS" / name)}')
    lines += [f'/usr/bin/printf %s {q(json.dumps(manifest, sort_keys=True))} > "$base/.trust-new.json"',
              '/usr/sbin/chown root:wheel "$base/.trust-new.json"', '/bin/chmod 644 "$base/.trust-new.json"',
              '/bin/mv "$base/.trust-new.json" "$base/trust.json"']
    if dry_run:
        print(json.dumps(manifest, indent=2)); print('\n'.join(lines)); return
    print('macOS will request administrator approval to install this fixed local test build. Enter credentials only in the system dialog.', flush=True)
    administrator('\n'.join(lines))
    subprocess.run([str(dest / 'Contents/MacOS/LocaleShift'), '--diagnostics'], check=True)
    print(f'Installed: {dest}\nNext: "{dest}/Contents/MacOS/LocaleShift" --local-command register')


def remove(dry_run):
    manifest = json.loads((BASE / 'trust.json').read_text())
    app = Path(manifest['bundle'])
    if inspect(app) != manifest:
        raise SystemExit('Installed manifest no longer matches; leave recovery files intact for manual investigation.')
    command = [str(app / 'Contents/MacOS/LocaleShift'), '--local-command', 'unregister']
    if not dry_run:
        subprocess.run(command, check=True)
        running = subprocess.run(['/usr/bin/pgrep', '-f', str(app / 'Contents/MacOS')], capture_output=True)
        if running.returncode != 1:
            raise SystemExit('Installed processes remain (or cannot be inspected). Quit the app, wait for helpers to stop, and retry; installed bytes are preserved.')
    script = '\n'.join(['set -eu', PROTECTED_DIRECTORY, f'protected_directory {q(BASE)}',
                         f'/bin/mkdir {q(BASE / ".install-lock")}',
                         f'trap {q("/bin/rmdir " + q(BASE / ".install-lock"))} EXIT',
                         # Root opens/checks the durable journal before installation trust can be removed.
                         f'{q(app / "Contents/MacOS/LocaleShiftTimezoneService")} --local-removal-check',
                         f'/bin/rm {q(BASE / "trust.json")}', f'/bin/rm -rf {q(app.parent)}'])
    if dry_run:
        print(' '.join(map(q, command))); print(script); return
    administrator(script)
    print('Removed local test executables and trust. User records and the empty machine journal are preserved.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['install', 'remove', 'status'])
    parser.add_argument('--app', type=Path)
    parser.add_argument('--dry-run', action='store_true', help='inspect and print commands without authorization, installation or service registration')
    args = parser.parse_args()
    if args.action == 'install':
        if not args.app:
            parser.error('install requires --app')
        install(args.app.resolve(), args.dry_run)
    elif args.action == 'remove':
        remove(args.dry_run)
    else:
        print((BASE / 'trust.json').read_text() if (BASE / 'trust.json').exists() else 'No local test build installed.')
