#!/usr/bin/env python3
"""Extract the checksum-verified GTK source without Windows tar or child decompressors."""
from pathlib import Path, PurePosixPath
import argparse
import shutil
import tarfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('archive', type=Path)
parser.add_argument('destination', type=Path)
parser.add_argument('--skip-pixbuf-test-images', action='store_true')
args = parser.parse_args()
archive, destination = args.archive, args.destination
started = time.monotonic()
count = total = 0
with tarfile.open(archive, 'r:xz') as source:
    for member in source:
        count += 1
        total += member.size
        parts = PurePosixPath(member.name)
        if (count > 10000 or total > 200 * 1024 * 1024 or time.monotonic() - started > 180 or
                parts.is_absolute() or '..' in parts.parts or '\\' in member.name or ':' in member.name):
            raise RuntimeError('GTK source archive structure exceeds the pinned source bounds')
        # The fixed Pixbuf archive contains symlinked reference images. Tests
        # are disabled in this runtime build; omit this exact fixture subtree
        # instead of creating links or relaxing extraction for source files.
        if args.skip_pixbuf_test_images and parts.parts[:3] == ('gdk-pixbuf-2.44.7', 'tests', 'test-images'):
            continue
        if not (member.isfile() or member.isdir()):
            raise RuntimeError('GTK source archive contains a non-regular entry')
        target = destination.joinpath(*parts.parts)
        if member.isdir():
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            with source.extractfile(member) as reader, target.open('wb') as writer:
                shutil.copyfileobj(reader, writer)
        if count % 1000 == 0:
            print('Extracted source entries: ' + str(count), flush=True)
print('Extracted GTK source entries: ' + str(count), flush=True)
