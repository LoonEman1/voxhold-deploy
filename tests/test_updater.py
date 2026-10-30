import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get("VOXHOLD_UPDATER_SOURCE", ROOT / "update.sh"))
FAKE_DOCKER = r"""#!/usr/bin/env python3
import json, os, sys
args=sys.argv[1:]
with open(os.environ['MOCK_TRACE'],'a') as out: out.write(json.dumps(args)+'\n')
if args[:2]==['compose','config'] and '--format' in args:
    image=os.environ.get('VOXHOLD_BACKEND_IMAGE')
    if not image:
        for line in open('.env'):
            if line.startswith('VOXHOLD_BACKEND_IMAGE='): image=line.split('=',1)[1].strip().strip(chr(34))
    print('services:')
    print('  backend:')
    print('    image: '+image)
    print('  bootstrap:')
    print('    image: bootstrap:other')
    print('  migrate:')
    print('    image: migrate:other')
    sys.exit(0)
if args[:2]==['manifest','inspect']:
    sys.exit(0 if args[-1] in os.environ.get('MOCK_CPU_TAGS','').split(',') else 1)
if args[:2]==['compose','run'] and '--check-cpu' in args:
    sys.exit(1 if os.environ.get('MOCK_CPU_FAIL')=='1' else 0)
if args[:2]==['compose','ps'] and '-q' in args:
    print('old-'+args[-1]); sys.exit(0)
if args and args[0]=='inspect':
    fmt=args[args.index('-f')+1]
    service='frontend' if 'frontend' in args[-1] else 'backend'
    if '.RepoDigests' in fmt: sys.exit(1)
    if '.Config.Image' in fmt: print('ghcr.io/looneman1/voxhold-'+service+':2.0.0')
    elif '.State.Health' in fmt: print('unhealthy' if os.environ.get('MOCK_UNHEALTHY')==service else 'healthy')
    elif '.Image' in fmt: print('sha256:old-'+service)
    sys.exit(0)
if args[:2]==['image','inspect']:
    if 'io.voxhold.cpu-check' in ' '.join(args):
        print('1' if os.environ.get('MOCK_CPU_CHECK')=='1' else '<no value>'); sys.exit(0)
    service='frontend' if 'frontend' in args[-1] else 'backend'
    print('ghcr.io/looneman1/voxhold-'+service+'@sha256:'+('2' if service=='frontend' else '1')*64)
    sys.exit(0)
if args[:2]==['compose','pull'] and os.environ.get('MOCK_PULL_FAIL')=='1': sys.exit(1)
"""

