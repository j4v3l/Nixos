#!/usr/bin/env python3
"""Detect hardware and serialize host settings. Detection never writes files."""
import argparse
import copy
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

HOST_RE = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_-]*\Z")
NPU_IDS = {"8086": {"7d1d", "ad1d", "643e", "b03e", "fd3e"}, "1022": {"1502", "17f0"}}


def bus_id(slot):
    domain, bus, device, function = re.split(r"[:.]", slot)
    return f"PCI:{int(bus, 16)}@{int(domain, 16)}:{int(device, 16)}:{int(function, 16)}"


def inventory():
    if not Path('/sys/bus/pci/devices').exists():
        raise ValueError("Hardware detection requires Linux; use --inventory for fixture data.")
    def read(path, default=""):
        try:
            return Path(path).read_text().strip()
        except OSError:
            return default
    cpu = read('/proc/cpuinfo')
    match = re.search(r'vendor_id\s*:\s*(\S+)', cpu)
    devices = []
    for device in sorted(Path('/sys/bus/pci/devices').iterdir()):
        devices.append({"slot": device.name, "vendor": read(device/'vendor').removeprefix('0x'),
                        "device": read(device/'device').removeprefix('0x'),
                        "class": read(device/'class').removeprefix('0x')[:4],
                        "bootVga": read(device/'boot_vga') == '1'})
    return {"cpuVendor": match.group(1) if match else "", "chassisType": read('/sys/class/dmi/id/chassis_type'), "pci": devices}


def detect(data):
    cpu = {"GenuineIntel": "intel", "AuthenticAMD": "amd"}.get(data.get('cpuVendor'), 'other')
    laptop = str(data.get('chassisType')) in {'8', '9', '10', '11', '14', '30', '31', '32'}
    graphics = [p for p in data.get('pci', []) if p.get('class', '').startswith('03')]
    vendors = {'8086': 'intel', '1002': 'amd', '10de': 'nvidia'}
    gpus = sorted({vendors[p['vendor']] for p in graphics if p['vendor'] in vendors})
    npu = 'none'
    for p in data.get('pci', []):
        if p.get('device') in NPU_IDS.get(p.get('vendor'), set()):
            npu = 'intel' if p['vendor'] == '8086' else 'amd'
    hw = {'formFactor': 'laptop' if laptop else 'desktop', 'cpu': cpu, 'gpus': gpus, 'npu': npu}
    nvidia = [p for p in graphics if p['vendor'] == '10de']
    integrated = [p for p in graphics if p['vendor'] in ('8086', '1002')]
    if nvidia:
        cfg = {'mode': 'dedicated', 'open': True, 'branch': 'stable', 'intelBusId': '', 'amdgpuBusId': '', 'nvidiaBusId': ''}
        # A desktop may expose an unused iGPU. Offload is only suggested for laptops.
        if laptop and len(nvidia) == 1 and len(integrated) == 1:
            cfg['mode'] = 'offload'
            cfg['nvidiaBusId'] = bus_id(nvidia[0]['slot'])
            key = 'intelBusId' if integrated[0]['vendor'] == '8086' else 'amdgpuBusId'
            cfg[key] = bus_id(integrated[0]['slot'])
        hw['nvidia'] = cfg
    return hw


def validate(settings):
    identity = settings['identity']
    if not re.fullmatch(r'[a-z_][a-z0-9_-]*', identity['username']):
        raise ValueError('Invalid Linux username')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]*', identity['hostname']):
        raise ValueError('Invalid hostname')
    if settings['hardware']['formFactor'] not in ('laptop', 'desktop'):
        raise ValueError('Profile must be laptop or desktop')
    if any(not isinstance(v, str) for v in identity.values()):
        raise ValueError('Identity fields must be strings')
    for key in ('timezone', 'locale'):
        if '\n' in identity[key] or '\x00' in identity[key]:
            raise ValueError(f'Invalid {key}')


def prompt(label, default):
    print(f"  {label} [{default}]: ", end='', file=sys.stderr, flush=True)
    answer = sys.stdin.readline()
    if answer == '':
        raise ValueError('Input ended before configuration was complete')
    return answer.rstrip('\n') or default


