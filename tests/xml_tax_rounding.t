use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Storable qw(dclone);
use lib 'files';
use SL::XMLTaxRounding;

{ package Parser;
  sub metadata { $_[0]->{metadata} }
  sub tax_totals { $_[0]->{taxes} }
}
{ package DB;
  sub selectrow_array { $_[0]->{stored} }
  sub do { my ($self,$sql,$attrs,$json,$id)=@_; $self->{stored}=$json; $self->{saved_id}=$id; 1 }
}
{ package SL::SessionFile;
  our %files;
  sub new {
    my ($class,$name,%params)=@_;
    my $self=bless {},$class;
    if ($params{mode} eq 'w') { open $self->{fh}, '>', \$files{$name} or die $!; }
    elsif (exists $files{$name}) { open $self->{fh}, '<', \$files{$name} or die $!; }
    return $self;
  }
  sub fh { $_[0]->{fh} }
  $INC{'SL/SessionFile.pm'}=__FILE__;
}
{ package Tax;
  sub rate { $_[0]->{rate} }
  sub taxkey { 9 }
  sub reverse_charge_chart_id { 0 }
  sub chart { undef }
}
{ package SL::DB::Manager::Tax;
  sub find_by { my ($class,%args)=@_; bless {rate => $args{id} == 7 ? .07 : .19}, 'Tax' }
}
our %myconfig;
my $parser=bless {
  metadata=>{type=>'380',net_total=>'120.73',tax_total=>'15.11',gross_total=>'135.84'},
  taxes=>[
    {category_code=>'S',type_code=>'VAT',tax_rate=>'7.00',net_amount=>'65.23',amount=>'4.57'},
    {category_code=>'S',type_code=>'VAT',tax_rate=>'19.00',net_amount=>'55.50',amount=>'10.54'},
  ],
}, 'Parser';
my $form={vendor_id=>42,invnumber=>'SYNTHETIC-ROUNDING',currency=>'EUR',defaultcurrency=>'EUR',exchangerate=>1,taxincluded=>0,rowcount=>5};
my @rows=([47.60,19],[43.60,7],[9.75,7],[11.88,7],[7.90,19]);
for my $i (1..5) { $form->{"amount_$i"}=$rows[$i-1][0]; $form->{"taxchart_$i"}=$rows[$i-1][1].'--'.($rows[$i-1][1]/100); }
my $context=SL::XMLTaxRounding->context($parser,$form);
is($context->{tax},1511,'XML group tax totals retained in cents');
my $token=SL::XMLTaxRounding->prepare($parser,$form);
$form->{xml_tax_context_file}=$token;

