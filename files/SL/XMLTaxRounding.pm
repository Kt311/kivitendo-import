package SL::XMLTaxRounding;
use strict;
use warnings;
use utf8;
use JSON::PP ();
use Math::BigRat;
use Digest::SHA qw(sha256_hex);

# All decisions use rational numbers/integer cents, never binary float equality.
sub _number {
  my ($v) = @_;
  $v =~ s/^\s+|\s+$//g if defined($v);
  die "XML-Steuerabgleich: ungueltiger Zahlenwert." unless defined($v)
    && "$v" =~ /^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$/;
  return Math::BigRat->new("$v");
}
sub _cents {
  my $v = _number($_[0])->bmul(100);
  die "XML-Steuerabgleich: Betrag hat mehr als zwei Nachkommastellen."
    unless $v->denominator->is_one;
  return 0 + $v->numerator->bstr;
}
sub _rate {
  my $r = _number($_[0]);
  die "XML-Steuerabgleich: ungueltiger Steuersatz." if $r < 0 || $r > 1;
  return $r->bstr;
}
sub _round_cents {
  my ($net, $rate) = @_;
  my $r = _number($net)->bmul(Math::BigRat->new($rate));
  my $sign = $r < 0 ? -1 : 1;
  return $sign * (0 + $r->babs->badd('1/2')->bfloor->bstr);
}
sub _json { JSON::PP->new->canonical->utf8 }

