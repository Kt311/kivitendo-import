# kivitendo Import-Erweiterung

Import-Erweiterung **v6.3 für kivitendo ERP 4.1.0**. Enthält Quellcode,
geprüften Installer und Tests. Eigenständiges Community-Patchpaket, kein
offizielles kivitendo-Release und keine vollständige ERP-Installation.

## Funktionen

- XRechnung/UBL und ZUGFeRD-Import mit Artikelzuordnung für Einkaufsrechnungen.
- Normale PDF-Einkaufsrechnungen lokal auslesen und vor Übernahme prüfen;
  OCR-Unterstützung. Die regelbasierte Erkennung unterstützt nicht jedes Layout.
- CSV- und unterstützte textbasierte PDF-Verkaufsberichte einlesen.
- Verkaufspositionen nach Quelle, Monat und Zahlungsart zusammenfassen.
- Artikelzuordnungen speichern; aktuelle Verkaufspreise aus dem Artikelstamm
  vorbelegen. Historische Preise werden nicht aus dem Belegdatum rekonstruiert.
- Kunden in der Verkaufsrechnung auswählen; Preise vor dem Buchen bearbeiten.
- Wiederholte Verkaufsimporte derselben Quelle/Periode/Zahlungsart erkennen.
  Bereits gebuchte Vorgänge gegen erneutes Buchen über diesen Import schützen.

**Status:** lokal getestetes Patchpaket. Die vollständige Buchung muss im
eigenen Testmandanten geprüft werden. Tests mit Ersatzobjekten ersetzen keinen
Test mit Datenbank, Steuereinstellungen und Weboberfläche.

## Voraussetzungen

- kivitendo **4.1.0**, unveränderter passender Quellstand oder bekannte
  Paketversion 1 bis 6.2. Abweichende lokale Änderungen stoppt der Installer.
- Python **3.9 oder neuer** (Installer und Parser), bestehende kivitendo-Perl-Umgebung.
- Poppler für PDF, IPC::Run für den Aufruf des Parsers; Tesseract für OCR.

Debian/Ubuntu:

```sh
sudo apt-get install python3 poppler-utils libipc-run-perl tesseract-ocr tesseract-ocr-deu tesseract-ocr-eng
```

## Installation und Update

Dateien und Mandantendatenbank sichern. ZIP entpacken oder Repository klonen.
Die folgenden Befehle im Verzeichnis mit `install.py` ausführen; Installationspfad
bei Bedarf anpassen. Änderungen und Neustart außerhalb laufender Buchungen planen.

```sh
sudo python3 install.py /var/www/kivitendo-erp --check
sudo python3 install.py /var/www/kivitendo-erp --apply
sudo systemctl restart apache2
```

Bei anderer Betriebsart die entsprechenden kivitendo-Anwendungsprozesse neu starten.
Kein vorheriger Rollback erforderlich. Erstinstallation der Verkaufsfunktion:
neu anmelden und das von kivitendo angebotene Mandanten-Datenbankupdate ausführen.
Der Installer führt SQL nicht selbst aus. **Version 6.3 benötigt das neue
Mandanten-Datenbankupdate `xml_tax_rounding`.** Nach dem Neustart neu anmelden
und das angebotene Datenbankupdate ausführen, bevor Kreditorenbuchungen bearbeitet
werden. Das zusätzliche Feld speichert die XML-Steuerwerte am gebuchten Beleg.

## Verkaufsbericht verwenden

1. **Verkauf → Verkaufsbericht importieren** öffnen.
2. Quelle/Standort immer identisch schreiben. CSV oder unterstützte PDF wählen.
3. Wenn das Jahr in der Datei fehlt, das Jahr ausdrücklich eingeben.
   Der Monat muss in der Datei stehen. Bruttobeträge in EUR bestätigen.
