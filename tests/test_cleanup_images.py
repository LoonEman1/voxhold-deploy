import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('cleanup_images', ROOT / 'cleanup-images.py')
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)
BACKEND = 'ghcr.io/looneman1/voxhold-backend'
FRONTEND = 'ghcr.io/looneman1/voxhold-frontend'


def image(identity, *tags, digests=()):
    return {'Id': identity, 'RepoTags': list(tags), 'RepoDigests': list(digests)}


class CleanupTests(unittest.TestCase):
    def test_preserves_current_and_rollback_and_only_removes_official_old_tags(self):
        images = [image('current', FRONTEND + ':2.3.1'), image('rollback', FRONTEND + ':2.3.0'), image('old', FRONTEND + ':2.2.0'), image('vpn', 'amnezia:latest')]
        containers = [{'Image': 'current', 'Config': {'Image': FRONTEND + ':2.3.1'}}]
        self.assertEqual(cleanup.cleanup_plan(images, containers, {FRONTEND + ':2.3.0'}), [FRONTEND + ':2.2.0'])

    def test_preserves_stopped_containers_and_digest_only_rollback(self):
        images = [image('old', BACKEND + ':2.1.0'), image('rollback', BACKEND + ':2.2.0', digests=[BACKEND + '@sha256:rollback'])]
        containers = [{'Image': 'old', 'Config': {'Image': BACKEND + ':2.1.0'}}]
        self.assertEqual(cleanup.cleanup_plan(images, containers, {BACKEND + '@sha256:rollback'}), [])

    def test_preserves_operator_aliases_and_resolves_container_tag_to_index_identity(self):
        images = [image('multiarch-index', FRONTEND + ':2.3.0'), image('aliased', BACKEND + ':2.0.0', 'my-pinned-copy:stable'), image('dangling')]
        containers = [{'Image': 'platform-config', 'Config': {'Image': FRONTEND + ':2.3.0'}}]
        self.assertEqual(cleanup.cleanup_plan(images, containers, set()), [])

    def test_manifest_parser_does_not_execute_shell_text_or_accept_empty_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / '.last-good.env'
            path.write_text('VOXHOLD_FRONTEND_IMAGE="' + FRONTEND + ':2.3.0"\nSAVED_AT_UTC="now"\n')
            self.assertEqual(cleanup.rollback_references(path), {FRONTEND + ':2.3.0'})
            path.write_text('SAVED_AT_UTC="now"\n')
            with self.assertRaises(ValueError):
                cleanup.rollback_references(path)


if __name__ == '__main__':
    unittest.main()
