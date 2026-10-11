"""Synthetic fixtures only; no private invoice files needed."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('reader', ROOT / 'files/scripts/sales_report_import.py')
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)
HEADER = 'Jahr;Monat;Produkt;Zahlungsart;Steuersatz;Verkäufe;Summe €\n'

class PublicTests(unittest.TestCase):
    def test_payload_integrity(self):
        data = json.loads((ROOT / 'manifest.json').read_text())
        for name, entry in data['files'].items():
            with self.subTest(name=name):
                self.assertEqual(hashlib.sha256((ROOT/'files'/name).read_bytes()).hexdigest(), entry['after'])

    def test_grouping_and_repeat(self):
        text = HEADER + '2026;9;Beispielartikel;CASH;19%;2;4,00\n2026;9;Beispielartikel;CASH;19%;3;6,00\n2026;9;Beispielartikel;CASHLESS;19%;1;2,00\n2026;10;Beispielartikel;CASH;19%;1;2,00\n'
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'example.csv'
            path.write_text(text, encoding='utf-8')
            first = reader.analyze(path)
            self.assertEqual(first, reader.analyze(path))
        self.assertEqual(len(first['groups']), 3)
        group = first['groups'][0]
        self.assertEqual((group['quantity'],group['total']), ('5','10.00'))
        self.assertEqual(group['end_date'], '2026-09-30')

    def test_missing_year(self):
        text = HEADER+';9;Beispielartikel;CASH;19%;1;2,00'
        with self.assertRaisesRegex(ValueError, 'Jahr fehlt'):
            reader.csv_rows(text, '')
        self.assertEqual(reader.csv_rows(text,'2026')[0][0]['year'],2026)

    def test_blank_year_fallback_and_explicit_priority(self):
        for year,expected in [(' ',2026),('2025',2025)]:
            rows,_=reader.csv_rows(HEADER+year+';9;Beispielartikel;CASH;19%;1;2,00','2026')
            self.assertEqual(rows[0]['year'],expected)

    def test_no_guessed_month(self):
        with self.assertRaisesRegex(ValueError, 'Monat fehlt'):
            reader.csv_rows(HEADER+'2026;;Beispielartikel;CASH;19%;1;2,00','2026')

    def test_invalid_quantities_and_tax(self):
        for index,value in [(1,'13'),(3,'unknown'),(4,'20%'),(5,'0'),(5,'1.5'),(6,'2.555')]:
            args=['2026','9','Beispielartikel','CASH','19%','2','4,00']
            args[index]=value
            with self.subTest(value=value),self.assertRaises(ValueError):reader.item(*args)

    def test_bad_width(self):
        with self.assertRaisesRegex(ValueError,'Spaltenzahl'):
            reader.csv_rows(HEADER+'2026;9;Beispielartikel;CASH;19%;1;2,00;extra','')

if __name__ == '__main__':
    unittest.main()
