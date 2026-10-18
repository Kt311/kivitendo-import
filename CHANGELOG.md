## 6.3 – 2026-10-18

- XML-Steuerbeträge in Kreditorenbuchungen beim Aktualisieren und Buchen
  anhand der Original-Steuergruppen kontrolliert abgleichen.
- Rundungskontext transaktionssicher am Beleg speichern; erneutes Bearbeiten
  benötigt die ursprüngliche Sitzung nicht mehr.
- Nettosummen und Steuersätze prüfen, größere Differenzen zurückweisen.
- CII-Rechnungsbrutto aus GrandTotalAmount statt DuePayableAmount lesen;
  Vorauszahlung und offenen Zahlbetrag getrennt auslesen.
- Steuerzuordnung aus XML beim Laden einer Buchungsvorlage beibehalten.
- Neues Mandanten-Datenbankupdate xml_tax_rounding erforderlich.
- Tests für Aktualisieren, wiederholtes Aktualisieren, Buchen, Wiederöffnen,
  zusammengefasste Gruppen und ungültige Abweichungen hinzugefügt.

# Änderungen

## 6.2
- Preisregeln erst bei vorhandenem Kunden/Lieferanten abfragen.
- Leeres Ergebnis vor Kundenauswahl nicht zwischenspeichern.
- GitHub-Paket mit unabhängigen synthetischen Tests und CI.

## 6.1
- Eindeutiger Jahresplatzhalter und konkrete Fehler für fehlendes Jahr/Monat.
- Leere CSV-Jahreswerte nutzen das Formularjahr, auch bei Leerzeichen.
- Checkboxen nach fehlgeschlagenem Upload erhalten.

## 6
- Monatsweise Verkaufsrechnungen aus CSV/PDF-Berichten vorbereiten.
- Gespeicherte Artikelzuordnung, aktuelle Stammpreise, manuelle Kundenauswahl.
- Duplikatsperre und Verknüpfung mit gebuchter Rechnung.

## 1–5.1
- Einkaufsimport für UBL/XRechnung und ZUGFeRD mit Artikelpositionen.
- Lokale PDF-Auswertung, OCR, Prüfmaske und Steuerbetragsprüfung.
- Geprüfte Dateiinstallation mit Sicherung, Upgrade und Rollback.