sub context {
  my ($class, $parser, $form) = @_;
  my $m = $parser->metadata;
  return undef unless ($m->{type} // '') eq '380' && $parser->can('tax_totals');
  my $taxes = $parser->tax_totals;
  return undef unless $taxes && @$taxes;
  my %groups;
  for my $t (@$taxes) {
    die "XML-Steuerabgleich: Steuerkategorie nicht unterstuetzt."
      unless ($t->{category_code} // '') =~ /^(S|Z|E)$/ && ($t->{type_code} // '') eq 'VAT';
    my $key = _rate(_number($t->{tax_rate})->bdiv(100)->as_float(12)->bstr);
    my $g = $groups{$key} ||= { net => 0, tax => 0 };
    $g->{net} += _cents($t->{net_amount});
    $g->{tax} += _cents($t->{tax_amount} // $t->{amount});
  }
  my ($net, $tax) = (0, 0);
  for my $key (keys %groups) {
    my $g = $groups{$key};
    die "XML-Steuerabgleich: Steuerbetrag weicht um mehr als einen Cent von der Steuerbasis ab."
      if abs($g->{tax} - _round_cents($g->{net}, $key)) > 1;
    die "XML-Steuerabgleich: Steuerbetrag bei Steuersatz null." if $key eq '0' && $g->{tax};
    $net += $g->{net}; $tax += $g->{tax};
  }
  die "XML-Steuerabgleich: Steueraufteilung und Rechnungssummen passen nicht zusammen."
    unless $net == _cents($m->{net_total}) && $tax == _cents($m->{tax_total})
        && $net + $tax == _cents($m->{gross_total});
  return { version => 1, vendor_id => $form->{vendor_id}, invnumber => $form->{invnumber},
    currency => $form->{currency}, groups => \%groups, net => $net, tax => $tax };
}

sub prepare {
  my ($class, $parser, $form) = @_;
  my $context = $class->context($parser, $form);
  return undef unless $context;
  my $json = _json()->encode($context);
  my $name = 'xml-tax-' . sha256_hex($json) . '.json';
  require SL::SessionFile;
  my $file = SL::SessionFile->new($name, mode => 'w');
  die "XML-Steuerabgleich: Sitzungsdatei konnte nicht geschrieben werden." unless $file->fh;
  $file->fh->print($json) or die "XML-Steuerabgleich: Schreiben fehlgeschlagen.";
  $file->fh->close or die "XML-Steuerabgleich: Schliessen fehlgeschlagen.";
  return $name;
}

sub load {
  my ($class, $form, %params) = @_;
  # Posted invoices retain their original context independently of session expiry
  # or browser fields. Use the booking transaction's handle when supplied.
  if ($form->{id}) {
    require SL::DB unless $params{dbh};
    my $dbh = $params{dbh} || SL::DB->client->dbh;
    my ($json) = $dbh->selectrow_array('SELECT xml_tax_context FROM ap WHERE id = ?', undef, $form->{id});
    return (_json()->decode($json), $json) if defined($json) && length($json);
  }
  my $name = $form->{xml_tax_context_file};
  return () unless defined($name) && length($name);
  die "XML-Steuerabgleich: ungueltige Sitzungsdatei." unless $name =~ /^xml-tax-([a-f0-9]{64})\.json$/;
  my $digest = $1;
  require SL::SessionFile;
  my $file = SL::SessionFile->new($name, mode => '<');
  die "XML-Steuerabgleich: Sitzung abgelaufen; Rechnung erneut importieren." unless $file->fh;
  local $/;
  my $json = readline($file->fh);
  $file->fh->close;
  die "XML-Steuerabgleich: Sitzungsdaten beschaedigt." unless defined($json) && sha256_hex($json) eq $digest;
  return (_json()->decode($json), $json);
}

sub apply {
  my ($class, $form, %params) = @_;
  my ($context, $json) = $class->load($form, %params);
  return () unless $context;
  my $tax = $class->reconcile($form, $context, %params);
  return ($tax, $json);
}

sub reconcile {
  my ($class, $form, $context, %params) = @_;
  my $sign = $params{signed} ? -1 : 1;
  die "XML-Steuerabgleich: Belegdaten wurden gegenueber dem Import geaendert."
    unless ($context->{version} // 0) == 1
      && ($form->{vendor_id} // '') eq ($context->{vendor_id} // '')
      && ($form->{invnumber} // '') eq ($context->{invnumber} // '')
      && ($form->{currency} // '') eq ($context->{currency} // '')
      && !$form->{taxincluded};
  die "XML-Steuerabgleich: Fremdwaehrungsumrechnung wird noch nicht unterstuetzt."
    if ($params{signed} && _number($form->{exchangerate} // 1) != 1)
    || (defined($form->{defaultcurrency}) && length($form->{defaultcurrency})
        && $form->{defaultcurrency} ne $form->{currency});
  my %actual;
  for my $i (1 .. ($form->{rowcount} || 0)) {
    my $net = $sign * _cents($form->{"amount_$i"} // 0);
    next unless $net;
    my (undef, $rate) = split /--/, ($form->{"taxchart_$i"} // '');
    my $key = _rate($rate);
    my $g = $actual{$key} ||= { net => 0, tax => 0, rows => [] };
    my $tax = $sign * _cents($form->{"tax_$i"} // 0);
    # Rows must have been calculated by kivitendo, not supplied as tax overrides.
    die "XML-Steuerabgleich: unerwarteter Steuerbetrag in Buchungszeile."
      if abs($tax - _round_cents($net, $key)) > 1;
    $g->{net} += $net; $g->{tax} += $tax;
    push @{ $g->{rows} }, { i => $i, net => $net, tax => $tax };
  }
  my %keys = map { $_ => 1 } (keys %actual, keys %{ $context->{groups} });
  my @changes;
  my $total = 0;
  for my $key (sort keys %keys) {
    my $actual_group = $actual{$key} || { net => 0, tax => 0, rows => [] };
    my $g = $context->{groups}{$key};
    die "XML-Steuerabgleich: Nettobetraege oder Steuersaetze passen nicht mehr zur XML."
      unless $g && $actual_group->{net} == $g->{net};
    my $delta = $g->{tax} - $actual_group->{tax};
    die "XML-Steuerabgleich: Differenz ist groesser als eine Rundungsabweichung."
      if abs($delta) > @{ $actual_group->{rows} } || ($key eq '0' && $delta);
    # At most one cent per row; preserve net amounts, accounts and tax keys.
    my $step = $delta < 0 ? -1 : 1;
    for my $row (sort { abs($b->{net}) <=> abs($a->{net}) || $a->{i} <=> $b->{i} } @{ $actual_group->{rows} }) {
      last unless $delta;
      push @changes, [ $row->{i}, $sign * ($row->{tax} + $step) / 100 ];
      $delta -= $step;
    }
    $total += $sign * $g->{tax};
  }
  # Validation completes before any row is mutated.
  $form->{'tax_' . $_->[0]} = $_->[1] for @changes;
  return $total / 100;
}
1;
