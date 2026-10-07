#!/usr/bin/env python3
import importlib.util
import json
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('version', Path(__file__).with_name('version.py'))
version = importlib.util.module_from_spec(spec)
spec.loader.exec_module(version)


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.com')
        self.git('config', 'commit.gpgsign', 'false')
        self.git('config', 'tag.gpgsign', 'false')
        (self.root / 'VERSION').write_text('1.0\n')
        self.commit()

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], text=True).strip()

    def commit(self):
        self.sequence = getattr(self, 'sequence', 0) + 1
        self.git('add', '.')
        self.git('commit', '-qm', f'Fixture {self.sequence}', '--allow-empty')

    def test_release_and_following_commits(self):
        self.git('tag', '-a', '1.0', '-m', 'Release 1.0')
        self.assertEqual(version.version_info(self.root)['display'], '1.0')
        self.commit()
        self.commit()
        self.assertEqual(version.version_info(self.root)['display'], '1.0-2')
        (self.root / 'VERSION').write_text('1.1\n')
        self.commit()
        self.assertEqual(version.version_info(self.root)['display'], '1.1-3')
        self.git('tag', '-a', '1.1', '-m', 'Release 1.1')
        self.assertEqual(version.version_info(self.root)['display'], '1.1')

    def test_unrelated_and_non_release_tags_do_not_reset_count(self):
        self.git('tag', '1.0')
        self.git('checkout', '-qb', 'future')
        self.commit()
        self.git('tag', '9.0')
        self.git('checkout', '-q', 'main')
        self.commit()
        self.git('tag', 'preview')
        info = version.version_info(self.root)
        self.assertEqual(info['display'], '1.0-1')
        self.assertEqual(info['releaseTag'], '1.0')

    def test_no_tag_uses_history_count(self):
        self.assertEqual(version.version_info(self.root)['display'], '1.0-1')

    def test_bundle_metadata_and_display_are_consistent(self):
        self.git('tag', '1.0')
        bundle = self.root / 'App.app'
        (bundle / 'Contents').mkdir(parents=True)
        with (bundle / 'Contents/Info.plist').open('wb') as handle:
            plistlib.dump({'CFBundleIdentifier': 'example.fixture'}, handle)
        info = version.version_info(self.root)
        version.write_bundle(bundle, info)
        with (bundle / 'Contents/Info.plist').open('rb') as handle:
            plist = plistlib.load(handle)
        self.assertEqual(plist['CFBundleShortVersionString'], '1.0')
        self.assertEqual(plist['CodexUsageViewerDisplayVersion'], '1.0')
        self.assertEqual(json.loads((bundle / 'Contents/Resources/BuildVersion.json').read_text()), info)

    def test_version_change_at_old_tag_is_not_a_release(self):
        self.git('tag', '1.0')
        (self.root / 'VERSION').write_text('1.1\n')
        self.assertEqual(version.version_info(self.root)['display'], '1.1-0')


if __name__ == '__main__':
    unittest.main()
