use inc::Module::Install;

my $MI  = $Module::Install::MAIN;
name           'AnyEvent-Syslog';
all_from       'lib/AnyEvent/Syslog.pm';
author         'Mons Anderson <mons@cpan.org>';
license        'perl';

build_requires 'Test::More';
build_requires 'lib::abs',  '0.90';

requires 'common::sense',    2;
# requires 'uni::perl';

auto_provides;
auto_install;

WriteAll;

print STDERR "Generated makefile for ".$MI->load('name')->name."-".$MI->load('version')->version."\n";
