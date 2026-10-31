#!/usr/bin/env python3
"""Bounded listener freshness sampling and per-home systemd unit management."""

import hashlib
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

SCRIPT = Path(__file__).with_suffix('.sh')
HEALTH_HOME = Path(os.environ['FM_HOME'])
STATE = Path(os.environ['FM_STATE_OVERRIDE'])
POLL = int(os.environ['FM_POLL'])
CADENCED_FAILURE = 75
CHECK_IN_GRACE = POLL / 2


def command(args, timeout=5):
    process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, start_new_session=True)
    try:
        out, err = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise RuntimeError(f'command timed out: {args[0]}')
    return process.returncode, out.strip(), err.strip()


def freshness():
    stamps = []
    for name in ('.last-watcher-beat', '.last-successful-drain'):
        path = STATE / name
        if path.is_file() and not path.is_symlink():
            stamps.append(path.stat().st_mtime)
    return max(stamps, default=0)


def delivery_problem():
    marker = STATE / '.primary-loss-alert'
    if not marker.is_file():
        return ''
    lines = marker.read_text().splitlines()
    if lines and lines[0].startswith('listener-health:') and lines[1:] != ['delivery-sent']:
        return 'Telegram delivery failed or remains uncertain; automatic resend is suppressed'
    return ''


def check_window(wait, deadline):
    while True:
        fresh = freshness()
        if fresh > time.time() + 1:
            raise RuntimeError('supervision timestamp is in the future')
        remaining = fresh + CHECK_IN_GRACE - time.time()
        if remaining > 0:
            if (STATE / '.primary-loss-alert').exists():
                rc, _, err = command([str(SCRIPT), '_clear'])
                if rc:
                    raise RuntimeError(err or 'could not clear recovered incident')
        else:
            problem = delivery_problem()
            if problem:
                raise RuntimeError(problem)
            rc, _, err = command([str(SCRIPT), '_live'], timeout=min(POLL, 5))
            if rc not in (0, 1):
                raise RuntimeError(err or 'endpoint check failed')
            if rc == 0:
                if freshness() + CHECK_IN_GRACE > time.time():
                    continue
                rc, out, err = command([str(SCRIPT), '_incident'], timeout=POLL + 5)
                if out:
                    print(out)
                if rc:
                    raise RuntimeError(err or 'incident publication failed')
                print('supervision-health: primary-supervision-lost')
            else:
                print('supervision-health: no live work')
            return
        budget = deadline - time.monotonic()
        if not wait or budget <= 0:
            print('supervision-health: healthy')
            return
        time.sleep(min(remaining, budget, 0.2))


def check(wait):
    deadline = time.monotonic() + (POLL if wait else 0)
    try:
        check_window(wait, deadline)
    finally:
        if wait:
            time.sleep(max(0, deadline - time.monotonic()))


def quote(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%').replace('\n', '\\n') + '"'


def units():
    name = 'firstmate-supervision-health-' + hashlib.sha256(str(HEALTH_HOME).encode()).hexdigest()[:16]
    directory = Path(os.environ.get('FM_SUPERVISION_UNIT_DIR',
                     str(Path(os.environ.get('XDG_CONFIG_HOME', str(Path.home() / '.config'))) / 'systemd/user')))
    env = {key: os.environ[key] for key in ('FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE',
           'FM_CONFIG_OVERRIDE', 'FM_POLL', 'PATH')}
    env['PATH'] = os.pathsep.join(dict.fromkeys(env['PATH'].split(os.pathsep)))
    service = '[Unit]\nDescription=Firstmate independent supervision health\nStartLimitIntervalSec=0\n\n[Service]\nType=oneshot\nRestart=on-failure\n'
    service += f'RestartPreventExitStatus={CADENCED_FAILURE}\n'
    service += ''.join(f'Environment={quote(key + "=" + value)}\n' for key, value in env.items())
    bash = shutil.which('bash')
    if not bash:
        raise RuntimeError('bash is required')
    service += f'RestartSec={POLL}s\n'
    service += f'ExecStart={quote(bash)} {quote(SCRIPT)} run\nTimeoutStartSec={POLL + 10}\n'
    timer = ('[Unit]\nDescription=Firstmate independent supervision health cadence\n\n[Timer]\n'
             f'OnActiveSec=1ms\nOnUnitActiveSec={POLL}s\nOnUnitInactiveSec=1ms\nAccuracySec=1ms\n'
             f'Unit={name}.service\n\n[Install]\nWantedBy=timers.target\n')
    return name, directory, {name + '.service': service, name + '.timer': timer}


def systemctl(*args):
    rc, out, err = command(['systemctl', '--user', *args])
    if rc:
        raise RuntimeError(err or out or 'systemctl --user failed')
    return out


def manage(install):
    if not shutil.which('systemctl'):
        raise RuntimeError('independent supervision timer requires Linux systemd --user')
    name, directory, expected = units()
    if install:
        if directory.is_symlink():
            raise RuntimeError('unit directory must not be a symlink')
        directory.mkdir(parents=True, exist_ok=True)
        for file, content in expected.items():
            path = directory / file
            if path.is_symlink():
                raise RuntimeError(f'refusing symlink unit: {path}')
            with tempfile.NamedTemporaryFile(mode='w', dir=directory, delete=False) as tmp:
                tmp.write(content)
            os.replace(tmp.name, path)
        systemctl('daemon-reload')
        systemctl('enable', '--now', name + '.timer')
        systemctl('restart', name + '.timer')
    for file, content in expected.items():
        path = directory / file
        if path.is_symlink() or not path.is_file() or path.read_text() != content:
            raise RuntimeError(f'unit missing or outdated: {path}; run install')
    if systemctl('is-enabled', name + '.timer') != 'enabled':
        raise RuntimeError('timer is not enabled')
    if systemctl('is-active', name + '.timer') != 'active':
        raise RuntimeError('timer is not active')
    problem = delivery_problem()
    if problem:
        raise RuntimeError(problem)
    result = systemctl('show', name + '.service', '--property=Result', '--value')
    if result not in ('', 'success'):
        raise RuntimeError(f'last oneshot failed: {result}')
    print(f'supervision-health: ready {name}.timer poll={POLL}s')


try:
    if sys.argv[1] == 'delivery':
        problem = delivery_problem()
        if problem:
            raise RuntimeError(problem)
        sys.exit(0)
    if sys.argv[1] == 'fresh':
        sys.exit(0 if freshness() + CHECK_IN_GRACE > time.time() else 1)
    if sys.argv[1] in ('check', 'run'):
        check(sys.argv[1] == 'run')
    else:
        manage(sys.argv[1] == 'install')
except (OSError, RuntimeError, ValueError) as error:
    print(f'supervision-health: {error}', file=sys.stderr)
    sys.exit(CADENCED_FAILURE if sys.argv[1] == 'run' else 1)