@unittest.skipUnless(os.name == 'posix', 'Bash updater scenarios run on Linux CI')
class UpdaterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copyfile(SOURCE, self.root / 'update.sh')
        shutil.copyfile(ROOT / 'cpu-images.sh', self.root / 'cpu-images.sh')
        binary = self.root / 'bin'; binary.mkdir()
        for name, text in {'docker': FAKE_DOCKER, 'sleep': '#!/bin/sh\nexit 0\n'}.items():
            path=binary/name;path.write_text(text);path.chmod(0o755)
        (self.root/'backup.sh').write_text('#!/bin/sh\ntouch backup.done\n')
        (self.root/'backup.sh').chmod(0o755)
        values = {'VOXHOLD_BACKEND_IMAGE':'ghcr.io/looneman1/voxhold-backend:2.0.0', 'VOXHOLD_FRONTEND_IMAGE':'ghcr.io/looneman1/voxhold-frontend:2.0.0', 'VOXHOLD_CADDYFILE':'./Caddyfile.ip', 'COMPOSE_PROFILES':'web,turn','TURN_USER_QUOTA':'0','TURN_TOTAL_QUOTA':'400'}
        values.update({f'WEBRTC_{side}_ICE_{field}':'' for side in ['CLIENT','SERVER'] for field in ['SERVERS','USERNAME','CREDENTIAL']})
        (self.root/'.env').write_text(''.join(f'{k}="{v}"\n' for k,v in values.items()))
        self.env = dict(os.environ, PATH=str(binary)+os.pathsep+os.environ['PATH'], MOCK_TRACE=str(self.root/'trace.jsonl'))

    def run_update(self, *args, **env):
        return subprocess.run(['bash','update.sh',*args],cwd=self.root,env=dict(self.env,**env),capture_output=True,text=True)

    def manifest(self):
        return (self.root/'.last-good.env').read_text()

    def test_backend_pin_preserves_the_running_release_for_rollback(self):
        result=self.run_update('--backend-version','2.1.0')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('VOXHOLD_BACKEND_IMAGE="ghcr.io/looneman1/voxhold-backend:2.0.0"',self.manifest())
        self.assertIn('voxhold-backend@sha256:'+'1'*64,self.manifest())
        self.assertTrue((self.root/'backup.done').exists())

    def test_paired_release_selects_both_images(self):
        result=self.run_update('--backend-version','2.1.0','--frontend-version','v2.1.0')
        self.assertEqual(result.returncode,0,result.stderr)
        desired=(self.root/'.env').read_text()
        for component in ['backend','frontend']:
            self.assertIn(f'ghcr.io/looneman1/voxhold-{component}:2.1.0',desired)
            self.assertIn(f'ghcr.io/looneman1/voxhold-{component}:2.0.0',self.manifest())
        self.assertIn('voxhold-frontend@sha256:'+'2'*64,self.manifest())

    def test_failed_health_keeps_rollback_point_and_returns_failure(self):
        for service in ['backend','frontend']:
            with self.subTest(service=service):
                result=self.run_update('--backend-version','2.1.0',MOCK_UNHEALTHY=service)
                self.assertNotEqual(result.returncode,0)
                self.assertIn('voxhold-backend@sha256:'+'1'*64,self.manifest())
                self.assertNotIn('Update finished;',result.stdout)

    def test_rollback_uses_immutable_digests_without_replacing_manifest(self):
        original='VOXHOLD_BACKEND_IMAGE="old:2.0.0"\nVOXHOLD_BACKEND_IMAGE_DIGEST="ghcr.io/looneman1/voxhold-backend@sha256:'+('1'*64)+'"\nVOXHOLD_FRONTEND_IMAGE="old:2.0.0"\nVOXHOLD_FRONTEND_IMAGE_DIGEST="ghcr.io/looneman1/voxhold-frontend@sha256:'+('2'*64)+'"\n'
        (self.root/'.last-good.env').write_text(original)
        result=self.run_update('--rollback')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.manifest(),original)
        self.assertFalse((self.root/'backup.done').exists())
        self.assertIn('voxhold-backend@sha256:'+'1'*64,(self.root/'.env').read_text())

    def test_failed_pull_never_touches_the_running_stack(self):
        result=self.run_update('--backend-version','2.1.0',MOCK_PULL_FAIL='1')
        self.assertNotEqual(result.returncode,0)
        calls=[json.loads(line) for line in (self.root/'trace.jsonl').read_text().splitlines()]
        self.assertFalse(any(call[:2]==['compose','up'] for call in calls))
        self.assertFalse((self.root/'backup.done').exists())

    def cleanup_helper(self, failing=False):
        (self.root/'cleanup-images.py').write_text("from pathlib import Path\nPath('cleanup.done').touch()\n" + ("raise RuntimeError('test cleanup failure')\n" if failing else ""))

    def test_cleanup_runs_only_after_both_components_are_healthy(self):
        self.cleanup_helper()
        result=self.run_update('--frontend-version','2.3.1',MOCK_UNHEALTHY='frontend')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse((self.root/'cleanup.done').exists())
        result=self.run_update('--frontend-version','2.3.1')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue((self.root/'cleanup.done').exists())

    def test_operator_can_keep_historical_images(self):
        self.cleanup_helper()
        result=self.run_update('--frontend-version','2.3.1',VOXHOLD_UPDATE_KEEP_IMAGES='1')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse((self.root/'cleanup.done').exists())

    def test_cleanup_failure_does_not_fail_a_healthy_update(self):
        self.cleanup_helper(failing=True)
        result=self.run_update('--frontend-version','2.3.1')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('Update finished;',result.stdout)
        self.assertTrue((self.root/'cleanup.done').exists())

    def test_cpu_preflight_failure_never_stops_the_running_backend(self):
        result = self.run_update('--backend-version', '2.5.0', MOCK_CPU_CHECK='1', MOCK_CPU_FAIL='1')
        self.assertNotEqual(result.returncode, 0)
        calls = [json.loads(line) for line in (self.root/'trace.jsonl').read_text().splitlines()]
        self.assertTrue(any('--check-cpu' in call for call in calls))
        self.assertFalse(any(call[:2] == ['compose', 'up'] for call in calls))
        self.assertFalse((self.root/'backup.done').exists())
        self.assertFalse((self.root/'.last-good.env').exists())

    def test_cpu_variant_is_selected_before_pull(self):
        image = 'ghcr.io/looneman1/voxhold-backend:2.5.0-amd64-v1'
        result = self.run_update('--backend-version', '2.5.0', VOXHOLD_AMD64='v1', MOCK_CPU_TAGS=image, MOCK_CPU_CHECK='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(image, (self.root/'.env').read_text())
        self.assertIn('voxhold-backend:2.0.0', self.manifest())
        calls = [json.loads(line) for line in (self.root/'trace.jsonl').read_text().splitlines()]
        pull = next(i for i, call in enumerate(calls) if call[:2] == ['compose', 'pull'])
        probe = next(i for i, call in enumerate(calls) if '--check-cpu' in call)
        start = next(i for i, call in enumerate(calls) if call[:2] == ['compose', 'up'])
        self.assertLess(pull, probe)
        self.assertLess(probe, start)

    def test_image_environment_override_is_preflighted(self):
        override = 'example.test/backend:cpu-v3'
        result = self.run_update(VOXHOLD_BACKEND_IMAGE=override, MOCK_CPU_CHECK='1', MOCK_CPU_FAIL='1')
        self.assertNotEqual(result.returncode, 0)
        calls = [json.loads(line) for line in (self.root/'trace.jsonl').read_text().splitlines()]
        self.assertTrue(any(call[:2] == ['image', 'inspect'] and call[-1] == override for call in calls))
        self.assertFalse((self.root/'backup.done').exists())

    def test_installer_persists_cpu_mode_for_later_updates(self):
        shutil.copyfile(ROOT/'install.sh', self.root/'install.sh')
        for name, script in {'uname': '#!/bin/sh\ncase $1 in -m) echo x86_64 ;; *) echo Linux ;; esac\n', 'curl': '#!/bin/sh\necho 203.0.113.10\n'}.items():
            path = self.root/'bin'/name
            path.write_text(script); path.chmod(0o755)
        # English, backend-only, no autostart, default image, public IP,
        # default name/owner, synthetic password, default WebRTC IP, no TURN.
        answers = '1\n1\nn\n\n203.0.113.10\n\n\nLocalFixturePassword123!\n\nn\n'
        installed = subprocess.run(['bash', 'install.sh'], cwd=self.root, env=dict(self.env, VOXHOLD_AMD64='v1'), input=answers, capture_output=True, text=True)
        self.assertEqual(installed.returncode, 0, installed.stdout+installed.stderr)
        self.assertIn('VOXHOLD_AMD64="v1"', (self.root/'.env').read_text())
        # Use the real host architecture for the subsequent updater.
        (self.root/'bin'/'uname').unlink()
        image = 'ghcr.io/looneman1/voxhold-backend:2.5.0-amd64-v1'
        updated = self.run_update('--backend-version', '2.5.0', MOCK_CPU_TAGS=image)
        self.assertEqual(updated.returncode, 0, updated.stdout+updated.stderr)
        self.assertIn(image, (self.root/'.env').read_text())

    def test_version_selection_cannot_be_combined_with_rollback(self):
        result=self.run_update('--frontend-version','2.1.0','--rollback')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse((self.root/'trace.jsonl').exists())

if __name__=='__main__': unittest.main()
