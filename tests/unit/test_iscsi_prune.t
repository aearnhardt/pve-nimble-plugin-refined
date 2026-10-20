#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;

BEGIN { package PVE::JSONSchema; $INC{'PVE/JSONSchema.pm'} = 1; }
BEGIN { package PVE::Network;    $INC{'PVE/Network.pm'}    = 1; }
BEGIN { package PVE::INotify; sub nodename { 'testnode' } $INC{'PVE/INotify.pm'} = 1; }
BEGIN { package PVE::Storage; sub APIVER { 14 } sub APIAGE { 5 } $INC{'PVE/Storage.pm'} = 1; }
BEGIN {
  package PVE::Storage::Plugin;
  our @SHARED_STORAGE;
  sub get_next_vm_diskname { 'vm-100-disk-0' }
  $INC{'PVE/Storage/Plugin.pm'} = 1;
}

my $fake_iscsiadm = File::Spec->catfile( tempdir( CLEANUP => 1 ), 'iscsiadm' );
open my $fh, '>', $fake_iscsiadm or die $!;
print {$fh} "#!/bin/sh\nexit 0\n";
close $fh;
chmod 0755, $fake_iscsiadm;

our $live  = 'iqn.2007-11.com.nimblestorage:vm-100-disk-0-v1.00000001.aa';
our $stale = 'iqn.2007-11.com.nimblestorage:vm-101-disk-0-v1.00000002.aa';
our $busy  = 'iqn.2007-11.com.nimblestorage:vm-102-disk-0-v1.00000003.aa';
our $other = 'iqn.2007-11.com.nimblestorage:vm-900-disk-0-v2.00000009.bb';    # a different Nimble array
our $truenas = 'iqn.2026.02.org.truenas.ctl:f60-lab-sas';

my @logouts;
my @deletes;
BEGIN {
  package PVE::Tools;
  use Exporter 'import';
  our @EXPORT_OK = qw(file_read_firstline run_command file_get_contents exec_command);
  sub file_read_firstline { '' }
  sub file_get_contents   { '' }
  sub exec_command        { 1 }
  sub run_command {
    my ( $cmd, %o ) = @_;
    my $f = $o{ outfunc };
    my $j = join ' ', @$cmd;
    if ( $j =~ /-m session -r (\d+) -u/ ) { push @logouts, $1; return 1; }
    if ( $j =~ /--op delete/ )            { push @deletes, $j;  return 1; }
    if ( $j =~ /-m session -r \d+ -P 3/ ) { return 1; }
    if ( $j =~ /-m session\z/ ) {
      $f->($_) for (
        "tcp: [1] 10.0.0.1:3260,1 $live (non-flash)",
        "tcp: [2] 10.0.0.1:3260,1 $stale (non-flash)",
        "tcp: [3] 10.0.0.1:3260,1 $busy (non-flash)",
        "tcp: [4] 10.9.9.9:3260,1 $other (non-flash)",
        "tcp: [5] 10.0.0.5:3260,1 $truenas (non-flash)",
      );
      return 1;
    }
    if ( $j =~ /-m node\z/ ) {
      $f->($_) for (
        "10.0.0.1:3260,1 $live",
        "10.0.0.1:3260,1 $stale",
        "10.9.9.9:3260,1 $other",
      );
      return 1;
    }
    if ( $j =~ /--targetname (\S+)/ ) { $f->("10.0.0.1:3260,1 $1") if $f; return 1; }
    return 1;
  }
  $INC{'PVE/Tools.pm'} = 1;
}

require './NimbleStoragePlugin.pm';
my $P = 'PVE::Storage::Custom::NimbleStoragePlugin';
{
  no warnings 'redefine';
  no strict 'refs';
  *{"${P}::nimble_iscsiadm_path"} = sub { $fake_iscsiadm };
  # $busy is held open by a VM; everything else is idle.
  *{"${P}::nimble_iscsi_target_in_use"} = sub { my ($iqn) = @_; return $iqn eq $busy ? 1 : 0; };
}
# sendtargets on this array reports only $live (on 10.0.0.1)
my @recs = ( { iqn => $live, portal => '10.0.0.1:3260' } );
$P->can('nimble_iscsi_prune_stale_targets')->( 'tst', ['10.0.0.1'], \@recs, 0 );

is_deeply( \@logouts, [2], 'only the stale, idle, same-array session is logged out (not live, in-use, other array, TrueNAS)' );
is( scalar @deletes, 1, 'exactly one node record is deleted' );
like( $deletes[0], qr/vm-101-disk-0/, 'the deleted node record is the stale IQN' );

@logouts = @deletes = ();
$P->can('nimble_iscsi_prune_stale_targets')->( 'tst', ['10.0.0.1'], [], 0 );
is( scalar @logouts + scalar @deletes, 0, 'empty sendtargets listing prunes nothing' );

is( $P->can('nimble_iscsi_portal_host')->('10.0.0.1:3260,2460'), '10.0.0.1', 'portal_host strips port and tpgt' );
is( $P->can('nimble_iscsi_portal_host')->('[fe80::1]:3260'),     'fe80::1',  'portal_host handles bracketed IPv6' );

done_testing();
