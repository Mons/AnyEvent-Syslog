package AnyEvent::Syslog;

use 5.008008;
use common::sense 2;m{
use strict;
use warnings;
};
use Carp;
use File::Basename;
use AnyEvent::Socket;

=head1 NAME

AnyEvent::Syslog - Nonblocking work with syslog

=cut

our $VERSION = '0.01'; $VERSION = eval($VERSION);

=head1 SYNOPSIS

    package Sample;

    use AnyEvent::Syslog;
    my $log = AnyEvent::Syslog->new(
        facility => 'local1',
        ident    => 'sample',
    );

    $log->syslog( 'debug|local1|local2', "XXX ".time." test \n x" );
    $log->syslog( 'info', "XXX ".time." test \n x" );

=head1 DESCRIPTION

    ...

=cut

use Socket qw(sockaddr_un AF_UNIX SOCK_STREAM SOCK_DGRAM);
use AnyEvent::Util qw(guard fh_nonblocking);
use Errno ();
use Scalar::Util;

sub LOG_EMERG    () { 0 }
sub LOG_ALERT    () { 1 }
sub LOG_CRIT     () { 2 }
sub LOG_ERR      () { 3 }
sub LOG_WARNING  () { 4 }
sub LOG_NOTICE   () { 5 }
sub LOG_INFO     () { 6 }
sub LOG_DEBUG    () { 7 }

our %LEVEL = (
        emerg     => LOG_EMERG,
        alert     => LOG_ALERT,
        crit      => LOG_CRIT,
        err       => LOG_ERR,
        error     => LOG_ERR,
        warning   => LOG_WARNING,
        warn      => LOG_WARNING,
        notice    => LOG_NOTICE,
        info      => LOG_INFO,
        debug     => LOG_DEBUG,
);

sub LOG_KERN     () { 0 }
sub LOG_USER     () { 8 }
sub LOG_MAIL     () { 16 }
sub LOG_DAEMON   () { 24 }
sub LOG_AUTH     () { 32 }
sub LOG_SYSLOG   () { 40 }
sub LOG_LPR      () { 48 }
sub LOG_NEWS     () { 56 }
sub LOG_UUCP     () { 64 }
sub LOG_CRON     () { 72 }
sub LOG_AUTHPRIV () { 80 }
sub LOG_FTP      () { 88 }
sub LOG_LOCAL0   () { 128 }
sub LOG_LOCAL1   () { 136 }
sub LOG_LOCAL2   () { 144 }
sub LOG_LOCAL3   () { 152 }
sub LOG_LOCAL4   () { 160 }
sub LOG_LOCAL5   () { 168 }
sub LOG_LOCAL6   () { 176 }
sub LOG_LOCAL7   () { 184 }

our %FACILITY = (
        kern      => LOG_KERN,
        user      => LOG_USER,
        mail      => LOG_MAIL,
        daemon    => LOG_DAEMON,
        auth      => LOG_AUTH,
        syslog    => LOG_SYSLOG,
        lpr       => LOG_LPR,
        news      => LOG_NEWS,
        uucp      => LOG_UUCP,
        cron      => LOG_CRON,
        authpriv  => LOG_AUTHPRIV,
        ftp       => LOG_FTP,
        local0    => LOG_LOCAL0,
        local1    => LOG_LOCAL1,
        local2    => LOG_LOCAL2,
        local3    => LOG_LOCAL3,
        local4    => LOG_LOCAL4,
        local5    => LOG_LOCAL5,
        local6    => LOG_LOCAL6,
        local7    => LOG_LOCAL7,
);


sub new {
	my $pk = shift;
	my $self = bless {
		facility    => 'user',
		socket      => '/dev/log',
		socket_type => SOCK_STREAM,
		pid         => 1,
		@_,
	}, $pk;
	$self->{ident} = basename($0) || getlogin() || getpwuid($<) || 'syslog' unless length $self->{ident};
	-S $self->{socket} or -c $self->{socket}  or croak "$self->{socket} is not a socket";
	exists $FACILITY{$self->{facility}} or croak "Unknown facility: $self->{facility}";
	$self->{facility} = $FACILITY{$self->{facility}};
	$self->{wsize} = 1;
	$self->{wlast} = $self->{wbuf} = { s => 0 };
	$self;
}

sub _connect_error {
	weaken(my $self = shift);
	$self->{cnt} = AE::timer 1,0,sub {
		$self or return;
		delete $self->{cnt};
		$self->{connecting} = 0;
		$self->_connect_last;
	};
}

use uni::perl ':dumper';

