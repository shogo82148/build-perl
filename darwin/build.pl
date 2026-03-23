#!/usr/bin/env perl

use utf8;
use warnings;
use strict;
use 5.026001;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Try::Tiny;
use Devel::PatchPerl;
use Perl::Build;
use File::pushd qw[pushd];
use File::Spec;
use File::Path qw/make_path/;
use version 0.77 ();
use Carp qw/croak/;

my $version = $ENV{PERL_VERSION};
my $thread = $ENV{PERL_MULTI_THREAD};

if (version->parse("v$version") >= version->parse("v5.42.0")) {
    # monkey patch Devel::PatchPerl to allow patching perl source
    # https://github.com/bingos/devel-patchperl/issues/64
    no warnings 'redefine';
    no strict 'refs';
    *Devel::PatchPerl::patch_source = sub {
        my $vers = shift;
        $vers = shift if eval { $vers->isa('Devel::PatchPerl') };
        my $source = shift || '.';
        if ( !$vers ) {
            $vers = Devel::PatchPerl::_determine_version($source);
            if ( $vers ) {
                warn "Auto-guessed '$vers'\n";
            }
            else {
                die "You didn't provide a perl version and I don't appear to be in a perl source tree\n";
            }
        }

        $source = File::Spec->rel2abs($source);

        my $patch_exe = Devel::PatchPerl::_can_run('gpatch') || Devel::PatchPerl::_can_run('patch');
        {
            my $dir = pushd( $source );
            Devel::PatchPerl::_process_plugin( version => $vers, source => $source, patchexe => $patch_exe );
        }
    };
}

if (version->parse("v$version") >= version->parse("v5.8.9") &&
    version->parse("v$version") <= version->parse("v5.10.0")) {
    # monkey patch Devel::PatchPerl::_patch to fix mkppport.lst patching on Darwin.
    # Devel::PatchPerl::_patch_dbfile_clang uses ext/Win32API/File as context in
    # its mkppport.lst diff, which doesn't exist on Darwin, causing patch(1) to fail.
    # Replacing _patch_dbfile_clang doesn't work because it is captured by reference
    # in Devel::PatchPerl's @patch array at compile time. Instead, we override _patch,
    # which is called by name (dynamically) from _patch_b64, so the replacement takes
    # effect at runtime.
    # https://github.com/bingos/devel-patchperl/issues/65
    no warnings 'redefine';
    no strict 'refs';
    my $orig_patch = \&Devel::PatchPerl::_patch;
    *Devel::PatchPerl::_patch = sub {
        my ($patch) = @_;
        if ($patch =~ /^\+{3}\s+mkppport\.lst\b/m) {
            # The upstream patch uses ext/Win32API/File as context, which doesn't
            # exist on Darwin. Use file I/O to append ext/DB_File instead.
            print "patching mkppport.lst\n";
            my $file = 'mkppport.lst';
            my $content = do {
                local $/;
                open my $fh, '<', $file or die "Can't open $file: $!";
                my $data = <$fh>;
                close $fh;
                $data;
            };
            unless ($content =~ /^ext\/DB_File\b/m) {
                chmod 0644, $file or die "Can't chmod $file: $!";
                open my $fh, '>>', $file or die "Can't open $file for append: $!";
                print $fh "ext/DB_File\n";
                close $fh;
            }
            return;
        }
        $orig_patch->(@_);
    };
}

my $tmpdir = File::Spec->rel2abs($ENV{RUNNER_TEMP} || "tmp");
make_path($tmpdir);
my $runner_tool_cache = $tmpdir;
if (my $cache = $ENV{RUNNER_TOOL_CACHE}) {
    # install path is hard coded in the action, so check whether it has expected value.
    if ($cache ne '/Users/runner/hostedtoolcache') {
        die "unexpected RUNNER_TOOL_CACHE: $cache";
    }
    $runner_tool_cache = $cache;
}
chomp (my $arch = `uname -m`);
if ($arch eq 'x86_64') {
    $arch = 'x64';
} elsif ($arch eq 'arm64' || $arch eq 'aarch64') {
    $arch = 'arm64';
} else {
    die "unsupported arch: $arch";
}
my $install_dir = File::Spec->rel2abs(
    File::Spec->catdir($runner_tool_cache, "perl", $version . ($thread ? "-thr" : ""), $arch));
my $perl = File::Spec->catfile($install_dir, 'bin', 'perl');

sub execute_or_die {
    say "::debug::executing @_";
    my $code = system(@_);
    if ($code != 0) {
        my $cmd = join ' ', @_;
        croak "failed to execute $cmd: exit code $code";
    }
}

