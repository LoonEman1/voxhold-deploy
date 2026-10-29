#!/usr/bin/env python3
"""Reclaim obsolete official Voxhold images while retaining containers and rollback."""
import argparse
import json
from pathlib import Path
import shlex
import subprocess

REPOSITORIES = {'ghcr.io/looneman1/voxhold-backend', 'ghcr.io/looneman1/voxhold-frontend'}
IMAGE_KEYS = {'VOXHOLD_BACKEND_IMAGE', 'VOXHOLD_BACKEND_IMAGE_DIGEST', 'VOXHOLD_FRONTEND_IMAGE', 'VOXHOLD_FRONTEND_IMAGE_DIGEST'}


def rollback_references(manifest):
    values = set()
    for line in manifest.read_text().splitlines():
        key, separator, value = line.partition('=')
        if separator and key in IMAGE_KEYS:
            tokens = shlex.split(value, comments=True)
            if len(tokens) == 1 and tokens[0]:
                values.add(tokens[0])
    if not values:
        raise ValueError('rollback manifest contains no image references')
    return values


def cleanup_plan(images, containers, rollback):
    protected_ids = {item['Image'] for item in containers}
    protected_names = rollback | {item.get('Config', {}).get('Image', '') for item in containers}
    for image in images:
        names = set(image.get('RepoTags') or []) | set(image.get('RepoDigests') or [])
        if names & protected_names:
            protected_ids.add(image['Id'])
    result = []
    for image in images:
        tags = image.get('RepoTags') or []
        if image['Id'] in protected_ids or not tags:
            continue
        # Preserve operator aliases and every image outside these two repositories.
        if any(tag.rpartition(':')[0] not in REPOSITORIES for tag in tags):
            continue
        result.extend(tag for tag in tags if tag not in protected_names)
    return sorted(set(result))


def docker(*args):
    result = subprocess.run(['docker', *args], capture_output=True, text=True, timeout=60, check=True)
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true', help='Remove the planned image tags; default is preview only')
    parser.add_argument('--manifest', type=Path, default=Path(__file__).resolve().parent / '.last-good.env')
    args = parser.parse_args()
    try:
        rollback = rollback_references(args.manifest)
        ids = sorted(set(docker('image', 'ls', '--no-trunc', '-q').split()))
        images = []
        for start in range(0, len(ids), 100):
            images.extend(json.loads(docker('image', 'inspect', *ids[start:start + 100])))
        container_ids = docker('ps', '-aq').split()
        containers = json.loads(docker('inspect', *container_ids)) if container_ids else []
        plan = cleanup_plan(images, containers, rollback)
        print(json.dumps({'obsolete_voxhold_image_tags': plan, 'apply': args.apply}))
        if not args.apply:
            return
        for tag in plan:
            # Docker's own in-use checks stay enabled; never force removal.
            try:
                docker('image', 'rm', tag)
                print('Removed obsolete image tag: ' + tag)
            except subprocess.CalledProcessError:
                print('Kept image tag (Docker refused removal): ' + tag)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        # Cleanup must never make an otherwise healthy deployment fail.
        print('Image cleanup skipped safely: ' + str(error))


if __name__ == '__main__':
    main()
