#!/usr/bin/env python3
"""Exercise the real installer against local copies of the release assets."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
archive = root/'dist/Teum-1.0.5-macOS-universal.zip'
assert archive.is_file(), 'Build the release first'
with tempfile.TemporaryDirectory(prefix='teum-install-test-') as temporary:
    base = Path(temporary)
    assets = base/'assets'; assets.mkdir()
    (assets/archive.name).write_bytes(archive.read_bytes())
    checksum = assets/'SHA256SUMS.txt'
    checksum.write_bytes((root/'dist/SHA256SUMS.txt').read_bytes())
    tools = base/'tools'; tools.mkdir()
    curl = tools/'curl'
    curl.write_text('''#!/bin/bash
set -eu
output=''; url=''
while [ "$#" -gt 0 ]; do
 case "$1" in -o) output="$2"; shift 2;; --retry|--proto|--tlsv1.2) if [ "$1" = --tlsv1.2 ]; then shift; else shift 2; fi;; https://*) url="$1"; shift;; *) shift;; esac
done
cp "$TEUM_TEST_ASSETS/${url##*/}" "$output"
''')
    curl.chmod(0o755)
    appdir = base/"Apps with spaces 'test'"
    bindir = base/'bin'
    env = dict(os.environ, PATH=str(tools)+':'+os.environ['PATH'], TEUM_TEST_ASSETS=str(assets))
    command = ['bash', str(root/'install.sh'), '--app-dir', str(appdir), '--bin-dir', str(bindir), '--no-open']
    def install(ok=True):
        p = subprocess.run(command, env=env, capture_output=True, text=True)
        assert (p.returncode == 0) == ok, p.stdout+p.stderr
        return p
    install()
    binary = appdir/'Teum.app/Contents/MacOS/Teum'
    before = hashlib.sha256(binary.read_bytes()).hexdigest()
    p = subprocess.run([str(bindir/'teum-cli'),'--help'],capture_output=True,text=True)
    assert p.returncode == 0 and 'budget' in p.stdout, p.stderr
    install()
    assert list(appdir.glob('Teum.app.backup-*')), 'Previous app was not backed up'
    checksum.write_text('0'*64+'  '+archive.name+'\n')
    p = install(False)
    assert '다운로드 검증 실패' in p.stderr
    assert hashlib.sha256(binary.read_bytes()).hexdigest() == before
    (bindir/'teum-cli').write_text('#!/bin/bash\necho unrelated\n')
    p = install(False)
    assert '기존 teum-cli' in p.stderr
    assert 'unrelated' in (bindir/'teum-cli').read_text()
    assert hashlib.sha256(binary.read_bytes()).hexdigest() == before
print('Installer: install, quoted paths, CLI, upgrade backup, checksum rejection and existing CLI preservation passed')
