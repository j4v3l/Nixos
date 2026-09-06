import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def bash(code, extra=None):
    return subprocess.run(['bash', '-c', code], cwd=ROOT, text=True, capture_output=True, env={**os.environ, **(extra or {})})


class Installer(unittest.TestCase):
    def test_hardware_generation_failure_preserves_previous_file(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory)/'hardware-configuration.nix'
            file.write_text('original\n')
            result = bash('''source scripts/setup/hardware.sh
sudo() { printf 'partial'; return 1; }
write_hardware_config "" "$TEST_OUTPUT"
''', {'TEST_OUTPUT':str(file)})
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(file.read_text(), 'original\n')
            self.assertEqual(list(Path(directory).iterdir()), [file])

    def test_dry_install_never_invokes_mutating_steps(self):
        result = bash('''set -Eeuo pipefail
ROOT="$PWD"; HOST=desktop; VERSION=test; SETUP_DRY_RUN=1
source scripts/setup/installation.sh
clear_screen() { :; }; panel() { :; }; warning() { :; }; info() { :; }; section() { :; }; verdict() { :; }
CYAN=""; ICON_INFO=""
ci_preflight() { :; }; ci_collect_identity() { :; }; ci_show_disks() { :; }; ci_select_target_disk() { :; }
for step in ci_require_live ci_confirm_destroy ci_release_target ci_partition ci_format ci_mount ci_place_repo; do
    eval "$step() { echo UNSAFE:$step >&2; return 91; }"
done
for step in ci_setup_swap ci_apply_identity ci_generate_hardware ci_prepare_target_store ci_validate_flake ci_build_system ci_install ci_fix_ownership ci_set_password ci_handle_stale_efi; do
    eval "$step() { [[ \\"\\$CI_DRY_RUN\\" -eq 1 ]] || return 92; }"
done
clean_install
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('UNSAFE', result.stderr)

    def test_confirmation_rejection_stops_before_partitioning(self):
        result = bash('''set -Eeuo pipefail
ROOT="$PWD"; HOST=desktop; VERSION=test; SETUP_DRY_RUN=0
source scripts/setup/installation.sh
clear_screen() { :; }; panel() { :; }; section() { :; }; info() { :; }
ci_require_live() { :; }; id() { echo 0; }; ci_preflight() { :; }; ci_collect_identity() { :; }
ci_show_disks() { :; }; ci_select_target_disk() { :; }; ci_confirm_destroy() { return 1; }
ci_release_target() { echo UNSAFE; }; ci_partition() { echo UNSAFE; }
ci_on_error() { :; }
clean_install
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('UNSAFE', result.stdout)

    def test_host_target_and_dry_run_flags(self):
        result = subprocess.run(['bash', str(ROOT/'setup.sh'), 'rebuild', '--host', 'desktop', '--dry-run'], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('--dry-run is supported', result.stderr)
        result = subprocess.run(['bash', str(ROOT/'setup.sh'), 'help', '--host', 'desktop'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('--host desktop', result.stdout)


if __name__ == '__main__':
    unittest.main()
