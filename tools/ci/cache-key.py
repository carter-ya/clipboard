#!/usr/bin/env python3
"""Identify compiled dependencies using committed inputs, not resolver side effects."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess


def cache_key(repo, package, configuration, operating_system, architecture, compiler):
    if package not in ('Core', 'Desktop') or configuration not in ('debug', 'release'):
        raise ValueError('Unsupported package or build configuration')
    paths = ['Core/Package.swift', 'Core/Package.resolved', 'tools/ci/cache-key.py',
             '.github/actions/swift-build-cache',
             'tools/desktop-ui/install-windows-zlib.ps1']
    if package == 'Desktop':
        paths += ['Desktop/Package.swift', 'Desktop/Package.resolved', 'Desktop/Patches',
                  'tools/desktop-ui/build-desktop.py', 'tools/desktop-ui/install-windows-gtk.ps1',
                  'tools/desktop-ui/apply-gtk-source-patch.py', 'tools/desktop-ui/gtk-4.22.4-accesskit-actions.patch',
                  'tools/desktop-pdf', 'tools/desktop-image', 'tools/desktop-language', 'tools/desktop-text']
    # Git object IDs ignore checkout line endings and SwiftPM rewrites. Include
    # native-worker recipes as well as dependency pins; application edits remain
    # incremental inputs to SwiftPM rather than invalidating every dependency.
    tree = subprocess.check_output(['git', 'ls-tree', '-r', '-z', 'HEAD', '--', *paths], cwd=repo)
    entries = []
    for entry in tree.split(b'\0'):
        if not entry:
            continue
        name = Path(entry.split(b'\t', 1)[1].decode('utf-8'))
        if name.parts[:1] == ('tools',) and len(name.parts) > 1 and name.parts[1] in (
                'desktop-pdf', 'desktop-image', 'desktop-language', 'desktop-text'):
            if name.name not in ('upstream.json', 'build-worker.py', 'CMakeLists.txt') and name.suffix not in (
                    '.c', '.cpp', '.h', '.hpp', '.cmake', '.patch'):
                continue
        entries.append(entry)
    tree = b'\0'.join(entries)
    names = {entry.split(b'\t', 1)[1].decode('utf-8') for entry in entries}
    required = {'Core/Package.swift', 'Core/Package.resolved'}
    if package == 'Desktop':
        required |= {'Desktop/Package.swift', 'Desktop/Package.resolved'}
    if not required <= names:
        raise ValueError('Committed package manifests and dependency pins are required')
    identity = json.dumps([operating_system, architecture, compiler, package, configuration],
                          ensure_ascii=True, separators=(',', ':')).encode('utf-8')
    fingerprint = hashlib.sha256(identity + b'\0' + tree).hexdigest()
    return 'swift-deps-v2-' + package.lower() + '-' + configuration + '-' + fingerprint


def compiler_identity():
    output = subprocess.check_output(['swift', '--version'], text=True)
    lines = [line.strip() for line in output.splitlines()
             if 'Swift version' in line or line.startswith('Target:')]
    if not any('Swift version' in line for line in lines):
        raise ValueError('Cannot identify selected Swift compiler')
    if platform.system() == 'Darwin':
        lines.append(subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-build-version'], text=True).strip())
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', choices=['Core', 'Desktop'], required=True)
    parser.add_argument('--configuration', choices=['debug', 'release'], default='debug')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    operating_system = os.environ.get('RUNNER_OS', platform.system())
    if os.environ.get('ImageOS'):
        operating_system += '/' + os.environ['ImageOS']
    key = cache_key(repo, args.package, args.configuration,
                    operating_system,
                    os.environ.get('RUNNER_ARCH', platform.machine()), compiler_identity())
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8', newline='\n') as output:
            output.write('key=' + key + '\n')
    print(key)


if __name__ == '__main__':
    main()
