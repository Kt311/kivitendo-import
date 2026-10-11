#!/usr/bin/env python3
"""Local PDF extraction and strict validation; no network, no automatic posting."""
import sys,json,re,subprocess,tempfile,shutil,datetime
from pathlib import Path
from decimal import Decimal,ROUND_HALF_UP

def run(args, timeout=45):
    try:
        p=subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
    except FileNotFoundError:
        raise ValueError('Programm fehlt: '+args[0])
    if p.returncode: raise ValueError('PDF-Verarbeitung fehlgeschlagen: '+args[0])
    return p.stdout.decode('utf-8',errors='replace')

def money(value):
    s=str(value).strip().replace(' ','').replace('\u00a0','')
    if ',' in s: s=s.replace('.','').replace(',','.')
    if not re.fullmatch(r'-?\d+(?:\.\d{1,5})?',s): raise ValueError('Ungueltige Zahl: '+s[:40])
    v=Decimal(s)
    if not v.is_finite() or abs(v)>Decimal('1000000000'): raise ValueError('Zahl ausserhalb des erlaubten Bereichs')
    return v

def analyze(path):
    if Path(path).stat().st_size>50*1024*1024: raise ValueError('PDF zu gross (maximal 50 MiB)')
    info=run(['pdfinfo',path]);m=re.search(r'^Pages:\s+(\d+)',info,re.M)
    if not m or not 1<=int(m[1])<=20: raise ValueError('PDF muss 1 bis 20 Seiten haben')
    pages=int(m[1]);text=run(['pdftotext','-layout','-enc','UTF-8',path,'-'])
    warnings=['Alle Angaben mit dem Original vergleichen. OCR und Texterkennung koennen Fehler enthalten.']
    # Inspect every page so mixed digital/scanned documents do not lose pages silently.
    chunks=text.split('\f');needs=[i for i in range(pages) if i>=len(chunks) or len(re.sub(r'\W','',chunks[i]))<30]
    if needs:
        if not shutil.which('tesseract') or not shutil.which('pdftoppm'):
            warnings.append('OCR fehlt: mindestens eine Seite hat keinen lesbaren Text. Angaben manuell vervollstaendigen.')
        else:
            langs=run(['tesseract','--list-langs']);lang='+'.join(x for x in ('deu','eng') if x in langs.split())
            if not lang: raise ValueError('Tesseract-Sprachdaten deu oder eng fehlen')
            with tempfile.TemporaryDirectory(prefix='kivi-ocr-') as d:
                while len(chunks)<pages: chunks.append('')
                for i in needs:
                    prefix=str(Path(d)/str(i))
                    run(['pdftoppm','-f',str(i+1),'-l',str(i+1),'-singlefile','-scale-to','2400','-png',path,prefix])
                    chunks[i]=run(['tesseract',prefix+'.png','stdout','-l',lang],60)
            text='\n\f\n'.join(chunks[:pages]);warnings.append('OCR verwendet: Ziffern und Dezimalzeichen besonders pruefen.')
    if len(text)>300000: raise ValueError('PDF-Text zu umfangreich')
    result={'text':text,'warnings':warnings,'invnumber':'','transdate':'','currency':'','net_total':'','tax_total':'','gross_total':'','items_text':''}
    def unique(key, values):
        values=list(dict.fromkeys(values))
        if len(values)==1:result[key]=values[0]
        elif len(values)>1:warnings.append('Mehrdeutige Erkennung: '+key+'; bitte selbst eintragen.')
    unique('ustid',re.findall(r'\bDE\s*(\d{9})\b',text))
    if result.get('ustid'):result['ustid']='DE'+result['ustid']
    unique('invnumber',re.findall(r'(?:Rechnungsnummer|Rechnungs[- ]?Nr\.?|Invoice\s*(?:number|no\.?))\s*:?\s*([A-Za-z0-9][A-Za-z0-9/._-]*)',text,re.I))
    dates=re.findall(r'(?:Rechnungsdatum|Invoice date)\s*:?\s*(\d{1,2}\.\d{1,2}\.\d{4}|\d{4}-\d{2}-\d{2})',text,re.I)
    unique('transdate',dates)
    currencies=re.findall(r'\b(?:EUR|USD|GBP|CHF)\b',text)
    if '€' in text: currencies.append('EUR')
    unique('currency',currencies)
    amount=r'(-?\d[\d.,]*)\s*(?:EUR|USD|GBP|CHF|€)?\s*$'
    patterns={'net_total':r'(?:Zwischensumme Netto|Nettobetrag|Gesamt netto|Net total)', 'tax_total':r'(?:Mehrwertsteuer|Umsatzsteuer|MwSt\.?|VAT total)', 'gross_total':r'(?:Zu zahlender Betrag|Rechnungsbetrag|Gesamtbetrag|Bruttobetrag|Grand total|Amount due)'}
    for key,label in patterns.items():
        found=[]
        for line in text.splitlines():
            if re.search(label,line,re.I):
                m=re.search(amount,line)
                if m:
                    try:found.append(str(money(m[1])))
                    except ValueError:pass
        unique(key,found)
    # Conservative line detection: explicit position, quantity, unit, net price, net total, VAT.
    items=[]
    for line in text.splitlines():
        m=re.match(r'^\s*\d+\s{2,}(.+?)\s{2,}(\d+(?:[.,]\d+)?)\s+(?:Stk\.?|Stueck|pcs|h)\s{2,}([\d.,]+)\s{2,}([\d.,]+)\s{2,}([\d.,]+)\s*%\s*$',line)
        if m:
            desc,q,price,total,rate=m.groups()
            try:
                if abs(money(q)*money(price)-money(total))<=Decimal('.01'):
                    items.append(' | '.join([desc,str(money(q)),str(money(total)),str(money(rate))]))
            except ValueError:pass
    if items: result['items_text']='\n'.join(items)
    else:
        rates=set(re.findall(r'(?:Mehrwertsteuer|MwSt\.?|Umsatzsteuer)[^\n\d]{0,8}(\d+(?:[.,]\d+)?)\s*%',text,re.I))
        if result['net_total'] and len(rates)==1:
            result['items_text']='Sammelposition laut Originalrechnung | 1 | '+result['net_total']+' | '+str(money(next(iter(rates))))
            warnings.append('Nur Sammelposition vorgeschlagen: Einzelpositionen wurden nicht zuverlaessig erkannt. Bitte ersetzen oder bewusst bestaetigen.')
        else:warnings.append('Positionen nicht sicher erkannt. Bitte aus dem Original eintragen.')
    return result

