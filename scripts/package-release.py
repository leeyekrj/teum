#!/usr/bin/env python3
"""Build a universal, data-free GitHub release. Does not install the app."""
import argparse
import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def run(*args):
    subprocess.run([str(x) for x in args], cwd=ROOT, check=True)

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--version', default='1.0.5')
    p.add_argument('--test-x86_64', action='store_true')
    args = p.parse_args()
    import re
    if not re.fullmatch(r'\d+\.\d+\.\d+', args.version): p.error('Use a semantic version')
    binaries = []
    for arch in ['arm64', 'x86_64']:
        scratch = ROOT/f'.build-{arch}'
        run('swift','build','--scratch-path',scratch,'--triple',f'{arch}-apple-macosx14.0',
            '-c','release','-j','4','-Xswiftc','-file-prefix-map','-Xswiftc',f'{Path.home()}=~')
        binaries.append(scratch/f'{arch}-apple-macosx/release/Teum')
    build = ROOT/'build'; build.mkdir(exist_ok=True)
    if not (build/'Teum.icns').exists():
        run('swift',ROOT/'scripts/icon.swift',build/'Teum.iconset')
        run('iconutil','-c','icns',build/'Teum.iconset','-o',build/'Teum.icns')
    out = ROOT/'dist'; out.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='teum-release-') as temporary:
        app = Path(temporary)/'Teum.app'; contents = app/'Contents'
        resources = contents/'Resources'; resources.mkdir(parents=True)
        (contents/'MacOS').mkdir()
        run('lipo','-create',*binaries,'-output',contents/'MacOS/Teum')
        run('strip','-S',contents/'MacOS/Teum')
        strings = subprocess.check_output(['strings',str(contents/'MacOS/Teum')])
        if (str(Path.home())+'/').encode() in strings:
            raise SystemExit('Release binary contains the developer home path; refusing to package')
        run('lipo',contents/'MacOS/Teum','-verify_arch','arm64','x86_64')
        shutil.copy2(build/'Teum.icns',resources/'Teum.icns')
        shutil.copy2(ROOT/'Vendor/LICENSE-QuotaBar',resources/'LICENSE-QuotaBar')
        shutil.copy2(ROOT/'LICENSE',resources/'LICENSE')
        shutil.copy2(ROOT/'THIRD_PARTY_NOTICES.md',resources/'THIRD_PARTY_NOTICES.md')
        shutil.copytree(ROOT/'licenses',resources/'licenses')
        shutil.copytree(ROOT/'Sources/Teum/Resources/logos',resources/'logos')
        (resources/'cli').mkdir()
        shutil.copy2(ROOT/'cli/teum_cli.py',resources/'cli/teum_cli.py')
        info = dict(CFBundleIdentifier='io.paul.teum',CFBundleName='Teum',CFBundleDisplayName='틈',
            CFBundleExecutable='Teum',CFBundleIconFile='Teum.icns',CFBundlePackageType='APPL',
            CFBundleShortVersionString=args.version,CFBundleVersion=args.version,
            LSMinimumSystemVersion='14.0',LSUIElement=True,NSHighResolutionCapable=True,
            NSPrincipalClass='NSApplication')
        (contents/'Info.plist').write_bytes(plistlib.dumps(info))
        for file_path in sorted(app.rglob('*')):
            if file_path.is_file() and str(Path.home()).encode('utf-8') in file_path.read_bytes():
                raise SystemExit(f'Release bundle file {file_path.relative_to(app)} contains the developer home path; refusing to package')
        run('codesign','--force','--sign','-',app)
        run('codesign','--verify','--strict',app)
        # Self-test only: no live collection, login, settings or history access.
        run(contents/'MacOS/Teum','--self-test')
        if args.test_x86_64:
            run('/usr/bin/arch','-x86_64',contents/'MacOS/Teum','--self-test')
        archive = out/f'Teum-{args.version}-macOS-universal.zip'
        if archive.exists(): archive.unlink()
        # Generated app files only: omit Finder/resource-fork metadata.
        run('ditto','-c','-k','--norsrc','--noextattr','--keepParent',app,archive)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        (out/'SHA256SUMS.txt').write_text(f'{digest}  {archive.name}\n')
        print(archive)

if __name__ == '__main__': main()