# Original kivitendo 4.1.0 tax functions, GPL-2.0, extracted without changes.
# https://github.com/kivitendo/kivitendo-erp/tree/release-4.1.0
{ package TestForm;
use List::Util qw(max min); use Config;
sub _round_number {
  my ($amount, $places, $adjust) = @_;

  return 0 if !defined $amount;

  $places //= 0;

  if ($adjust) {
    no warnings 'once';
    my $precision = $::instance_conf->get_precision || 0.01;
    return _round_number( _round_number($amount / $precision, 0) * $precision, $places);
  }

  # We use Perl's knowledge of string representation for
  # rounding. First, convert the floating point number to a string
  # with a high number of places. Then split the string on the decimal
  # sign and use integer calculation for rounding the decimal places
  # part. If an overflow occurs then apply that overflow to the part
  # before the decimal sign as well using integer arithmetic again.

  my $int_amount = int(abs $amount);
  my $str_places = max(min(10, 15 - length("$int_amount") - $places), $places);
  my $amount_str = sprintf '%.*f', $places + $str_places, abs($amount);

  return $amount unless $amount_str =~ m{^(\d+)\.(\d+)$};

  my ($pre, $post)      = ($1, $2);
  my $decimals          = '1' . substr($post, 0, $places);

  my $propagation_limit = $Config{i32size} == 4 ? 7 : 18;
  my $add_for_rounding  = substr($post, $places, 1) >= 5 ? 1 : 0;

  if ($places > $propagation_limit) {
    $decimals = Math::BigInt->new($decimals)->badd($add_for_rounding);
    $pre      = Math::BigInt->new($decimals)->badd(1) if substr($decimals, 0, 1) eq '2';

  } else {
    $decimals += $add_for_rounding;
    $pre      += 1 if substr($decimals, 0, 1) eq '2';
  }

  $amount  = ("${pre}." . substr($decimals, 1)) * ($amount <=> 0);

  return $amount;
}


sub round_amount { shift; _round_number(@_) }
sub parse_amount { $_[2] // 0 }
sub redo_rows { }
sub calculate_tax {
  # this function calculates the net amount and tax for the lines in ar, ap and
  # gl and is used for update as well as post. When used with update the return
  # value of amount isn't needed

  # calculate_tax should always work with positive values, or rather as the user inputs them
  # calculate_tax uses db/perl numberformat, i.e. parsed numbers
  # convert to negative numbers (when necessary) only when writing to acc_trans
  # the amount from $form for ap/ar/gl is currently always rounded to 2 decimals before it reaches here
  # for post_transaction amount already contains exchangerate and correct sign and is rounded
  # calculate_tax doesn't (need to) know anything about exchangerate

  my ($self,$amount,$taxrate,$taxincluded,$roundplaces) = @_;

  $roundplaces //= 2;
  $taxincluded //= 0;

  my $tax;

  if ($taxincluded) {
    # calculate tax (unrounded), subtract from amount, round amount and round tax
    $tax       = $amount - ($amount / ($taxrate + 1)); # equivalent to: taxrate * amount / (taxrate + 1)
    $amount    = $self->round_amount($amount - $tax, $roundplaces);
    $tax       = $self->round_amount($tax, $roundplaces);
  } else {
    $tax       = $amount * $taxrate;
    $tax       = $self->round_amount($tax, $roundplaces);
  }

  $tax = 0 unless $tax;

  return ($amount,$tax);
};
sub calculate_arap {
  my ($self,$buysell,$taxincluded,$exchangerate,$roundplaces) = @_;

  # this function is used to calculate netamount, total_tax and amount for AP and
  # AR transactions (Kreditoren-/Debitorenbuchungen) by going over all lines
  # (1..$rowcount)
  # Thus it needs a fully prepared $form to work on.
  # calculate_arap assumes $form->{amount_$i} entries still need to be parsed

  # The calculated total values are all rounded (default is to 2 places) and
  # returned as parameters rather than directly modifying form.  The aim is to
  # make the calculation of AP and AR behave identically.  There is a test-case
  # for this function in t/form/arap.t

  # While calculating the totals $form->{amount_$i} and $form->{tax_$i} are
  # modified and formatted and receive the correct sign for writing straight to
  # acc_trans, depending on whether they are ar or ap.

  # check parameters
  die "taxincluded needed in Form->calculate_arap" unless defined $taxincluded;
  die "exchangerate needed in Form->calculate_arap" unless defined $exchangerate;
  die 'illegal buysell parameter, has to be \"buy\" or \"sell\" in Form->calculate_arap\n' unless $buysell =~ /^(buy|sell)$/;
  $roundplaces = 2 unless $roundplaces;

  my $sign = 1;  # adjust final results for writing amount to acc_trans
  $sign = -1 if $buysell eq 'buy';

  my ($netamount,$total_tax,$amount);

  my $tax;

  # parse and round amounts, setting correct sign for writing to acc_trans
  for my $i (1 .. $self->{rowcount}) {
    $self->{"amount_$i"} = $self->round_amount($self->parse_amount(\%::myconfig, $self->{"amount_$i"}) * $exchangerate * $sign, $roundplaces);

    $amount += $self->{"amount_$i"} * $sign;
  }

  for my $i (1 .. $self->{rowcount}) {
    next unless $self->{"amount_$i"};
    ($self->{"tax_id_$i"}) = split /--/, $self->{"taxchart_$i"};
    my $tax_id = $self->{"tax_id_$i"};

    my $selected_tax = SL::DB::Manager::Tax->find_by(id => "$tax_id");
    if ( $selected_tax && !$selected_tax->reverse_charge_chart_id) {
      if ( $buysell eq 'sell' ) {
        $self->{AR_amounts}{"tax_$i"} = $selected_tax->chart->accno if defined $selected_tax->chart;
      } else {
        $self->{AP_amounts}{"tax_$i"} = $selected_tax->chart->accno if defined $selected_tax->chart;
      };

      $self->{"taxkey_$i"} = $selected_tax->taxkey;
      $self->{"taxrate_$i"} = $selected_tax->rate;
    };

    $self->{"taxkey_$i"} = $selected_tax->taxkey if ($selected_tax && $selected_tax->reverse_charge_chart_id);

    ($self->{"amount_$i"}, $self->{"tax_$i"}) = $self->calculate_tax($self->{"amount_$i"},$self->{"taxrate_$i"},$taxincluded,$roundplaces);

    $netamount  += $self->{"amount_$i"};
    $total_tax  += $self->{"tax_$i"};

  }
  $amount = $netamount + $total_tax;

  # due to $sign amount_$i und tax_$i already have the right sign for acc_trans
  # but reverse sign of totals for writing amounts to ar
  if ( $buysell eq 'buy' ) {
    $netamount *= -1;
    $amount    *= -1;
    $total_tax *= -1;
  };

  return($netamount,$total_tax,$amount);
}

sub format_dates {
  my ($self, $dateformat, $longformat, @indices) = @_;

  $dateformat ||= $::myconfig{dateformat};

  foreach my $idx (@indices) {
    if ($self->{TEMPLATE_ARRAYS} && (ref($self->{TEMPLATE_ARRAYS}->{$idx}) eq "ARRAY")) {
      for (my $i = 0; $i < scalar(@{ $self->{TEMPLATE_ARRAYS}->{$idx} }); $i++) {
        $self->{TEMPLATE_ARRAYS}->{$idx}->[$i] = $::locale->reformat_date(\%::myconfig, $self->{TEMPLATE_ARRAYS}->{$idx}->[$i], $dateformat, $longformat);
      }
    }

    next unless defined $self->{$idx};

    if (!ref($self->{$idx})) {
      $self->{$idx} = $::locale->reformat_date(\%::myconfig, $self->{$idx}, $dateformat, $longformat);

    } elsif (ref($self->{$idx}) eq "ARRAY") {
      for (my $i = 0; $i < scalar(@{ $self->{$idx} }); $i++) {
        $self->{$idx}->[$i] = $::locale->reformat_date(\%::myconfig, $self->{$idx}->[$i], $dateformat, $longformat);
      }
    }
  }
}

sub reformat_numbers {
  my ($self, $numberformat, $places, @indices) = @_;

  return if !$numberformat || ($numberformat eq $::myconfig{numberformat});

  foreach my $idx (@indices) {
    if ($self->{TEMPLATE_ARRAYS} && (ref($self->{TEMPLATE_ARRAYS}->{$idx}) eq "ARRAY")) {
      for (my $i = 0; $i < scalar(@{ $self->{TEMPLATE_ARRAYS}->{$idx} }); $i++) {
        $self->{TEMPLATE_ARRAYS}->{$idx}->[$i] = $self->parse_amount(\%::myconfig, $self->{TEMPLATE_ARRAYS}->{$idx}->[$i]);
      }
    }

    next unless defined $self->{$idx};

    if (!ref($self->{$idx})) {
      $self->{$idx} = $self->parse_amount(\%::myconfig, $self->{$idx});

    } elsif (ref($self->{$idx}) eq "ARRAY") {
      for (my $i = 0; $i < scalar(@{ $self->{$idx} }); $i++) {
        $self->{$idx}->[$i] = $self->parse_amount(\%::myconfig, $self->{$idx}->[$i]);
      }
    }
  }

  my $saved_numberformat    = $::myconfig{numberformat};
  $::myconfig{numberformat} = $numberformat;

  foreach my $idx (@indices) {
    if ($self->{TEMPLATE_ARRAYS} && (ref($self->{TEMPLATE_ARRAYS}->{$idx}) eq "ARRAY")) {
      for (my $i = 0; $i < scalar(@{ $self->{TEMPLATE_ARRAYS}->{$idx} }); $i++) {
        $self->{TEMPLATE_ARRAYS}->{$idx}->[$i] = $self->format_amount(\%::myconfig, $self->{TEMPLATE_ARRAYS}->{$idx}->[$i], $places);
      }
    }

    next unless defined $self->{$idx};

    if (!ref($self->{$idx})) {
      $self->{$idx} = $self->format_amount(\%::myconfig, $self->{$idx}, $places);

    } elsif (ref($self->{$idx}) eq "ARRAY") {
      for (my $i = 0; $i < scalar(@{ $self->{$idx} }); $i++) {
        $self->{$idx}->[$i] = $self->format_amount(\%::myconfig, $self->{$idx}->[$i], $places);
      }
    }
  }

  $::myconfig{numberformat} = $saved_numberformat;
}

sub _escape_style_attribute { SL::Presenter::EscapedText::escape($_[0]); }

sub create_email_signature {
  my $client_signature = $::instance_conf->get_signature;
  my $user_signature   = $::myconfig{signature};
  my $style;

  $style = _escape_style_attribute(SL::DB::Default->get->email_paragraph_style_employee_signature);
  $user_signature   =~ s{<p>}{<p style="$style">}g if $style;
  $style = _escape_style_attribute(SL::DB::Default->get->email_paragraph_style_company_signature);
  $client_signature =~ s{<p>}{<p style="$style">}g if $style;

  return join '', grep { $_ } ($user_signature, $client_signature);
}


}
bless $form,'TestForm';
sub file_text { open my $f,'<',$_[0] or die $!; local $/; <$f> }
# Exercise the actual update loop and newly inserted hook from the payload.
my $ui=file_text('files/bin/mozilla/ap.pl');
my ($update)=$ui =~ /sub update \{.*?(\$form->\{invtotal\} = 0;.*?)\n  \$form->\{invdate\}/s;
ok($update,'update integration block found');
sub run_update {
  my ($form)=@_;
  my %myconfig; my %params;
  my $totaltax;
  # The block declares its own totaltax; return it from the same eval scope.
  my $result=eval $update . "\n" . '$totaltax;'; die $@ if $@;
  my $net=0; $net+=$form->{"amount_$_"} for 1..$form->{rowcount};
  return $net+$result;
}
is(sprintf('%.2f',run_update($form)),'135.84','update matches XML');
is(sprintf('%.2f',$form->{tax_2}),'3.06','one cent allocated within 7% group');
is(sprintf('%.2f',run_update($form)),'135.84','repeated update does not accumulate cents');

my $ap=file_text('files/SL/AP.pm');
my ($posting)=$ap =~ /(  \(\$form->\{netamount\},\$form->\{total_tax\},\$form->\{invtotal\}\) = .*?)\n  # adjust paidaccounts/s;
ok($posting,'posting integration block found');
sub run_post {
  my ($form,$dbh,$payments_only)=@_;
  $payments_only //= 0;
  eval $posting; die $@ if $@;
}
my $db=bless {},'DB';
$form->{id}=99;
run_post($form,$db);
is(sprintf('%.2f',$form->{invtotal}),'135.84','posting matches XML after signed recalculation');
is(sprintf('%.2f',$form->{total_tax}),'15.11','posting retains complete input tax');
is(sprintf('%.2f',$form->{tax_2}),'-3.06','signed booking row receives same correction');
is($db->{saved_id},99,'context saved with posted invoice');
ok($db->{stored},'context persisted');
# A later session has no session token: stored context alone must suffice.
my $reopened=dclone($form); delete $reopened->{xml_tax_context_file};
for my $i (1..5) { $reopened->{"amount_$i"}=$rows[$i-1][0]; }
run_post($reopened,$db);
is(sprintf('%.2f',$reopened->{invtotal}),'135.84','reposting uses persisted context without session');
my $payment=dclone($form);
for my $i (1..5) { $payment->{"amount_$i"}=$rows[$i-1][0]; }
run_post($payment,$db,1);
is(sprintf('%.2f',$payment->{invtotal}),'135.84','payment-only calculation retains XML invoice total');


my $grouped=dclone($form); delete $grouped->{id};
$grouped->{rowcount}=2;
$grouped->{amount_1}=65.23; $grouped->{taxchart_1}='7--0.07';
$grouped->{amount_2}=55.50; $grouped->{taxchart_2}='19--0.19';
is(sprintf('%.2f',run_update($grouped)),'135.84','grouped import also matches XML (19% corrected down)');

for my $case (
  ['changed amount',sub { $_[0]->{amount_1}+=1 }],
  ['changed rate',sub { $_[0]->{taxchart_1}='19--0.19' }],
  ['changed vendor',sub { $_[0]->{vendor_id}=43 }],
  ['changed invoice',sub { $_[0]->{invnumber}='OTHER' }],
  ['gross input',sub { $_[0]->{taxincluded}=1 }],
  ['foreign currency',sub { $_[0]->{defaultcurrency}='USD' }],
) {
  my $f=dclone($grouped); $case->[1]->($f);
  eval { run_update($f) }; like($@,qr/XML-Steuerabgleich/,"reject $case->[0]");
}
my $ubl=dclone($parser);
for my $g (@{$ubl->{taxes}}) { $g->{tax_amount}=delete $g->{amount}; }
is_deeply(SL::XMLTaxRounding->context($ubl,$form),$context,'UBL tax_amount and CII amount have identical meaning');
my $bad=dclone($parser); $bad->{taxes}[0]{amount}='4.67';
eval { SL::XMLTaxRounding->context($bad,$form) };
like($@,qr/XML-Steuerabgleich/,'reject large discrepancy instead of changing net amounts');
my $untouched=dclone($grouped); delete $untouched->{xml_tax_context_file};
is(sprintf('%.2f',run_update($untouched)),'135.85','ordinary AP remains unchanged');
my $missing=dclone($grouped);$missing->{xml_tax_context_file}='xml-tax-'.('a'x64).'.json';
eval { run_update($missing) }; like($@,qr/Sitzung abgelaufen/,'missing source blocks import rather than losing correction');

# CII invoice total must not use the open balance of a prepaid invoice.
my $cii=file_text('files/SL/XMLInvoice/CrossIndustryInvoice.pm');
like($cii,qr/gross_total => '[^']*GrandTotalAmount'/,'CII invoice total uses GrandTotalAmount');
like($cii,qr/due_total => '[^']*DuePayableAmount'/,'CII open balance remains separate');
my $header=file_text('files/templates/design40_webpages/ap/form_header.html');
like($header,qr/hidden_tag\('xml_tax_context_file'/,'session context survives form submits');
like($ui,qr/taxchart_\$pos.*?\/\/=/,'record template preserves XML tax rate');
done_testing;
