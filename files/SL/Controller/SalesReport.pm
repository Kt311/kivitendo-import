package SL::Controller::SalesReport;
use strict;
use warnings;
use utf8;
use parent qw(SL::Controller::Base);
use SL::SalesReport;
use SL::DB::Manager::Part;
use SL::DB::Part;
use SL::Helper::Flash qw(flash);
__PACKAGE__->run_before('check_auth');
sub check_auth { $::auth->assert('invoice_edit') }
sub action_upload {
  my ($self)=@_;
  my $rows=eval { SL::SalesReport::dbh()->selectall_arrayref('SELECT import_key,source,period,payment,posted_ar_id FROM sales_report_imports ORDER BY created_at DESC LIMIT 200',{Slice=>{}}) };
  return $self->render('sales_report/upload',title=>'Verkaufsbericht importieren',imports=>$rows || [],db_missing=>!defined($rows));
}
sub action_import {
  my ($self)=@_; my $data;
  my $ok=eval {
    die "Bitte bestaetigen, dass die Export-Umsaetze Bruttobetraege in EUR sind." unless $::form->{gross_confirmed};
    die "Dieser Import benoetigt EUR als Mandantenwaehrung." unless $::form->get_default_currency(\%::myconfig) eq 'EUR';
    $data=SL::SalesReport::analyze($::form->{file},$::form->{year});
    SL::SalesReport::store_imports($data,$::form->{source}//'', $::form->{file_name},$::form->{replace_open});
    1;
  };
  if (!$ok) { my $error=$@ || 'Import fehlgeschlagen.'; flash('error',$error) }
  elsif (@{$data->{warnings}}) { flash('warning',join("\n",@{$data->{warnings}})) }
  return $self->action_upload;
}
sub action_portfolio {
  my ($self)=@_;
  my $data=SL::SalesReport::portfolio($::form->{source});
  return $self->render('sales_report/portfolio',title=>'Senvend: Produkte und Preisbeobachtungen',data=>$data);
}
sub action_mapping {
  my ($self)=@_;
  my $row=SL::SalesReport::load_import($::form->{import_key});
  $row->{version}=SL::SalesReport::version($row);
  die "Bericht bereits gebucht." if $row->{posted_ar_id};
  my @rows; my $i=0;
  for my $item (@{$row->{data}{items}}) {
    ++$i;
    my ($saved)=SL::SalesReport::dbh()->selectrow_array('SELECT parts_id FROM sales_report_mappings WHERE source=? AND description=?',undef,$row->{source},$item->{description});
    my $id=$row->{mapped}{$i} || $saved;
    my $part=$id ? eval { SL::DB::Part->new(id=>$id)->load } : undef;
    my $method=$part ? 'Gespeicherte Zuordnung' : 'Bitte Artikel auswaehlen';
    if ($part && ($part->obsolete)) { $part=undef; $method='Gespeicherter Artikel ist inaktiv/gesperrt' }
    if (!$part) {
      my $matches=SL::DB::Manager::Part->get_all(query=>[description=>$item->{description},obsolete=>0,part_type=>['part','service']],limit=>2);
      if (@$matches==1) { $part=$matches->[0]; $method='Namensvorschlag - bitte bestaetigen' }
    }
    push @rows,{%$item,row=>$i,part=>$part,method=>$method};
  }
  return $self->render('sales_report/mapping',title=>'Verkaufsbericht: Artikel zuordnen',report=>$row,rows=>\@rows);
}
sub action_save_mapping {
  my ($self)=@_;
  my $ok=eval {
    my $result=SL::DB->client->with_transaction(sub {
      my $dbh=SL::SalesReport::dbh();
      my $row=SL::SalesReport::load_import($::form->{import_key},$dbh,1);
      die "Bericht oder Zuordnung wurde zwischenzeitlich geaendert. Bitte die aktuelle Vorbereitung erneut pruefen."
        unless ($::form->{report_version}//'') eq SL::SalesReport::version($row);
      die "Bericht bereits gebucht." if $row->{posted_ar_id};
      my (%mapping,%chosen); my $i=0;
      if (@{ $row->{data}{review_issues} || [] }) {
        my $note=$::form->{review_note} // ''; $note =~ s/^\s+|\s+$//g;
        die "Auffaelligkeiten zuerst pruefen, bestaetigen und Pruefnotiz ausfuellen."
          unless $::form->{review_accepted} && length($note)>=10 && length($note)<=2000;
        $mapping{_review_accepted}=1; $mapping{_review_note}=$note;
      }
      for my $item (@{$row->{data}{items}}) {
        ++$i;my $id=$::form->{"mapping_$i"};
        die "Position $i: bitte einen Artikel auswaehlen." unless ($id//'') =~ /^\d+$/ && $id>0;
        my $p=SL::DB::Part->new(id=>$id)->load;
        die "Position $i: Artikel nicht verkaufbar." if $p->obsolete || ($p->part_type ne 'part' && $p->part_type ne 'service');
        die "Widerspruechliche Auswahl fuer denselben Artikelnamen." if $chosen{$item->{description}} && $chosen{$item->{description}} != $id;
        $chosen{$item->{description}}=$id; $mapping{$i}=0+$id;
        $dbh->do('INSERT INTO sales_report_mappings(source,description,parts_id) VALUES (?,?,?) ON CONFLICT (source,description) DO NOTHING',undef,$row->{source},$item->{description},$id);
        my ($existing)=$dbh->selectrow_array('SELECT parts_id FROM sales_report_mappings WHERE source=? AND description=? FOR UPDATE',undef,$row->{source},$item->{description});
        die "Eine bestehende Artikelzuordnung weicht ab. Zum bewussten Aendern das entsprechende Kaestchen aktivieren."
          if $existing != $id && !$::form->{replace_mapping};
        $dbh->do('UPDATE sales_report_mappings SET parts_id=? WHERE source=? AND description=?',undef,$id,$row->{source},$item->{description});
      }
      $dbh->do('UPDATE sales_report_imports SET mapping=? WHERE import_key=?',undef,SL::SalesReport::json()->encode(\%mapping),$row->{import_key});
      return 1;
    });
    die(SL::DB->client->error || 'Zuordnung konnte nicht gespeichert werden.') unless $result;
    1;
  };
  if (!$ok) { my $error=$@; flash('error',$error); return $self->action_mapping }
  return $self->redirect_to(controller=>'is.pl',action=>'load_sales_report',sales_report_key=>$::form->{import_key});
}
1;
