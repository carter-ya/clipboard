#!/usr/bin/env python3
"""Assemble reviewable desktop artifacts from an already built native executable."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import struct
import subprocess
import tarfile
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('--binary', required=True)
parser.add_argument('--output', required=True)
parser.add_argument('--platform', choices=['linux', 'windows'], required=True)
parser.add_argument('--gtk-prefix')
parser.add_argument('--version')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
version = args.version or (repo / 'Desktop/VERSION').read_text().strip()
if not re.fullmatch(r'\d+\.\d+\.\d+(?:-preview\.\d+)?', version):
    raise RuntimeError('Invalid desktop package version')
binary = Path(args.binary).resolve()
if not binary.is_file():
    raise RuntimeError('Build the native desktop executable before packaging')
output = Path(args.output).resolve()
output.mkdir(parents=True, exist_ok=True)
arch = 'x64' if platform.machine().lower() in ('x86_64', 'amd64') else 'arm64'
name = f'ClipboardDesktop-{version}-{args.platform}-{arch}'
root = output / name
# Never overwrite an earlier artifact, especially an installed application.
root.mkdir()
bin_dir, lib_dir = root / 'bin', root / 'lib'
bin_dir.mkdir()
lib_dir.mkdir()
shutil.copy2(binary, bin_dir / binary.name)
for resource in binary.parent.iterdir():
    if resource.is_dir() and resource.suffix in ('.resources', '.bundle'):
        shutil.copytree(resource, bin_dir / resource.name)
licenses = root / 'share/licenses'
licenses.mkdir(parents=True)


def copy_licenses(source, component):
    if not source.exists():
        return
    for file in source.rglob('*'):
        if (file.is_file() and file.stat().st_size < 2 * 1024 * 1024 and
                re.match(r'^(LICENSE|COPYING|NOTICE|COPYRIGHT)(?:\b|[._-])', file.name, re.IGNORECASE)):
            target = licenses / component / file.relative_to(source)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(file, target)


# Keep dependency notices alongside binaries, including Gtk's nested LGPL notice.
checkout_root = repo / 'Desktop/.build/checkouts'
if not checkout_root.exists():
    checkout_root = binary.parents[2] / 'checkouts'
for checkout in checkout_root.glob('*'):
    if checkout.is_dir():
        copy_licenses(checkout, checkout.name)
for resolved in [repo / 'Desktop/Package.resolved', repo / 'Core/Package.resolved']:
    shutil.copy2(resolved, licenses / (resolved.parent.name + '-Package.resolved'))

shutil.copy2(repo / 'Desktop/Packaging' / ('README-' + args.platform + '.md'), root / 'README.md')

runtime_files = []
if args.platform == 'linux':
    if platform.system() != 'Linux':
        raise RuntimeError('Linux packages must be assembled on their native Linux builder')
    dependencies = subprocess.check_output(['ldd', str(binary)], text=True)
    if 'not found' in dependencies:
        raise RuntimeError('The native executable has unresolved dependencies')
    for line in dependencies.splitlines():
        match = re.match(r'\s*(\S+) => (/\S+) \(', line)
        if not match:
            continue
        needed, value = match.groups()
        source = Path(value)
        # Bundle Swift's runtime only. Distribution GTK/OCR/security libraries
        # are declared as package dependencies and remain maintained by the OS.
        if '/lib/swift/' in str(source):
            target = lib_dir / needed
            if not target.exists():
                shutil.copy2(source, target)
                runtime_files.append(needed)
    if not runtime_files:
        raise RuntimeError('No Swift runtime was found; do not produce an incomplete archive')
    subprocess.run(['patchelf', '--set-rpath', '$ORIGIN/../lib', str(bin_dir / binary.name)], check=True)
    for library in lib_dir.iterdir():
        subprocess.run(['patchelf', '--set-rpath', '$ORIGIN', str(library)], check=True)
    launcher = bin_dir / 'clipboard-desktop'
    launcher.write_text('#!/bin/sh\nset -eu\napp_bin=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)\nexec "$app_bin/ClipboardDesktop" "$@"\n')
    launcher.chmod(0o755)
    shutil.copy2(repo / 'tools/desktop-package/install-linux.py', root / 'install.py')
    shutil.copy2(repo / 'tools/desktop-package/uninstall-linux.py', root / 'uninstall.py')
    shutil.copy2(repo / 'tools/desktop-package/linux_installation.py', root / 'linux_installation.py')
    icon = root / 'share/icons/hicolor/256x256/apps/com.clipboard.desktop.png'
    icon.parent.mkdir(parents=True)
    shutil.copy2(repo / 'App/Assets.xcassets/AppIcon.appiconset/icon_256x256.png', icon)
    swift = Path(shutil.which('swift')).resolve()
    for path in [swift.parents[1] / 'share/swift', swift.parents[2] / 'share/swift', swift.parents[2] / 'share/doc/swift']:
        copy_licenses(path, 'swift-runtime')
    archive = output / (name + '.tar.gz')
else:
    if os.name != 'nt' or not args.gtk_prefix:
        raise RuntimeError('Windows packaging requires a native builder and verified GTK prefix')
    gtk = Path(args.gtk_prefix).resolve()
    marker = json.loads((gtk / 'clipboard-runtime.json').read_text(encoding='utf-8-sig'))
    if marker.get('accessibility') != 'accesskit' or marker.get('gtk') != '4.22.4':
        raise RuntimeError('Verified GTK/AccessKit runtime is required')
    # Preserve the upstream bin/lib/share layout so GTK/GdkPixbuf relocation and
    # its relative loader cache keep working from an arbitrary install folder.
    for directory in ['gdk-pixbuf-2.0', 'gio/modules', 'gtk-4.0']:
        source = gtk / 'lib' / directory
        if source.exists():
            shutil.copytree(source, lib_dir / directory, ignore=shutil.ignore_patterns('*.lib', '*.pdb', '*.a', '*.la', '*.pc'))
    for directory in ['glib-2.0/schemas', 'icons', 'themes', 'locale', 'licenses', 'doc']:
        source = gtk / 'share' / directory
        if source.exists():
            shutil.copytree(source, root / 'share' / directory, dirs_exist_ok=True)
    shutil.copy2(gtk / 'clipboard-runtime.json', root / 'clipboard-runtime.json')
    tool = shutil.which('llvm-readobj')
    if not tool:
        raise RuntimeError('llvm-readobj is required to verify the Windows DLL closure')
    headers = subprocess.check_output([tool, '--file-headers', str(binary)], text=True)
    if 'IMAGE_SUBSYSTEM_WINDOWS_GUI' not in headers:
        raise RuntimeError('The packaged application must use the Windows GUI subsystem')
    compiler = Path(shutil.which('swiftc')).resolve()
    target_info = json.loads(subprocess.check_output(['swiftc', '-print-target-info'], text=True))
    search = [gtk / 'bin', compiler.parent]
    for path in target_info['paths'].get('runtimeLibraryPaths', []):
        directory = Path(path)
        search.extend([directory, directory.parent / 'bin'])
    sdk = target_info.get('paths', {}).get('sdkPath') or os.environ.get('SDKROOT')
    if sdk:
        search.extend([Path(sdk) / 'usr/bin', Path(sdk) / 'usr/bin/x86_64'])
    # Swift's runtime DLLs may live in the platform runtime directory rather
    # than its compiler directory. Search only the selected installation.
    installation = next((path for path in compiler.parents if (path / 'Toolchains').is_dir() and (path / 'Platforms').is_dir()), None)
    if installation is None:
        raise RuntimeError('Could not locate the selected Swift installation')
    selected_version = compiler.parents[2].name.split('+', 1)[0]
    for subtree in ['Platforms', 'Runtimes']:
        for release in (installation / subtree).glob(selected_version + '*'):
            for library in release.rglob('*.dll'):
                if library.parent not in search:
                    search.append(library.parent)
    locator = Path(os.environ['ProgramFiles(x86)']) / 'Microsoft Visual Studio/Installer/vswhere.exe'
    visual_studio = Path(subprocess.check_output([str(locator), '-latest', '-products', '*', '-property', 'installationPath'], text=True).strip())
    redists = sorted((visual_studio / 'VC/Redist/MSVC').glob('*/x64/Microsoft.VC143.CRT'))
    if not redists:
        raise RuntimeError('The licensed MSVC x64 redistributable files are required')
    search.append(redists[-1])
    for library in redists[-1].glob('*.dll'):
        shutil.copy2(library, bin_dir / library.name)
    copy_licenses(visual_studio / 'VC/Redist', 'msvc-runtime')
    copy_licenses(installation, 'swift-runtime')
    system = Path(os.environ['SystemRoot']) / 'System32'
    processed = set()
    pending = [bin_dir / binary.name] + list(bin_dir.glob('*.dll')) + list(lib_dir.rglob('*.dll'))
    while pending:
        file = pending.pop()
        if file.name.lower() in processed:
            continue
        processed.add(file.name.lower())
        imported = subprocess.check_output([tool, '--coff-imports', str(file)], text=True)
        for dependency in re.findall(r'^\s*Name: ([A-Za-z0-9_.+-]+\.dll)\s*$', imported, re.MULTILINE | re.IGNORECASE):
            if dependency.lower().startswith(('api-ms-', 'ext-ms-')):
                continue
            if (bin_dir / dependency).exists():
                continue
            candidate = next((folder / dependency for folder in search if (folder / dependency).is_file()), None)
            if candidate:
                shutil.copy2(candidate, bin_dir / dependency)
                runtime_files.append(dependency)
                pending.append(bin_dir / dependency)
            elif not (system / dependency).is_file():
                raise RuntimeError('Unresolved Windows runtime dependency: ' + dependency)
    icon = root / 'share/icons/clipboard.ico'
    icon.parent.mkdir(parents=True, exist_ok=True)
    png = (repo / 'App/Assets.xcassets/AppIcon.appiconset/icon_256x256.png').read_bytes()
    # Windows ICO permits a PNG payload. Preserve the existing icon pixels.
    icon.write_bytes(struct.pack('<HHHBBBBHHII', 0, 1, 1, 0, 0, 0, 0, 1, 32, len(png), 22) + png)
    archive = output / (name + '.zip')

# An explicit manifest makes the runtime closure and exact binary hashes reviewable.
manifest = {'applicationID': 'com.clipboard.desktop', 'version': version, 'platform': args.platform, 'architecture': arch,
            'runtimeFiles': sorted(runtime_files), 'files': {}}
for file in sorted(root.rglob('*')):
    if file.is_file():
        manifest['files'][str(file.relative_to(root)).replace('\\', '/')] = hashlib.sha256(file.read_bytes()).hexdigest()
(root / 'package-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
# Add the manifest after its own content hashes have been computed.
if args.platform == 'linux':
    with tarfile.open(archive, 'w:gz') as tar:
        tar.add(root, arcname=name)
else:
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as zip:
        for file in root.rglob('*'):
            if file.is_file():
                zip.write(file, name + '/' + str(file.relative_to(root)).replace('\\', '/'))
checksums = output / 'SHA256SUMS'
with checksums.open('a') as file:
    file.write(hashlib.sha256(archive.read_bytes()).hexdigest() + '  ' + archive.name + '\n')
print(json.dumps({'directory': str(root), 'archive': str(archive), 'version': version, 'architecture': arch}))
