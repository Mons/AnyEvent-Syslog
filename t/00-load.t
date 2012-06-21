#!/usr/bin/env perl -w

use common::sense;
use lib::abs '../lib';
use Test::More tests => 2;
use Test::NoWarnings;

BEGIN {
	use_ok( 'AnyEvent::Syslog' );
}

diag( "Testing AnyEvent::Syslog $AnyEvent::Syslog::VERSION, Perl $], $^X" );
