#!/usr/bin/env python3
"""Run actual Mac App analysis sources against built Core; no desktop or network."""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
p.add_argument('--baseline')
args = p.parse_args()
if sys.platform != 'darwin':
    raise SystemExit('This actual App regression requires macOS')
binary = Path(subprocess.check_output(['swift','build','--package-path',str(ROOT/'Core'),'--show-bin-path'],text=True).strip()).resolve()
archive = binary/'libClipboardCore.a'
if archive.exists():
    libraries = [str(archive)]
else:
    libraries = [str(obj) for name in ['ClipboardCore','ZIPFoundation','KeyboardShortcuts','CDesktopModelFiles']
                 for obj in sorted((binary/(name+'.build')).glob('*.o'))]
    if not libraries: raise RuntimeError('Run Core build/tests before the actual Mac analysis regression')
module_maps = [binary/'CDesktopModelFiles.build/module.modulemap',
               ROOT/'Core/.build/out/Intermediates.noindex/GeneratedModuleMaps/CDesktopModelFiles.modulemap']
module_map = next((path for path in module_maps if path.is_file()),None)
if module_map is None: raise RuntimeError('Actual built Core C module map is required')
with tempfile.TemporaryDirectory(prefix='clipboard-mac-sensitive-analysis-') as temporary:
    folder = Path(temporary)
    sources = []
    for name in ['Summarizer.swift','RemoteOpenAISummarizer.swift','SummaryCoordinator.swift','SummaryProgress.swift','AICapability.swift']:
        path = ROOT/'App'/name
        if args.baseline:
            old = folder/name
            old.write_text(subprocess.check_output(['git','-C',str(ROOT),'show',args.baseline+':App/'+name],text=True),encoding='utf-8')
            path = old
        sources.append(str(path))
    executable = folder/'probe'
    command = ['swiftc','-swift-version','5','-parse-as-library',
               '-I',str(binary/'Modules'),'-I',str(binary),
               '-Xcc','-fmodule-map-file='+str(module_map),'-I',str(ROOT/'Core/Sources/CDesktopModelFiles/include'),
               '-module-cache-path',str(folder/'modules')]
    if args.baseline: command += ['-D','LIFECYCLE_ONLY']
    command += sources+[str(ROOT/'tools/desktop-ui/mac-sensitive-analysis-probe.swift')]+libraries+['-lz','-o',str(executable)]
    subprocess.run(command,check=True,timeout=90)
    for mode in [[], ['--manual']]:
        profile = folder / ('private-manual' if mode else 'private-automatic')
        try: subprocess.run([str(executable),str(profile)]+mode,check=True,timeout=15)
        except subprocess.TimeoutExpired:
            raise SystemExit('FAIL actual Mac analysis did not complete owned cancellation within the fixture deadline')