def prepare(root, name, profile=None, data=None, interactive=False, redetect=False):
    file = root/'hosts'/name/'settings.json'
    existing = file.exists()
    settings = json.loads((file if existing else root/'templates/desktop/settings.json').read_text())
    if not existing or redetect:
        settings['hardware'] = detect(data if data is not None else inventory())
    if profile:
        settings['hardware']['formFactor'] = profile
    if not existing:
        settings['identity']['hostname'] = name
        settings['identity']['username'] = os.environ.get('SUDO_USER', os.environ.get('USER', 'nixos'))
    if interactive:
        for key, value in settings['identity'].items():
            settings['identity'][key] = prompt(key, value)
        for key in ('development', 'creator', 'virtualisation', 'ai', 'wallpapers'):
            settings['features'][key] = prompt(f'Enable {key}? y/n', 'y' if settings['features'].get(key) else 'n').lower() == 'y'
        if settings['features']['ai']:
            backend = prompt('Ollama backend: cpu/cuda/rocm/vulkan', settings.get('ai', {}).get('backend', 'cpu'))
            if backend not in ('cpu', 'cuda', 'rocm', 'vulkan'):
                raise ValueError('Unknown Ollama backend')
            settings['ai'] = {'backend': backend}
        hw = settings['hardware']
        if 'nvidia' in hw.get('gpus', []):
            print('NVIDIA generation cannot be inferred reliably from vendor IDs. Verify the branch and module choice.', file=sys.stderr)
            cfg = hw['nvidia']
            cfg['open'] = prompt('Open NVIDIA modules? y/n (Turing and newer)', 'y' if cfg.get('open', True) else 'n').lower() == 'y'
            cfg['branch'] = prompt('NVIDIA branch (stable or supported legacy branch)', cfg.get('branch', 'stable'))
            cfg['mode'] = prompt('NVIDIA mode: dedicated/offload', cfg.get('mode', 'dedicated'))
            if cfg['mode'] not in ('dedicated', 'offload'):
                raise ValueError('Unknown NVIDIA mode')
            if cfg['mode'] == 'offload':
                for key in ('intelBusId', 'amdgpuBusId', 'nvidiaBusId'):
                    cfg[key] = prompt(key, cfg.get(key, ''))
        print(json.dumps(settings, indent=2, ensure_ascii=False), file=sys.stderr)
    validate(settings)
    return settings


def atomic_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.settings-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(data, stream, indent=2, ensure_ascii=False)
            stream.write('\n')
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def apply(root, name, settings):
    validate(settings)
    path = root/'hosts'/name
    atomic_json(path/'settings.json', settings)
    default = path/'default.nix'
    if not default.exists():
        default.write_text('{ ... }: { imports = [ ./hardware-configuration.nix ]; }\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['detect', 'prepare', 'apply', 'get'])
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--host', default='laptop')
    parser.add_argument('--profile', choices=['desktop', 'laptop'])
    parser.add_argument('--inventory', type=Path)
    parser.add_argument('--interactive', action='store_true')
    parser.add_argument('--redetect', action='store_true')
    parser.add_argument('--key')
    args = parser.parse_args()
    if not HOST_RE.fullmatch(args.host):
        parser.error('Invalid host name')
    data = json.loads(args.inventory.read_text()) if args.inventory else None
    try:
        if args.command == 'detect':
            result = detect(data if data is not None else inventory())
        elif args.command == 'prepare':
            result = prepare(args.root, args.host, args.profile, data, args.interactive, args.redetect)
        elif args.command == 'apply':
            apply(args.root, args.host, json.load(sys.stdin))
            return
        else:
            result = json.loads((args.root/'hosts'/args.host/'settings.json').read_text())
            for key in args.key.split('.'):
                result = result[key]
            print(result if isinstance(result, str) else json.dumps(result))
            return
        print(json.dumps(result, ensure_ascii=False))
    except (ValueError, OSError, KeyError) as exc:
        parser.exit(1, f'{exc}\n')


if __name__ == '__main__':
    main()
