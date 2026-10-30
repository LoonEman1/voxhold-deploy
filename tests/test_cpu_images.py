import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
OFFICIAL = 'ghcr.io/looneman1/voxhold-backend:'


@unittest.skipUnless(os.name == 'posix', 'CPU selection scenarios run on Linux CI')
class CPUImageTests(unittest.TestCase):
    def select(self, image=OFFICIAL+'2.5.0', mode='auto', supported=True, arch='x86_64', tags=()):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'.env').write_text(f'VOXHOLD_BACKEND_IMAGE="{image}"\nVOXHOLD_AMD64="{mode}"\nSECRET="untouched"\n')
            binary = root/'bin'; binary.mkdir()
            docker = binary/'docker'
            docker.write_text('#!/usr/bin/env python3\nimport os,sys\nsys.exit(0 if sys.argv[-1] in os.environ.get("TAGS", "").split(",") else 1)\n')
            docker.chmod(0o755)
            source = shutil.copyfile(ROOT/'cpu-images.sh', root/'cpu-images.sh')
            command = 'set -Eeuo pipefail; . ./cpu-images.sh; cpu_supports_v3() { return '+('0' if supported else '1')+'; }; uname() { if [[ "$1" == -m ]]; then echo '+arch+'; else echo Linux; fi; }; cpu_select_backend_image'
            result = subprocess.run(['bash', '-c', command], cwd=root, env=dict(os.environ, PATH=str(binary)+os.pathsep+os.environ['PATH'], TAGS=','.join(tags)), capture_output=True, text=True)
            text = (root/'.env').read_text()
            self.assertIn('SECRET="untouched"', text)
            return result, text

    def test_auto_selects_v3_only_when_supported_and_published(self):
        result, text = self.select(tags=[OFFICIAL+'2.5.0-amd64-v3'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(OFFICIAL+'2.5.0-amd64-v3', text)

    def test_unknown_cpu_selects_v1(self):
        result, text = self.select(supported=False, tags=[OFFICIAL+'2.5.0-amd64-v1'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(OFFICIAL+'2.5.0-amd64-v1', text)

    def test_explicit_baseline_on_modern_cpu(self):
        result, text = self.select(mode='v1', tags=[OFFICIAL+'2.5.0-amd64-v1'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(OFFICIAL+'2.5.0-amd64-v1', text)

    def test_old_release_falls_back_to_portable_tag(self):
        result, text = self.select(image=OFFICIAL+'2.4.0-amd64-v3')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f'VOXHOLD_BACKEND_IMAGE="{OFFICIAL}2.4.0"', text)

    def test_forced_v3_requires_cpu_and_published_tag(self):
        for supported, tags in [(False, [OFFICIAL+'2.5.0-amd64-v3']), (True, [])]:
            result, _ = self.select(mode='v3', supported=supported, tags=tags)
            self.assertNotEqual(result.returncode, 0)

    def test_custom_images_and_digest_pins_are_preserved(self):
        for image in ['example.test/backend:custom', OFFICIAL[:-1]+'@sha256:'+'a'*64]:
            result, text = self.select(image=image)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f'VOXHOLD_BACKEND_IMAGE="{image}"', text)

    def test_arm64_uses_portable_tag(self):
        result, text = self.select(image=OFFICIAL+'2.5.0-amd64-v3', arch='aarch64')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f'VOXHOLD_BACKEND_IMAGE="{OFFICIAL}2.5.0"', text)

    def test_existing_variant_can_switch_without_stacking_suffixes(self):
        result, text = self.select(image=OFFICIAL+'2.5.0-amd64-v1', tags=[OFFICIAL+'2.5.0-amd64-v3'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(OFFICIAL+'2.5.0-amd64-v3', text)
        self.assertNotIn('v1-amd64', text)

    def test_invalid_modes_fail(self):
        result, _ = self.select(mode='v2')
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