4. Bericht einlesen; je Monat und Zahlungsart entsteht eine Vorbereitung.
5. **Zuordnen / Vorbereitung wieder öffnen** wählen, Artikel prüfen und zuordnen.
6. In der Verkaufsrechnung den passenden Kunden auswählen, Mengen, Preise,
   Einheiten und Steuern prüfen; erst dann manuell buchen.

Der Import bucht und bezahlt nicht automatisch. Artikelstammpreise sind netto;
ursprüngliche Bruttoumsätze dienen zum Vergleich. Bei Preisänderungen sind
Abweichungen möglich. Wiederöffnen einer Vorbereitung lädt aktuelle Stammpreise
erneut und stellt ungebuchte manuelle Maskenänderungen nicht wieder her.
Originalbelege separat an der Rechnung hinterlegen.

Die Option zum Ersetzen offener Monatsberichte nur für bewusste Korrekturen
verwenden. Alte Rechnungs-Tabs werden dadurch ungültig. Gebuchte Vorgänge bleiben
gesperrt; Korrekturen über die regulären kivitendo-Funktionen vornehmen.
Andere Importwege oder geänderte Quellnamen können diese Duplikatsperre umgehen.

### Unterstützte Statistik-CSV

UTF-8, Semikolon als Trennzeichen. `Jahr` optional bei Eingabe im Formular.

```csv
Jahr;Monat;Produkt;Zahlungsart;Steuersatz;Verkäufe;Summe €
2026;9;Beispielartikel;CASH;19%;2;4,00
2026;9;Beispielartikel;CASHLESS;19%;3;6,00
```

Auch der unterstützte detaillierte Verkaufsbericht mit Zeitpunkt,
Rechnungsnummer, Status, Artikel, Preis, Steuersatz und Zahlungsarten kann
eingelesen werden. Mehrdeutige Rechnungsnummern werden zurückgewiesen.
PDF-Verkaufsberichte benötigen lesbaren Text und zusammenhängende Spalten;
gescannte Verkaufsberichte und beliebige PDF-Layouts werden nicht unterstützt.

## Einkaufsimport

### XML-Rundungsabgleich in Kreditorenbuchungen (v6.3)

Bei XML-Rechnungen (Typ 380, Steuerkategorien S/Z/E) werden die ausgewiesenen
Steuerbeträge je Steuersatz beim **Aktualisieren und Buchen** erhalten. Der
Abgleich verändert ausschließlich Steuerzeilen um höchstens einen Cent pro
Zeile; Nettobeträge, Mengen, Konten und Steuerschlüssel bleiben erhalten. Die
XML-Steuer je Gruppe darf höchstens einen Cent von der gerundeten Steuerbasis
abweichen. Größere Differenzen sowie geänderte Nettosummen, Steuersätze,
Lieferanten, Rechnungsnummern oder Währungen stoppen den Abgleich.

Beispiel: 120,73 EUR netto und XML-Steuerbeträge 4,57 EUR (7 %) plus 10,54 EUR
(19 %) ergeben 135,84 EUR. Sowohl Einzelpositionen als auch zusammengefasste
Buchungszeilen behalten dieses Ergebnis. Beim Buchen wird der Kontext innerhalb
derselben Datenbanktransaktion gespeichert und beim späteren Bearbeiten erneut
verwendet. Ohne XML-Kontext arbeiten gewöhnliche Kreditorenbuchungen wie bisher.
Der CII-Parser verwendet `GrandTotalAmount` als Rechnungsbrutto; `DuePayableAmount`
ist der separate offene Zahlbetrag. Vorauszahlungen werden nicht automatisch gebucht.

