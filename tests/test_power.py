import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from test_hosts import host, FIXTURES, ROOT
from test_installer import bash

spec = importlib.util.spec_from_file_location('power', ROOT/'scripts/power.py')
power = importlib.util.module_from_spec(spec)
spec.loader.exec_module(power)


class HardwarePower(unittest.TestCase):
    def test_yoga_detection_and_model_guard(self):
        for model, fixture, expected in [('Yoga 7 2-in-1 14AKP10', 'amd-desktop', 'yoga-14akp10'),
                                         ('Yoga 7 14IRL8', 'intel-laptop', 'yoga-14irl8')]:
            data = copy.deepcopy(FIXTURES[fixture])
            data.update(chassisType='31', ramKiB=16*1048576, dmi={'product_version': model})
            hardware = host.detect(data)
            self.assertEqual(hardware['model'], expected)
            self.assertEqual(hardware['inventory']['ramKiB'], 16*1048576)
            settings = json.loads((ROOT/'templates/desktop/settings.json').read_text())
            settings['hardware'] = hardware
            host.validate(settings)
            hardware['gpus'] = ['nvidia']
            with self.assertRaisesRegex(ValueError, 'Yoga model'):
                host.validate(settings)

    def test_guest_detection_ignores_emulated_cpu_and_npu(self):
        data = copy.deepcopy(FIXTURES['intel-npu'])
        data['virtualization'] = 'kvm'
        hw = host.detect(data)
        self.assertEqual((hw['formFactor'], hw['gpus'], hw['npu']), ('vm', [], 'none'))

    def test_conservation_capabilities_and_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            vendor = base/'class/dmi/id/sys_vendor'
            vendor.parent.mkdir(parents=True)
            vendor.write_text('LENOVO')
            with self.assertRaisesRegex(ValueError, 'no supported'):
                power.conservation('enabled', base)
            modern = base/'class/power_supply/BAT0/charge_types'
            modern.parent.mkdir(parents=True)
            modern.write_text('[Standard] Long Life')
            legacy = base/'bus/platform/drivers/ideapad_acpi/VPC2004:00/conservation_mode'
            legacy.parent.mkdir(parents=True)
            legacy.write_text('0')
            self.assertEqual(power.conservation('enabled', base), [str(modern)])
            self.assertEqual(modern.read_text().strip(), 'Long Life')
            self.assertEqual(legacy.read_text(), '0')
            modern.unlink()
            power.conservation('enabled', base)
            self.assertEqual(legacy.read_text().strip(), '1')
            self.assertEqual(power.conservation('unchanged', base), [])

    def test_measurement_units(self):
        old = {'timestamp': 0, 'supplies': {'BAT0': {'type':'Battery', 'energy_now':'50000000', 'status':'Discharging'}}}
        new = copy.deepcopy(old)
        new['timestamp'] = 1800
        new['supplies']['BAT0']['energy_now'] = '47000000'
        result = power.compare(old, new)['batteries']['BAT0']
        self.assertEqual(result['energyUsedWh'], 3)
        self.assertEqual(result['averageWatts'], 6)


class EncryptedInstaller(unittest.TestCase):
    def plan(self, ram, override=''):
        return bash('''source scripts/setup/installation.sh
HOST=yoga-amd; HOST_SETTINGS='{"hardware":{"model":"yoga-14akp10","formFactor":"laptop"}}'
CI_DRY_RUN=1
info() { :; }; warning() { :; }; error() { echo "$*" >&2; }; ci_need_cmd() { :; }
awk() { echo "$TEST_RAM"; }
INSTALL_SWAP_GIB="$TEST_SWAP"
ci_storage_plan || exit 1
printf '%s:%s' "$CI_LAYOUT" "$CI_SWAP_GIB"
''', {'TEST_RAM':str(ram), 'TEST_SWAP':override})

    def test_ram_rounding_and_minimum_swap(self):
        for ram, expected in [(8*1048576, 10), (16*1048576-2048, 18), (32*1048576, 34)]:
            result = self.plan(ram)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, f'encrypted:{expected}')
        self.assertNotEqual(self.plan(16*1048576, '8').returncode, 0)
        self.assertEqual(self.plan(16*1048576, '24').stdout, 'encrypted:24')

    def test_encrypted_dry_run_never_executes_storage_commands(self):
        result = bash('''set -euo pipefail
source scripts/setup/installation.sh
CI_DRY_RUN=1; CI_LAYOUT=encrypted
info() { :; }
for tool in cryptsetup pvcreate vgcreate lvcreate mkswap swapon vgchange umount; do
    eval "$tool() { echo UNSAFE; return 91; }"
done
ci_read_passphrase
ci_encrypt
ci_storage_settings
ci_storage_cleanup
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('UNSAFE', result.stdout)

    def test_failure_cleanup_only_closes_created_resources(self):
        result = bash('''set -euo pipefail
source scripts/setup/installation.sh
CI_LAYOUT=encrypted; CI_ROOT_PART=/dev/test2; CI_PASSPHRASE=only-a-fixture; CI_VG=aurora_test; CI_SWAP_GIB=10
error() { echo "$*"; }
cryptsetup() { cat >/dev/null; return 0; }
pvcreate() { return 1; }
vgcreate() { echo UNSAFE; }
if ci_encrypt; then exit 90; fi
[[ "$CI_LUKS_OPENED" == 1 && "$CI_VG_CREATED" == 0 ]]
mountpoint() { return 1; }
vgchange() { echo UNSAFE; }
cryptsetup() { echo "CLEAN:$*"; }
ci_storage_cleanup
[[ ! -v CI_PASSPHRASE ]]
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'CLEAN:close aurora')

    def test_passphrase_mismatch_and_missing_key_stop_format(self):
        result = bash('''source scripts/setup/installation.sh
CI_LAYOUT=encrypted
error() { :; }
ci_read_passphrase <<< $'testpass1\\ntestpass2' && exit 90
[[ ! -v CI_PASSPHRASE ]] || exit 91
cryptsetup() { echo UNSAFE; }
if ci_encrypt; then exit 92; fi
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('UNSAFE', result.stdout)
