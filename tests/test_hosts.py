import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('host_config', ROOT/'scripts/host-config.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)
FIXTURES = json.loads((ROOT/'tests/fixtures/hardware.json').read_text())


class Detection(unittest.TestCase):
    def test_integrated_profiles(self):
        intel = host.detect(FIXTURES['intel-laptop'])
        self.assertEqual((intel['cpu'], intel['gpus'], intel['formFactor']), ('intel', ['intel'], 'laptop'))
        amd = host.detect(FIXTURES['amd-desktop'])
        self.assertEqual((amd['cpu'], amd['gpus'], amd['formFactor']), ('amd', ['amd'], 'desktop'))

    def test_dedicated_nvidia_does_not_require_prime_bus_ids(self):
        result = host.detect(FIXTURES['nvidia-desktop'])['nvidia']
        self.assertEqual(result['mode'], 'dedicated')
        self.assertEqual(result['nvidiaBusId'], '')

    def test_hybrid_bus_ids_are_decimal_and_preserve_domain(self):
        intel = host.detect(FIXTURES['intel-nvidia'])['nvidia']
        self.assertEqual(intel['nvidiaBusId'], 'PCI:10@1:31:2')
        self.assertEqual(intel['intelBusId'], 'PCI:0@0:2:0')
        amd = host.detect(FIXTURES['amd-nvidia'])['nvidia']
        self.assertEqual(amd['amdgpuBusId'], 'PCI:5@0:0:0')
        self.assertEqual(amd['intelBusId'], '')

    def test_npu_uses_device_ids_not_just_vendor(self):
        self.assertEqual(host.detect(FIXTURES['intel-npu'])['npu'], 'intel')
        self.assertEqual(host.detect(FIXTURES['amd-npu'])['npu'], 'amd')
        unknown = host.detect(FIXTURES['unknown'])
        self.assertEqual(unknown['npu'], 'none')
        self.assertEqual(unknown['gpus'], [])

    def test_ambiguous_hybrid_is_not_given_arbitrary_bus_ids(self):
        data = copy.deepcopy(FIXTURES['intel-nvidia'])
        data['pci'].append({'slot':'0000:02:00.0','vendor':'10de','device':'28a0','class':'0302'})
        self.assertEqual(host.detect(data)['nvidia']['mode'], 'dedicated')


class Settings(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        shutil.copytree(ROOT/'templates', self.root/'templates')
        shutil.copytree(ROOT/'hosts/laptop', self.root/'hosts/laptop')

    def tearDown(self):
        self.temp.cleanup()

    def test_preparing_new_host_does_not_write(self):
        before = sorted(str(p.relative_to(self.root)) for p in self.root.rglob('*'))
        with patch.dict(os.environ, {'USER':'alice'}, clear=True):
            settings = host.prepare(self.root, 'desktop', data=FIXTURES['amd-desktop'])
        after = sorted(str(p.relative_to(self.root)) for p in self.root.rglob('*'))
        self.assertEqual(before, after)
        self.assertEqual(settings['identity']['username'], 'alice')
        self.assertFalse(any(settings['features'].values()))
        self.assertFalse(settings['ssh']['enable'])

    def test_existing_choices_are_preserved(self):
        original = json.loads((self.root/'hosts/laptop/settings.json').read_text())
        self.assertEqual(host.prepare(self.root, 'laptop'), original)

    def test_reconfiguration_redetects_hardware_only_when_requested(self):
        original = json.loads((self.root/'hosts/laptop/settings.json').read_text())
        original['features']['ai'] = False
        (self.root/'hosts/laptop/settings.json').write_text(json.dumps(original))
        changed = host.prepare(self.root, 'laptop', data=FIXTURES['amd-desktop'], redetect=True)
        self.assertEqual(changed['identity'], original['identity'])
        self.assertEqual(changed['features'], original['features'])
        self.assertEqual(changed['hardware']['gpus'], ['amd'])

    def test_conflicting_compute_backend_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'backend does not match'):
            host.prepare(self.root, 'laptop', data=FIXTURES['amd-desktop'], redetect=True)

    def test_json_escaping_and_no_borrowed_uuid(self):
        settings = json.loads((self.root/'templates/desktop/settings.json').read_text())
        value = 'Alice "Example" \\ ${builtins.abort "bad"} $(printf bad) `printf bad`\nsecond line'
        settings['identity']['fullName'] = value
        host.apply(self.root, 'desktop', settings)
        result = json.loads((self.root/'hosts/desktop/settings.json').read_text())
        self.assertEqual(result['identity']['fullName'], value)
        self.assertFalse((self.root/'hosts/desktop/hardware-configuration.nix').exists())
        (self.root/'hosts/desktop/default.nix').write_text('# custom module\n')
        host.apply(self.root, 'desktop', settings)
        self.assertEqual((self.root/'hosts/desktop/default.nix').read_text(), '# custom module\n')

    def test_invalid_identity_never_overwrites_file(self):
        settings = json.loads((self.root/'hosts/laptop/settings.json').read_text())
        old = (self.root/'hosts/laptop/settings.json').read_bytes()
        settings['identity']['username'] = '../../root'
        with self.assertRaises(ValueError):
            host.apply(self.root, 'laptop', settings)
        self.assertEqual((self.root/'hosts/laptop/settings.json').read_bytes(), old)

    def test_host_traversal_rejected(self):
        result = subprocess.run(['python3', str(ROOT/'scripts/host-config.py'), 'prepare', '--host', '../evil'], capture_output=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
