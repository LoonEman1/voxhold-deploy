import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import tarfile
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]

@unittest.skipUnless(os.name == 'posix' and shutil.which('docker'), 'Linux Docker integration test')
class BackupRestoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        result = subprocess.run(['docker', 'info'], capture_output=True)
        if result.returncode:
            raise unittest.SkipTest('Docker daemon unavailable')
        subprocess.run(['docker', 'pull', 'alpine:3.22'], check=True, capture_output=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ['restore.sh', 'backup.sh']:
            shutil.copyfile(ROOT / name, self.root / name)
        self.volume = 'voxhold_restore_test_' + uuid.uuid4().hex
        subprocess.run(['docker', 'volume', 'create', self.volume], check=True, capture_output=True)
        self.addCleanup(lambda: subprocess.run(['docker', 'volume', 'rm', self.volume], capture_output=True))
        self.container = subprocess.check_output(['docker', 'create', '-v', self.volume + ':/app/data', 'alpine:3.22', 'tail', '-f', '/dev/null'], text=True).strip()
        self.addCleanup(lambda: subprocess.run(['docker', 'rm', '-f', self.container], capture_output=True))
        self.old = self.database('old.sqlite', 'old')
        self.snapshot = self.database('snapshot.sqlite', 'snapshot')
        self.write_volume({'voxhold.db': self.old, 'obsolete.txt': b'old attachment'})
        self.archive = self.root / 'snapshot.tar.gz'
        with tarfile.open(self.archive, 'w:gz') as archive:
            directory = tarfile.TarInfo('data'); directory.type = tarfile.DIRTYPE
            archive.addfile(directory)
            for name, value in {'manifest.json': b'{}', 'data/voxhold.db': self.snapshot, 'data/attachments/file': b'saved attachment', 'data/.hidden': b'private state'}.items():
                info = tarfile.TarInfo(name); info.size = len(value)
                archive.addfile(info, io.BytesIO(value))
        Path(str(self.archive) + '.sha256').write_text(hashlib.sha256(self.archive.read_bytes()).hexdigest())
        binary = self.root / 'bin'; binary.mkdir()
        docker = binary / 'docker'
        docker.write_text("#!/usr/bin/env python3\nimport os,subprocess,sys\na=sys.argv[1:]\nif a[:3]==['compose','ps','-q']:\n print(os.environ['TEST_BACKEND'] if a[-1]=='backend' else '');sys.exit(0)\nif a[:2] in (['compose','stop'],['compose','start']): a=[a[1],os.environ['TEST_BACKEND']]\nsys.exit(subprocess.call([os.environ['REAL_DOCKER'],*a]))\n")
        docker.chmod(0o755)
        self.env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'], TEST_BACKEND=self.container, REAL_DOCKER=shutil.which('docker'))
        (self.root / '.env').write_text('VOXHOLD_BACKEND_IMAGE=ghcr.io/looneman1/voxhold-backend:2.4.0\nVOXHOLD_FRONTEND_IMAGE=ghcr.io/looneman1/voxhold-frontend:2.4.0\nBACKUP_KEEP_COUNT=7\n')

    def database(self, name, value):
        path = self.root / name
        with sqlite3.connect(path) as db:
            db.execute('CREATE TABLE state(value TEXT)')
            db.execute('INSERT INTO state VALUES(?)', (value,))
        return path.read_bytes()

    def write_volume(self, files):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w') as archive:
            for name, value in files.items():
                info = tarfile.TarInfo(name); info.size = len(value)
                archive.addfile(info, io.BytesIO(value))
        subprocess.run(['docker', 'run', '--rm', '-i', '-v', self.volume + ':/data', 'alpine:3.22', 'tar', 'xf', '-', '-C', '/data'], input=data.getvalue(), check=True, capture_output=True)

    def read(self, volume, path):
        return subprocess.check_output(['docker', 'run', '--rm', '-v', volume + ':/data:ro', 'alpine:3.22', 'cat', '/data/' + path])

    def test_safe_restore_uses_volume_root_and_preserves_production(self):
        result = subprocess.run(['bash', 'restore.sh', str(self.archive)], cwd=self.root, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        volume = re.search(r'Restoring into a NEW volume (\S+) ', result.stdout).group(1)
        self.addCleanup(lambda: subprocess.run(['docker', 'volume', 'rm', volume], capture_output=True))
        self.assertEqual(self.read(volume, 'voxhold.db'), self.snapshot)
        self.assertEqual(self.read(volume, 'attachments/file'), b'saved attachment')
        self.assertEqual(self.read(volume, '.hidden'), b'private state')
        self.assertEqual(self.read(self.volume, 'voxhold.db'), self.old)
        self.assertNotIn('docker volume rename', result.stdout)
        self.assertIn('external: true', result.stdout)

    def test_overwrite_replaces_volume_contents_and_preserves_running_state(self):
        subprocess.run(['docker', 'start', self.container], check=True, capture_output=True)
        result = subprocess.run(['bash', 'restore.sh', str(self.archive), '--into-existing'], cwd=self.root, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read(self.volume, 'voxhold.db'), self.snapshot)
        self.assertEqual(self.read(self.volume, 'attachments/file'), b'saved attachment')
        self.assertEqual(self.read(self.volume, '.hidden'), b'private state')
        remaining = subprocess.check_output(['docker', 'run', '--rm', '-v', self.volume + ':/data:ro', 'alpine:3.22', 'ls', '-a', '/data'], text=True)
        self.assertNotIn('obsolete.txt', remaining)
        self.assertEqual(subprocess.check_output(['docker', 'inspect', '-f', '{{.State.Running}}', self.container], text=True).strip(), 'true')

    def test_backup_manifest_records_running_image_instead_of_requested_update(self):
        subprocess.run(['docker', 'start', self.container], check=True, capture_output=True)
        result = subprocess.run(['bash', 'backup.sh'], cwd=self.root, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = next((self.root / 'backups').glob('*.tar.gz'))
        with tarfile.open(archive) as backup:
            manifest = json.load(backup.extractfile('manifest.json'))
            self.assertEqual(manifest['backend_image'], 'alpine:3.22')
            self.assertNotIn(':2.4.0', manifest['backend_image'])
            self.assertEqual(backup.extractfile('data/voxhold.db').read(), self.old)
        self.assertEqual(Path(str(archive) + '.sha256').read_text().strip(), hashlib.sha256(archive.read_bytes()).hexdigest())
