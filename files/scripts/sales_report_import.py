#!/usr/bin/env python3
"""Local, strict vending sales report reader. Never posts accounting records."""
import csv
import calendar
import hashlib
import io
import json
import re
import subprocess
import sys
from collections import defaultdict
from datetime import datetime
from decimal import Decimal, InvalidOperation
from pathlib import Path

def number(value):
    value = str(value).strip().replace('€', '').replace(' ', '')
    if ',' in value:
        value = value.replace('.', '').replace(',', '.')
    if not re.fullmatch(r'\d+(?:\.\d+)?', value):
        raise ValueError('Ungueltige Zahl: ' + value[:60])
    result = Decimal(value)
    if not result.is_finite() or result > 100000000:
        raise ValueError('Zahl ausserhalb des erlaubten Bereichs.')
    return result

def rate(value):
    value = str(value).strip()
    result = number(value.replace('%', ''))
    if '%' not in value and result in (Decimal('.07'), Decimal('.19')):
        result *= 100
    if result not in (0, 7, 19):
        raise ValueError('Nicht unterstuetzter Steuersatz: ' + value)
    return int(result)

def payment(value):
    value = value.strip()
    if value in ('PaymentTypeEnum.CASH', 'CASH', 'Bar'):
        return 'CASH'
    if value in ('PaymentTypeEnum.CASHLESS', 'CASHLESS', 'Bargeldlos'):
        return 'CASHLESS'
    raise ValueError('Unbekannte Zahlungsart: ' + value[:80])

def item(year, month, product, pay, tax, qty, total):
    year, month = str(year or '').strip(), str(month or '').strip()
    if not year:
        raise ValueError('Jahr fehlt. Bitte im Importformular das Jahr vierstellig eingeben (z. B. 2026) und die Datei erneut auswaehlen.')
    if not re.fullmatch(r'\d{4}', year) or not 2000 <= int(year) <= 2100:
        raise ValueError('Jahr ungueltig. Erwartet wird eine vierstellige Jahreszahl von 2000 bis 2100.')
    if not month:
        raise ValueError('Monat fehlt in der Datei. Bitte die Spalte Monat mit einer Zahl von 1 bis 12 fuellen.')
    if not re.fullmatch(r'\d{1,2}', month) or not 1 <= int(month) <= 12:
        raise ValueError('Monat ungueltig. Erwartet wird eine Zahl von 1 bis 12 in der Datei.')
    year, month = int(year), int(month)
    product = product.strip()
    if not product or len(product) > 500 or any(ord(c) < 32 for c in product):
        raise ValueError('Artikelbezeichnung fehlt oder ist ungueltig.')
    qty, total = number(qty), number(total)
    if qty <= 0 or qty != qty.to_integral() or total != total.quantize(Decimal('.01')):
        raise ValueError('Erwartet werden positive ganze Stueckzahlen und centgenaue Umsaetze.')
    return dict(year=year, month=month, product=product, payment=payment(pay),
                tax_rate=rate(tax), quantity=qty, total=total)

def csv_rows(text, year):
    lines = text.lstrip('\ufeff').splitlines()
    # Reports may start with an export timestamp and emoji headers.
    start = next((i for i,l in enumerate(lines) if ';' in l and
                  (('Produkt' in l and 'Verkäufe' in l) or ('Zeitpunkt' in l and 'Rechnungsnummer' in l))), None)
    if start is None:
        raise ValueError('CSV-Kopfzeile fehlt. Erwartet: Produkt, Zahlungsart, Steuersatz, Verkaeufe und Summe €.')
    reader = csv.DictReader(lines[start:], delimiter=';')
    reader.fieldnames = [re.sub(r'^[^A-Za-zÄÖÜäöüß]+', '', s).strip() for s in reader.fieldnames]
    result, warnings, seen = [], [], set()
    full = 'Zeitpunkt' in reader.fieldnames
    for line,r in enumerate(reader, start+2):
        if not any(r.values()):
            continue
        if None in r or any(v is None for v in r.values()):
            raise ValueError(f'CSV-Zeile {line}: falsche Spaltenzahl.')
        try:
            if not full:
                result.append(item((r.get('Jahr') or '').strip() or year, r['Monat'], r['Produkt'],
                                   r['Zahlungsart'], r['Steuersatz'], r['Verkäufe'], r['Summe €']))
                continue
            if 'abgebrochen' in r['Zahlungsarten'].lower() and r['Preis'].strip() == '-':
                warnings.append(f"Abgebrochener Verkauf ausgelassen: {r['Rechnungsnummer']}")
                continue
            if r['Status'].lower() != 'abgeschlossen':
                raise ValueError('Nicht abgeschlossener Verkauf.')
            stamp = datetime.strptime(r['Zeitpunkt'], '%d.%m.%Y %H:%M')
            key = (r.get('Maschine',''), r['Rechnungsnummer'])
            if key in seen:
                raise ValueError('Mehrfach vorkommende Rechnungsnummer zuerst klaeren: ' + key[1])
            seen.add(key)
            match = re.fullmatch(r'(.+?)\s*\((\d+)x\)', r['Artikel'])
            if not match:
                raise ValueError('Artikelmenge nicht eindeutig.')
            pays = re.findall(r'(Bar|GIROCARD|VISA|MASTERCARD|MAESTRO|VPAY|V PAY|AMEX|AMERICAN_EXPRESS)\s*\(',r['Zahlungsarten'],re.I)
            if len(pays) != 1:
                raise ValueError('Gemischte oder unbekannte Zahlungsart.')
            row=item(stamp.year,stamp.month,match[1],'Bar' if pays[0].lower()=='bar' else 'Bargeldlos',
                     r['Steuersatz'],match[2],r['Preis'])
            row['machine']=r.get('Maschine','').strip()
            result.append(row)
        except (ValueError, KeyError, TypeError) as e:
            raise ValueError(f'CSV-Zeile {line}: {e}') from e
    machines={r.get('machine') for r in result if r.get('machine')}
    if len(machines)>1:
        raise ValueError('Bitte pro Standort eine Datei hochladen.')
    return result,warnings

