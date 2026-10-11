use strict;
use warnings;
use Test::More;
use JSON::PP;
my $root=shift || '.';
sub source {
  open my $f,'<:encoding(UTF-8)',"$root/$_[0]" or die $!;
  return do { local $/; <$f> };
}
my $module=source('SL/SalesReport.pm');
$module =~ s/^use (?:SL::\S+|DateTime|IPC::Run)\b[^\n]*\n//mg;
{
 package SL::SalesReport;
 sub run { 1 } sub timeout { 100 }
}
eval $module;is($@,'','sales module compiles with app dependencies stubbed');
my $controller=source('SL/Controller/SalesReport.pm');
$controller =~ s/^use (?:SL::\S+|parent)\b[^\n]*\n//mg;
{ package SL::Controller::SalesReport; sub run_before {} sub flash {} }
eval $controller;is($@,'','sales controller compiles with dependencies stubbed');
{
 package FakeDB;
 sub selectrow_hashref { my ($s,$sql)=@_;$s->{locked}=($sql =~ /FOR UPDATE/);return $s->{row} }
 sub do {my ($s,$sql,$unused,@args)=@_;$s->{updated}=\@args;1}
}
my $key='a'x64;
my $db=bless {row=>{content_hash=>'version1',payload=>JSON::PP->new->encode({items=>[{tax_rate=>19}]}),mapping=>' {"1":7}',posted_ar_id=>undef}},'FakeDB';
my $version=SL::SalesReport::version($db->{row});
my %form=(sales_report_key=>$key,sales_report_version=>$version,type=>'invoice',currency=>'EUR',rowcount=>1,id_1=>7,taxaccounts_1=>'1776','1776_rate'=>.19);
ok(SL::SalesReport::lock_for_post($db,\%form),'unposted report may be posted');
ok($db->{locked},'row locked until transaction completion');
$form{sales_report_version}='old';eval {SL::SalesReport::lock_for_post($db,\%form)};like($@,qr/neueren Bericht/,'old open invoice rejected after corrected re-upload');$form{sales_report_version}=$version;
$db->{row}{posted_ar_id}=42;
eval {SL::SalesReport::lock_for_post($db,\%form)};like($@,qr/bereits gebucht/,'second invoice rejected');
$form{id}=42;ok(SL::SalesReport::lock_for_post($db,\%form),'same existing invoice may be edited');
$form{storno}=1;eval {SL::SalesReport::lock_for_post($db,\%form)};like($@,qr/Verkaufsrechnung/,'cannot reuse key for reversal');delete $form{storno};
$form{'1776_rate'}=.07;eval {SL::SalesReport::lock_for_post($db,\%form)};like($@,qr/Artikelsteuer/,'wrong article tax rejected');$form{'1776_rate'}=.19;
$form{currency}='USD';eval {SL::SalesReport::lock_for_post($db,\%form)};like($@,qr/EUR/,'foreign currency rejected');$form{currency}='EUR';
SL::SalesReport::mark_posted($db,\%form);is_deeply($db->{updated},[42,$key],'booking links the actual AR id');
my $native=source('SL/IS.pm');
like($native,qr/my \$dbh = \$provided_dbh.*?lock_for_post\(\$dbh, \$form\)/s,'guard uses native booking DB transaction handle');
like($native,qr/mark_posted\(\$dbh, \$form\).*?\$validity_token->delete/s,'link updated before native transaction completes');
my $is=source('bin/mozilla/is.pl');
like($is,qr/id type queued printed emailed vc discount sales_report_key/,'import key survives form submission');
like($is,qr/previous_customer_id.*?sales_report_key.*?IS->get_customer/s,'initial customer selection loads native customer defaults');
my ($entry)=$is =~ /(sub load_sales_report \{.*?\n\})/s;
eval "package TestIS; sub invoice_links {} sub prepare_invoice {} sub display_form {} $entry";
is($@,'','native invoice entry point compiles');
{
 package FakeForm;
 sub format_amount { $_[2] } sub get_default_currency {'EUR'}
 package DateTime;
 sub new { my($c,%p)=@_;bless \%p,$c }
 sub to_kivitendo {sprintf('%02d.%02d.%04d',$_[0]{day},$_[0]{month},$_[0]{year})}
 package SL::DB::Part;
 sub new { my($c,%p)=@_;bless \%p,$c } sub load {$_[0]}
 sub obsolete {0} sub part_type {'part'} sub price_factor_id {undef}
 sub id {$_[0]{id}} sub partnumber {'A007'} sub description {'Cola'} sub unit {'Stck'} sub sellprice {2.5}
}
{
 no warnings qw(redefine once);
 local *SL::SalesReport::dbh=sub {$db};
 local $::form=bless {},'FakeForm';
 local $db->{row}={content_hash=>'v',mapping=>'{"1":7,"2":7}',source=>'Automat',period=>'2026-09',payment=>'CASH',
   payload=>JSON::PP->new->encode({items=>[{description=>'Cola',tax_rate=>19,quantity=>2},{description=>'Cola Alias',tax_rate=>19,quantity=>3}],
     end_date=>'2026-09-30',start_date=>'2026-09-01',total=>'10.00',quantity=>'5'})};
 my $defaults=SL::SalesReport::form_defaults($key);
 is($defaults->{customer_id},'','no customer is preselected');
 is($defaults->{rowcount},1,'aliases mapped to same article consolidated');
 is($defaults->{qty_1},5,'source quantities summed once');
 is($defaults->{sellprice_1},2.5,'article master price used, not export unit price');
 is($defaults->{taxincluded},0,'article price interpreted as net');
 is($defaults->{invdate},'30.09.2026','month end formatted in user locale');
 is($defaults->{invnumber},'','native invoice number assigned only on booking');
}
done_testing;