Geltungsbereich: **Kreditorenbuchung (`ap.pl`)**, Nettoeingabe und keine
Währungsumrechnung. Artikelbasierte Einkaufsrechnungen (`ir.pl`) haben einen
anderen Rechenweg und sind von diesem Rundungsabgleich nicht erfasst. Die
CII-Korrektur der Rechnungssumme gilt für beide Importwege. Buchungen, die schon
vor Version 6.3 erstellt wurden, erhalten nicht rückwirkend XML-Steuerdaten.
Vorhandene Belege werden nicht automatisch verändert. Bei ungebuchten alten
Import-Tabs nach dem Update die XML erneut importieren. Bereits gebuchte
Altbelege anhand des Originalbelegs prüfen und über den regulären Korrekturweg
berichtigen; keine zweite Rechnung mit derselben Nummer anlegen.

Die zusätzlichen Rundungstests verwenden Ersatzobjekte für Datenbank und
Sitzungsdateien sowie die originalen 4.1.0-Rechenfunktionen. Eine vollständige
Buchung im eigenen Testmandanten einschließlich Datenbankupdate und erneutem
Öffnen bleibt vor dem Produktiveinsatz erforderlich.


Den bestehenden ZUGFeRD-/XML-Import öffnen. Für Artikelpositionen die Option
**Als Einkaufsrechnung mit Artikelpositionen importieren** aktivieren und
Lieferant sowie Artikelzuordnung prüfen. Ohne diese Option bleibt der bisherige
Kreditorenbuchungsweg erhalten. Normale PDFs durchlaufen eine bearbeitbare
Prüfmaske; erkannte Werte stets mit dem Original vergleichen.

## Tests und Release

```sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
perl tests/sales_report.t files
perl tests/price_rules_without_customer.t files
python3 tools/build_release.py
```

Die Tests benötigen keine echten Rechnungen. GitHub Actions führt dieselben
Prüfungen aus und stellt ein ZIP als Workflow-Artefakt bereit. Keine automatische
Veröffentlichung und kein Deployment. Optionaler Installertest gegen einen lokal
bereitgestellten unveränderten 4.1.0-Quellbaum:

```sh
python3 tests/installer_scenarios.py /pfad/zu/kivitendo-4.1.0
```

Nach Quellcodeänderungen die `after`-Hashes im Manifest aktualisieren und den
Unified Diff gegen den Originalquellstand regenerieren. `before` und bekannte
Upgrade-Hashes niemals zur Umgehung einer Konfliktprüfung verändern.

## Rücknahme

Der Installer nennt nach Installation den Sicherungspfad. Diesen exakt einsetzen:

```sh
sudo python3 install.py /var/www/kivitendo-erp --rollback /vollstaendiger/pfad/zur/sicherung
sudo systemctl restart apache2
```

Rollback nimmt Dateien zurück, keine Buchungen oder Datenbankmigrationen.
Zwischenzeitlich veränderte Dateien werden nicht ungeprüft überschrieben.

## GitHub einrichten

Leeres Repository namens `kivitendo-import` anlegen, ohne automatisch erzeugte
README oder Lizenz. Dieses Paket vollständig entpacken, einschließlich `.github`.
Im Paketordner:

```sh
git init -b main
git add .
git commit -m "Initial import: kivitendo 4.1.0 import extension v6.2"
git remote add origin https://github.com/DEIN-BENUTZERNAME/kivitendo-import.git
git push -u origin main
```

`DEIN-BENUTZERNAME` ersetzen. Für ein Release nach erfolgreicher Prüfung den Tag
`v6.2.0` erstellen und das mit `tools/build_release.py` erzeugte ZIP anhängen.

## Lizenz und Herkunft

GPL-2.0-or-later, siehe [COPYING](COPYING). Enthält geänderte Dateien aus
kivitendo ERP 4.1.0. Bestehende Urheber- und Lizenzhinweise bleiben erhalten;
die ergänzten Paketbestandteile stehen ebenfalls unter GPL-2.0-or-later.
Die Änderungen sind im Unified Diff dokumentiert.

Originalprojekt: https://github.com/kivitendo/kivitendo-erp

Keine Zugangsdaten, Mandantendatenbanken oder echten Rechnungsdateien enthalten.
