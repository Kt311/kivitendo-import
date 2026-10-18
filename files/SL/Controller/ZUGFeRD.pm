package SL::Controller::ZUGFeRD;
use strict;
use warnings;
use utf8;
use parent qw(SL::Controller::Base);

use SL::DB::RecordTemplate;
use SL::DB::MakeModel;
use SL::DB::Manager::Part;
use SL::DB::Part;
use SL::DB::Vendor;
use SL::Helper::Flash qw(flash flash_later);
use Digest::SHA qw(sha256_hex);
use Scalar::Util qw(looks_like_number);
use SL::Locale::String qw(t8);
use SL::Helper::DateTime;
use SL::XMLInvoice;
use SL::ZUGFeRD;
use SL::PDFInvoice;
use JSON::PP ();
use SL::SessionFile;
use SL::Helper::Number qw(_format_total);

use XML::LibXML;
use List::Util qw(first max);


__PACKAGE__->run_before('check_auth');

sub action_upload_zugferd {
  my ($self, %params) = @_;

  $self->pre_render();
  $self->render('zugferd/form', title => $::locale->text('Factur-X/ZUGFeRD import'));
}


sub action_import_zugferd {
  my ($self, %params) = @_;

  my $file      = $::form->{file};
  my $file_name = $::form->{file_name};
  my $import_as_purchase_invoice = $::form->{import_as_purchase_invoice};

  if (!defined($file) || !length($file)) {
    my $message = 'Bitte eine PDF- oder XML-Rechnungsdatei auswählen.';
    flash_later('error', $message);
    return $self->redirect_to(action => 'upload_zugferd');
  }
  $file_name = 'xrechnung-' . sha256_hex($file) . ($file =~ m/^%PDF-/ ? '.pdf' : '.xml');

  my $res = eval { _extract_invoice_data($file) };
  if (!$res && $file =~ /^%PDF-/) {
    return $self->_review_plain_pdf($file_name, $file);
  }
  if (!$res) {
    return $self->_redirect_import_error($@ || 'unbekannter Importfehler');
  }

  return $self->_review_plain_pdf($file_name, $file)
    if $res->{pdf_vendor_id} && !$params{pdf_review_confirmed};
  $import_as_purchase_invoice = 1 if $res->{pdf_vendor_id};
  my $vendor = _find_invoice_vendor($res);
  _check_invoice_duplicates($vendor->id, $res);

  # Store the original file before an item mapping page is rendered. The file
  # is reparsed after confirmation, so invoice values never have to be trusted
  # from hidden browser fields.
  _save_session_invoice($file_name, $file);

  if (!$import_as_purchase_invoice) {
    my $form_defaults = $self->build_ap_transaction_form_defaults($res);
    return $self->_redirect_to_invoice_form('ap.pl', $form_defaults, $file_name);
  }

  $::auth->assert('vendor_invoice_edit');
  _assert_valid_purchase_invoice_items($res);
  my ($mapping_rows, $needs_mapping) = $self->_build_mapping_rows(
    $vendor->id,
    $res->{invoice_xml}->items,
  );

  if ($needs_mapping) {
    $::auth->assert('part_service_assembly_edit');
    return $self->_render_mapping_form(
      vendor       => $vendor,
      rows         => $mapping_rows,
      session_file => $file_name,
    );
  }

  my $form_defaults = $self->build_purchase_invoice_form_defaults(
    $res,
    vendor => $vendor,
  );
  return $self->_redirect_to_invoice_form('ir.pl', $form_defaults, $file_name);
}

sub _render_pdf_review {
  my ($self, $name, $values, $error) = @_;
  my $context_name = $name // '';
  $context_name =~ s/\.pdf$/-review.json/;
  my ($context) = eval { _load_session_invoice($context_name) };
  if ($context) {
    my $saved = eval { JSON::PP->new->utf8->decode($context) };
    if (ref($saved) eq 'HASH') {
      $values->{text} = $saved->{text};
      $values->{warnings} = $saved->{warnings};
    }
  }
  $self->render('zugferd/pdf_review', title => 'PDF-Rechnung pruefen',
    session_file => $name, values => $values, review_error => $error);
}

sub _review_plain_pdf {
  my ($self, $name, $file) = @_;
  $::auth->assert('vendor_invoice_edit');
  return $self->_redirect_import_error('PDF ist groesser als 50 MiB.') if length($file) > 50 * 1024 * 1024;
  _save_session_invoice($name, $file);
  my $values = eval { SL::PDFInvoice::call_helper('analyze', $file) };
  return $self->_redirect_import_error($@) unless $values;
  if ($values->{ustid}) {
    my $vendor = eval { SL::ZUGFeRD::find_vendor($values->{ustid}, undef) };
    $values->{vendor_id} = $vendor->id if $vendor;
  }
  my $context_name = $name;
  $context_name =~ s/\.pdf$/-review.json/;
  _save_session_invoice($context_name, JSON::PP->new->utf8->encode($values));
  return $self->_render_pdf_review($name, $values, '');
}

