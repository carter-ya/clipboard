#!/usr/bin/env python3
"""Create a new synthetic profile matching the approved visual reference.

Requires ImageMagick only to draw the public test image; no user clipboard,
existing profile, network or private file is read.
"""
import argparse
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root = args.output.resolve()
root.mkdir(parents=True, exist_ok=False)
image = root / 'palette.png'
command = ['convert', '-size', '1200x800', 'xc:#a9d4ed',
           '-fill', '#f2d1bb', '-draw', 'rectangle 400,0 799,799',
           '-fill', '#d5dfbc', '-draw', 'rectangle 800,0 1199,799',
           '-font', 'DejaVu-Sans', '-pointsize', '40', '-fill', '#203342']
for x, index, name, color in [(40, '01', 'Sky blue', '#A9D4ED'),
                              (440, '02', 'Apricot', '#F2D1BB'),
                              (840, '03', 'Sage', '#D5DFBC')]:
    for y, text in [(80, index), (420, name), (740, color)]:
        command += ['-draw', f'text {x},{y} "{text}"']
subprocess.run(command + [str(image)], check=True, timeout=15)
palette = image.read_bytes()
text = '下周产品评审安排\n\n周二 10:00\n确认桌面端交互方案\n\n周三 14:00\n整理测试反馈与问题优先级\n\n周五 16:00\n演示本周迭代成果'
rich = '<p>让内容占据主要空间</p><p>图片完整显示，文本保持清晰的段落。</p><p>常用操作靠近内容，低频操作适度收起。</p>'
fixtures = [
    ('image', '春日配色参考', '照片', 0, False, 'public.png', palette),
    ('text', '下周评审：确认界面方案，整理测试反馈', 'Teams', 3, True, 'public.utf8-plain-text', text.encode()),
    ('file', '界面参考.png、交互需求.docx', '资源管理器', 12, False, 'public.file-url', b'file:///synthetic/design.png\r\nfile:///synthetic/requirements.docx'),
    ('rtf', '让内容占据主要空间，减少常驻按钮', 'Word', 25, True, 'public.html', rich.encode()),
    ('mixed', '本周迭代要点与配图', '浏览器', 60, False, 'public.utf8-plain-text', '本周迭代要点\n\n搜索、预览、键盘导航与窗口缩放。'.encode()),
]
now = datetime.now(timezone.utc)
items = [dict(id=str(uuid.uuid4()), kind=kind, preview=title, sourceBundleID='linux:' + source,
              createdAt=(now - timedelta(minutes=minutes)).isoformat(timespec='seconds').replace('+00:00', 'Z'),
              pinned=pinned, sensitive=False, sizeBytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
              payloads=[dict(pasteboardType=payload_type, inlineData=base64.b64encode(data).decode())])
         for kind, title, source, minutes, pinned, payload_type, data in fixtures]
(root / 'history.json').write_text(json.dumps(dict(version=1, items=items)), encoding='utf-8')
(root / 'desktop-settings.json').write_text(json.dumps(dict(languageOverride='zh-Hans',
    recordingEnabled=False, shortcutEnabled=False, historyCapacity=100)), encoding='utf-8')
