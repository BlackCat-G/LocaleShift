#!/usr/bin/env python3
"""Build three native executables and package without registering or launching services."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--identity', default='-', help='codesign identity; default ad-hoc read-only development')
parser.add_argument('--configuration', choices=['debug', 'release'], default='release')
parser.add_argument('--require-system-switching', action='store_true', help='refuse ad-hoc/signature-only output; require matching Apple-anchored Team ID signatures for all three processes')
parser.add_argument('--local-development', action='store_true', help='build a unique, frozen local test package; administrator installation is required separately')
parser.add_argument('--output', type=Path, default=ROOT / 'build' / 'LocaleShift.app')
args = parser.parse_args()
if args.local_development and (args.require_system_switching or args.identity != '-'):
    raise SystemExit('--local-development uses pinned ad-hoc signing; do not combine with production signing options.')
build_id = uuid.uuid4().hex if args.local_development else None
prefix = 'com.localeshift.localdev.' + build_id if build_id else 'com.localeshift'
app_id, agent_id, root_id = [prefix + suffix for suffix in ['.app', '.user-agent', '.timezone-service']]
if args.require_system_switching and args.identity == '-':
    raise SystemExit('System-switching build requires --identity with a valid Apple development/signing certificate. Ad-hoc output is read-only.')
env = os.environ.copy()
env.setdefault('CLANG_MODULE_CACHE_PATH', str(Path(tempfile.gettempdir()) / 'localeshift-clang'))
env.setdefault('SWIFTPM_MODULECACHE_OVERRIDE', str(Path(tempfile.gettempdir()) / 'localeshift-modules'))
scratch = ROOT / ('.build-local-development' if args.local_development else '.build')
command = ['swift', 'build', '--disable-sandbox', '--scratch-path', str(scratch), '-c', args.configuration]
if args.local_development:
    command += ['-Xswiftc', '-DLOCALESHIFT_LOCAL_DEVELOPMENT']
subprocess.run(command, cwd=ROOT, env=env, check=True)
path_command = command + ['--show-bin-path']
bin_path = Path(subprocess.check_output(path_command, cwd=ROOT, env=env, text=True).strip())
app = args.output.resolve()
# A new directory is constructed in the destination parent. Never mutate a running/registered helper in place.
app.parent.mkdir(parents=True, exist_ok=True)
staging = Path(tempfile.mkdtemp(prefix='.LocaleShift-build-', dir=app.parent)) / 'LocaleShift.app'
contents = staging / 'Contents'
(contents / 'MacOS').mkdir(parents=True)
(contents / 'Resources').mkdir()
for name in ['LocaleShift', 'LocaleShiftUserAgent', 'LocaleShiftTimezoneService']:
    shutil.copy2(bin_path / name, contents / 'MacOS' / name)
# Resource resolvers load these bundles from the signed app's Resources folder.
for target in ['LocaleShiftCore', 'LocaleShiftApp']:
    for resource in bin_path.glob('*' + target + '.bundle'):
        shutil.copytree(resource, contents / 'Resources' / resource.name)
shutil.copy2(ROOT / 'assets' / 'branding' / 'AppIcon.icns', contents / 'Resources' / 'AppIcon.icns')
info = {'CFBundleIdentifier': app_id, 'CFBundleName': 'LocaleShift Local Test' if args.local_development else 'LocaleShift',
        'CFBundleDisplayName': 'LocaleShift', 'CFBundleExecutable': 'LocaleShift',
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '1',
        'LSMinimumSystemVersion': '13.0', 'LSUIElement': True,
        'CFBundleDevelopmentRegion': 'zh-Hans', 'CFBundleLocalizations': ['zh-Hans'],
        'NSHighResolutionCapable': True, 'CFBundleIconFile': 'AppIcon.icns'}
if build_id:
    info['LocaleShiftDevelopmentBuild'] = build_id
    info['CFBundleDisplayName'] = 'LocaleShift 本机测试版'
with (contents / 'Info.plist').open('wb') as output:
    plistlib.dump(info, output)
for category, identifier, executable, extra in [
    ('LaunchAgents', agent_id, 'LocaleShiftUserAgent', {'LimitLoadToSessionType': 'Aqua'}),
    ('LaunchDaemons', root_id, 'LocaleShiftTimezoneService', {})]:
    folder = contents / 'Library' / category
    folder.mkdir(parents=True)
    settings = {'Label': identifier, 'BundleProgram': 'Contents/MacOS/' + executable,
                'MachServices': {identifier: True}, 'RunAtLoad': True, 'KeepAlive': True,
                'ThrottleInterval': 10, 'AssociatedBundleIdentifiers': [app_id], **extra}
    with (folder / (identifier + '.plist')).open('wb') as output:
        plistlib.dump(settings, output)
for name, identifier in [('LocaleShiftUserAgent', agent_id), ('LocaleShiftTimezoneService', root_id)]:
    subprocess.run(['codesign', '--force', '--sign', args.identity, '--identifier', identifier, '--options', 'runtime', str(contents / 'MacOS' / name)], check=True)
subprocess.run(['codesign', '--force', '--sign', args.identity, '--options', 'runtime', str(staging)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(staging)], check=True)
if args.require_system_switching:
    items = [(staging, 'com.localeshift.app'),
             (contents / 'MacOS' / 'LocaleShiftUserAgent', 'com.localeshift.user-agent'),
             (contents / 'MacOS' / 'LocaleShiftTimezoneService', 'com.localeshift.timezone-service')]
    expected_team = None
    for item, identifier in items:
        inspection = subprocess.run(['codesign', '-dv', '--verbose=4', str(item)], capture_output=True, text=True, check=True)
        match = re.search(r'^TeamIdentifier=([A-Z0-9]+)$', inspection.stderr, re.MULTILINE)
        if not match:
            raise SystemExit(f'Missing Apple Team ID; this package cannot enable system switching. Staging preserved: {staging}')
        team = match.group(1)
        if expected_team is not None and expected_team != team:
            raise SystemExit(f'App and helpers must share one signing team. Staging preserved: {staging}')
        expected_team = team
        requirement = f'anchor apple generic and certificate leaf[subject.OU] = "{team}" and identifier "{identifier}"'
        subprocess.run(['codesign', '--verify', '--strict', '-R', '=' + requirement, str(item)], check=True)
    print(f'System-switching signature preflight passed for all three processes; Team ID: {expected_team}')

# Replacement is for an unregistered development artifact. Release upgrades must restore/unregister first.
if app.exists():
    previous = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    previous_prefix = previous['CFBundleIdentifier'].removesuffix('.app')
    for label in [f'gui/{os.getuid()}/{previous_prefix}.user-agent', f'system/{previous_prefix}.timezone-service']:
        loaded = subprocess.run(['launchctl', 'print', label], capture_output=True)
        if loaded.returncode != 0 and b'Operation not permitted' in loaded.stderr:
            raise SystemExit(f'Cannot verify service status; staging preserved at {staging}. Run from an authorized local terminal.')
        if loaded.returncode == 0:
            raise SystemExit(f'Protection service is registered; restore/unregister before replacing. Staging: {staging}')
    registered = subprocess.run(['pgrep', '-f', str(app / 'Contents' / 'MacOS')], capture_output=True)
    if registered.returncode not in (0, 1):
        raise SystemExit(f'Cannot verify running processes; staging preserved at {staging}. Run from an authorized local terminal.')
    if registered.returncode == 0:
        raise SystemExit(f'App is running; staging preserved at {staging}. Quit and restore before replacing.')
    shutil.rmtree(app)
shutil.move(str(staging), str(app))
staging.parent.rmdir()
print(f'Built {app}')
if build_id:
    print(f'Local test build {build_id}. Run scripts/local_development.py install --app {app} to request native administrator installation. This workspace copy remains read-only.')
else:
    print('Ad-hoc development: configuration and read-only UI available; privileged writes require trusted Team ID.' if args.identity == '-' else 'Signed build ready for separate service integration acceptance.')