sub action_confirm_pdf {
  my ($self) = @_;
  $::auth->assert('vendor_invoice_edit');
  my $name = $::form->{pdf_session_file};
  my %values = map { $_ => $::form->{"pdf_$_"} // '' } qw(vendor_id invnumber transdate currency net_total tax_total gross_total items_text confirmed);
  my ($file, $approved);
  my $ok = eval {
    ($file) = _load_session_invoice($name);
    die "Keine Original-PDF vorhanden." unless $file =~ /^%PDF-/;
    $approved = SL::PDFInvoice::call_helper('validate', \%values);
    my $vendor = SL::DB::Vendor->new(id => $approved->{vendor_id})->load;
    die "Lieferant ist nicht verfuegbar." if $vendor->obsolete;
    $approved->{pdf_sha256} = sha256_hex($file);
    1;
  };
  return $self->_render_pdf_review($name, \%values, _clean_import_error($@)) unless $ok;
  _save_session_invoice('xrechnung-' . sha256_hex($file) . '.json', JSON::PP->new->utf8->encode($approved));
  local $::form->{file} = $file;
  local $::form->{import_as_purchase_invoice} = 1;
  return $self->action_import_zugferd(pdf_review_confirmed => 1);
}

sub _extract_invoice_data {
  my ($file) = @_;
  die "Keine Rechnungsdatei vorhanden." unless defined($file) && length($file);
  die "Rechnungsdatei ist groesser als 50 MiB." if length($file) > 50 * 1024 * 1024;
  my $res;
  if ($file =~ /^%PDF-/) {
    my $review_name = 'xrechnung-' . sha256_hex($file) . '.json';
    my ($review) = eval { _load_session_invoice($review_name) };
    if ($review) {
      my $data = JSON::PP->new->utf8->decode($review);
      die "PDF-Pruefdaten passen nicht zur Originaldatei." unless ($data->{pdf_sha256} // '') eq sha256_hex($file);
      return { result => SL::ZUGFeRD::RES_OK(), invoice_xml => SL::PDFInvoice->from_review($data), pdf_vendor_id => $data->{vendor_id} };
    }
    $res = SL::ZUGFeRD->extract_from_pdf($file);
  } else {
    # Accept XML with/without declaration and UTF-8 BOM; reject DTDs.
    my $doc = XML::LibXML->load_xml(string => $file, no_network => 1,
      load_ext_dtd => 0, expand_entities => 0, recover => 0);
    die "XML mit DTD wird nicht importiert." if $doc->internalSubset || $doc->externalSubset;
    $res = SL::ZUGFeRD->extract_from_xml($file);
  }
  die "Keine unterstuetzte Rechnungs-XML gefunden. Fuer normale PDFs ist die Pruefung der erkannten Daten erforderlich."
    unless ref($res) eq 'HASH' && defined($res->{result}) && $res->{result} == SL::ZUGFeRD::RES_OK();
  return $res;
}

sub _canonical_invoice_number {
  my ($number) = @_;
  # Ignore case and whitespace only. Preserve punctuation and leading zeros.
  $number = lc(_trim_value($number));
  $number =~ s/\s+//g;
  return $number;
}

sub _duplicate_findings {
  my ($metadata, $rows) = @_;
  my (@exact, @similar);
  my $key = _canonical_invoice_number($metadata->{invnumber});
  die "Rechnungsnummer fehlt; Import abgebrochen." unless length($key);
  my $date = $metadata->{transdate} // '';
  $date =~ s/^(\d{4})(\d{2})(\d{2})$/$1-$2-$3/;
  foreach my $row (@$rows) {
    if (_canonical_invoice_number($row->{invnumber}) eq $key) {
      push @exact, $row;
    } elsif ($date ne '' && $date eq ($row->{transdate} // '')
             && ($metadata->{currency} // '') eq ($row->{currency} // '')
             && looks_like_number($metadata->{gross_total})
             && looks_like_number($row->{amount})
             && abs($metadata->{gross_total} - $row->{amount}) < 0.005) {
      push @similar, $row;
    }
  }
  return (\@exact, \@similar);
}

sub _check_invoice_duplicates {
  my ($vendor_id, $data) = @_;
  my $dbh = SL::DB->client->dbh;
  my $rows = $dbh->selectall_arrayref(
    'SELECT a.id, a.invnumber, a.transdate, '
    . 'CASE WHEN a.currency_id = (SELECT currency_id FROM defaults LIMIT 1) THEN a.amount ELSE NULL END AS amount, c.name AS currency '
    . 'FROM ap a LEFT JOIN currencies c ON c.id = a.currency_id WHERE a.vendor_id = ?',
    { Slice => {} }, $vendor_id);
  my ($exact, $similar) = _duplicate_findings($data->{invoice_xml}->metadata, $rows);
  die "Moegliche Rechnungs-Dublette: Lieferant und Rechnungsnummer bereits vorhanden (Beleg-ID: "
    . join(', ', map { $_->{id} } @$exact) . "). Import abgebrochen; bestehenden Beleg pruefen."
    if @$exact;
  return '' unless @$similar;
  return "DUBLETTENVERDACHT: gleicher Lieferant, Rechnungsdatum, Bruttobetrag und Waehrung, aber andere Rechnungsnummer (Beleg-ID: "
    . join(', ', map { $_->{id} } @$similar) . "). Vor dem Buchen pruefen.";
}

sub _clean_import_error {
  my ($error) = @_;

  $error //= '';
  $error =~ s/[\r\n]+/ /g;
  $error =~ s/^\s+|\s+$//g;
  $error =~ s/\s+at\s+\S+\s+line\s+\d+\.?$//;
  $error = 'unbekannter Importfehler' if $error eq '';
  return substr($error, 0, 800);
}

sub _redirect_import_error {
  my ($self, $error) = @_;

  flash_later('error', 'Rechnungsimport nicht möglich: ' . _clean_import_error($error));
  return $self->redirect_to(action => 'upload_zugferd');
}

sub _save_session_invoice {
  my ($file_name, $file) = @_;

  my $session_file = SL::SessionFile->new($file_name, mode => 'w');
  die "XRechnungsdatei konnte nicht in der Sitzung gespeichert werden."
    unless $session_file->fh;
  $session_file->fh->print($file);
  $session_file->fh->close;
}

sub _load_session_invoice {
  my ($file_name) = @_;

  die "Sitzungsdatei fuer die XRechnung fehlt." unless _trim_value($file_name) ne '';
  die "Ungueltige Import-Sitzungsdatei." unless $file_name =~ /^xrechnung-[a-f0-9]{64}(?:-review)?\.(?:xml|pdf|json)$/;
  my $session_file = SL::SessionFile->new($file_name, mode => '<');
  die "Die XRechnungsdatei ist nicht mehr in der Sitzung vorhanden. Bitte erneut hochladen."
    unless $session_file->fh;

  local $/;
  my $file = readline($session_file->fh);
  $session_file->fh->close;
  return ($file, $session_file);
}

sub _find_invoice_vendor {
  my ($data) = @_;

  if ($data->{pdf_vendor_id}) {
    my $vendor = SL::DB::Vendor->new(id => $data->{pdf_vendor_id})->load;
    die "Lieferant ist nicht verfuegbar." if $vendor->obsolete;
    return $vendor;
  }
  my %metadata = %{ $data->{invoice_xml}->metadata };
  die t8("Cannot process this invoice: neither VAT ID nor tax ID present.")
    unless $metadata{ustid} || $metadata{taxnumber};

  my $vendor = SL::ZUGFeRD::find_vendor($metadata{ustid}, $metadata{taxnumber});
  die t8(
    "Vendor with VAT ID (#1) and/or tax ID (#2) not found. Please check if the vendor #3 exists and whether it has the correct tax ID/VAT ID.",
    $metadata{ustid},
    $metadata{taxnumber},
    $metadata{vendor_name},
  ) unless $vendor;

  return $vendor;
}

sub _is_decimal {
  return defined($_[0]) && $_[0] =~ /^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$/;
}

sub _assert_valid_purchase_invoice_items {
  my ($data) = @_;

  my $parser   = $data->{invoice_xml};
  my %metadata = %{ $parser->metadata };
  my @items    = @{ $parser->items || [] };

  die "Artikelbasierter Import unterstuetzt derzeit nur Rechnungen (TypeCode 380)."
    unless ($metadata{type} // '') eq '380';
  die "Die XRechnung enthaelt keine Rechnungspositionen." unless @items;

  my @errors;
  my $line_sum = 0;
  foreach my $tax (@{ $parser->tax_totals || [] }) {
    push @errors, "Steuerkategorie wird im Artikelimport nicht unterstuetzt."
      unless ($tax->{category_code} // '') =~ /^(?:S|Z|E)$/;
  }
  foreach my $index (0 .. $#items) {
    my $row   = $index + 1;
    my $label = _trim_value($items[$index]->{vendor_partno})
             || _trim_value($items[$index]->{description})
             || "Position $row";

    push @errors, "Position $row ($label): ungueltige oder leere Menge"
      if !_is_decimal($items[$index]->{quantity}) || $items[$index]->{quantity} == 0;
    push @errors, "Position $row ($label): ungueltige Positionssumme"
      if !_is_decimal($items[$index]->{subtotal});
    push @errors, "Position $row ($label): ungueltiger Steuersatz"
      if !_is_decimal($items[$index]->{tax_rate}) || $items[$index]->{tax_rate} < 0 || $items[$index]->{tax_rate} > 100;
    $line_sum += $items[$index]->{subtotal} if _is_decimal($items[$index]->{subtotal});
  }

  push @errors, "Positionssummen stimmen nicht mit dem Netto-Gesamtbetrag ueberein. Belegweite Zu-/Abschlaege werden nicht automatisch verteilt."
    if !_is_decimal($metadata{net_total}) || abs($line_sum - $metadata{net_total}) > 0.01;
  push @errors, "Brutto-, Netto- und Steuerbetrag sind nicht konsistent."
    if !_is_decimal($metadata{gross_total}) || !_is_decimal($metadata{tax_total})
       || abs($metadata{gross_total} - $metadata{net_total} - $metadata{tax_total}) > 0.01;

  die "Artikelbasierter XRechnungsimport abgebrochen; ungueltige Rechnungspositionen:\n- "
    . join("\n- ", @errors) if @errors;
}

sub _redirect_to_invoice_form {
  my ($self, $controller, $form_defaults, $file_name) = @_;

  my $res = _extract_invoice_data((_load_session_invoice($file_name))[0]);
  my $warning = _check_invoice_duplicates($form_defaults->{vendor_id}, $res);
  if ($warning) {
    $form_defaults->{intnotes} .= "\n" . $warning;
    flash_later("warning", $warning);
  }
  if ($controller eq 'ap.pl') {
    require SL::XMLTaxRounding;
    $form_defaults->{xml_tax_context_file} = SL::XMLTaxRounding->prepare(
      $res->{invoice_xml}, $form_defaults,
    );
  }
  $form_defaults->{zugferd_session_file} = $file_name;
  $form_defaults->{callback}             = $self->url_for(action => 'upload_zugferd');

  return $self->redirect_to(
    controller    => $controller,
    action        => 'load_zugferd',
    form_defaults => $form_defaults,
  );
}

sub _trim_value {
  my ($value) = @_;

  $value //= '';
  $value =~ s/^\s+|\s+$//g;
  return $value;
}

sub _normalized_name {
  my ($value) = @_;

  $value = lc(_trim_value($value));
  $value =~ s/ä/ae/g;
  $value =~ s/ö/oe/g;
  $value =~ s/ü/ue/g;
  $value =~ s/ß/ss/g;
  $value =~ s/[^\p{L}\p{N}]+/ /g;
  $value =~ s/\s+/ /g;
  return _trim_value($value);
}

sub _ilike_exact_pattern {
  my ($value) = @_;

  $value = _trim_value($value);
  $value =~ s/([\\%_])/\\$1/g;
  return $value;
}

sub _part_mapping_error {
  my ($part, $lookup_value) = @_;

  return "zugeordneter Artikel '$lookup_value' ist deaktiviert"
    if $part->obsolete;
  return "zugeordneter Artikel '$lookup_value' ist keine Ware/Dienstleistung"
    unless (($part->part_type // '') eq 'part') || (($part->part_type // '') eq 'service');
  return "zugeordneter Artikel '$lookup_value' ist nicht fuer den Einkauf freigegeben"
    if !$part->classification || !$part->classification->used_for_purchase;
  return undef;
}

sub _parts_for_mappings {
  my ($mappings) = @_;

  my %parts_by_id;
  foreach my $mapping (@{ $mappings || [] }) {
    next unless $mapping->parts_id;
    $parts_by_id{ $mapping->parts_id } ||= SL::DB::Manager::Part->find_by(
      id => $mapping->parts_id,
    );
  }
  return grep { $_ } values %parts_by_id;
}

sub _candidate_list_text {
  my (@parts) = @_;

  return join(', ', map {
    my @status;
    push @status, 'deaktiviert' if $_->obsolete;
    push @status, 'keine Ware/Dienstleistung'
      unless (($_->part_type // '') eq 'part') || (($_->part_type // '') eq 'service');
    push @status, 'nicht fuer Einkauf freigegeben'
      if !$_->classification || !$_->classification->used_for_purchase;

    ($_->partnumber // '?') . " - " . ($_->description // '')
      . (@status ? ' [' . join(', ', @status) . ']' : '')
  } sort {
    ($a->partnumber // '') cmp ($b->partnumber // '')
  } @parts);
}

sub _find_part_for_xml_item {
  my ($vendor_id, $item) = @_;

  my $vendor_partno = _trim_value($item->{vendor_partno});
  my $description   = _trim_value($item->{description});

  if ($vendor_partno ne '') {
    my $mappings = SL::DB::Manager::MakeModel->get_all(
      where => [ make => $vendor_id ],
    );
    $mappings = [ grep {
      _same_text_ci($_->model, $vendor_partno)
    } @{ $mappings } ];
    my @mapped_parts = _parts_for_mappings($mappings);
    my @valid_parts  = grep { !_part_mapping_error($_, $vendor_partno) } @mapped_parts;

    if (@mapped_parts > 1) {
      my $preferred_part = @valid_parts == 1 ? $valid_parts[0] : undef;
      return ($preferred_part, 'conflict',
        "mehrere Zuordnungen fuer Lieferanten-Art-Nr. '$vendor_partno' gefunden: "
        . _candidate_list_text(@mapped_parts));
    }
    return ($valid_parts[0], 'supplier_number', undef)
      if @valid_parts == 1;

    if (@mapped_parts) {
      return (undef, undef, _part_mapping_error($mapped_parts[0], $vendor_partno)
        || "Lieferanten-Art-Nr. '$vendor_partno' zeigt auf keine verwendbare Ware/Dienstleistung");
    }
    return (undef, undef,
      "Lieferanten-Art-Nr. '$vendor_partno' zeigt auf einen nicht mehr vorhandenen Artikel")
      if @{ $mappings };
  }

  if ($description ne '') {
    # A saved, supplier-specific description wins over a global article name.
    # This lets generic lines such as shipping be learned per supplier.
    my $description_mappings = SL::DB::Manager::MakeModel->get_all(where => [ make => $vendor_id ]);
    $description_mappings = [ grep {
         _same_text_ci($_->model, $description)
      || _same_text_ci($_->part_description, $description)
    } @{ $description_mappings } ];
    my @all_supplier_parts = _parts_for_mappings($description_mappings);
    my @supplier_parts = grep {
      !_part_mapping_error($_, $description)
    } @all_supplier_parts;

    if (@all_supplier_parts > 1) {
      my $preferred_part = @supplier_parts == 1 ? $supplier_parts[0] : undef;
      return ($preferred_part, 'conflict',
        "mehrere Lieferanten-Zuordnungen fuer Bezeichnung '$description' gefunden: "
        . _candidate_list_text(@all_supplier_parts));
    }
    return ($supplier_parts[0], 'supplier_description', undef)
      if @supplier_parts == 1;

    my $invalid_supplier_mapping = @all_supplier_parts
      ? "vorhandene Lieferanten-Zuordnung fuer Bezeichnung '$description' ist unbrauchbar: "
        . _candidate_list_text(@all_supplier_parts)
      : @{ $description_mappings }
      ? "vorhandene Lieferanten-Zuordnung fuer Bezeichnung '$description' zeigt auf einen nicht mehr vorhandenen Artikel"
      : undef;

    my $local_name_matches = SL::DB::Manager::Part->get_all(
      where => [ description => { ilike => _ilike_exact_pattern($description) } ],
    );
    my @local_parts = grep {
         _same_text_ci($_->description, $description)
      && !_part_mapping_error($_, $description)
    } @{ $local_name_matches };

    return (undef, undef, "mehrere aktive Artikel fuer Bezeichnung '$description' gefunden: "
      . _candidate_list_text(@local_parts)) if @local_parts > 1;
    return ($local_parts[0], 'local_description', $invalid_supplier_mapping)
      if @local_parts == 1;

    return (undef, undef, $invalid_supplier_mapping)
      if $invalid_supplier_mapping;

    my $number_hint = $vendor_partno ne ''
                    ? "Lieferanten-Art-Nr. '$vendor_partno' und "
                    : '';
    return (undef, undef, "keine Zuordnung fuer ${number_hint}Bezeichnung '$description' gefunden");
  }

  return (undef, undef, 'weder Lieferantenartikelnummer noch Bezeichnung vorhanden')
    if $vendor_partno eq '';
  return (undef, undef, "keine Zuordnung fuer Lieferanten-Art-Nr. '$vendor_partno' gefunden");
}

sub _mapping_tokens {
  my ($value) = @_;

  my %stopword = map { $_ => 1 } qw(
    der die das den dem ein eine einer eines und mit fuer von im in am zum zur
    stueck stck stk pack packung
  );
  my %tokens;
  foreach my $token (split /\s+/, _normalized_name($value)) {
    next if !$token || $stopword{$token} || $token =~ /^\d+er$/;
    $token = 'versand' if $token =~ /^(?:dhl|paket|porto|fracht|versand|versandkosten)$/;
    $tokens{$token} = 1;
  }
  return \%tokens;
}

sub _name_similarity {
  my ($left, $right) = @_;

  my $left_tokens  = _mapping_tokens($left);
  my $right_tokens = _mapping_tokens($right);
  my $left_count   = scalar keys %{ $left_tokens };
  my $right_count  = scalar keys %{ $right_tokens };
  return 0 unless $left_count && $right_count;

  my $intersection = scalar grep { $right_tokens->{$_} } keys %{ $left_tokens };
  return 0 unless $intersection;

  my $score = 0.35 * ($intersection / $left_count)
            + 0.55 * ($intersection / $right_count);
  my $left_normalized  = _normalized_name($left);
  my $right_normalized = _normalized_name($right);
  $score += 0.10 if index($left_normalized, $right_normalized) >= 0
                    || index($right_normalized, $left_normalized) >= 0;
  return $score > 1 ? 1 : $score;
}

sub _active_purchase_parts {
  my ($self) = @_;

  return $self->{_zugferd_active_purchase_parts}
    if $self->{_zugferd_active_purchase_parts};

  my $parts = SL::DB::Manager::Part->get_all(where => [
    or => [ obsolete => undef, obsolete => 0 ],
  ], with_objects => [ 'classification' ]);
  $self->{_zugferd_active_purchase_parts} = [ grep {
    !_part_mapping_error($_, $_->partnumber // '')
  } @{ $parts } ];
  return $self->{_zugferd_active_purchase_parts};
}

sub _suggest_parts {
  my ($self, $description) = @_;

  my @candidates = sort {
       $b->{score} <=> $a->{score}
    || ($a->{part}->partnumber // '') cmp ($b->{part}->partnumber // '')
  } grep {
    $_->{score} >= 0.20
  } map {
    +{ part => $_, score => _name_similarity($description, $_->description) }
  } @{ $self->_active_purchase_parts };

  splice @candidates, 5 if @candidates > 5;
  $_->{score_text} = sprintf('%.0f %%', $_->{score} * 100) for @candidates;

  my $suggested_part;
  if (@candidates && $candidates[0]->{score} >= 0.78) {
    my $distance = @candidates > 1
                 ? $candidates[0]->{score} - $candidates[1]->{score}
                 : 1;
    $suggested_part = $candidates[0]->{part} if $distance >= 0.15;
  }

  return (\@candidates, $suggested_part);
}

sub _mapping_method_label {
  my ($method) = @_;

  return 'Gespeicherte Lieferanten-Art.-Nr.'         if ($method // '') eq 'supplier_number';
  return 'Gespeicherte Lieferantenbezeichnung'       if ($method // '') eq 'supplier_description';
  return 'Exakter Kivitendo-Artikelname; noch nicht gespeichert'
                                                       if ($method // '') eq 'local_description';
  return 'Automatischer Namensvorschlag; bitte pruefen' if ($method // '') eq 'suggestion';
  return 'Widerspruechliche Zuordnung; bitte bestaetigen' if ($method // '') eq 'conflict';
  return 'Noch nicht zugeordnet';
}

sub _build_mapping_rows {
  my ($self, $vendor_id, $items) = @_;

  my @rows;
  my $needs_mapping = 0;
  my $row = 0;
  foreach my $item_ref (@{ $items || [] }) {
    $row++;
    my %item = %{ $item_ref };
    my ($part, $method, $mapping_error) = _find_part_for_xml_item($vendor_id, \%item);
    my $vendor_partno = _trim_value($item{vendor_partno});
    my ($candidates, $suggested_part) = ([], undef);

    my $row_needs_mapping = !!$mapping_error
                         || ($method // '') ne 'supplier_number'
                         || ($vendor_partno ne '' && ($method // '') ne 'supplier_number');

    if ($mapping_error && !$part) {
      ($candidates, $suggested_part) = $self->_suggest_parts($item{description});
      if ($suggested_part) {
        $part   = $suggested_part;
        $method = 'suggestion';
      }
    }

    $needs_mapping ||= $row_needs_mapping;
    push @rows, {
      row             => $row,
      vendor_partno   => $vendor_partno,
      description     => _trim_value($item{description}),
      quantity        => $item{quantity},
      subtotal        => $item{subtotal},
      tax_rate        => $item{tax_rate},
      selected_part   => $part,
      method           => $method,
      method_label     => _mapping_method_label($method),
      mapping_error    => $mapping_error,
      candidates       => $candidates,
      requires_mapping => $row_needs_mapping,
    };
  }

  return (\@rows, $needs_mapping);
}

sub _render_mapping_form {
  my ($self, %params) = @_;

  my $selected_parts = $params{selected_parts} || {};
  foreach my $row (@{ $params{rows} || [] }) {
    $row->{selected_part} = $selected_parts->{ $row->{row} }
      if $selected_parts->{ $row->{row} };
  }

  $self->setup_mapping_action_bar;
  return $self->render(
    'zugferd/mapping',
    title        => 'XRechnung: Artikel zuordnen',
    vendor       => $params{vendor},
    rows         => $params{rows},
    session_file => $params{session_file},
  );
}

sub _same_text_ci {
  my ($left, $right) = @_;
  return lc(_trim_value($left)) eq lc(_trim_value($right));
}

sub _supplier_key {
  my ($item) = @_;
  my $number = _trim_value($item->{vendor_partno});
  return ($number ne '' ? 'number:' . lc($number) : 'name:' . lc(_trim_value($item->{description})));
}

sub _store_supplier_mapping {
  my ($vendor_id, $part, $item) = @_;
  my $number = _trim_value($item->{vendor_partno});
  my $description = _trim_value($item->{description});
  die "Lieferantenschluessel fehlt." if $number eq '' && $description eq '';
  # Called under a table lock inside the mapping transaction. Do not delete or
  # overwrite prices, descriptions or another article's existing supplier key.
  my $rows = SL::DB::Manager::MakeModel->get_all(where => [ make => $vendor_id ]);
  my @matching = grep {
    $number ne '' ? _same_text_ci($_->model, $number)
                 : _same_text_ci($_->part_description, $description)
                   || _same_text_ci($_->model, $description)
  } @$rows;
  die "Bestehende Lieferanten-Zuordnung widerspricht der Auswahl. Bitte Artikelstammdaten pruefen."
    if grep { !$_->parts_id || $_->parts_id != $part->id } @matching;
  return if @matching; # Idempotent; preserve existing rows, including prices.
  my $last = max(0, map { $_->sortorder || 0 } grep { $_->parts_id == $part->id } @$rows);
  SL::DB::MakeModel->new(
    parts_id => $part->id, make => $vendor_id, model => $number,
    part_description => $description, sortorder => $last + 1,
  )->save;
  if (!$part->makemodel) {
    $part->makemodel(1);
    $part->save(changes_only => 1);
  }
}

sub action_save_mapping {
  my ($self) = @_;

  $::auth->assert('vendor_invoice_edit');
  $::auth->assert('part_service_assembly_edit');

  my $file_name = $::form->{mapping_session_file};
  my ($file, $res);
  my $loaded = eval {
    ($file) = _load_session_invoice($file_name);
    $res    = _extract_invoice_data($file);
    1;
  };
  return $self->_redirect_import_error($@ || 'Sitzungsdatei konnte nicht gelesen werden')
    unless $loaded;
  my $vendor     = _find_invoice_vendor($res);
  _check_invoice_duplicates($vendor->id, $res);
  _assert_valid_purchase_invoice_items($res);
  my @items      = @{ $res->{invoice_xml}->items };

  my (@selected_parts, %selected_by_row, @errors);
  foreach my $index (0 .. $#items) {
    my $row     = $index + 1;
    my $part_id = $::form->{"mapping_part_id_$row"};
    $part_id = undef unless defined($part_id) && $part_id =~ /^[1-9][0-9]*$/;
    my $label   = _trim_value($items[$index]->{vendor_partno})
               || _trim_value($items[$index]->{description})
               || "Position $row";

    if (_trim_value($items[$index]->{vendor_partno}) eq ''
        && _trim_value($items[$index]->{description}) eq '') {
      push @errors, "Position $row: Lieferanten-Art.-Nr. und Bezeichnung fehlen; eine dauerhafte Zuordnung ist nicht moeglich.";
      next;
    }

    if (!$part_id) {
      push @errors, "Position $row ($label): Bitte einen Kivitendo-Artikel auswaehlen.";
      next;
    }

    my $part = SL::DB::Manager::Part->find_by(id => $part_id);
    if (!$part) {
      push @errors, "Position $row ($label): Der ausgewaehlte Artikel existiert nicht.";
      next;
    }

    my $part_error = _part_mapping_error($part, $part->partnumber // $part_id);
    if ($part_error) {
      push @errors, "Position $row ($label): $part_error";
      next;
    }

    $selected_parts[$index] = $part;
    $selected_by_row{$row}  = $part;
  }

  my %targets;
  foreach my $index (0 .. $#items) {
    next unless $selected_parts[$index];
    my $key = _supplier_key($items[$index]);
    my $id = $selected_parts[$index]->id;
    push @errors, "Derselbe Lieferantenschluessel wurde verschiedenen Artikeln zugeordnet."
      if exists($targets{$key}) && $targets{$key} != $id;
    $targets{$key} = $id;
  }

  if (@errors) {
    flash('error', @errors);
    my ($rows) = $self->_build_mapping_rows($vendor->id, \@items);
    return $self->_render_mapping_form(
      vendor         => $vendor,
      rows           => $rows,
      session_file   => $file_name,
      selected_parts => \%selected_by_row,
    );
  }

  my $db = $selected_parts[0]->db;
  my $form_defaults;
  my $ok = $db->with_transaction(sub {
    $db->dbh->do("LOCK TABLE makemodel IN SHARE ROW EXCLUSIVE MODE");
    foreach my $index (0 .. $#items) {
      _store_supplier_mapping($vendor->id, $selected_parts[$index], $items[$index]);
    }
    $form_defaults = $self->build_purchase_invoice_form_defaults($res, vendor => $vendor);
    return 1;
  });
  die "Lieferanten-Zuordnungen konnten nicht gespeichert werden: " . ($db->error // '')
    unless $ok;

  my $message = 'Die bestaetigten Lieferanten-Zuordnungen wurden gespeichert.';
  flash_later('ok', $message);
  return $self->_redirect_to_invoice_form('ir.pl', $form_defaults, $file_name);
}

sub _purchase_invoice_uses_gross_prices {
  my ($parser) = @_;
  my @items = @{ $parser->items };
  return 0 unless @items == 1;
  my $metadata = $parser->metadata;
  my $rate = $items[0]->{tax_rate} / 100;
  my $net = $metadata->{net_total};
  my $tax = $metadata->{tax_total};
  my $gross = $metadata->{gross_total};
  return 0 if abs($::form->round_amount($net * $rate, 2) - $tax) < 0.005;

  # A single invoice line can be represented exactly as a gross-price line.
  # Reproduce IR.pm's gross tax calculation, not a guessed rounding adjustment.
  my $gross_tax = $::form->round_amount($gross * $rate / (1 + $rate), 2);
  die "Rechnungssummen lassen sich weder mit Netto- noch mit Bruttopreisen exakt darstellen."
    if abs($gross_tax - $tax) >= 0.005
    || abs($::form->round_amount($gross - $gross_tax, 2) - $net) >= 0.005;
  return 1;
}

sub build_purchase_invoice_form_defaults {
  my ($self, $data, %params) = @_;
  _assert_valid_purchase_invoice_items($data);

  my $parser       = $data->{invoice_xml};
  my %metadata     = %{ $parser->metadata };
  my @items        = @{ $parser->items };
  my $use_gross_prices = _purchase_invoice_uses_gross_prices($parser);
  my $form_defaults = $self->build_ap_transaction_form_defaults($data, %params);

  die "Die XRechnung enthaelt keine Rechnungspositionen." unless @items;

  die "Artikelbasierter Import unterstuetzt derzeit nur Rechnungen (TypeCode 380)."
    unless ($metadata{type} // '') eq '380';

  my @mapping_errors;
  my @mapping_notes;
  my %item_form;
  my $row = 0;

  foreach my $item_ref (@items) {
    $row++;
    my %item = %{ $item_ref };
    my $label = _trim_value($item{vendor_partno}) || _trim_value($item{description}) || "Position $row";

    if (!looks_like_number($item{quantity}) || !$item{quantity}) {
      push @mapping_errors, "Position $row ($label): ungueltige oder leere Menge";
      next;
    }
    if (!looks_like_number($item{subtotal})) {
      push @mapping_errors, "Position $row ($label): ungueltige Positionssumme";
      next;
    }
    if (!looks_like_number($item{tax_rate})) {
      push @mapping_errors, "Position $row ($label): ungueltiger Steuersatz";
      next;
    }

    my ($part, $mapping_method, $mapping_error) =
      _find_part_for_xml_item($form_defaults->{vendor_id}, \%item);

    if ($mapping_error) {
      push @mapping_errors, "Position $row ($label): $mapping_error";
      next;
    }

    my $quantity     = $item{quantity} * 1;
    my $line_total   = ($use_gross_prices ? $metadata{gross_total} : $item{subtotal}) * 1;
    my $price_factor = ($part->price_factor_id && $part->price_factor)
                     ? $part->price_factor->factor
                     : 1;
    my $unit_price   = $line_total * $price_factor / $quantity;
    die "Brutto-Einzelpreis kann mit der verwendeten Menge/Preiseinheit nicht centgenau dargestellt werden."
      if $use_gross_prices
      && abs($::form->round_amount($::form->round_amount($unit_price, 5) * $quantity / $price_factor, 2) - $line_total) >= 0.005;
    my $tax_rate     = $item{tax_rate} * 1;
       $tax_rate    /= 100; # XML Percent is always a percentage, including 0.5 and 1.

    $item_form{"id_${row}"}                     = $part->id;
    $item_form{"partnumber_${row}"}             = $part->partnumber;
    $item_form{"description_${row}"}            = _trim_value($item{description}) || $part->description;
    $item_form{"qty_${row}"}                    = $::form->format_amount(\%::myconfig, $quantity, 5);
    $item_form{"sellprice_${row}"}              = $::form->format_amount(\%::myconfig, $unit_price, 5);
    $item_form{"discount_${row}"}               = $::form->format_amount(\%::myconfig, 0, 2);
    $item_form{"unit_${row}"}                   = $part->unit;
    $item_form{"part_type_${row}"}              = $part->part_type;
    $item_form{"price_factor_id_${row}"}         = $part->price_factor_id;
    $item_form{"_zugferd_tax_rate_${row}"}       = $tax_rate;
    my $xml_description = _trim_value($item{description});
    my $mapped_by_description = ($mapping_method // '') ne 'supplier_number';
    my $mapping_status  = ($mapping_method // '') eq 'supplier_description'
                        ? 'Gespeicherte Lieferantenbezeichnung'
                        : $mapped_by_description
                        ? 'NAMENSSUCHE - bitte pruefen'
                        : _normalized_name($xml_description) ne _normalized_name($part->description)
                        ? 'LIEFERANTEN-ART-NR.; Bezeichnungen weichen ab - bitte pruefen'
                        : 'Lieferanten-Art-Nr.';

    $item_form{"_zugferd_mapping_info_${row}"}   = sprintf(
      "Position %d: XML '%s'%s => Kivitendo %s - %s [%s]",
      $row,
      $xml_description || '(ohne Bezeichnung)',
      _trim_value($item{vendor_partno}) ne '' ? " / " . _trim_value($item{vendor_partno}) : '',
      $part->partnumber // '?',
      $part->description // '',
      $mapping_status,
    );

    if ($mapped_by_description) {
      my $reason = _trim_value($item{vendor_partno}) ne ''
                 ? "Lieferanten-Art-Nr. '" . _trim_value($item{vendor_partno}) . "' war nicht zugeordnet"
                 : 'Lieferanten-Art-Nr. fehlte';
      push @mapping_notes,
        "Position $row wurde ueber die exakte Bezeichnung '"
        . _trim_value($item{description}) . "' zugeordnet ($reason).";
    }
  }

  if (@mapping_errors) {
    die "Artikelbasierter XRechnungsimport abgebrochen. Bitte zuerst die Lieferantenpreise/"
      . "Lieferanten-Art-Nr. in den Artikelstammdaten korrigieren:\n- "
      . join("\n- ", @mapping_errors);
  }

  # Remove the amount rows created for the standard AP transaction import.
  delete $form_defaults->{$_} for grep {
    /^(?:AP_amount_chart_id_|previous_AP_amount_chart_id_|amount_|taxchart_)/
  } keys %{ $form_defaults };

  my $invdate = delete $form_defaults->{transdate};
  delete @{ $form_defaults }{qw(no_payment_bookings paid_1_suggestion)};

  $form_defaults->{intnotes} .= "\n" . join("\n", @mapping_notes) if @mapping_notes;
  $form_defaults->{intnotes} .= "\nMengeneinheiten: XML-Mengen werden in der lokalen Artikeleinheit verwendet. Keine automatische Gebindeumrechnung; vor dem Buchen pruefen.";
  $form_defaults->{intnotes} .= $use_gross_prices
    ? "\nBruttopreis automatisch aus Original-Gesamtbetrag uebernommen; Steuer im Preis inbegriffen. Original-Netto-, Steuer- und Bruttosumme wurden rechnerisch abgeglichen."
    : "\nNetto-Einzelpreise wurden fuer den Import aus Positionssumme / Menge berechnet.";

  return {
    %{ $form_defaults },
    %item_form,
    invdate                 => $invdate,
    rowcount                => $row,
    paidaccounts            => 1,
    type                    => 'purchase_invoice',
    taxincluded             => $use_gross_prices ? 1 : 0,
    transaction_description => 'XRechnung ' . ($metadata{invnumber} // ''),
  };
}

sub setup_mapping_action_bar {
  my ($self) = @_;

  for my $bar ($::request->layout->get('actionbar')) {
    $bar->add(
      action => [
        'Zuordnungen speichern und fortfahren',
        submit    => [ '#form', { action => 'ZUGFeRD/save_mapping' } ],
        checks    => [ 'kivi.validate_form' ],
        accesskey => 'enter',
      ],
      link => [
        'Abbrechen',
        link => $self->url_for(action => 'upload_zugferd'),
      ],
    );
  }
}

sub build_ap_transaction_form_defaults {
  my ($self, $data, %params) = @_;
  my $vendor = $params{vendor};

  my $parser = $data->{'invoice_xml'};

  my %metadata = %{$parser->metadata};
  my @items = @{$parser->items};

  my $intnotes = t8("ZUGFeRD Import. Type: #1", $metadata{'type'})->translated;
  $intnotes .= "\nPDF-Texterkennung: Werte vom Benutzer anhand des Originals bestaetigt. Original-PDF separat am Beleg ablegen; keine elektronische Originalrechnung." if $data->{pdf_vendor_id};
  my $iban = $metadata{'iban'};
  my $invnumber = $metadata{'invnumber'};

  if ($vendor) {
    if ($metadata{'ustid'} && $vendor->ustid && ($metadata{'ustid'} ne $vendor->ustid)) {
      $intnotes .= "\n" . t8('USt-IdNr.') . ': '
      . t8("Record VAT ID #1 doesn't match vendor VAT ID #2", $metadata{'ustid'}, $vendor->ustid);
    }
    if ($metadata{'taxnumber'} && $vendor->taxnumber && ($metadata{'taxnumber'} ne $vendor->taxnumber)) {
      $intnotes .= "\n" . t8("Tax Number") . ': '
      . t8("Record tax ID #1 doesn't match vendor tax ID #2", $metadata{'taxnumber'}, $vendor->taxnumber);
    }
  } else {
    if ( ! ($metadata{'ustid'} or $metadata{'taxnumber'}) ) {
      die t8("Cannot process this invoice: neither VAT ID nor tax ID present.");
    }

    $vendor = SL::ZUGFeRD::find_vendor($metadata{'ustid'}, $metadata{'taxnumber'});

    die t8("Vendor with VAT ID (#1) and/or tax ID (#2) not found. Please check if the vendor " .
            "#3 exists and whether it has the correct tax ID/VAT ID." ,
             $metadata{'ustid'},
             $metadata{'taxnumber'},
             $metadata{'vendor_name'},
    ) unless $vendor;
  }


  # Check IBAN specified on bill matches the one we've got in
  # the database for this vendor.
  if ($iban) {
    $intnotes .= "\nIBAN: ";
    $intnotes .= $iban ne $vendor->iban ?
          t8("Record IBAN #1 doesn't match vendor IBAN #2", $iban, $vendor->iban)
        : $iban
  }

  # Use invoice creation date as due date if there's no due date
  $metadata{'duedate'} = $metadata{'transdate'} unless defined $metadata{'duedate'};

  # parse dates to kivi if set/valid
  foreach my $key ( qw(transdate duedate) ) {
    next unless defined $metadata{$key};
    $metadata{$key} =~ s/^\s+|\s+$//g;

    if ($metadata{$key} =~ /^([0-9]{4})-?([0-9]{2})-?([0-9]{2})$/) {
    $metadata{$key} = DateTime->new(year  => $1,
                                    month => $2,
                                    day   => $3)->to_kivitendo;
    }
  }

  # Try to fill in AP account to book against
  my $ap_chart_id = $::instance_conf->get_ap_chart_id;

  unless ( defined $ap_chart_id ) {
    # If no default account is configured, just use the first AP account found.
    my ($ap_chart) = @{SL::DB::Manager::Chart->get_all(
      where   => [ link => 'AP' ],
      sort_by => [ 'accno' ],
    )};
    $ap_chart_id = $ap_chart->id;
  }

  my $currency = SL::DB::Manager::Currency->find_by(
    name => $metadata{'currency'},
    );

  my $default_ap_amount_chart = SL::DB::Manager::Chart->find_by(
    id => $::instance_conf->get_expense_accno_id
  );
  # Fallback if there's no default AP amount chart configured
  $default_ap_amount_chart ||= SL::DB::Manager::Chart->find_by(charttype => 'A');

  my $active_taxkey = $default_ap_amount_chart->get_active_taxkey;
  my $taxes = SL::DB::Manager::Tax->get_all(
    where   => [ chart_categories => {
        like => '%' . $default_ap_amount_chart->category . '%'
      }],
    sort_by => 'taxkey, rate',
  );
  die t8(
    "No tax found for chart #1", $default_ap_amount_chart->displayable_name
  ) unless scalar @{$taxes};


  my %item_form = ();
  if ($self->use_totals_for_ap_transaction($parser)) {
    # use tax totals instead to fill in the ap lines

    my $tax_totals = $parser->tax_totals;

    my $row = 0;
    for my $tax_row (@$tax_totals) {
      $row++;

      my $tax;
      if ($tax_row->{category_code} =~ /S/) {
        # Standard tax
        my $tax_rate = $tax_row->{tax_rate} / 100;
        $tax = first { $tax_rate == $_->rate } @$taxes;
        die t8('Can not find a tax for tax rate #1', $tax_rate) unless $tax;
      } elsif ($tax_row->{category_code} =~ /[ZE]/) {
        # Zero tax or tax Exempt
        $tax = first { 0 == $_->rate } @$taxes;
        die t8('Can not find a tax for tax rate #1', 0) unless $tax;
      } else {
        die t8('Tax category code #1 is not supported at the moment', $tax_row->{category_code});
      }

      $item_form{"AP_amount_chart_id_${row}"}          = $default_ap_amount_chart->id;
      $item_form{"previous_AP_amount_chart_id_${row}"} = $default_ap_amount_chart->id;
      $item_form{"amount_${row}"}                      = _format_total($tax_row->{net_amount});
      $item_form{"taxchart_${row}"}                    = $tax->id . '--' . $tax->rate;
    }

    # special case: untaxed positions like deposit don't show up in the tax blocks
    # invariant:
    # net_amount + tax + [UntaxedAmount] = amount

    my $untaxed_delta = $metadata{gross_total} - $metadata{net_total} - $metadata{tax_total};
    if ($untaxed_delta > 0.005) {
      $row++;

      # Zero tax or tax Exempt
      my $tax = first { 0 == $_->rate } @$taxes;
      die t8('Can not find a tax for tax rate #1', 0) unless $tax;

      $item_form{"AP_amount_chart_id_${row}"}          = $default_ap_amount_chart->id;
      $item_form{"previous_AP_amount_chart_id_${row}"} = $default_ap_amount_chart->id;
      $item_form{"amount_${row}"}                      = _format_total($untaxed_delta);
      $item_form{"taxchart_${row}"}                    = $tax->id . '--' . $tax->rate;
    }

    $item_form{rowcount} = $row;

  } else {
    # else: try to replicate the items in the ap transaction

    # parse items
    my $row = 0;
    foreach my $i (@items) {
      $row++;

      my %item = %{$i};

      my $net_total = $::form->format_amount(\%::myconfig, $item{'subtotal'}, 2);

      my $tax_rate = $item{'tax_rate'};
      $tax_rate /= 100 if $tax_rate > 1; # XML data is usually in percent

      my $tax   = first { $tax_rate              == $_->rate } @{ $taxes };
      $tax    //= first { $active_taxkey->tax_id == $_->id }   @{ $taxes };
      $tax    //= $taxes->[0];

      $item_form{"AP_amount_chart_id_${row}"}          = $default_ap_amount_chart->id;
      $item_form{"previous_AP_amount_chart_id_${row}"} = $default_ap_amount_chart->id;
      $item_form{"amount_${row}"}                      = $net_total;
      $item_form{"taxchart_${row}"}                    = $tax->id . '--' . $tax->rate;
    }
    $item_form{rowcount} = $row;
  }

  return {
    vendor_id            => $vendor->id,
    vendor               => $vendor->name,
    invnumber            => $invnumber,
    transdate            => $metadata{'transdate'},
    duedate              => $metadata{'duedate'},
    no_payment_bookings  => 0,
    intnotes             => $intnotes,
    taxincluded          => 0,
    direct_debit         => $metadata{'direct_debit'},
    currency             => $currency->name,
    AP_chart_id          => $ap_chart_id,
    paid_1_suggestion    => $::form->format_amount(\%::myconfig, $metadata{'total'}, 2),
    %item_form,
  },
}

sub use_totals_for_ap_transaction {
  my ($self, $parser) = @_;

  return 0 if !$parser->can('tax_totals');

  return $::instance_conf->get_zugferd_ap_transaction_use_totals;
}

sub check_auth {
  $::auth->assert('ap_transactions');
}
sub setup_zugferd_action_bar {
  my ($self) = @_;

  for my $bar ($::request->layout->get('actionbar')) {
    $bar->add(
      action => [
        $::locale->text('Import'),
        submit    => [ '#form', { action => 'ZUGFeRD/import_zugferd' } ],
        accesskey => 'enter',
      ],
    );
  }
}

sub pre_render {
  my ($self) = @_;

  $::request->{layout}->use_javascript("${_}.js") for qw(
    kivi.ZUGFeRD
  );

  $self->setup_zugferd_action_bar;
}


1;
__END__

=pod

=encoding utf8

=head1 NAME

SL::Controller::ZUGFeRD - Controller for importing ZUGFeRD PDF files or XML invoices to kivitendo

=head1 FUNCTIONS

=over 4

=item C<action_upload_zugferd>

Creates a web from with a single upload dialog.

=item C<action_import_zugferd $file>

Expects a single PDF with ZUGFeRD, Factur-X or XRechnung
metadata. Alternatively, it can also process said data as a
standalone XML file.

Checks if the param <C$pdf> is set and a valid PDF or XML
file. Calls helper functions to validate and extract the
ZUGFeRD/Factur-X/XRechnung data. The invoice needs to have a
valid VAT ID (EU) or tax number (Germany) and a vendor with
the same VAT ID or tax number enrolled in Kivitendo.

It parses some basic ZUGFeRD data (invnumber, total net amount,
transdate, duedate, vendor VAT ID, IBAN, etc.) and also
extracts the invoice's items.

If the invoice has a IBAN also, it will be be compared to the
IBAN saved for the vendor (if any). If they  don't match a
warning will be writte in ap.intnotes. Furthermore the ZUGFeRD
type code will be written to ap.intnotes. No callback
implemented.

=back

=head1 CAVEAT

This is just a very basic Parser for ZUGFeRD/Factur-X/XRechnung invoices.
We assume that the invoice's creator is a company with a valid
European VAT ID or German tax number and enrolled in
Kivitendo.

=head1 TODO

This implementation could be improved as follows:

=over 4

=item Automatic upload of invoice

Right now, one has to use the "Book and upload" button to
upload the raw invoice document to WebDAV or DMS and attach it
to the invoice. This should be a simple matter of setting a
check box when uploading.

=item Handling of vendor invoices

There is no reason this functionality could not be used to
import vendor invoices as well. Since these tend to be very
lengthy, the ability to import them would be very beneficial.

=item Automatic handling of payment purpose

If the ZUGFeRD data has a payment purpose set, this should
be the default for the SEPA-XML export.

=back

=head1 AUTHORS

=over 4

=item Jan Büren E<lt>jan@kivitendo-premium.deE<gt>,

=item Johannes Graßler E<lt>info@computer-grassler.deE<gt>,

=back

=cut
