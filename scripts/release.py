#!/usr/bin/env python3
"""Tag, build, notarize, and publish a clean release. Requires NOTARY_PROFILE."""
import argparse
import hashlib
import json
import os
import subprocess
from pathlib import Path
from version import ROOT, RELEASE, git


def run(*args, **kwargs):
    subprocess.run(args, cwd=ROOT, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('version')
    parser.add_argument('--notes', type=Path, required=True)
    args = parser.parse_args()
    if not RELEASE.fullmatch(args.version) or (ROOT / 'VERSION').read_text().strip() != args.version:
        parser.error('version must match the numeric VERSION file; commit the release changes first')
    profile = os.environ.get('NOTARY_PROFILE')
    if not profile:
        parser.error('set NOTARY_PROFILE to your existing notarytool Keychain profile')
    if git(ROOT, 'status', '--porcelain'):
        parser.error('working tree must be clean')
    if not args.notes.is_file():
        parser.error('release notes file is missing')
    branch = git(ROOT, 'branch', '--show-current')
    if not branch:
        parser.error('release from a branch, not detached HEAD')
    run('git', 'fetch', '--tags', 'origin')
    run('gh', 'auth', 'status', stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    run('xcrun', 'notarytool', 'history', '--keychain-profile', profile, '--output-format', 'json', stdout=subprocess.DEVNULL)
    existing = subprocess.run(['git', 'rev-parse', '--verify', f'refs/tags/{args.version}'], cwd=ROOT, capture_output=True)
    if existing.returncode == 0:
        if git(ROOT, 'rev-parse', f'{args.version}^{{commit}}') != git(ROOT, 'rev-parse', 'HEAD'):
            parser.error('release tag already points to a different commit')
    else:
        # The tag precedes the build so released app versions end in -0.
        run('git', 'tag', '-a', args.version, '-m', f'Release {args.version}')
    run('python3', 'scripts/test_version.py')
    run('swift', 'test')
    run('./scripts/build.sh', 'ARCHS=arm64 x86_64', 'ONLY_ACTIVE_ARCH=NO')
    app = ROOT / 'build/Build/Products/Release/Codex Usage Viewer.app'
    info = json.loads((app / 'Contents/Resources/BuildVersion.json').read_text())
    if info['display'] != f'{args.version}-0' or info['commit'] != git(ROOT, 'rev-parse', 'HEAD'):
        raise RuntimeError('built version does not match the release tag')
    run('codesign', '--verify', '--deep', '--strict', str(app))
    output = ROOT / 'dist' / args.version
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f'Codex-Usage-Viewer-{args.version}.zip'
    run('ditto', '-c', '-k', '--keepParent', str(app), str(archive))
    run('xcrun', 'notarytool', 'submit', str(archive), '--keychain-profile', profile, '--wait', '--output-format', 'json', stdout=(output / 'notarization.json').open('w'))
    notarization = json.loads((output / 'notarization.json').read_text())
    if notarization.get('status') != 'Accepted':
        raise RuntimeError('Apple did not accept the submitted app; publication stopped')
    run('xcrun', 'stapler', 'staple', str(app))
    run('xcrun', 'stapler', 'validate', str(app))
    run('spctl', '--assess', '--type', 'execute', '--verbose=4', str(app))
    archive.unlink()
    run('ditto', '-c', '-k', '--keepParent', str(app), str(archive))
    checksum = output / 'SHA256SUMS.txt'
    checksum.write_text(f'{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}\n')
    run('git', 'push', '--atomic', 'origin', branch, f'refs/tags/{args.version}')
    run('gh', 'release', 'create', args.version, str(archive), str(checksum), '--verify-tag', '--title', f'Codex Usage Viewer {args.version}', '--notes-file', str(args.notes.resolve()))
    print(f'Published Codex Usage Viewer {info["display"]}')


if __name__ == '__main__':
    main()