sub cpan_install {
    my ($url, $fragment, $name, $min_version, $max_version) = @_;

    my $skip = try {
        # this perl is too old to install the module.
        if ($min_version && version->parse("v$version") < version->parse("v$min_version")) {
            return 1;
        }
        # no need to install
        if ($max_version && version->parse("v$version") >= version->parse("v$max_version")) {
            return 1;
        }
        return 0;
    } catch {
        # perhaps, we couldn't parse the version.
        # try installing.
        return 0;
    };
    return if $skip;

    say "::group::installing $name from $url";

    local $ENV{PATH} = "$install_dir/bin:$ENV{PATH}";
    my ($filename, $dirname);
    if ($url =~ m(^http://.*/([^/]+)/archive/(([0-9a-fA-F]+)[.]tar[.][0-9a-z]+))) {
        $dirname = "$1-$3";
        $filename = $2;
    } elsif ($url =~ m(^https://.*/(([^/]+)[.]tar[.][0-9a-z]+))) {
        $dirname = $2;
        $filename = $1
    }

    chdir $tmpdir or die "failed to cd $tmpdir: $!";
    execute_or_die('curl', '--retry', '3', '-sSL', $url, '-o', $filename);
    execute_or_die('tar', 'xvf', $filename);
    chdir File::Spec->catfile($tmpdir, $dirname) or die "failed to cd $dirname: $!";
    execute_or_die($perl, 'Makefile.PL');
    execute_or_die('make', 'install');
    execute_or_die($perl, "-M$name", "-e1");

    say "::endgroup::";
}

sub run {
    {
        say "::group::building perl-$version";
        local $ENV{PERL5_PATCHPERL_PLUGIN} = "GitHubActions";

        # get the number of CPU cores to parallel make
        my $jobs = `sysctl -n hw.logicalcpu_max` + 0;
        if ($jobs <= 0 || version->parse("v$version") < version->parse("v5.30.0")) {
            # Makefiles older than v5.30.0 could break parallel make.
            $jobs = 1;
        }

        my @options = (
            "-de",
            # omit man
            "-Dman1dir=none", "-Dman3dir=none",
        );
        # enable shared library and PIC, fixes https://github.com/shogo82148/actions-setup-perl/issues/1756
        # on perl 5.8.8 or earlier, useshrplib doesn't work.
        if (version->parse("v$version") >= version->parse("v5.8.9")) {
            push @options, "-Dcccdlflags=-fPIC", "-Duseshrplib";
        }
        if ($thread) {
            # enable multi threading
            push @options, "-Duseithreads";
        }

        Perl::Build->install_from_cpan(
            $version => (
                dst_path          => $install_dir,
                configure_options => \@options,
                jobs              => $jobs,
            )
        );
        say "::endgroup::";
    }

    execute_or_die($perl, '-V');

    # cpanm or carton doesn't work with very very old version of perl.
    # so we manually install CPAN modules.
    {
        say "::group::installing CPAN modules";

        # JSON
        # JSON doesn't work with perl 5.6.x, skip it. https://github.com/shogo82148/build-perl/issues/3
        cpan_install('https://cpan.metacpan.org/authors/id/I/IS/ISHIGAKI/JSON-4.10.tar.gz', 'JSON', 'JSON', '5.8.0');

        # Cpanel::JSON::XS
        cpan_install('https://cpan.metacpan.org/authors/id/R/RU/RURBAN/Cpanel-JSON-XS-4.37.tar.gz', 'Cpanel-JSON-XS', 'Cpanel::JSON::XS', '5.6.2');

        # some requirements of JSON::XS
        cpan_install('https://cpan.metacpan.org/authors/id/M/ML/MLEHMANN/Canary-Stability-2013.tar.gz', 'Canary-Stability', 'Canary::Stability', '5.8.3');
        cpan_install('https://cpan.metacpan.org/authors/id/M/ML/MLEHMANN/common-sense-3.75.tar.gz', 'common-sense', 'common::sense', '5.8.3');
        cpan_install('https://cpan.metacpan.org/authors/id/M/ML/MLEHMANN/Types-Serialiser-1.01.tar.gz', 'Types-Serialiser', 'Types::Serialiser', '5.8.3');
        # JSON::XS
        cpan_install('https://cpan.metacpan.org/authors/id/M/ML/MLEHMANN/JSON-XS-4.03.tar.gz', 'JSON-XS', 'JSON::XS', '5.8.3');

        # some requirements of JSON::PP
        cpan_install('https://cpan.metacpan.org/authors/id/C/CO/CORION/parent-0.241.tar.gz', 'parent', 'parent', '5.8.1', '5.10.1');
        cpan_install('https://cpan.metacpan.org/authors/id/P/PE/PEVANS/Scalar-List-Utils-1.63.tar.gz', 'Scalar-List-Utils', 'Scalar::Util', '5.8.1', '5.8.1');
        # JSON::PP
        cpan_install('https://cpan.metacpan.org/authors/id/I/IS/ISHIGAKI/JSON-PP-4.16.tar.gz', 'JSON-PP', 'JSON::PP', '5.8.1');

        # JSON::MaybeXS
        # JSON::MaybeXS doesn't work with perl 5.6.1, skip it. workaround for https://github.com/shogo82148/build-perl/issues/15
        cpan_install('https://cpan.metacpan.org/authors/id/E/ET/ETHER/JSON-MaybeXS-1.004005.tar.gz', 'JSON-MaybeXS', 'JSON::MaybeXS', '5.6.2');

        # YAML
        cpan_install('https://cpan.metacpan.org/authors/id/I/IN/INGY/YAML-1.31.tar.gz', 'YAML', 'YAML', '5.8.1');

        # YAML::Tiny
        cpan_install('https://cpan.metacpan.org/authors/id/E/ET/ETHER/YAML-Tiny-1.74.tar.gz', 'YAML-Tiny', 'YAML::Tiny', '5.8.1');

        # YAML::XS
        # workaround for https://github.com/shogo82148/build-perl/issues/12
        # YAML::XS 0.88 doesn't work with perl 5.10.0, 5.8.9.
        cpan_install('https://cpan.metacpan.org/authors/id/I/IN/INGY/YAML-LibYAML-0.88.tar.gz', 'YAML-LibYAML', 'YAML::XS', '5.8.1', '5.8.9');
        cpan_install('https://cpan.metacpan.org/authors/id/I/IN/INGY/YAML-LibYAML-0.88.tar.gz', 'YAML-LibYAML', 'YAML::XS', '5.10.1');

        ### SSL/TLS

        # Net::SSLeay
        cpan_install('https://cpan.metacpan.org/authors/id/C/CH/CHRISN/Net-SSLeay-1.92.tar.gz', 'Net-SSLeay', 'Net::SSLeay', '5.8.1');

        # Mozilla::CA
        cpan_install('https://cpan.metacpan.org/authors/id/L/LW/LWP/Mozilla-CA-20231213.tar.gz', 'Mozilla-CA', 'Mozilla::CA', '5.6.0');

        # IO::Socket::SSL
        cpan_install('https://cpan.metacpan.org/authors/id/S/SU/SULLR/IO-Socket-SSL-2.084.tar.gz', 'IO-Socket-SSL', 'IO::Socket::SSL', '5.8.1');

        # Test::Harness
        cpan_install('https://cpan.metacpan.org/authors/id/L/LE/LEONT/Test-Harness-3.48.tar.gz', 'Test-Harness', 'Test::Harness', '5.6.0', '5.8.3');

        # requirements of Module::CoreList
        # version doesn't work with perl 5.8.0. skip it. workaround for https://github.com/shogo82148/build-perl/issues/2
        cpan_install('https://cpan.metacpan.org/authors/id/L/LE/LEONT/version-0.9930.tar.gz', 'version', 'version', '5.6.0', '5.8.0');
        cpan_install('https://cpan.metacpan.org/authors/id/L/LE/LEONT/version-0.9930.tar.gz', 'version', 'version', '5.8.1', '5.8.9');
        # Module::CoreList
        cpan_install('https://cpan.metacpan.org/authors/id/B/BI/BINGOS/Module-CoreList-5.20231230.tar.gz', 'Module-CoreList', 'Module::CoreList', '5.6.0', '5.8.0');
        cpan_install('https://cpan.metacpan.org/authors/id/B/BI/BINGOS/Module-CoreList-5.20231230.tar.gz', 'Module-CoreList', 'Module::CoreList', '5.8.1', '5.8.9');

        say "::endgroup::";
    }

    {
        my $dist = "$tmpdir/perl-$version".($thread ? "-thr" : "")."-darwin-$arch.tar.zstd";
        say "::group::archiving perl-$version";
        chdir $install_dir or die "failed to cd $install_dir: $!";
        execute_or_die("tar", "--use-compress-program", "zstd -T0 --long=30 --ultra -22", "-cf", $dist, ".");
        say "::endgroup::";
    }
}

run();

1;
