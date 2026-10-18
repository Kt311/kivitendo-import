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
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
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
    result, warnings, seen = [], [], {}
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
            # Receipt numbers are not unique line IDs. Preserve conflicting
            # rows for review rather than guessing whether either is a duplicate.
            fingerprint = hashlib.sha256(json.dumps(r,sort_keys=True,ensure_ascii=False).encode()).hexdigest()
            if fingerprint in seen:
                raise ValueError('Identische doppelte Exportzeile zuerst klaeren: ' + key[1])
            seen[fingerprint] = True
            match = re.fullmatch(r'(.+?)\s*\((\d+)x\)', r['Artikel'])
            if not match:
                raise ValueError('Artikelmenge nicht eindeutig.')
            pays = re.findall(r'(Bar|GIROCARD|VISA|MASTERCARD|MAESTRO|VPAY|V PAY|AMEX|AMERICAN_EXPRESS)\s*\(',r['Zahlungsarten'],re.I)
            if len(pays) != 1:
                raise ValueError('Gemischte oder unbekannte Zahlungsart.')
            row=item(stamp.year,stamp.month,match[1],'Bar' if pays[0].lower()=='bar' else 'Bargeldlos',
                     r['Steuersatz'],match[2],r['Preis'])
            amounts = re.findall(r'\(([^(),]+(?:,[0-9]{2})?)\s*€\)', r['Zahlungsarten'])
            if len(amounts) != 1 or number(amounts[0]) != row['total']:
                raise ValueError('Verkaufspreis und Zahlungsbetrag stimmen nicht eindeutig ueberein.')
            row.update(machine=r.get('Maschine','').strip(),
                       observed_at=stamp.isoformat(timespec='minutes'),
                       receipt=r['Rechnungsnummer'].strip(), selection=r.get('Auswahlnummer','').strip(),
                       event_id=fingerprint, source_line=line)
            row['review_issues'] = []
            if row['total'] / row['quantity'] < Decimal('0.20'):
                row['review_issues'].append('Ungewoehnlich kleiner Stueckpreis unter 0,20 EUR')
            result.append(row)
        except (ValueError, KeyError, TypeError) as e:
            raise ValueError(f'CSV-Zeile {line}: {e}') from e
    by_receipt=defaultdict(list)
    for r in result:
        if r.get('receipt'):
            by_receipt[(r['machine'],r['receipt'])].append(r)
    for key, matches in by_receipt.items():
        if len(matches)>1:
            for r in matches:
                r['review_issues'].append('Rechnungsnummer bei mehreren unterschiedlichen Zeilen: '+key[1])
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
        group=groups.setdefault(key,{'items':{},'events':[],'issues':[]})
        unit=(r['total']/r['quantity']).quantize(Decimal('.00001'),rounding=ROUND_HALF_UP)
        if (unit*r['quantity']).quantize(Decimal('.01'),rounding=ROUND_HALF_UP) != r['total']:
            raise ValueError('Exportpreis kann mit fuenf Nachkommastellen nicht centgenau abgebildet werden.')
        rowkey=(r['product'],r['tax_rate'],unit)
        value=group['items'].setdefault(rowkey,[Decimal(0),Decimal(0),[],set()])
        value[0]+=r['quantity'];value[1]+=r['total']
        if r.get('observed_at'): value[2].append(r['observed_at'])
        if r.get('selection') and r['selection'] != '-':value[3].add(r['selection'])
        if r.get('event_id'):
            event={k:r[k] for k in ('event_id','observed_at','receipt','selection','machine','product','tax_rate')}
            event.update(quantity=str(r['quantity']),total=str(r['total']),unit_gross=str(unit),
                         review_issues=r['review_issues'])
            group['events'].append(event)
            for issue in r['review_issues']:
                group['issues'].append(dict(event_id=r['event_id'],receipt=r['receipt'],
                    observed_at=r['observed_at'],product=r['product'],total=str(r['total']),message=issue))
    output=[]
    for (y,m,p),data in sorted(groups.items()):
        items=[dict(description=n,tax_rate=t,unit_gross=str(price),quantity=str(int(v[0])),
                    total=str(v[1].quantize(Decimal('.01'))),
                    first_observed=min(v[2]) if v[2] else '',last_observed=max(v[2]) if v[2] else '',
                    selections=sorted(v[3]))
               for (n,t,price),v in sorted(data['items'].items())]
        # Check rounding again after consolidation, since rounded unit averages
        # from summary exports must never drift from their original revenue.
        for i in items:
            if (Decimal(i['unit_gross'])*Decimal(i['quantity'])).quantize(Decimal('.01'),rounding=ROUND_HALF_UP) != Decimal(i['total']):
                raise ValueError('Zusammenfassung wuerde den Originalumsatz veraendern. Detaillierten Export verwenden.')
        if len(items)>500: raise ValueError('Mehr als 500 Artikel-/Preispositionen pro Monatsrechnung.')
        group=dict(schema_version=2,year=y,month=m,payment=p,items=items,
                   events=sorted(data['events'],key=lambda e:(e['observed_at'],e['event_id'])),
                   review_issues=sorted(data['issues'],key=lambda e:(e['observed_at'],e['event_id'],e['message'])),
                   source_kind='transactions' if data['events'] else 'summary',
                   total=str(sum((v[1] for v in data['items'].values()),Decimal(0)).quantize(Decimal('.01'))),
                   quantity=str(int(sum(v[0] for v in data['items'].values()))),
                   start_date=f'{y}-{m:02}-01',end_date=f'{y}-{m:02}-{calendar.monthrange(y,m)[1]}')
        group['content_hash']=hashlib.sha256(json.dumps(group,sort_keys=True,ensure_ascii=False).encode()).hexdigest()
        output.append(group)
    return dict(groups=output,warnings=warnings,sha256=hashlib.sha256(raw).hexdigest())

