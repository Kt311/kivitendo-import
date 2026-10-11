package SL::PDFInvoice;
use strict;
use warnings;
use utf8;
use JSON::PP ();
use File::Temp qw(tempfile);
use IPC::Run qw(run timeout);
sub call_helper {
  my ($mode, $input) = @_;
  my ($out, $err) = ('', '');
  my @cmd = ('python3', 'scripts/pdf_invoice_review.py', $mode);
  my ($fh, $path);
  my $stdin = '';
  if ($mode eq 'analyze') {
    ($fh, $path) = tempfile(SUFFIX => '.pdf', UNLINK => 1);
    binmode $fh; print {$fh} $input; close $fh;
    push @cmd, $path;
  } else {
    $stdin = JSON::PP->new->utf8->encode($input);
  }
  my $ok = run \@cmd, \$stdin, \$out, \$err, timeout(240);
  my $result = eval { JSON::PP->new->utf8->decode($out) };
  die "PDF-Auswertung fehlgeschlagen. Python 3, Poppler und ggf. Tesseract pruefen."
    unless ref($result) eq 'HASH';
  die $result->{error} if $result->{error};
  die "PDF-Auswertung fehlgeschlagen." unless $ok;
  return $result;
}
sub from_review {
  my ($class, $data) = @_;
  return bless $data, $class;
}
sub metadata { $_[0]->{metadata} }
sub items { $_[0]->{items} }
sub tax_totals { $_[0]->{tax_totals} }
1;
