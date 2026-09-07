import json
import os
from pathlib import Path
import subprocess
import tempfile
import tomllib
import unittest


@unittest.skipUnless(os.environ.get('AURORA_THEME_EXPORT'), 'Run scripts/check.sh for generated-theme tests')
class Themes(unittest.TestCase):
    def setUp(self):
        self.generated = json.loads(Path(os.environ['AURORA_THEME_EXPORT']).read_text())
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.home = Path(self.directory.name)
        self.env = {**os.environ, 'HOME': str(self.home), 'XDG_RUNTIME_DIR': str(self.home/'runtime')}
        for name, text in self.generated['files'].items():
            file = self.home/'.config'/name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(text)
        self.aurora = self.home/'.config/aurora'
        # Prevent interaction with this developer's running desktop or tmux server.
        commands = self.home/'bin'
        commands.mkdir()
        for command in ('hyprctl', 'tmux', 'kitten', 'kreo-rgb'):
            file = commands/command
            file.write_text('#!/usr/bin/env bash\nexit 0\n')
            file.chmod(0o755)
        self.env['PATH'] = str(commands) + os.pathsep + self.env['PATH']

    def activate(self):
        subprocess.run(['bash', '-eu', '-c', self.generated['activation']], env=self.env, check=True, capture_output=True)

    def test_initialization_switch_and_persistence(self):
        self.activate()
        self.assertEqual((self.aurora/'active-theme').read_text(), (self.aurora/'default-theme').read_text())
        result = subprocess.run(['bash', '-c', self.generated['switcher'], 'aurora-theme', 'crimson'], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.activate()
        self.assertEqual((self.aurora/'active-theme').read_text(), 'crimson\n')
        for name, suffix in [('active-theme.lua', 'lua'), ('active-kitty.conf', 'kitty.conf'), ('active-tmux.conf', 'tmux.conf'), ('active-hyprlock.conf', 'hyprlock.conf'), ('active-starship.toml', 'starship.toml')]:
            self.assertEqual((self.aurora/name).resolve(), (self.aurora/'themes'/f'crimson.{suffix}').resolve())

    def test_invalid_saved_theme_recovers_to_configured_default(self):
        (self.aurora/'active-theme').write_text('missing-theme\n')
        self.activate()
        self.assertEqual((self.aurora/'active-theme').read_text(), (self.aurora/'default-theme').read_text())

    def test_generated_palettes_are_complete_and_parse(self):
        catalog = json.loads(self.generated['files']['aurora/themes.json'])
        required = set(catalog['themes']['catppuccin-mocha']['colors'])
        self.assertEqual(set(catalog['themes']['crimson']['colors']), required)
        for name, text in self.generated['files'].items():
            if name.endswith('.lua'):
                subprocess.run(['luac', '-p', '-'], input=text, text=True, check=True, capture_output=True)
            elif name.endswith('.toml'):
                tomllib.loads(text)
            elif name.endswith('.json'):
                json.loads(text)


if __name__ == '__main__':
    unittest.main()