def portfolio(reports):
    products={}
    price_observations={}
    timelines=defaultdict(list)
    slots=defaultdict(list)
    issues=[]
    seen=set()
    legacy_reports=0
    for report in reports:
        source=report['source'];g=report['data']
        if g.get('schema_version') != 2:
            legacy_reports+=1
            continue
        for i in g['items']:
            key=(source,i['description'])
            p=products.setdefault(key,dict(source=source,product=i['description'],quantity=0,
                revenue=Decimal(0),prices=set(),first_observed='',last_observed=''))
            p['quantity']+=int(i['quantity']);p['revenue']+=Decimal(i['total'])
            p['prices'].add(Decimal(i['unit_gross']))
            dates=[x for x in (p['first_observed'],p['last_observed'],i.get('first_observed'),i.get('last_observed')) if x]
            if dates:p['first_observed'],p['last_observed']=min(dates),max(dates)
        for issue in g.get('review_issues',[]):issues.append(dict(source=source,**issue))
        for e in g.get('events',[]):
            key=(source,e['event_id'])
            if key in seen:raise ValueError('Verkaufsereignis in mehreren gespeicherten Berichten. Quellen pruefen.')
            seen.add(key)
            key=(source,e['machine'],e['selection'],e['product'],e['unit_gross'])
            p=price_observations.setdefault(key,dict(source=source,machine=e['machine'],selection=e['selection'],
                product=e['product'],unit_gross=e['unit_gross'],quantity=0,revenue=Decimal(0),
                first_observed=e['observed_at'],last_observed=e['observed_at'],review=False))
            p['quantity']+=int(e['quantity']);p['revenue']+=Decimal(e['total'])
            p['first_observed']=min(p['first_observed'],e['observed_at'])
            p['last_observed']=max(p['last_observed'],e['observed_at'])
            p['review']=p['review'] or bool(e.get('review_issues'))
            if not e.get('review_issues'):
                timelines[(source,e['machine'],e['selection'],e['product'])].append(e)
                if e['selection'] and e['selection'] != '-':slots[(source,e['machine'],e['selection'])].append(e)
    price_changes=[]
    for (source,machine,selection,product),events in sorted(timelines.items()):
        # Unknown slots may conceal simultaneously different prices at different
        # selections. Show observations but infer no change from those rows.
        if not selection or selection=='-':continue
        previous=None
        for e in sorted(events,key=lambda x:(x['observed_at'],x['event_id'])):
            if previous and previous['unit_gross'] != e['unit_gross'] and previous['observed_at'] != e['observed_at']:
                price_changes.append(dict(source=source,machine=machine,selection=selection,product=product,
                    previous_price=previous['unit_gross'],observed_price=e['unit_gross'],
                    last_previous=previous['observed_at'],first_observed=e['observed_at']))
            previous=e
    product_changes=[]
    for (source,machine,selection),events in sorted(slots.items()):
        previous=None
        for e in sorted(events,key=lambda x:(x['observed_at'],x['event_id'])):
            if previous and previous['product']!=e['product'] and previous['observed_at'] != e['observed_at']:
                product_changes.append(dict(source=source,machine=machine,selection=selection,
                    previous_product=previous['product'],observed_product=e['product'],
                    last_previous=previous['observed_at'],first_observed=e['observed_at']))
            previous=e
    output=[]
    for key,p in sorted(products.items()):
        prices=p.pop('prices')
        p.update(min_price=str(min(prices)),max_price=str(max(prices)),price_count=len(prices),
                 average_price=str((p['revenue']/p['quantity']).quantize(Decimal('.01'),rounding=ROUND_HALF_UP)),
                 revenue=str(p['revenue'].quantize(Decimal('.01'))))
        output.append(p)
    obs=[]
    for _,p in sorted(price_observations.items()):
        p['revenue']=str(p['revenue'].quantize(Decimal('.01')));obs.append(p)
    return dict(products=output,price_observations=obs,
                price_changes=sorted(price_changes,key=lambda p:p['first_observed'],reverse=True),
                product_changes=sorted(product_changes,key=lambda p:p['first_observed'],reverse=True),
                review_issues=issues,legacy_reports=legacy_reports,
                revenue=str(sum((Decimal(p['revenue']) for p in output),Decimal(0)).quantize(Decimal('.01'))),
                quantity=sum(p['quantity'] for p in output))

if __name__=='__main__':
    try:
        result=portfolio(json.load(sys.stdin)) if sys.argv[1]=='--portfolio' else analyze(sys.argv[1],sys.argv[2] if len(sys.argv)>2 else '')
        print(json.dumps(result,ensure_ascii=False))
    except Exception as e:
        print(json.dumps({'error':str(e)},ensure_ascii=False));sys.exit(1)
