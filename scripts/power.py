#!/usr/bin/env python3
"""Power diagnostics, measurements, and narrowly scoped optional policies."""
import argparse
import json
from pathlib import Path
import select
import socket
import subprocess
import sys
import time

SYS = Path('/sys')


def read(path):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return None


def command(args):
    try:
        result = subprocess.run(args, text=True, capture_output=True, timeout=15)
        return result.stdout.strip() if result.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def supplies(base=SYS):
    return {p.name: {key: read(p/key) for key in (
        'type', 'status', 'online', 'capacity', 'energy_now', 'energy_full',
        'power_now', 'charge_now', 'voltage_now', 'current_now', 'charge_types',
        'charge_control_end_threshold')} for p in sorted((base/'class/power_supply').glob('*'))}


def ac_online(base=SYS):
    return any(s['online'] == '1' and s['type'] != 'Battery' for s in supplies(base).values())


def conservation(mode, base=SYS):
    if mode == 'unchanged':
        return []
    if 'lenovo' not in (read(base/'class/dmi/id/sys_vendor') or '').lower():
        raise ValueError('Charge conservation is only configured for Lenovo machines')
    modern = [p for p in (base/'class/power_supply').glob('*/charge_types')
              if 'Long Life' in (read(p) or '') and 'Standard' in (read(p) or '')]
    legacy = list((base/'bus/platform/drivers/ideapad_acpi').glob('*/conservation_mode'))
    paths = modern or legacy
    if not paths:
        raise ValueError('SKIP: firmware exposes no supported charge conservation control')
    if mode == 'enabled':
        for p in (base/'bus/platform/drivers/ideapad_acpi').glob('*/rapid_charge'):
            p.write_text('0\n')
    value = ('Long Life' if mode == 'enabled' else 'Standard') if modern else ('1' if mode == 'enabled' else '0')
    for p in paths:
        p.write_text(value + '\n')
    return [str(p) for p in paths]


def profiles(ac, battery):
    # Kernel power_supply events avoid a background polling loop. Manual changes
    # remain in effect until the next transition between AC and battery.
    sock = socket.socket(socket.AF_NETLINK, socket.SOCK_DGRAM, 15)
    sock.bind((0, 1))
    previous = None
    while True:
        online = ac_online()
        if online != previous:
            profile = ac if online else battery
            if profile != 'unchanged':
                subprocess.run(['powerprofilesctl', 'set', profile], check=True)
            previous = online
        select.select([sock], [], [])
        sock.recv(65536)


def diagnose():
    report = {
        'kernel': command(['uname', '-r']),
        'firmware': {k: read(SYS/'class/dmi/id'/k) for k in ('product_name', 'product_version', 'bios_version', 'bios_date')},
        'sleepStates': read(SYS/'power/state'), 'memSleep': read(SYS/'power/mem_sleep'),
        'resumeDevice': read(SYS/'power/resume'), 'resumeOffset': read(SYS/'power/resume_offset'),
        'lockdown': read(SYS/'kernel/security/lockdown'),
        'platformProfile': read(SYS/'firmware/acpi/platform_profile'),
        'cpuDriver': read(SYS/'devices/system/cpu/cpu0/cpufreq/scaling_driver'),
        'cpuEpp': read(SYS/'devices/system/cpu/cpu0/cpufreq/energy_performance_preference'),
        'supplies': supplies(),
        'swap': command(['swapon', '--show', '--bytes']),
        'rtcWakealarm': [str(p) for p in (SYS/'class/rtc').glob('*/wakealarm')],
        'suspendResidency': {str(p): read(p) for pattern in (
            'kernel/debug/amd_pmc/s0ix_stats', 'kernel/debug/pmc_core/slp_s0_residency_usec') for p in SYS.glob(pattern)},
        'canHibernate': command(['busctl', 'call', 'org.freedesktop.login1', '/org/freedesktop/login1', 'org.freedesktop.login1.Manager', 'CanHibernate']),
        'sleepLog': command(['journalctl', '-b', '--no-pager', '-n', '80', '-u', 'systemd-suspend.service', '-u', 'systemd-hibernate.service', '-u', 'systemd-suspend-then-hibernate.service']),
    }
    problems = []
    if report['canHibernate'] not in ('s "yes"', 's "challenge"'):
        problems.append('logind does not currently report hibernation support')
    if report['resumeDevice'] in (None, '0:0'):
        problems.append('No persistent resume device is registered; zram cannot store a resume image')
    if report['lockdown'] and '[none]' not in report['lockdown']:
        problems.append('Kernel lockdown is active; encryption alone does not enable hibernation')
    report['hibernationProblems'] = problems
    report['hardwareValidation'] = 'UNTESTED: a capability report is not a successful suspend/resume test'
    print(json.dumps(report, indent=2))
    return 1 if problems else 0


def snapshot():
    return {'timestamp': time.time(), 'supplies': supplies(), 'bootId': read('/proc/sys/kernel/random/boot_id')}


def compare(before, after):
    hours = (after['timestamp'] - before['timestamp']) / 3600
    if hours <= 0:
        raise ValueError('Snapshots must be in chronological order')
    results = {}
    for name, old in before['supplies'].items():
        new = after['supplies'].get(name, {})
        if old.get('type') != 'Battery':
            continue
        if old.get('energy_now') is None or new.get('energy_now') is None:
            results[name] = {'skipped': 'Battery does not expose energy_now; no estimated wattage reported'}
            continue
        wh = (int(old['energy_now']) - int(new['energy_now'])) / 1_000_000
        results[name] = {'elapsedHours': hours, 'energyUsedWh': wh, 'averageWatts': wh / hours,
                         'startStatus': old.get('status'), 'endStatus': new.get('status')}
    return {'batteries': results, 'note': 'Valid only for a controlled interval with no charging; endpoints cannot detect intermediate AC use.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('doctor')
    sub.add_parser('snapshot')
    comparison = sub.add_parser('compare')
    comparison.add_argument('before', type=Path)
    comparison.add_argument('after', type=Path)
    charge = sub.add_parser('conservation')
    charge.add_argument('mode', choices=['enabled', 'disabled', 'unchanged'])
    profile = sub.add_parser('profiles')
    for name in ('ac', 'battery'):
        profile.add_argument(name, choices=['unchanged', 'balanced', 'power-saver', 'performance'])
    args = parser.parse_args()
    if not SYS.joinpath('class/power_supply').exists():
        parser.exit(77, 'SKIP: requires a Linux target\n')
    try:
        if args.command == 'doctor':
            return diagnose()
        if args.command == 'snapshot':
            print(json.dumps(snapshot(), indent=2))
        elif args.command == 'compare':
            print(json.dumps(compare(json.loads(args.before.read_text()), json.loads(args.after.read_text())), indent=2))
        elif args.command == 'conservation':
            print(json.dumps({'controls': conservation(args.mode), 'limit': 'Firmware-defined; see doctor output for any reported threshold'}))
        else:
            profiles(args.ac, args.battery)
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f'{exc}\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
