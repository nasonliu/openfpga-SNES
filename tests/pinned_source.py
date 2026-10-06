"""Test-only exact source reconstruction; never creates a historical Git object."""
from functools import lru_cache
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess
import tempfile


def git_blob(data):
    return hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()


def _safe(root, name):
    path = PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or not path.parts:
        raise ValueError('unsafe fixture path')
    result = root/name
    if not result.resolve().is_relative_to(root.resolve()) or result.is_symlink():
        raise ValueError('unsafe fixture path')
    return result


def verify_source(data, entry):
    blob = entry.get('git_blob_sha', entry.get('git_blob'))
    if len(data) != entry['bytes'] or hashlib.sha256(data).hexdigest() != entry['sha256'] or git_blob(data) != blob:
        raise ValueError('source fixture integrity mismatch')
    return data


@lru_cache(maxsize=64)
def _reverse_patch(current, patch, name):
    # The cache keys include the complete input bytes, not just paths. Every
    # caller still validates current/patch/output hashes before receiving data.
    with tempfile.TemporaryDirectory(prefix='source-fixture-') as tmp:
        root = Path(tmp)
        path = _safe(root, name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(current)
        delta = root/'source.patch'
        delta.write_bytes(patch)
        for check in (True, False):
            command = ['git', 'apply', '-R', '--whitespace=nowarn']
            if check:
                command.append('--check')
            command += ['--', str(delta)]
            result = subprocess.run(command, cwd=root, text=True, capture_output=True)
            if result.returncode:
                raise ValueError('source fixture reverse patch failed: '+result.stderr.strip())
        return path.read_bytes()


def get_recipe(root, entry):
    manifest = json.loads((root/'tests/fixtures/savestate_patches/manifest.json').read_text())
    return manifest['recipes'][entry['patch_recipe']]


def reconstruct(root, entry, read_bytes=None):
    """Read exact current source, reverse a pinned patch and verify baseline."""
    read_bytes = read_bytes or Path.read_bytes
    recipe = get_recipe(root, entry)
    current = read_bytes(_safe(root, recipe['source_path']))
    verify_source(current, recipe['current'])
    patch = read_bytes(_safe(root, recipe['patch_path']))
    if hashlib.sha256(patch).hexdigest() != recipe['patch_sha256']:
        raise ValueError('source fixture patch integrity mismatch')
    return verify_source(_reverse_patch(current, patch, recipe['source_path']), entry)
