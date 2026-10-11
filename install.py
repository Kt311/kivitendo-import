#!/usr/bin/env python3
"""Checked, idempotent installation of the accompanying 4.1.0 patch payload."""
import argparse, datetime, hashlib, json, os, shutil, sys, tempfile, uuid
from pathlib import Path
BUNDLE=Path(__file__).resolve().parent

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None

def target(root,name):
    p=root/name
    if p.is_symlink() or not p.resolve().is_relative_to(root):
        raise RuntimeError('Unsicherer Dateipfad: '+name)
    if p.exists() and not p.is_file():
        raise RuntimeError('Keine regulaere Datei: '+name)
    return p

def write_file(src,dst):
    dst.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix='.xrechnung-',dir=dst.parent)
    os.close(fd)
    try:
        shutil.copyfile(src,tmp)
        if dst.exists():
            st=dst.stat()
            shutil.copystat(dst,tmp)
            if (os.stat(tmp).st_uid,os.stat(tmp).st_gid)!=(st.st_uid,st.st_gid):
                os.chown(tmp,st.st_uid,st.st_gid)
        else:
            os.chmod(tmp,0o644)
            st=dst.parent.stat()
            if (os.stat(tmp).st_uid,os.stat(tmp).st_gid)!=(st.st_uid,st.st_gid):
                os.chown(tmp,st.st_uid,st.st_gid)
        # New content must invalidate compiled templates and FastCGI file caches.
        os.utime(tmp, None)
        os.replace(tmp,dst)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

def main():
    parser=argparse.ArgumentParser(description='Prueft standardmaessig nur. --apply installiert; --rollback stellt die angegebenen Sicherungsdateien wieder her.')
    parser.add_argument('root',type=Path)
    group=parser.add_mutually_exclusive_group()
    group.add_argument('--check',action='store_true')
    group.add_argument('--apply',action='store_true')
    group.add_argument('--rollback',type=Path)
    args=parser.parse_args();root=args.root.resolve()
    manifest=json.loads((BUNDLE/'manifest.json').read_text())
    if (root/'VERSION').read_text().strip()!='4.1.0':
        raise RuntimeError('Nur fuer kivitendo 4.1.0.')
    entries=manifest['files']
    if args.rollback:
        backup=args.rollback.resolve()
        if not backup.is_relative_to(root/'.xrechnung-backups'):
            raise RuntimeError('Sicherung muss im .xrechnung-backups-Ordner dieser Installation liegen.')
        saved=json.loads((backup/'manifest.json').read_text())
        restore_hashes=saved.pop('restore_hashes',{})
        if saved!=manifest:
            raise RuntimeError('Sicherung gehoert zu einem anderen Patchstand.')
        for name,e in entries.items():
            p=target(root,name)
            if digest(p)!=e['after']:
                raise RuntimeError('Ruecknahme abgebrochen: nachtraeglich geaenderte Datei '+name)
            if restore_hashes.get(name,e['before']) is not None and digest(backup/name)!=restore_hashes.get(name,e['before']):
                raise RuntimeError('Unvollstaendige Sicherung: '+name)
        for name,e in entries.items():
            p=target(root,name)
            if restore_hashes.get(name,e['before']) is None: p.unlink()
            else: write_file(backup/name,p)
        print('Quelldateien wiederhergestellt. Datenbank-Zuordnungen bleiben erhalten.')
        return
    for name,e in entries.items():
        if digest(BUNDLE/'files'/name)!=e['after']:
            raise RuntimeError('Beschaedigtes Patchpaket: '+name)
    states={name:digest(target(root,name)) for name in entries}
    if all(states[n]==e['after'] for n,e in entries.items()):
        print('Bereits vollstaendig installiert. Keine Aenderung.');return
    known_upgrade=any(states==hashes for hashes in manifest.get('compatible_versions',{}).values())
    mismatches=[] if known_upgrade else [n for n,e in entries.items() if states[n]!=e['before']]
    if mismatches:
        raise RuntimeError('Abweichender/teilweise gepatchter Quellstand; nichts geaendert:\n'+'\n'.join(mismatches))
    if not args.apply:
        print('Pruefung OK: passender 4.1.0-Quellstand oder bekannter vorheriger Patch. Noch nichts installiert.');return
    backup=root/'.xrechnung-backups'/(datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+uuid.uuid4().hex[:8])
    backup.mkdir(parents=True)
    for name,e in entries.items():
        if states[name] is not None:
            dst=backup/name;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(root/name,dst)
    (backup/'manifest.json').write_text(json.dumps(dict(manifest,restore_hashes=states),indent=2)+'\n')
    changed=[]
    try:
        for name,e in entries.items():
            write_file(BUNDLE/'files'/name,root/name);changed.append(name)
        for name,e in entries.items():
            if digest(root/name)!=e['after']: raise RuntimeError('Hashpruefung nach Installation fehlgeschlagen: '+name)
    except Exception:
        for name in reversed(changed):
            if states[name] is None: (root/name).unlink(missing_ok=True)
            else: write_file(backup/name,root/name)
        raise
    print('Installiert. Sicherung: '+str(backup))
    print('Anwendungsprozesse neu starten; Testmandant pruefen. Keine Datenbankmigration ausgefuehrt.')

if __name__=='__main__':
    try: main()
    except (OSError,ValueError,RuntimeError) as e:
        print('ABBRUCH: '+str(e),file=sys.stderr);sys.exit(1)
