#!/usr/bin/env python3
"""Public synthetic image records, recording and shortcuts disabled."""
from pathlib import Path
import base64, hashlib, json, struct, uuid, zlib

import argparse
parser = argparse.ArgumentParser(description='Create synthetic preview/performance fixtures; never use a normal profile.')
parser.add_argument('--output', required=True, type=Path)
root = parser.parse_args().output
root.mkdir(exist_ok=False)
def chunk(kind, body):
    return struct.pack('>I',len(body))+kind+body+struct.pack('>I',zlib.crc32(kind+body))
w,h=640,360
pixels=b''.join(b'\0'+b''.join(bytes((220 if x<w//2 else 20, 60 if y<h//2 else 200, 50)) for x in range(w)) for y in range(h))
png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(pixels))+chunk(b'IEND',b'')
def bmp(size,bpp,alpha):
    compression=3 if size>=108 else 0
    stride=((w*bpp+31)//32)*4
    header=bytearray(struct.pack('<IiiHHIIiiII',size,w,h,1,bpp,compression,stride*h,0,0,0,0)+bytes(size-40))
    if size>=108:
        struct.pack_into('<IIIII',header,40,0xff0000,0xff00,0xff,0xff000000,0x73524742)
    raw=b''.join(b''.join(bytes((50,60 if y<h//2 else 200,220 if x<w//2 else 20))+(bytes([alpha]) if bpp==32 else b'') for x in range(w))+bytes(stride-w*bpp//8) for y in range(h))
    return b'BM'+struct.pack('<IHHI',14+size+len(raw),0,0,14+size)+header+raw
fixtures=[('PNG','public.png',png),('BMP24','com.microsoft.bmp',bmp(40,24,0)),('BMP32','com.microsoft.bmp',bmp(40,32,0)),('BMPV5','com.microsoft.bmp',bmp(124,32,255)),('BMPV5zero','com.microsoft.bmp',bmp(124,32,0))]
items=[]
for i in range(100):
    if i<len(fixtures):name,kind,data=fixtures[i]; preview='Fixture '+name; item_kind='image'
    else:preview='Synthetic note %03d - local interface responsiveness'%i;data=preview.encode();kind='public.utf8-plain-text';item_kind='text'
    items.append(dict(id=str(uuid.uuid4()),createdAt='2026-01-01T00:00:00Z',kind=item_kind,preview=preview,sha256=hashlib.sha256(data).hexdigest(),sizeBytes=len(data),pinned=i%10==0,sensitive=False,payloads=[dict(pasteboardType=kind,inlineData=base64.b64encode(data).decode())]))
(root/'history.json').write_text(json.dumps(dict(version=1,items=items)))
(root/'desktop-settings.json').write_text(json.dumps(dict(languageOverride='en',recordingEnabled=False,shortcutEnabled=False,historyCapacity=100)))

