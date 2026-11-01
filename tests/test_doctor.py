import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.name == 'posix', 'Bash scenarios run on Linux CI')
class DoctorTests(unittest.TestCase):
    def run_doctor(self, env_text):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copyfile(ROOT / 'doctor.sh', root / 'doctor.sh')
            (root / '.env').write_text(env_text)
            (root / '.env').chmod(0o600)
            return subprocess.run(['bash', 'doctor.sh'], cwd=root, capture_output=True, text=True,
                                  env=dict(os.environ, PATH='/usr/bin:/bin'))

    def test_reports_missing_env(self):
        with tempfile.TemporaryDirectory() as directory:
            shutil.copyfile(ROOT / 'doctor.sh', Path(directory) / 'doctor.sh')
            result = subprocess.run(['bash', 'doctor.sh'], cwd=directory, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('.env not found', result.stdout)

    def test_flags_turn_profile_without_secret_and_is_read_only(self):
        result = self.run_doctor('PUBLIC_HOST="203.0.113.1"\nCOMPOSE_PROFILES="web,turn"\nVOXHOLD_PUBLIC_URL="http://127.0.0.1:9"\n')
        self.assertEqual(result.returncode, 1)
        self.assertIn('FAIL: turn profile is enabled but WEBRTC_TURN_SECRET is empty', result.stdout)
        self.assertIn('OK:   .env permissions are 600', result.stdout)


if __name__ == '__main__':
    unittest.main()