def pdf_rows(path, year):
    info=subprocess.run(['pdfinfo',str(path)],capture_output=True,text=True,timeout=30,check=True).stdout
    pages=re.search(r'^Pages:\s+(\d+)',info,re.M)
    if not pages or int(pages[1])>30:
        raise ValueError('PDF: maximal 30 Seiten.')
    text=subprocess.run(['pdftotext','-layout',str(path),'-'],capture_output=True,text=True,timeout=45,check=True).stdout
    if len(text)>1000000:
        raise ValueError('PDF-Text ist zu gross.')
    rows=[]
    # Compact reports generated from this workflow have a period/payment heading.
    months=['Januar','Februar','März','April','Mai','Juni','Juli','August','September','Oktober','November','Dezember']
    period=re.search(r'Verkaufsbericht\s+('+'|'.join(months)+r')\s+(20\d{2})',text)
    pay=re.search(r'Zahlungsart:.*?PaymentTypeEnum\.(CASHLESS|CASH)',text)
    for line in text.splitlines():
        line=line.strip()
        if not line or line.startswith(('Column1','Jahr','Monat','Produkt','Verkaufsbericht','Zahlungsart:','Quelle:','Verkaufsübersicht','Gesamt')):
            continue
        if 'PaymentTypeEnum.' in line:
            m=re.fullmatch(r'(?:(20\d{2})\s+)?(\d{1,2})\s+(.+?)\s+PaymentTypeEnum\.(CASHLESS|CASH)\s+(\d+(?:[.,]\d+)?\s*%?)\s+([\d.,]+)\s+([\d.,]+)',line)
            if not m:
                raise ValueError('PDF-Zeile nicht eindeutig lesbar: '+line[:100])
            y,mo,name,p,t,q,a=m.groups()
            rows.append(item(y or year,mo,name,p,t,q,a))
        elif period and pay:
            m=re.fullmatch(r'(.+?)\s+(\d+)\s*%\s+([\d.,]+)\s+([\d.,]+)',line)
            if m:
                name,t,q,a=m.groups(); rows.append(item(period[2],months.index(period[1])+1,name,pay[1],t+'%',q,a))
            else:
                raise ValueError('PDF-Zeile nicht eindeutig lesbar: '+line[:100])
        else:
            raise ValueError('PDF-Layout nicht unterstuetzt. Alle Spalten zusammen exportieren oder Original-CSV verwenden.')
    return rows,[]

def analyze(path, year=''):
    path=Path(path)
    if path.stat().st_size>50*1024*1024:
        raise ValueError('Datei groesser als 50 MiB.')
    raw=path.read_bytes()
    rows,warnings=pdf_rows(path,year) if raw.startswith(b'%PDF') else csv_rows(raw.decode('utf-8-sig'),year)
    if not rows or len(rows)>50000:
        raise ValueError('Keine Positionen oder mehr als 50000 Zeilen.')
    groups={}
    for r in rows:
        key=(r['year'],r['month'],r['payment'])
        group=groups.setdefault(key,{})
        rowkey=(r['product'],r['tax_rate'])
        value=group.setdefault(rowkey,[Decimal(0),Decimal(0)])
        value[0]+=r['quantity'];value[1]+=r['total']
    output=[]
    for (y,m,p),data in sorted(groups.items()):
        items=[dict(description=n,tax_rate=t,quantity=str(int(q)),total=str(a.quantize(Decimal('.01')))) for (n,t),(q,a) in sorted(data.items())]
        if len(items)>500: raise ValueError('Mehr als 500 Artikel pro Monatsrechnung.')
        group=dict(year=y,month=m,payment=p,items=items,total=str(sum((v[1] for v in data.values()),Decimal(0)).quantize(Decimal('.01'))),quantity=str(int(sum(v[0] for v in data.values()))),
                   start_date=f'{y}-{m:02}-01',end_date=f'{y}-{m:02}-{calendar.monthrange(y,m)[1]}')
        group['content_hash']=hashlib.sha256(json.dumps(group,sort_keys=True,ensure_ascii=False).encode()).hexdigest()
        output.append(group)
    return dict(groups=output,warnings=warnings,sha256=hashlib.sha256(raw).hexdigest())

if __name__=='__main__':
    try:
        print(json.dumps(analyze(sys.argv[1],sys.argv[2] if len(sys.argv)>2 else ''),ensure_ascii=False))
    except Exception as e:
        print(json.dumps({'error':str(e)},ensure_ascii=False));sys.exit(1)
