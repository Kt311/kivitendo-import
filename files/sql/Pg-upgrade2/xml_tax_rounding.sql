-- @tag: xml_tax_rounding
-- @description: XML-Steuerbetraege fuer Kreditorenbuchungen dauerhaft erhalten
-- @depends: release_3_9_0
ALTER TABLE ap ADD COLUMN xml_tax_context text;