sub _connect_ready {
	my ($self,$sock) = @_;
	$self->{fh} = $sock;
	$self->{ww} = AE::io $sock, 1, sub {
		if (my $sin = getpeername $self->{fh}) {
			my ($port, $host) = AnyEvent::Socket::unpack_sockaddr $sin;
			warn dumper [$port,$host];
			delete $self->{ww};delete $self->{to};
			$self->_connected;
		} else {
			if ($! == Errno::ENOTCONN) {
				sysread $self->{fh}, my $buf, 1;
				$! = (unpack "l", getsockopt $self->{fh}, Socket::SOL_SOCKET(), Socket::SO_ERROR()) || Errno::EAGAIN
					if AnyEvent::CYGWIN && $! == Errno::EAGAIN;
			}
			return if $! == Errno::EAGAIN;
			delete $self->{ww}; delete $self->{to};
			return $self->_connect_error( "Can't connect socket: $!" );
		}
	};
}

sub _connect_stream {
	my $self = shift;
	$self->{connecting} = 1;
	my $addr = sockaddr_un $self->{socket};
	socket my $sock, AF_UNIX, SOCK_STREAM, 0
		or return $self->_connect_error( "Can't create stream socket: $!" );
	if (connect ($sock, $addr) or $! == Errno::EINPROGRESS or $! == Errno::EWOULDBLOCK) {
		$self->{connected_last} = '_connect_stream';
		$self->_connect_ready($sock);
	}
	elsif( $! == Errno::EPROTOTYPE ) {
		delete $self->{connected_last};
		return $self->_connect_dgram;
	}
	else {
		return $self->_connect_error( "Can't connect stream socket: $!" );
	}
}

sub _connect_dgram {
	my $self = shift;
	my $addr = sockaddr_un $self->{socket};
	socket my $sock, AF_UNIX, SOCK_DGRAM, 0
		or return $self->_connect_error( "Can't create dgram socket: $!" );
	if (connect ($sock, $addr) or $! == Errno::EINPROGRESS or $! == Errno::EWOULDBLOCK) {
		$self->{connected_last} = '_connect_dgram';
		$self->_connect_ready($sock);
	}
	else {
		return $self->_connect_error( "Can't connect dgram socket: $!" );
	}
}

sub _connect_last {
	my $self = shift;
	if (exists $self->{connected_last}) {
		my $m = delete  $self->{connected_last};
		$self->$m();
	} else {
		$self->_connect_stream;
	}
}

sub _connected {
	my $self = shift;
	$self->{connected} = 1;
	delete $self->{connecting};
	$self->_ww;
}

sub insert_after {
	my ($self,$cur,$data,$msgs) = @_;
	my $next;
	if (exists $cur->{next}) {
		# add to middle
		$next = $cur->{next};
	#} else {
		# add to tail
	}
	my $seq = $cur->{s};
	my $s = 0;
	for (@$msgs) {
		$s++;
		#warn "insert after: $seq: $s";
		$cur->{next} = {
			%$data,
			s => $seq.'.'.$s,
			w => $_,
		};
		$self->{wsize}++;
		$cur = $cur->{next};
	}
	 if (defined $next) {
		$cur->{next} = $next;
	} else {
		$self->{wlast} = $cur;
	}
}

sub _ww {
	Scalar::Util::weaken( my $self = shift );
	delete $self->{ww};
	return unless $self->{fh};
	my $cur = $self->{wbuf};
	warn "enter _ww: $cur->{s}";
	while ( !exists $cur->{w} and exists $cur->{next} ) {
		$self->{wsize}--;
		$self->{wbuf} = $cur = $cur->{next};
	};
	while (exists $cur->{w} or exists $cur->{next}) {
		if (my $ref = ref $cur->{w}) {
			if ($ref eq 'CODE') {
				$cur->{w}->($cur);
			} else {
				warn "Doesn't know how to process $ref";
			}
			delete $cur->{w};
		}
		if (!exists $cur->{w}) {
			if (exists $cur->{next}) {
				my $prev = $cur;
				$self->{wbuf} = $cur = $cur->{next};
				$self->{wsize}--;
				warn "take next $cur->{s} after $prev->{s} (left $self->{wsize})";
				next;
			}
			last;
		}
		if ($self->{max_msg_size} and length $cur->{w} > $self->{max_msg_size}) {
			my $size = $self->{max_msg_size};
			my @parts = $cur->{w} =~ /\G(.{1,$size})/gc;
			$cur->{w} = shift @parts;
			$self->insert_after($cur,{
				pre => $cur->{pre},
				eol => $cur->{eol},
			}, \@parts);
		}
		my $buf = $cur->{pre}.$cur->{w}.$cur->{eol};
		my $need = length $buf;
		#warn "writing $need bytes [".substr($buf,0,length($buf) - 2)."]";
		warn "writing $cur->{s}";
		my $len = syswrite $self->{fh}, $buf, $need, 0;
		if (defined $len) {
			if ($need > $len) {
				if ($len < length $cur->{pre} + length $cur->{eol}) {
					die "TODO: Can't write message [$buf]: even prefix not written";
				}
				my $left = substr( $buf, $len );
				substr($left, -length $cur->{eol}, length $cur->{eol}, '');# cut EOL
				warn "Not written complete message: need $need, written: $len. Wrap [$left] to next step";
				$self->insert_after($cur,{
					pre => $cur->{pre},
					eol => $cur->{eol},
				}, [ substr( $buf, $len ) ]);
			}
			$cur->{written} = $len;
			delete $cur->{w};
			next;
		}
		elsif ($! == Errno::EMSGSIZE or $! == Errno::ENOBUFS) {
			#warn "$! ($need)";
			if (exists $cur->{max_detect}) {
				my $dt = $cur->{max_detect};
				$dt->{left} = substr( $cur->{w},length($cur->{w}) - 1, 1, '' ).$dt->{left};
				$dt->{size} = length($cur->{w});
			} else {
				my $next;
				my $wcur = $cur;
				my $detect = $cur->{max_detect} = {
					left => substr( $cur->{w},length($cur->{w}) - 1, 1, '' ),
				};
				$detect->{size} = length($cur->{w});
				
				$next = exists $cur->{next} && $cur->{next};
				$self->insert_after($cur,{},[sub {
					#warn "sub ".dumper $_[0];
					$self->{max_msg_size} = $detect->{size};
					$self->{max_buf_size} = $wcur->{written};
					
					#warn "Full wbuf: ".dumper $wcur, $detect, $self;
					warn "Detected size: $self->{max_msg_size} ($self->{max_buf_size}). Left: $detect->{left}";
					$self->insert_after($_[0],$wcur,[ $detect->{left} ]);
					
					undef $detect;
					undef $wcur;
					#exit;
				}]);
				unless (defined $next) {
					$self->{wlast} = $cur->{next};
				}
			}
			redo;
		}
		elsif ( $! == Errno::EAGAIN or $! == Errno::EINTR ) {
			warn "Not written completely: $!";
			return $self->{ww} = &AE::io( $self->{fh}, 1, sub { $self and $self->_ww; });
		}
		else {
			warn "Socket connection aborted: $!";
			#$cur->{w} = '';
			$self->{connected} = 0;
			$self->_connect_stream;
		}
	}
	warn "leaving _WW";
	$self->_printq;
}


