#!/usr/bin/env python3
"""Extract the checksum-verified GTK source without Windows tar or child decompressors."""
from pathlib import Path, PurePosixPath
import shutil
import sys
import tarfile
import time

archive, destination = map(Path, sys.argv[1:])
started = time.monotonic()
count = total = 0
with tarfile.open(archive, 'r:xz') as source:
    for member in source:
        count += 1
        total += member.size
        parts = PurePosixPath(member.name)
        if (count > 10000 or total > 200 * 1024 * 1024 or time.monotonic() - started > 180 or
                parts.is_absolute() or '..' in parts.parts or '\\' in member.name or ':' in member.name or
                not (member.isfile() or member.isdir())):
            raise RuntimeError('GTK source archive structure exceeds the pinned source bounds')
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
