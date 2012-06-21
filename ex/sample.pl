#!/usr/bin/env perl

use uni::perl ':dumper';
use lib::abs '../lib';
use AnyEvent::Syslog;
use EV;

say "my pid is $$";

my $t = AE::timer 0,1,sub {};

my $sl = AnyEvent::Syslog->new(
#	facility => 'local1',
	ident    => 'sample',
);

my $long = join('','0'..'9','a'..'z');
$long .= $long while length $long < 2020;
$long = substr($long,0,2020);

my $z; $z = AE::timer 1, 1, sub {
	#$sl->syslog( 'debug|local1|local2', "XXX ".time." test \n x" );
	$sl->syslog( 'info', "XXX ".time." test \n x" );
	$sl->syslog( 'info', $long );
	$sl->syslog( 'info', "XXX ".time." test \n x" );
	#undef $z;
};

EV::loop;