def validate(data):
    if str(data.get('confirmed',''))!='1':raise ValueError('Originalvergleich muss bestaetigt werden')
    if not re.fullmatch(r'[1-9]\d*',str(data.get('vendor_id',''))):raise ValueError('Lieferant muss ausgewaehlt werden')
    number=str(data.get('invnumber','')).strip()
    if not number or len(number)>100 or re.search(r'[\x00-\x1f]',number):raise ValueError('Rechnungsnummer fehlt oder ist ungueltig')
    date=str(data.get('transdate','')).strip()
    try:d=datetime.datetime.strptime(date,'%Y-%m-%d' if '-' in date else '%d.%m.%Y').date()
    except ValueError:raise ValueError('Rechnungsdatum ungueltig (TT.MM.JJJJ)')
    currency=str(data.get('currency','')).strip().upper()
    if not re.fullmatch('[A-Z]{3}',currency):raise ValueError('Waehrung muss ein dreistelliger Code sein')
    totals={k:money(data.get(k,'')) for k in ('net_total','tax_total','gross_total')}
    if any(v<0 or v!=v.quantize(Decimal('.01')) for v in totals.values()):raise ValueError('Nur positive Rechnungen mit Cent-Betraegen; Gutschriften nicht unterstuetzt')
    if abs(totals['net_total']+totals['tax_total']-totals['gross_total'])>Decimal('.001'):raise ValueError('Netto + Steuer stimmt nicht mit Brutto ueberein')
    items=[]
    for line in str(data.get('items_text','')).splitlines():
        if not line.strip():continue
        fields=[v.strip() for v in line.split('|')]
        if len(fields)!=4:raise ValueError('Position: Bezeichnung | Menge | Netto-Gesamtbetrag | Steuer-% erwartet')
        desc,q,total,rate=fields;q,total,rate=map(money,(q,total,rate))
        if not desc or len(desc)>1000 or q<=0 or total<0 or rate not in (Decimal(0),Decimal(7),Decimal(19)):raise ValueError('Position ungueltig; unterstuetzt werden positive Mengen und 0, 7, 19 %')
        if total!=total.quantize(Decimal('.01')):raise ValueError('Positionssumme muss ein Cent-Betrag sein')
        items.append({'description':desc,'quantity':str(q),'subtotal':str(total),'tax_rate':str(rate),'vendor_partno':''})
    if not 1<=len(items)<=100:raise ValueError('1 bis 100 Positionen erforderlich')
    if abs(sum(money(i['subtotal']) for i in items)-totals['net_total'])>Decimal('.001'):raise ValueError('Positionssummen stimmen nicht mit Netto ueberein')
    groups={}
    for i in items:
        rate=money(i['tax_rate']);groups[rate]=groups.get(rate,Decimal(0))+money(i['subtotal'])
    rounded=lambda v:v.quantize(Decimal('.01'),rounding=ROUND_HALF_UP)
    calculated=sum(rounded(net*rate/100) for rate,net in groups.items())
    gross_match=False
    if len(items)==1:
        rate=money(items[0]['tax_rate'])/100
        gross_match=rounded(totals['gross_total']*rate/(1+rate))==totals['tax_total']
    if calculated!=totals['tax_total'] and not gross_match:
        raise ValueError('Steuersumme passt nicht centgenau zu den Positionen; Rundung und Steuersaetze pruefen')
    metadata={'type':'380','invnumber':number,'transdate':d.strftime('%Y%m%d'),'currency':currency,**{k:str(v) for k,v in totals.items()}}
    return {'vendor_id':int(data['vendor_id']),'metadata':metadata,'items':items,'tax_totals':[{'category_code':'S' if money(i['tax_rate']) else 'Z','tax_rate':i['tax_rate'],'net_amount':i['subtotal']} for i in items]}

if __name__=='__main__':
    try:
        result=analyze(sys.argv[2]) if sys.argv[1]=='analyze' else validate(json.load(sys.stdin))
        print(json.dumps(result,ensure_ascii=True))
    except Exception as e:
        print(json.dumps({'error':str(e)},ensure_ascii=True));sys.exit(1)
