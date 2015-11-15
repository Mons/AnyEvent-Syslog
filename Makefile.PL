use 5.008008;
use ExtUtils::MakeMaker;
$ENV{AUTHOR} and require CPAN::Meta;

WriteMakefile(
	NAME              => 'AnyEvent::Syslog',
	VERSION_FROM      => 'lib/AnyEvent/Syslog.pm',
	BUILD_REQUIRES => {
		'Test::More' => 0,
	},
	PREREQ_PM         => {
		AnyEvent => 7,
		'common::sense' => 2,
	},
	ABSTRACT_FROM  => 'lib/AnyEvent/Syslog.pm', # retrieve abstract from module
	AUTHOR         => 'Mons Anderson <mons@cpan.org>',
	LICENSE        => 'perl',
);
