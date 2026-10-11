from pathlib import Path
import subprocess, tempfile, shutil, json, hashlib, sys
src=Path(sys.argv[1]).resolve();bundle=Path(__file__).resolve().parent.parent;m=json.loads((bundle/'manifest.json').read_text())
with tempfile.TemporaryDirectory(prefix='xrechnung-install-test-') as d:
 root=Path(d)/'kivi';root.mkdir();shutil.copy2(src/'VERSION',root/'VERSION')
 for n,e in m['files'].items():
  if e['before'] is not None:
   p=root/n;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src/n,p)
 def run(*args,ok=True):
  r=subprocess.run(['python3',str(bundle/'install.py'),str(root),*args],text=True,capture_output=True)
  assert (r.returncode==0)==ok,(r.stdout,r.stderr)
  return r.stdout+r.stderr
 assert 'Pruefung OK' in run('--check')
 assert 'Installiert.' in run('--apply')
 assert 'Bereits vollstaendig' in run('--apply')
 backup=next((root/'.xrechnung-backups').iterdir())
 changed=root/'SL/Controller/ZUGFeRD.pm';good=changed.read_bytes();changed.write_bytes(good+b'\n# local edit\n')
 assert 'nachtraeglich' in run('--rollback',str(backup),ok=False)
 changed.write_bytes(good)
 assert 'wiederhergestellt' in run('--rollback',str(backup))
 assert 'Pruefung OK' in run('--check')
 changed.write_bytes(changed.read_bytes()+b'\n# pre-existing local edit\n')
 assert 'Abweichender' in run('--apply',ok=False)
 for n,e in m['files'].items():
  if n!='SL/Controller/ZUGFeRD.pm':
   assert (hashlib.sha256((root/n).read_bytes()).hexdigest() if (root/n).exists() else None)==e['before']
 print('7 installer scenarios passed; rollback and conflict rejection verified')
