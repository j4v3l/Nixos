#!/usr/bin/env python3
"""Detect hardware and serialize host settings. Detection never writes files."""
import argparse
import json
import os
from pathlib import Path
import re
import sys
import subprocess
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
    memory = re.search(r'MemTotal:\s*(\d+)', read('/proc/meminfo'))
    try:
        virt = subprocess.run(['systemd-detect-virt', '--vm'], capture_output=True, text=True).stdout.strip()
    except OSError:
        virt = 'none'
    return {"cpuVendor": match.group(1) if match else "", "chassisType": read('/sys/class/dmi/id/chassis_type'),
            "pci": devices, "ramKiB": int(memory.group(1)) if memory else 0,
            "virtualization": virt, "cpuModel": next((line.split(':', 1)[1].strip() for line in cpu.splitlines() if line.startswith('model name')), ''),
            "dmi": {key: read('/sys/class/dmi/id/' + key) for key in ('sys_vendor', 'product_name', 'product_version', 'bios_version', 'bios_date')}}


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
    dmi = data.get('dmi', {})
    identity = ' '.join(dmi.get(key, '') for key in ('product_name', 'product_version')).upper()
    model = 'yoga-14akp10' if '14AKP10' in identity else 'yoga-14irl8' if '14IRL8' in identity else 'generic'
    hw['model'] = model
    hw['inventory'] = data
    virtual = data.get('virtualization', 'none') not in ('', 'none') or any(v in identity for v in ('QEMU', 'KVM', 'PROXMOX'))
    if virtual:
        hw.update(formFactor='vm', model='generic', gpus=[], npu='none')
        return hw
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
    if settings['hardware']['formFactor'] not in ('laptop', 'desktop', 'vm'):
        raise ValueError('Profile must be laptop, desktop or vm')
    if any(not isinstance(v, str) for v in identity.values()):
        raise ValueError('Identity fields must be strings')
    for key in ('timezone', 'locale'):
        if '\n' in identity[key] or '\x00' in identity[key]:
            raise ValueError(f'Invalid {key}')

    hw = settings['hardware']
    model = hw.get('model', 'generic')
    if model not in ('generic', 'yoga-14akp10', 'yoga-14irl8'):
        raise ValueError('Unknown hardware model')
    if model != 'generic':
        vendor = 'amd' if model == 'yoga-14akp10' else 'intel'
        if hw['formFactor'] != 'laptop' or hw['cpu'] != vendor or hw['gpus'] != [vendor]:
            raise ValueError('Yoga model does not match detected CPU/GPU/profile')
        if model == 'yoga-14irl8' and hw.get('npu', 'none') != 'none':
            raise ValueError('Yoga 14IRL8 has no Intel NPU')
    if hw['formFactor'] == 'vm' and (hw.get('npu', 'none') != 'none' or settings.get('power', {}).get('hibernate')):
        raise ValueError('VM guests cannot enable physical NPU or hibernation')
    storage = settings.get('storage', {})
    if storage.get('layout', 'plain') not in ('plain', 'encrypted'):
        raise ValueError('Unknown storage layout')
    for key in ('luksUuid', 'swapUuid'):
        if storage.get(key) and not re.fullmatch(r'[a-fA-F0-9-]+', storage[key]):
            raise ValueError('Invalid storage UUID')
    if type(storage.get('swapGiB', 0)) is not int or storage.get('swapGiB', 0) < 0:
        raise ValueError('Invalid swap size')
    gpus = hw.get('gpus', [])
    if hw.get('npu') == 'intel' and hw.get('cpu') != 'intel':
        raise ValueError('Intel NPU requires an Intel CPU')
    if hw.get('npu') == 'amd' and hw.get('cpu') != 'amd':
        raise ValueError('AMD NPU requires an AMD CPU')
    if settings.get('features', {}).get('ai'):
        backend = settings.get('ai', {}).get('backend', 'cpu')
        if (backend == 'cuda' and 'nvidia' not in gpus) or (backend == 'rocm' and 'amd' not in gpus):
            raise ValueError(f'Ollama {backend} backend does not match detected graphics; select a compatible backend')
    cfg = hw.get('nvidia', {})
    if 'nvidia' in gpus:
        if cfg.get('branch', 'stable').startswith('legacy_') and cfg.get('open', True):
            raise ValueError('Legacy NVIDIA branches require closed modules')
        if cfg.get('mode') == 'offload':
            valid_bus = lambda value: re.fullmatch(r'PCI:[0-9]+(?:@[0-9]+)?:[0-9]+:[0-9]+', value or '')
            intel = valid_bus(cfg.get('intelBusId')) and 'intel' in gpus
            amd = valid_bus(cfg.get('amdgpuBusId')) and 'amd' in gpus
            if not valid_bus(cfg.get('nvidiaBusId')) or bool(intel) == bool(amd):
                raise ValueError('PRIME offload requires NVIDIA and exactly one matching iGPU bus ID')


def prompt(label, default):
    print(f"  {label} [{default}]: ", end='', file=sys.stderr, flush=True)
    answer = sys.stdin.readline()
    if answer == '':
        raise ValueError('Input ended before configuration was complete')
    return answer.rstrip('\n') or default


def prepare(root, name, profile=None, data=None, interactive=False, redetect=False, model=None):
    file = root/'hosts'/name/'settings.json'
    existing = file.exists()
    settings = json.loads((file if existing else root/'templates/desktop/settings.json').read_text())
    if not existing or redetect:
        settings['hardware'] = detect(data if data is not None else inventory())
    if profile:
        settings['hardware']['formFactor'] = profile
    if model:
        settings['hardware']['model'] = model
    if not existing:
        settings['identity']['hostname'] = name
        settings['identity']['username'] = os.environ.get('SUDO_USER', os.environ.get('USER', 'nixos'))
    if interactive:
        for key, value in settings['identity'].items():
            settings['identity'][key] = prompt(key, value)
        for key in ('development', 'creator', 'virtualisation', 'ai', 'wallpapers'):
            settings['features'][key] = prompt(f'Enable {key}? y/n', 'y' if settings['features'].get(key) else 'n').lower() == 'y'
        ssh = settings.setdefault('ssh', {})
        ssh['enable'] = prompt('Enable SSH server? y/n', 'y' if ssh.get('enable') else 'n').lower() == 'y'
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
    parser.add_argument('--profile', choices=['desktop', 'laptop', 'vm'])
    parser.add_argument('--model', choices=['generic', 'yoga-14akp10', 'yoga-14irl8'])
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
            result = prepare(args.root, args.host, args.profile, data, args.interactive, args.redetect, args.model)
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
