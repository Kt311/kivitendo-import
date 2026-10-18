import json
from pathlib import Path
import tempfile
import unittest
from test_public import reader

HEADER='Zeitpunkt;Rechnungsnummer;Status;Auswahlnummer;Artikel;Preis;Steuersatz;Zahlungsarten;Maschine\n'

def sale(date='01.09.2026 10:00',receipt='20260901-1',slot='11',product='Testprodukt',price='2,00',qty=1,payment='Bar',paid=None):
    return f'{date};{receipt};abgeschlossen;{slot};{product} ({qty}x);{price} €;19.0%;{payment} ({paid or price} €);Testautomat\n'

def analyze(text):
    with tempfile.TemporaryDirectory() as d:
        p=Path(d)/'synthetic.csv';p.write_text(HEADER+text,encoding='utf-8')
        return reader.analyze(p)

class HistoryTests(unittest.TestCase):
    def test_two_prices_one_product(self):
        a=analyze(sale()+sale('02.09.2026 10:00','20260902-1',price='2,20'))
        g=a['groups'][0]
        self.assertEqual(g['total'],'4.20')
        self.assertEqual([x['unit_gross'] for x in g['items']],['2.00000','2.20000'])
        self.assertEqual([x['quantity'] for x in g['items']],['1','1'])
        self.assertEqual(len(g['events']),2)
        p=reader.portfolio([{'source':'Test','data':g}])
        self.assertEqual(len(p['price_changes']),1)
        self.assertEqual(p['price_changes'][0]['first_observed'],'2026-09-02T10:00')
        self.assertEqual(p['products'][0]['average_price'],'2.10')

    def test_product_change_keeps_names_separate(self):
        a=analyze(sale()+sale('02.09.2026 10:00','20260902-1',product='Anderes Produkt'))
        p=reader.portfolio([{'source':'Test','data':a['groups'][0]}])
        self.assertEqual(len(p['products']),2)
        self.assertEqual(len(p['product_changes']),1)
        self.assertEqual(p['product_changes'][0]['previous_product'],'Testprodukt')

    def test_unknown_slot_is_not_a_product_change(self):
        a=analyze(sale(slot='-')+sale('02.09.2026 10:00','20260902-1',slot='-',product='Anderes Produkt'))
        p=reader.portfolio([{'source':'Test','data':a['groups'][0]}])
        self.assertEqual(p['product_changes'],[])

    def test_conflicting_receipt_is_preserved_for_review(self):
        a=analyze(sale()+sale(product='Anderes Produkt',slot='12'))
        g=a['groups'][0]
        self.assertEqual(g['total'],'4.00')
        self.assertEqual(len(g['events']),2)
        self.assertEqual(len(g['review_issues']),2)
        p=reader.portfolio([{'source':'Test','data':g}])
        self.assertEqual(p['product_changes'],[])

    def test_identical_duplicate_is_rejected(self):
        with self.assertRaisesRegex(ValueError,'Identische doppelte'):
            analyze(sale()+sale())

    def test_payment_total_is_checked(self):
        with self.assertRaisesRegex(ValueError,'Zahlungsbetrag'):
            analyze(sale(paid='1,00'))

    def test_small_amount_retained_and_flagged(self):
        a=analyze(sale(price='0,03'))
        g=a['groups'][0]
        self.assertEqual(g['total'],'0.03')
        self.assertEqual(len(g['review_issues']),1)

    def test_failed_vend_is_not_a_sale(self):
        row='01.09.2026 10:00;20260901-2;abgeschlossen;11;Testprodukt (1x) (Fehler bei der Ausgabe, Grund: Unbekannt);-;19%;GIROCARD (2,00 €, abgebrochen);Testautomat\n'
        a=analyze(sale()+row)
        self.assertEqual(a['groups'][0]['quantity'],'1')
        self.assertEqual(len(a['warnings']),1)

    def test_price_is_order_total_for_multiple_units(self):
        a=analyze(sale(price='4,00',qty=2))
        i=a['groups'][0]['items'][0]
        self.assertEqual((i['unit_gross'],i['quantity'],i['total']),('2.00000','2','4.00'))

    def test_no_false_price_change_between_slots(self):
        a=analyze(sale()+sale('02.09.2026 10:00','20260902-1',slot='12',price='2,20'))
        p=reader.portfolio([{'source':'Test','data':a['groups'][0]}])
        self.assertEqual(p['price_changes'],[])
        self.assertEqual(len(p['price_observations']),2)

    def test_observations_are_sorted_across_months_and_payments(self):
        a=analyze(sale('01.10.2026 10:00','20261001-1',price='2,20',payment='GIROCARD')+sale())
        p=reader.portfolio([{'source':'Test','data':g} for g in a['groups']])
        self.assertEqual(p['price_changes'][0]['previous_price'],'2.00000')
        self.assertEqual(p['price_changes'][0]['observed_price'],'2.20000')

    def test_export_order_does_not_change_content_hash(self):
        a=sale();b=sale('02.09.2026 10:00','20260902-1',price='2,20')
        self.assertEqual(analyze(a+b)['groups'][0]['content_hash'],analyze(b+a)['groups'][0]['content_hash'])

    def test_event_cannot_be_counted_twice_in_portfolio(self):
        g=analyze(sale())['groups'][0]
        with self.assertRaisesRegex(ValueError,'mehreren gespeicherten'):
            reader.portfolio([{'source':'Test','data':g},{'source':'Test','data':g}])

    def test_legacy_report_is_explicitly_excluded(self):
        p=reader.portfolio([{'source':'Test','data':{'items':[]}}])
        self.assertEqual(p['legacy_reports'],1)
        self.assertEqual(p['revenue'],'0.00')

if __name__=='__main__':unittest.main()
