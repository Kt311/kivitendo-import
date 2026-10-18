package SL::SalesReport;
use strict;
use warnings;
use utf8;
use JSON::PP ();
use Digest::SHA qw(sha256_hex);
use Encode qw(encode);
use File::Temp qw(tempfile);
use IPC::Run qw(run timeout);
use SL::DB;
use SL::DB::Part;
use DateTime;
use SL::Helper::DateTime;

sub json { JSON::PP->new->canonical }
sub version { sha256_hex($_[0]->{content_hash} . $_[0]->{mapping}) }
sub dbh { SL::DB->client->dbh }
sub analyze {
  my ($bytes, $year) = @_;
  $year //= ''; $year =~ s/^\s+|\s+$//g;
  die "Bitte eine Datei bis 50 MiB auswaehlen." unless length($bytes // '') && length($bytes) <= 50*1024*1024;
  die "Jahr bitte vierstellig angeben." if length($year // '') && $year !~ /^20\d\d$/;
  my ($fh,$path)=tempfile(UNLINK=>1); binmode $fh; print {$fh} $bytes; close $fh;
  my ($out,$err,$stdin)=('','',''); my @cmd=('python3','scripts/sales_report_import.py',$path,$year // '');
  my $ok=run \@cmd, \$stdin, \$out, \$err, timeout(100);
  my $data=eval { JSON::PP->new->utf8->decode($out) };
  die "Verkaufsbericht konnte nicht gelesen werden. Python 3 und Poppler pruefen." unless ref($data) eq 'HASH';
  die "$data->{error}\n" if $data->{error};
  die "Auswertung fehlgeschlagen." unless $ok && ref($data->{groups}) eq 'ARRAY';
  return $data;
}
sub load_import {
  my ($key, $dbh, $lock)=@_; $dbh ||= dbh();
  die "Ungueltiger Import." unless ($key // '') =~ /^[a-f0-9]{64}$/;
  my $row=$dbh->selectrow_hashref('SELECT * FROM sales_report_imports WHERE import_key = ?'.($lock ? ' FOR UPDATE' : ''),undef,$key);
  die "Importvorgang nicht gefunden." unless $row;
  $row->{data}=json()->decode($row->{payload});
  $row->{mapped}=json()->decode($row->{mapping});
  return $row;
}
sub store_imports {
  my ($data,$source,$filename,$replace_open)=@_;
  $source =~ s/^\s+|\s+$//g;
  die "Bitte einen festen Standort/Quellnamen mit maximal 120 Zeichen angeben." unless length($source) && length($source)<=120 && $source !~ /[\x00-\x1f]/;
  my @keys;
  my $ok=SL::DB->client->with_transaction(sub {
    my $dbh=dbh();
    for my $g (@{$data->{groups}}) {
      my $period=sprintf('%04d-%02d',$g->{year},$g->{month});
      my $key=sha256_hex(encode('UTF-8',json()->encode([$source,$period,$g->{payment}])));
      $dbh->do('INSERT INTO sales_report_imports (import_key,source,period,payment,content_hash,payload,source_sha256,filename) VALUES (?,?,?,?,?,?,?,?) ON CONFLICT (import_key) DO NOTHING',undef,
        $key,$source,$period,$g->{payment},$g->{content_hash},json()->encode($g),$data->{sha256},substr($filename // 'Verkaufsbericht',0,250));
      my $existing=load_import($key,$dbh,1);
      if ($existing->{content_hash} ne $g->{content_hash}) {
        die "Fuer $source / $period / $g->{payment} liegt bereits ein anderer Bericht vor. Gebuchte Berichte koennen nicht ersetzt werden; offene nur mit ausdruecklicher Auswahl. Nichts importiert."
          if $existing->{posted_ar_id} || !$replace_open;
        $dbh->do("UPDATE sales_report_imports SET payload=?,content_hash=?,mapping='{}',source_sha256=?,filename=? WHERE import_key=?",undef,
          json()->encode($g),$g->{content_hash},$data->{sha256},substr($filename // 'Verkaufsbericht',0,250),$key);
      }
      push @keys,$key;
    }
    return 1;
  });
  die(SL::DB->client->error || 'Import konnte nicht gespeichert werden.') unless $ok;
  return \@keys;
}
sub _iso_date {
  my ($y,$m,$d)=split /-/, $_[0];
  return DateTime->new(year=>$y,month=>$m,day=>$d)->to_kivitendo;
}
sub form_defaults {
  my ($key)=@_;
  my $row=load_import($key);
  die "Dieser Monatsbericht ist bereits gebucht (Beleg-ID $row->{posted_ar_id})." if $row->{posted_ar_id};
  my $g=$row->{data}; my %f;
  die "Alte Importvorbereitung: Originalbericht fuer historische Verkaufspreise erneut hochladen."
    unless ($g->{schema_version} // 0) == 2;
  _assert_review($row);
  my @items = @{ expected_lines($row) };
  my $i=0;
  for my $item (@items) {
    ++$i;
    my $id=$item->{part_id};
    my $p=SL::DB::Part->new(id=>$id)->load;
    die "Artikel ist inaktiv oder gesperrt: ".$p->partnumber if $p->obsolete || ($p->part_type ne 'part' && $p->part_type ne 'service');
    my $factor=$p->price_factor_id ? $p->price_factor->factor : 1;
    die "Ungueltige Preiseinheit." unless $factor>0;
    @f{map { "${_}_$i" } qw(id partnumber description unit part_type price_factor_id price_factor)}=
      ($p->id,$p->partnumber,$p->description,$p->unit,$p->part_type,$p->price_factor_id,$factor);
    $f{"qty_$i"}=$::form->format_amount(\%::myconfig,$item->{quantity},0);
    $f{"sellprice_$i"}=$::form->format_amount(\%::myconfig,$item->{unit_gross} * $factor,5);
    $f{"discount_$i"}='0';
    $f{"active_price_source_$i"}='';
    $f{"active_discount_source_$i"}='';
  }
  return { %f, rowcount=>$i, type=>'invoice', vc=>'customer', customer_id=>'', customer=>'', previous_customer_id=>'',
    currency=>$::form->get_default_currency(\%::myconfig), taxincluded=>1, taxincluded_changed_by_user=>1,
    invdate=>_iso_date($g->{end_date}),
    tax_point_start=>_iso_date($g->{start_date}),
    tax_point=>_iso_date($g->{end_date}),
    sales_report_key=>$key, sales_report_version=>version($row), paidaccounts=>1, invnumber=>'',
    transaction_description=>"Automatenverkaeufe $row->{source} $row->{period} $row->{payment}",
    intnotes=>"Verkaufsbericht $row->{source}, $row->{period}, $row->{payment}\nOriginalumsatz: $g->{total} EUR brutto; Menge $g->{quantity}.\nImport: $key\nOriginale Verkaufserloese und Bruttoverkaufspreise aus dem Export; keine Neuberechnung mit Stammpreisen. Mengen in lokaler Artikeleinheit; Gebinde kontrollieren. Keine Zahlungsbuchung. Originaldatei bitte als Beleg anhaengen."
      . ($row->{mapped}{_review_note} ? "\nExport-Auffaelligkeiten geprueft: $row->{mapped}{_review_note}" : ''),
  };
}
sub lock_for_post {
  my ($dbh,$form)=@_;
  return unless $form->{sales_report_key};
  my $row=load_import($form->{sales_report_key},$dbh,1);
  die "Die Vorbereitung wurde durch einen neueren Bericht ersetzt. Bitte erneut oeffnen."
    unless ($form->{sales_report_version}//'') eq version($row);
  die "Dieser Bericht wurde bereits gebucht." if $row->{posted_ar_id} && (!$form->{id} || $row->{posted_ar_id} != $form->{id});
  die "Verkaufsbericht nur als Verkaufsrechnung buchbar." unless ($form->{type}//'') eq 'invoice' && !$form->{storno};
  die "Verkaufsbericht muss in EUR gebucht werden." unless ($form->{currency}//'') eq 'EUR';
  # Source tax rates must remain compatible with the selected article accounts.
  my %rates; my $n=0;
  for my $item (@{$row->{data}{items}}) {
    my $id=$row->{mapped}{++$n};
    die "Unvollstaendige Artikelzuordnung." unless $id;
    die "Ein Artikel ist mit unterschiedlichen Export-Steuersaetzen zugeordnet. Bitte getrennte Artikel verwenden."
      if exists($rates{$id}) && $rates{$id} != $item->{tax_rate};
    $rates{$id}=$item->{tax_rate};
  }
  for my $i (1 .. ($form->{rowcount}||0)) {
    my $id=$form->{"id_$i"}; next unless $id && exists($rates{$id});
    my $rate=0;
    $rate += $form->{"${_}_rate"} // 0 for grep { length } split /\s+/, ($form->{"taxaccounts_$i"}//'');
    die "Position $i: Artikelsteuer weicht vom Verkaufsbericht ab ($rates{$id} %). Bitte Zuordnung/Kunde/Buchungsgruppe pruefen."
      if abs($rate*100-$rates{$id}) > 0.00001;
  }
  if (($row->{data}{schema_version} // 0) == 2) {
    _assert_review($row);
    _assert_original_lines($row,$form);
  } elsif (!$row->{posted_ar_id}) {
    die "Alte Importvorbereitung: Originalbericht erneut hochladen.";
  }
  return $row;
}
sub _assert_review {
  my ($row)=@_;
  die "Export enthaelt Auffaelligkeiten. Erst in der Artikelzuordnung pruefen und begruendet bestaetigen."
    if @{ $row->{data}{review_issues} || [] }
      && (!$row->{mapped}{_review_accepted} || !length($row->{mapped}{_review_note} // ''));
}
sub expected_lines {
  my ($row)=@_;
  my (@items,%by_key); my $source_row=0;
  for my $item (@{ $row->{data}{items} }) {
    my $id=$row->{mapped}{++$source_row};
    die "Bitte alle Artikel zuordnen." unless $id && $id =~ /^\d+$/;
    die "Originalpreis fehlt. Originalbericht erneut hochladen."
      unless defined $item->{unit_gross} && defined $item->{total};
    my $key=join(':',$id,$item->{tax_rate},sprintf('%.5f',$item->{unit_gross}));
    if (my $existing=$by_key{$key}) {
      $existing->{quantity}+=$item->{quantity}; $existing->{total}+=$item->{total};
    } else {
      my $combined={%$item,part_id=>$id};
      $by_key{$key}=$combined; push @items,$combined;
    }
  }
  return \@items;
}
sub _input_number {
  my ($form,$field)=@_;
  return $::form ? $::form->parse_amount(\%::myconfig,$form->{$field} // 0) : 0+($form->{$field} // 0);
}
sub _assert_original_lines {
  my ($row,$form)=@_;
  die "Verkaufsbericht benoetigt Bruttoeingabe." unless $form->{taxincluded};
  my (%expected,%actual);
  for my $i (@{ expected_lines($row) }) {
    my $key=join(':',$i->{part_id},$i->{tax_rate},sprintf('%.5f',$i->{unit_gross}));
    $expected{$key}=$i->{quantity};
  }
  for my $i (1..($form->{rowcount}||0)) {
    my $id=$form->{"id_$i"}; next unless $id;
    my $qty=_input_number($form,"qty_$i"); next unless $qty;
    die "Rabatte duerfen Originalumsaetze nicht veraendern." if _input_number($form,"discount_$i");
    my $p=SL::DB::Part->new(id=>$id)->load;
    my $factor=$p->price_factor_id ? $p->price_factor->factor : 1;
    die "Artikeleinheit oder Preiseinheit weicht ab."
      unless ($form->{"unit_$i"}//'') eq ($p->unit//'')
        && ($form->{"price_factor_id_$i"}//'') eq ($p->price_factor_id//'') && $factor>0;
    my $price=_input_number($form,"sellprice_$i")/$factor;
    my $rate=0;
    $rate+=$form->{"${_}_rate"}//0 for grep {length} split /\s+/,($form->{"taxaccounts_$i"}//'');
    my $key=join(':',$id,0+sprintf('%.5f',$rate*100),sprintf('%.5f',$price));
    $actual{$key}+=$qty;
  }
  die "Artikel, Mengen oder Verkaufspreise weichen vom Originalbericht ab. Vorbereitung erneut oeffnen."
    unless keys(%actual)==keys(%expected)
      && !grep { !exists($actual{$_}) || abs($actual{$_}-$expected{$_})>0.000001 } keys %expected;
}
sub verify_total {
  my ($dbh,$form,$amount)=@_;
  return unless $form->{sales_report_key};
  my $row=load_import($form->{sales_report_key},$dbh);
  return unless ($row->{data}{schema_version}//0)==2;
  die "Buchungssumme weicht vom Originalumsatz ab. Steuerberechnung und Preiseinheiten pruefen."
    if abs($amount-$row->{data}{total})>0.004;
}
sub portfolio {
  my ($source)=@_;
  $source //= '';
  my $rows=dbh()->selectall_arrayref(
    'SELECT source,payload,mapping FROM sales_report_imports WHERE (? = \'\' OR source = ?) ORDER BY source,period,payment LIMIT 1001',
    {Slice=>{}},$source,$source);
  die "Zu viele Berichte. Bitte einen Standort filtern." if @$rows>1000;
  my @groups=map { +{source=>$_->{source},data=>json()->decode($_->{payload})} } @$rows;
  my ($out,$err,$input)=('','',JSON::PP->new->utf8->encode(\@groups));
  my @cmd=('python3','scripts/sales_report_import.py','--portfolio');
  my $ok=run \@cmd, \$input, \$out, \$err, timeout(100);
  die "Portfolioauswertung fehlgeschlagen." unless $ok;
  return JSON::PP->new->utf8->decode($out);
}
sub mark_posted {
  my ($dbh,$form)=@_;
  return unless $form->{sales_report_key};
  $dbh->do('UPDATE sales_report_imports SET posted_ar_id = ? WHERE import_key = ?',undef,$form->{id},$form->{sales_report_key});
}
1;
