"""Source-only savestate provenance and fixture integrity checks."""
import copy
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from pinned_source import get_recipe, reconstruct

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = json.loads((ROOT/'docs/savestate-source-manifest.json').read_text())
BASE = ROOT/'tests/fixtures/savestate_predecode'


def blob(data):
    return hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()


def check_entry(data, entry):
    if len(data) != entry['bytes'] or hashlib.sha256(data).hexdigest() != entry['sha256'] or blob(data) != entry['git_blob_sha']:
        raise ValueError('fixture integrity mismatch')


class SavestateSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run([sys.executable, str(ROOT/'tools/generate_savestate_rom.py')], check=True, capture_output=True)

    def test_reverse_patch_rejects_changed_current_source(self):
        entry = json.loads((BASE/'manifest.json').read_text())['files'][0]
        with self.assertRaisesRegex(ValueError, 'integrity mismatch'):
            reconstruct(ROOT, entry, lambda p: p.read_bytes()+b'changed' if p == ROOT/get_recipe(ROOT, entry)['source_path'] else p.read_bytes())

    def test_reverse_patch_rejects_changed_patch(self):
        entry = json.loads((BASE/'manifest.json').read_text())['files'][0]
        with self.assertRaisesRegex(ValueError, 'patch integrity mismatch'):
            reconstruct(ROOT, entry, lambda p: p.read_bytes()+b'changed' if p.suffix == '.patch' else p.read_bytes())

    def test_reverse_patch_rejects_false_baseline_identity(self):
        entry = copy.deepcopy(json.loads((BASE/'manifest.json').read_text())['files'][0])
        entry['sha256'] = '0'*64
        with self.assertRaisesRegex(ValueError, 'integrity mismatch'):
            reconstruct(ROOT, entry)

    def test_predecode_snapshot_inventory_and_hashes(self):
        manifest = json.loads((BASE/'manifest.json').read_text())
        self.assertEqual({x['path'] for x in manifest['files']}, {
            'rtl/upstream/CPU.vhd', 'rtl/upstream/SNES.vhd',
            'rtl/upstream/main.v', 'rtl/upstream/savestates.sv'})
        for entry in manifest['files']:
            check_entry(reconstruct(ROOT, entry), entry)

    def test_corrupt_snapshot_bytes_or_metadata_rejected(self):
        entry = json.loads((BASE/'manifest.json').read_text())['files'][0]
        data = reconstruct(ROOT, entry)
        for changed in (data+b'\n', bytes([data[0]^1])+data[1:]):
            with self.assertRaisesRegex(ValueError, 'integrity mismatch'):
                check_entry(changed, entry)
        for field in ('bytes', 'sha256', 'git_blob_sha'):
            changed = dict(entry, **{field: -1 if field == 'bytes' else '0'*40})
            with self.assertRaisesRegex(ValueError, 'integrity mismatch'):
                check_entry(data, changed)

    def test_unmodified_imports_match_immutable_upstream_hashes(self):
        for entry in MANIFEST['files']:
            if not entry['modified']:
                data = (ROOT/entry['path']).read_bytes()
                self.assertEqual(hashlib.sha256(data).hexdigest(), entry['source_sha256'], entry['path'])
                self.assertEqual(blob(data), entry['source_blob_sha'], entry['path'])
                self.assertIn('/blob/', entry['source_url'])

    def test_complete_helper_assembly_includes_are_manifested(self):
        directory = ROOT/'rtl/upstream/src'
        entries = {x['path']: x for x in MANIFEST['files']}
        includes = re.findall(r'^include "([^"]+)"', (directory/'savestates.asm').read_text(), re.M)
        self.assertEqual(set(includes), {'savestates_sa1.asm', 'savestates_dspn.asm', 'savestates_gsu.asm', 'savestates_cx4.asm'})
        for name in ['savestates.asm', *includes]:
            path = directory/name
            self.assertTrue(path.is_file())
            self.assertFalse(entries[str(path.relative_to(ROOT))]['modified'])
            for nested in re.findall(r'^include "([^"]+)"', path.read_text(), re.M):
                self.assertTrue((directory/nested).is_file())

    def test_helper_initializers_equal_pinned_binary_and_zero_padding(self):
        data = (ROOT/'rtl/upstream/releases/boot1.rom').read_bytes()
        self.assertEqual(len(data), 3558)
        self.assertEqual(hashlib.sha256(data).hexdigest(), '109b065d87989fae5d010040acfa6147160b8c8d3df50ab8cdabe7776e153001')
        padded = data.ljust(4096, b'\0')
        lines = (ROOT/'rtl/mister_top/boot1.hex').read_text().splitlines()
        self.assertEqual(len(lines), 2048)
        self.assertEqual(b''.join(int(x, 16).to_bytes(2, 'little') for x in lines), padded)
        mif = (ROOT/'rtl/mister_top/boot1.mif').read_text()
        pairs = re.findall(r'^([0-9A-F]+) : ([0-9A-F]+);$', mif, re.M)
        self.assertEqual([int(a, 16) for a, _ in pairs], list(range(2048)))
        self.assertEqual(b''.join(int(v, 16).to_bytes(2, 'little') for _, v in pairs), padded)

    def test_generator_rejects_altered_helper_before_writing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for directory in ('tools', 'rtl/upstream/releases', 'rtl/mister_top'):
                (root/directory).mkdir(parents=True, exist_ok=True)
            (root/'tools/generate_savestate_rom.py').write_bytes((ROOT/'tools/generate_savestate_rom.py').read_bytes())
            data = bytearray((ROOT/'rtl/upstream/releases/boot1.rom').read_bytes()); data[0] ^= 1
            (root/'rtl/upstream/releases/boot1.rom').write_bytes(data)
            p = subprocess.run([sys.executable, str(root/'tools/generate_savestate_rom.py')], capture_output=True, text=True)
            self.assertNotEqual(p.returncode, 0)
            self.assertIn('Unexpected helper ROM', p.stderr)
            self.assertFalse((root/'rtl/mister_top/boot1.mif').exists())

    def test_licenses_retained(self):
        self.assertIn('GNU GENERAL PUBLIC LICENSE', (ROOT/'LICENSE').read_text())
        notice = (ROOT/'docs/licenses/openfpga-litex-MIT.txt').read_text()
        self.assertIn('Copyright (c) 2023 agg23', notice)
        self.assertIn('Permission is hereby granted', notice)
        self.assertIn('openfpga-litex', (ROOT/'target/pocket/sram.sv').read_text())


if __name__ == '__main__':
    unittest.main()
