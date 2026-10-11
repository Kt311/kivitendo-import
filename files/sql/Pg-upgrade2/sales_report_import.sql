-- @tag: sales_report_import
-- @description: Verkaufsbericht-Import: Artikelzuordnungen und transaktionssichere Importvorgaenge
-- @depends: release_3_9_0
CREATE TABLE sales_report_imports (
  import_key text PRIMARY KEY,
  source text NOT NULL,
  period text NOT NULL,
  payment text NOT NULL,
  content_hash text NOT NULL,
  payload text NOT NULL,
  mapping text NOT NULL DEFAULT '{}',
  source_sha256 text NOT NULL,
  filename text NOT NULL,
  posted_ar_id integer REFERENCES ar(id) ON DELETE RESTRICT,
  created_at timestamp NOT NULL DEFAULT now(),
  UNIQUE(source, period, payment)
);
CREATE TABLE sales_report_mappings (
  source text NOT NULL,
  description text NOT NULL,
  parts_id integer NOT NULL REFERENCES parts(id) ON DELETE RESTRICT,
  PRIMARY KEY(source, description)
);
