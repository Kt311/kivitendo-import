use strict;
use warnings;
use Test::More;
my $root=shift || '.';
open my $fh,'<',"$root/SL/PriceSource/PriceRules.pm" or die $!;
my $source=do { local $/; <$fh> };
$source =~ s/^use (?:parent|SL::\S+|List::UtilsBy)\b[^\n]*\n//mg;
{
  package SL::PriceSource::PriceRules;
  sub record { $_[0]{record} }
  sub record_item { $_[0]{item} }
  sub customer_vendor { $_[0]{partner} }
}
{
  package SL::DB::Manager::PriceRule;
  our $calls=0;
  our @args;
  sub PRICE_DISCOUNT { 2 }
  sub get_all_matching { shift; @args=@_; ++$calls; return ['matching-rule'] }
}
eval $source;
is($@,'','Actual price-rule source compiles with dependencies stubbed');
my $s=bless {record=>'invoice',item=>'line'},'SL::PriceSource::PriceRules';
is_deeply($s->available_rules,[],'No rules without a customer');
is($s->best_price,undef,'No rule price without a customer');
is($s->best_discount,undef,'No rule discount without a customer');
is($SL::DB::Manager::PriceRule::calls,0,'No matching query before customer selection');
ok(!exists $s->{available},'Missing customer result is not cached');
$s->{partner}='selected customer';
is_deeply($s->available_rules,['matching-rule'],'Rules become available after selection');
is($SL::DB::Manager::PriceRule::calls,1,'Normal matching query runs');
is_deeply({@SL::DB::Manager::PriceRule::args},{record=>'invoice',record_item=>'line'},'Original invoice and line reach matcher');
is_deeply($s->available_rules,['matching-rule'],'Normal rule cache retained');
is($SL::DB::Manager::PriceRule::calls,1,'Cached rules avoid duplicate query');
done_testing;