sub sock_connect {
	shift->_connect_stream;
}

use Sys::Syslog ':macros';
use POSIX ();

sub stime () {
	my $oldlocale = POSIX::setlocale(POSIX::LC_TIME);
	POSIX::setlocale(POSIX::LC_TIME, 'C');
	my $timestamp = POSIX::strftime "%b %e %H:%M:%S", localtime;
	POSIX::setlocale(POSIX::LC_TIME, $oldlocale);
	$timestamp;
}

sub _printq {
	my $self = shift;
	my $cur = $self->{wbuf};
	while($cur) {
		print "$cur->{s}(".length($cur->{w}).") ";
		if (exists $cur->{next}) {
			$cur = $cur->{next};
		} else {
			undef $cur;
		}
	}
	print "\n";
	
}

sub syslog {
	my $self = shift;
	my $to = shift;
	my $msg = shift; utf8::encode $msg if utf8::is_utf8 $msg;
	$msg =~ s{(\r?\n)+$}{}s;
	
	my @to = split '\|',$to;
	my @levels;
	my @facilities;
	for (@to) {
		if (exists $LEVEL{$_}) {
			push @levels, $LEVEL{$_};
		}
		elsif (exists $FACILITY{$_}) {
			push @facilities, $FACILITY{$_};
		}
		else {
			carp "Unknown level or facility: '$_'";
		}
	}
	@levels = (LOG_INFO) unless @levels;
	@facilities = ($self->{facility}) unless @facilities;
	my $levels = 0; $levels |= $_ for @levels;
	
	for my $facility (@facilities) {
		my $raw = sprintf "<%d>%s %s%s: ",
			$levels | $facility,
			stime,
			$self->{ident}, $self->{pid} ? "[$$]" : '',
		;
		my @parts;
		if ($self->{max_msg_size} and length $msg > $self->{max_msg_size}) {
			my $size = $self->{max_msg_size};
			@parts = $msg =~ /\G(.{1,$size})/gc;
			#warn "Splitted [$msg] into ".join ',',map { "[$_]\n" } @parts;
		} else {
			@parts = ($msg);
		}
		for (@parts) {
			$self->{wsize}++;
			$self->{seq}++;
			#warn "add new $self->{seq} (".length($_)."): as follower for $self->{wlast}{s} (left $self->{wsize})";
			my $l = { w => $_, s => $self->{seq}, pre => $raw, eol => "\n\0" };
			$self->{wlast}{next} = $l;
			$self->{wlast} = $l;
		}
	}
	$self->_printq;
	#warn dumper $self->{wbuf};
	if ($self->{connected}) {
		$self->_ww;
	} else {
		return if $self->{connecting};
		$self->_connect_stream;
	}
	return;
}

=head1 AUTHOR

Mons Anderson, C<< <mons@cpan.org> >>

=head1 COPYRIGHT & LICENSE

Copyright 2012 Mons Anderson, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

=cut

1;
