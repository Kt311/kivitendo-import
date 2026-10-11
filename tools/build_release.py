"""Build the installable release using an explicit source-file allowlist."""
import hashlib
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]

def build():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    names = ['README.md', 'CHANGELOG.md', 'COPYING', 'install.py',
             'manifest.json', 'kivitendo-4.1.0-xrechnung.patch']
    for name, entry in manifest['files'].items():
        path = ROOT / 'files' / name
        if hashlib.sha256(path.read_bytes()).hexdigest() != entry['after']:
            raise ValueError('Manifest hash mismatch: ' + name)
        names.append('files/' + name)
    names += [str(p.relative_to(ROOT)) for p in (ROOT / 'tests').glob('*.py')]
    names += [str(p.relative_to(ROOT)) for p in (ROOT / 'tests').glob('*.t')]
    names += ['tools/build_release.py', '.github/workflows/tests.yml', '.gitignore']
    out = ROOT / 'dist' / ('kivitendo-import-' + manifest['version'] + '.zip')
    out.parent.mkdir(exist_ok=True)
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as archive:
        for name in sorted(names):
            archive.write(ROOT / name, 'kivitendo-import/' + name)
    print(out)
    return out

if __name__ == '__main__':
    build()
