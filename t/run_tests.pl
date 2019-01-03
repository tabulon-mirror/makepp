#!/usr/bin/env perl
#
# See bottom of file for documentation.
#

package Mpp;

use lib '.';			# May have been removed for security.
use Config;
use Cwd;
use File::Path;

# on some (Windowsish) filesystems rmtree may temporarily fail
sub slow_rmtree(@) {
  for my $tree ( grep -d, @_ ) {
    for( 0..20 ) {
      select undef, undef, undef, .1 if $_;
      eval { local $SIG{__WARN__} = sub { $@ = $_[0] }; rmtree $tree }; # don't die, can have chdir'ed
      -d $tree or last;
    }
    warn $@ if $@;
  }
}


#
# See if this architecture defines the INT signal.
#
my $sigint;
if(defined $Config{sig_name}) {
  my $i=0;
  for(split(' ', $Config{sig_name})) {
    $sigint=$i,last if $_ eq 'INT';
    ++$i;
  }
}

my $archive = $Config{perlpath}; # Temp assignment is work-around for a nasty perl5.8.0 bug
our $source_path;
my $old_cwd;
my $dot;
my $verbose;
my $test;
my $keep;
my $basedir;
my $dotted;
our $makepp_path;

# Global constants for compile time check.
BEGIN {
  open OSTDOUT, '>&STDOUT' or die $!;
  open OSTDERR, '>&STDERR' or die $!;

  $old_cwd = cwd;		# Remember where we were so we can cd back here.

  if( $0 =~ m@/@ ) {		# Path specified?
    ($source_path = $0) =~ s@/[^/]+$@@; # Get the path to our script.
  } elsif( $ENV{PATH} =~ /[;\\]/ ) { # Find it in Win $PATH:
    foreach (split(/;/, $ENV{PATH}), '.') {
      my $dir = $_ || '.';	# Blank path element is .
      if( -e "$dir\\$0" ) {
	$source_path = $dir;
	last;
      }
    }
  } else {				# Find it in $PATH:
    foreach (split(/:/, $ENV{PATH}), '.') {
      my $dir = $_ || '.';	# Blank path element is .
      if( -x "$dir/$0" ) {
	$source_path = $dir;
	last;
      }
    }
  }
  $source_path or die "$0: something's wrong, can't find path to executable\n";
  $source_path =~ m@^/@ or $source_path = "$old_cwd/$source_path";
				# Make path absolute.
  $source_path =~ s@/(?:\./)+@/@;
  $source_path =~ s@/\.$@@;
  1 while
    ($source_path =~ s@/\.(?=/|$)@@) || # Convert x/./y into x/y.
    ($source_path =~ s@/[^/]+/\.\.(?=/|$)@@); # Convert x/../y into y.

  $makepp_path = $source_path;
  $makepp_path =~ s@/([^/]+)$@/makepp@; # Get the path to the makepp
				# executable, which should always be in the
				# directory above us.

  our $datadir = substr $makepp_path, 0, rindex $makepp_path, '/';
  push @INC, $datadir;
  unless( eval { require Mpp::Text } ) {
    open my $fh, '<', $makepp_path;
    while( <$fh> ) {
      if( /^\$datadir = / ) {
	eval;
	$INC[-1] = $datadir;
	require Mpp::Text;
	last;
      }
      die "$0: Can't locate path to makepp libraries." if $. == 99;
    }
  }

  if( $^O =~ /^MSWin/ && $] < 5.008007 ) { # IDENTICAL AS IN makepp
    # This is a very bad hack!  On earlier Win Active State "lstat 'file'; lstat _ or -l _" is broken.
    my $file = "$datadir/Mpp/File.pm";
    local $_ = "$file.broken";
    unless( -f ) {		# Already converted
      rename $file, $_;
      open my $in, '<', $_;
      open my $out, '>', $file;
      chmod 07777 & (stat)[2], $file;
      while( <$in> ) {
	s/\blstat\b/stat/g;
	s/-l _/0/g;
	print $out $_;
      }
    }
  }

  Mpp::Text::getopts(
    [qw(b basedir), \$basedir, 1],
    [qw(d dots), \$dot],
    [qw(k keep), \$keep],
    [qw(m makepp), \$makepp_path, 1],
    [qw(n name), \my $name, 1],
    [qw(s subdir), \my $subdir],
    [qw(t test), \$test],
    [qw(v verbose), \$verbose],
    [qr/[h?]/, 'help', undef, 0, sub { print <<EOF; exit }] );
run_tests.pl[ options][ tests]
    -b, --basedir=BASEDIR
	Put tdirs into subdir of given dir, to perform tests elsewhere.
    -d, --dots
	Output only a dot for every successful test.
    -k, --keep
	Keep the tdir even if the test was successful.
    -m, --makepp=PATH_TO_MAKEPP
	Use that makepp, instead of the one above run_tests.pl.
    -n, --name=NAME
	Give this test series a name.
    -s, --subdir
	Put tdirs into a subdir named [BASEDIR/]perlversion[-NAME].
    -t, --test
	Output in format expected by TAP::Harness.
    -v, --verbose
	Give some initial info and final statistics.

    If no tests are given, runs all in the current directory.
EOF

  require Mpp::Utils;
  require Mpp::Cmds;
  for( keys %Mpp::Cmds:: ) {
    if( /^c_/ and my $coderef = *{"Mpp::Cmds::$_"}{CODE} ) {
      *{"Mpp::$_"} = $coderef;
    }
  }

  my $perltype =
    $Config{cf_email} =~ /(Active)(?:Perl|State)/ ? $1 :
    $Config{ldflags} =~ /(vanilla|strawb(?:erry|(?=~))|chocolate)/i ? ucfirst lc $1 :
    '';

  printf "%s%sPerl V%vd %dbits - %s %s\n",
    $name ? "$name " : '',
    $perltype,
    $^V, $Config{ptrsize} * 8, $^O, $Config{archname}
    if $verbose;

  if( defined $basedir ) {
    substr $basedir, 0, 0, "$old_cwd/" if &is_windows ? $basedir !~ /^(?:[a-z]:)?\//i : $basedir !~ /^\//;
    $basedir .= '/' if $basedir !~ /\/$/
  } else {
    $basedir = "$old_cwd/";
  }
  if( $subdir ) {
    $basedir .= sprintf $Config{ptrsize} == 4 ? 'V%vd' : 'V%vd-%dbits', $^V, $Config{ptrsize} * 8;
    $basedir .= "-$perltype" if $perltype;
    $basedir .= "-$name" if $name;
    slow_rmtree $basedir;
    $basedir .= '/';
  }
  -d $basedir or c_mkdir( -p => $basedir ) or die "$0: can't mkdir $basedir--$!";

  chdir $basedir;
  mkdir 'd';
  my $symlink = (stat 'd')[1] &&	# Do we have inums?
    eval { symlink 'd', 'e' } &&	# Dies on MSWin32.
    (stat _)[1] == (stat 'e')[1];	# MinGW emulates symlink by recursive copy, useless for repository.
  rmdir 'd';
  unlink 'e' or rmdir 'e';
  eval 'sub no_symlink() {' . ($symlink ? '' : 1) . '}';
  open my $fh, '>', 'f';		# Use different filename because rmdir may fail on Win
  close $fh;
  my $link = eval { link 'f', 'g' } &&	# might die somewhere
    ((stat 'f')[1] ?	# Do we have inums?
      (stat _)[1] == (stat 'g')[1] : # vfat emulates link by copy, useless for build_cache.

      (stat _)[3] == 2 && (stat 'g')[3] == 2); # Link count right?
  unlink 'f', 'g';
  eval 'sub no_link() {' . ($link ? '' : 1) . '}';
  chdir $old_cwd;
}

my( $cc_errors, $have_cc, $want_cc ) = 0;
my $cc_hint1 = 'This test needs a C compiler that accepts options in common order.
';
my $cc_hint = $cc_hint1 .
  ($ENV{CC} ? 'Please check your value of $CC' :
   'Old makes use CC=cc, but makepp may choose another compiler in $PATH') . ".\n" .
  ($ENV{CFLAGS} ?
  'Make sure that your CFLAGS are understood by the chosen compiler!
' : '');
sub have_cc() {
  $want_cc = 1;
  unless( defined $have_cc ) {
    $have_cc =
      $ENV{CC} ||
      system( PERL, '-w', $makepp_path.'builtin', 'expr',
	      # Use mpp's CC function without loading full mpp.  No "" because of fucked up Win.
	      'sub Mpp::log($@) {} sub Mpp::Makefile::implicitly_load {} close STDERR; q!not-found! eq Mpp::Subs::f_CC',
	      '-ohave_cc' ) ?
      1 : 0;
  }
  $have_cc;
}


$ENV{PERL} ||= PERL;
#delete $ENV{'MAKEPPFLAGS'};     # These environment variables can possibly
#delete $ENV{'MAKEFLAGS'};       # mess up makepp tests.
# For some reason, with Perl 5.8.4, deleting the environment variables doesn't
# actually remove them from the environment.
$ENV{"${_}FLAGS"} = ''
  for qw(MAKEPP MAKE MAKEPPBUILTIN MAKEPPCLEAN MAKEPPLOG MAKEPPGRAPH);


for( $ENV{PATH} ) {
  my $sep = is_windows > 0 ? ';' : ':';
  s/^\.?$sep+//;			# Make sure we don't rely on current dir in PATH.
  s/$sep+\.?$//;
  s/$sep+\.?$sep+/$sep/;
  $_ = "$source_path$sep$_";
}

#
# Equivalent of system() except that it handles INT signals correctly.
#
# If the first argument is a reference to a string, that is the command to report as failing, if it did fail.
#
sub system_intabort {
  my $cmd = ref( $_[0] ) && shift;
  system @_;
  kill 'INT', $$ if $sigint && $? == $sigint;
  if( $? && $cmd ) {
    if( $? == -1 ) {
      die "failed to execute $$cmd: $!\n"
    } elsif( $? & 127 ) {
      die sprintf "$$cmd died with signal %d%s coredump\n",
	($? & 127),  ($? & 128) ? ' and' : ', no';
    } else {
      die sprintf "$$cmd exited with value %d\n", $? >> 8;
    }
  }
  return $?;
}

my %file;
my $page_break = '';
my $log_count = 1;
sub makepp(@) {
  my $extra = ref $_[0];
  my $suffix = $extra ? ${shift()} : '';
  print $page_break;
  $page_break = "\cL\n";
  if( !$suffix && -f '.makepp/log' ) {
    chdir '.makepp';		# For Win.
    my $save = 'log' . $log_count++;
    print "saved log to $save\n"
      if rename log => $save;
    chdir '..';
  }
  print "makepp$suffix" . (@_ ? " @_\n" : "\n");
  system_intabort \"makepp$suffix", # "
    PERL, '-w', exists $file{'makeppextra.pm'} ? qw(-I. -Mmakeppextra) : (), $makepp_path.$suffix, @_;
  unless( $extra ) {
    for my $file ( <{*/*/*/,*/*/,*/,}.makepp/*.mk> ) {
      open my $fh, '<', $file;
      $file =~ s!\.makepp/(.+)\.mk$!$1!;
      -r $file && !-d _ or next;
      my $binfo = Mpp::File::grok_build_info_file $fh;
      my $sig = join ',', (stat _)[9,7];
      warn "$file $binfo->{SIGNATURE} vs. " . $sig
	if $binfo->{SIGNATURE} ne $sig;
    }
  }
  1;				# Command succeeded.
}

@ARGV or @ARGV = <*.test *.tar *.tar.gz>;
				# Get a list of arguments.

my $n_failures = 0;
my $n_successes = 0;

(my $wts = $0) =~ s/run_tests/wait_timestamp/;
do $wts;			# Preload the function.
eval { require Time::HiRes };	# Preload the library.

# spar <http://www.cpan.org/scripts/> extraction function
# assumes DATA to be opened to the spar
sub un_spar() {
    my( $lines, $kind, $mode, %mode, $atime, $mtime, $name, $nl ) = (-1, 0);
    while( <DATA> ) {
	s/\r?\n$//;		# cross-plattform chomp
	if( $lines >= 0 ) {
	    print F $_, $lines ? "\n" : $nl;
	} elsif( $kind eq 'L' ) {
	    if( $mode eq 'S' ) {
		symlink $_, $name;
	    } else {
		link $_, $name;
	    }
	    $kind = 0;
	} elsif( /^###\t(?!SPAR)/ ) {
	    (undef, $kind, $mode, $atime, $mtime, $name) = split /\t/, $_, 6;
	    if( !$name ) {
	    } elsif( $kind eq 'D' ) {
		$name =~ s!/+$!!;
		-d $name or mkdir $name, 0700 or warn "spar: can't mkdir `$name': $!\n";
		$mode{$name} = [$atime, $mtime, oct $mode];
	    } elsif( $kind ne 'L' ) {
		open F, '>', $name or warn "spar: can't open >`$name': $!\n";
		$lines = abs $kind;
		$nl = ($kind < 0) ? '' : "\n";
	    }
	} elsif( defined $mode ) {
	    warn "spar: $archive:$.: trailing garbage ignored\n";
	}			# else before beginning of spar
    } continue {
	if( !$lines-- ) {
	    close F;
	    chmod oct( $mode ), $name and
		utime $atime, $mtime, $name or
		warn "spar: $archive:$name: Failed to set file attributes: $!\n";
	}
    }

    for( keys %mode ) {
	chmod pop @{$mode{$_}}, $_ and
	    utime @{$mode{$_}}, $_ or
	    warn "spar: $archive:$_: Failed to set directory attributes: $!\n";
    }
}


# With -d report '.' for success, 's' for skipped because of symlink failure,
# 'w' for not applicable on Windows, '-' for otherwise skipped.
sub dot($$;$) {
  if( defined $_[0] ) {
    if( $test ) {
      for( "$_[1]" ) {
	s/^passed // || s/^skipped/# skip/;
	print "ok $test $_";
      }
      $test++;
    } else {
      print $_[$dot ? 0 : 1];
      $dotted = 1 if $dot;
    }
    return;
  } elsif( $test ) {
    print "not ok $test $_[1]";
    $test++;
  } else {
    print "\n" if defined $dotted;
    print "FAILED $_[1]";
    undef $dotted;
  }
  if( $_[2] ) {			# See the error in logs that people send in.
    open my $fh, '>>', $_[2];
    print $fh "\nmakepp: run_tests.pl `FAILED' $_[1]"; # Format that Emacs makes red.
    close $fh;
  }
}


$Mpp::Subs::rule->{MAKEFILE}{PACKAGE} = 'Mpp';
sub do_pl($) {
  my $pl = "$_[0].pl";
  return -1 unless exists $file{$pl};
  $Mpp::Subs::rule->{MAKEFILE}{MAKEFILE} = Mpp::File::file_info $pl;
  $Mpp::Subs::rule->{RULE_SOURCE} = $pl . ':0';
  do $pl;
}


sub n_files(;$$) {
  my( $outf, $code ) = @_;
  open my $logfh, '<', '.makepp/log' or die ".makepp/log--$!\n";
  seek $logfh, -20, 2 if !$code; # More than enough to find last message.
  open my $outfh, '>', $outf if $outf;
  while( <$logfh> ) {
    &$code if $code;
    if( /^[\02\03]?N_FILES\01(\d+)\01(\d+)\01(\d+)\01$/ ) {
      close $logfh;		# Might happen too late for Windows.
      my $ret ="$1 $2 $3\n";
      print $outfh $ret if $outfh;
      return $ret;
    }
  }
  return;
}

my $have_shell = -x '/bin/sh';
our $mod_answer;

print OSTDOUT '1..'.@ARGV."\n" if $test;
test_loop:
foreach $archive (@ARGV) {
  $want_cc = 0;
  undef $mod_answer;
  %file = ();
  my $testname = $archive;
  my( $tarcmd, $dirtest, $warned, $tdir, $tdir_failed, $log );
  $SIG{__WARN__} = sub {
    warn defined $dotted ? "\n" : '',
      $warned ? '' : "$testname: warning: ",
      $_[0];
    undef $dotted if -t STDERR;	# -t workaround for MSWin
    $warned = 1;
  };
  if( -d $archive ) {
    $tdir = $archive;
    substr $tdir, 0, 0, "$old_cwd/" if is_windows ? $tdir !~ /^(?:[a-z]:)?\// : $tdir !~ /^\//;
    ($log = $tdir) =~ s!/*$!.log!;
    chdir $tdir;
    $dirtest = 1;
  } else {
    $testname =~ s/\..*$//; # Test name is tar file name w/o extension.
    if( is_windows && $testname =~ /_unix/ ) {
				# Skip things that will cause errors on Cygwin.
				# E.g., the test for file names with special
				# characters doesn't work under NT!
      dot w => "skipped $testname on Windows\n";
      next;
    }
    if( no_symlink && $testname =~ /repository|symlink/ ) {
      dot s => "skipped $testname because symbolic links do not work\n";
      next;
    }
    if( no_link && $testname =~ /build_cache/ ) {
      dot l => "skipped $testname because links do not work\n";
      next;
    }
    if ($archive !~ /^\//) {	# Not an absolute path to tar file?
      $archive = "$old_cwd/$archive"; # Make it absolute, because we're going
    }				# to cd below.

    if ($testname =~ /\.gz$/) { # Compressed tar file?
      $tarcmd = "gzip -dc $archive | tar xf -";
    }
    elsif ($testname =~ /\.bz2$/) { # Tar file compressed harder?
      $tarcmd = "bzip2 -dc $archive | tar xf -";
    }
    ($tdir = "$testname.tdir") =~ s!.*/!!;
    substr $tdir, 0, 0, $basedir;
    $log = substr( $tdir, 0, -4 ) . 'log';
    $tdir_failed = substr( $tdir, 0, -4 ) . 'failed';
    slow_rmtree $tdir, $tdir_failed;
    mkdir $tdir, 0755 or die "$0: can't make directory $tdir--$!\n";
				# Make a directory.
    chdir $tdir or die "$0: can't cd into tdir--$!\n";
  }

  eval {
    local $SIG{ALRM} = sub { die "timed out\n" };
    eval { alarm( $ENV{MAKEPP_TEST_TIMEOUT} || 600 ) }; # Dies in Win Active State 5.6
    if( $tarcmd ) {
      system_intabort $tarcmd and # Extract the tar file.
	die "$0: can't extract testfile $archive\n";
    } elsif( !$dirtest ) {
      open DATA, '<', $archive or die "$0: can't open $archive--$!\n";
      eval { local $SIG{__WARN__} = sub { die @_ if $_[0] !~ /Failed to set/ }; un_spar };
				# Alas happens a lot on native Windows.
      die +(is_windows && $@ =~ /symlink .* unimplemented/) ? "skipped s\n" :
	$@ =~ /: can't open >`/ ? "skipped\n" : $@
      	if $@;
    }
    open STDOUT, '>', $log or die "write $log: $!";
    open STDERR, '>&STDOUT' or die $!;
    open my $fh, '>>', '.makepprc';	# Don't let tests be confused by a user's file further up.
    close $fh;
    # check for all special files in one go:
    @file{<{is_relevant.pl,makepp_test_script.pl,makepp_test_script,cleanup_script.pl,makeppextra.pm,hint}*>} = ();

    eval {
      die "skipped x\n" if exists $file{makepp_test_script} && !$have_shell;

      do_pl 'is_relevant' or die "skipped r\n";

      $page_break = '';
      $log_count = 1;
      if( exists $file{'makepp_test_script.pl'} ) {
	local %ENV = %ENV;	# some test wrappers change it.
	do_pl 'makepp_test_script' or
	  die 'makepp_test_script.pl ' . ($@ ? "died: $@" : "returned false\n");
      } elsif( exists $file{'makepp_test_script'} ) {
	system_intabort \'makepp_test_script', './makepp_test_script', $makepp_path;
      } else {
	makepp;
      }
    };
    open STDOUT, '>&OSTDOUT' or die $!;
    open STDERR, '>&OSTDERR' or die $!;
    die $@ if $@;

#
# Now look at all the final targets:
#
    my @errors;
    {
      local $/;			# Slurp in the whole file at once.
      for my $name ( <answers/{*/*/*/,*/*/,*/,}*> ) {
	next if $name =~ /\/n_files$/ # Skip the special file.
	  or -d $name;		# Skip subdirectories.
	open TFILE, '<:crlf', $name or die "$0: can't open $tdir/$name--$!\n";
	$tfile_contents = <TFILE>; # Read in the whole thing.

	# Get the name of the actual file.
	$name =~ s!answers/!!;
	open TFILE, '<:crlf', $name or die "$0: can't open $tdir/$name--$!\n";
	my $mtfile_contents = <TFILE>; # Read in the whole file.
	&$mod_answer( $name, $mtfile_contents, $tfile_contents ) if $mod_answer;
	$mtfile_contents eq $tfile_contents
	  or push @errors, $name;
      }
    }
    close TFILE;

#
# See if the correct number of files were built:
#
    if( !defined( my $n_files_updated = n_files )) {
      push @errors, '.makepp/log';
    } elsif( open my $n_files, '<', 'answers/n_files' ) { # Count of # of files updated?
      $_ = <$n_files>;
      &$mod_answer( 'n_files', $n_files_updated, $_ ) if $mod_answer;
      $_ eq $n_files_updated
	or push @errors, 'n_files';
    }

#
# Also search through the log file to make sure there are no Perl messages
# like "uninitialized value" or something like that.
#
    if( open my $logfile, '<', $log ) {
      while( <$logfile> ) {
	# Have to control a few warnings before we can unleash this:
	#/makepp: warning/
	if( /at (\S+) line \d+/ && $1 !~ /[Mm]akep*file$|\.mk$/ || /(?:internal|generated) error/ ) {
	  push @errors, $log;
	  last;
	}
      }
    }
    eval { alarm 0 };
    die 'wrong file' . (@errors > 1 ? 's' : '') . ': ' . join( ', ', @errors) . "\n" if @errors;
  };

  if( $@ ) {
# Get rid of the log file so we don't get confused if the next test doesn't
# make a log file for some reason.  For a failed test it remains, hence the name.
    rename '.makepp/log' => '.makepp/log.failed';

    if ($@ =~ /skipped(?: (.))?/) {	# Skip this test?
      chop( my $loc = $@ );
      dot $1 || '-', "$loc $testname\n";
      if( !$dirtest ) {
	do_pl 'cleanup_script';
	chdir $old_cwd;		# Get back to the old directory.
	slow_rmtree $tdir;	# Get rid of the test directory.
      } else {
	chdir $old_cwd;		# Get back to the old directory.
      }
      next;
    } elsif ($@ =~ /^\S+$/) {	# Just one word?
      my $loc = $@;
      $loc =~ s/\n//;		# Strip off the trailing newline.
      dot undef, "$testname (at $loc)\n", $log;
    } else {
      dot undef, "$testname: $@", $log;
    }
    ++$n_failures;
    close TFILE;		# or Cygwin will hang
    if( exists $file{hint} ) {
      c_sed 'print "\f\n" if $. == 1', 'hint', "-o>>$log";
      c_sed 's/^/\t/', 'hint' unless $test;
    } else {
      if( $want_cc ) {
	c_echo '-n', "\f\n$cc_hint", "-o>>$log";
	unless( $test ) {
	   (my $hint = ++$cc_errors == 1 ? $cc_hint : $cc_hint1) =~ s/^/\t/gm;
	   print $hint;
	}
      }
      if( $testname =~ /(build_cache|repository)/ ) {
	my $hint = "Likely only the useful but not essential $1 feature failed.\n";
	c_echo '-n', "\f\n$hint", "-o>>$log";
	$hint =~ s/^/\t/;
	print $hint unless $test;
      }
    }
    chdir $old_cwd;		# Get back to the old directory.
    rename $tdir => $tdir_failed unless $dirtest;
    last if $testname eq 'aaasimple'; # If this one fails something is very wrong
  } else {
    dot '.', "passed $testname\n";
    $n_successes++;
    if( !$dirtest ) {
      do_pl 'cleanup_script';
      chdir $old_cwd;		# Get back to the old directory.
      slow_rmtree $tdir
	unless $keep;		# Get rid of the test directory.
    } else {
      chdir $old_cwd;		# Get back to the old directory.
    }
  }
}
print "\n" if defined $dotted;
if( $n_failures && $hint ) {
  print "\n";
  my $common = "\nIn the $basedir directory you will find details\nin the <testname>.log files and <testname>.failed directories.\n";
  if( $n_failures > $n_successes ) {
    print $n_successes ? 'Fairly bad failure!' : 'Total failure!',
      $common;
  } else {
    print $n_failures > $n_successes / 2 ? 'Partial failure, but many things work, so makepp might be ok for you...' :
      'Some failures, which possibly all have the same cause -- you are probably ok.',
      $common, <<EOF;
If you are trying to install from a makefile you configured, you need to
touch .test_done
in case you want to ignore the above failures.
EOF
  }
}
printf "%ds real  %.2fs user  %.2fs system  children: %.2fs user  %.2fs system\n", time - $^T, times
  if $verbose;
close OSTDOUT;			# shutup warnings.
close OSTDERR;
exit $n_failures;


=head1 NAME

run_tests.pl -- Run makepp regression tests

=head1 SYNOPSYS

    run_tests.pl[ options] test1.test test2.test ...

If no arguments are specified, defaults to *.test.

=head1 DESCRIPTION

This script runs the specified tests and reports their result.  With the -d
option it only prints a dot for each successful test.  A test that is skipped
for a standard reason outputs a letter instead of a dot.  The letters are B<l>
or B<m> for build cache tests that were skipped because links don't work or
MD5 is not available, B<s> for a repository test skipped because symbolic
links don't work or B<w> for a Unix test skipped because you are on Windows.
An B<x> means the test can't be executed because that would require a Shell.
If the test declares itself to not be relevant, that gives an B<r>.
Other reasons may be output as B<->.

With the -v option it also gives info about the used Perl version and system,
handy when parallely running this on many setups, and the used time for the
runner (and Perl scripts it runs directly) on the one hand and for the makepp
(and shell) child processes on the other hand.

With the -? option help more available options are shown.

A test is stored as a file with an extension of F<.test> (very economic and --
with some care -- editable spar format), or F<.tar>, F<.tar.bz2> or
F<.tar.gz>.

First a directory is created called F<I<testname>.tdir> (called the test directory
below).	 Then we cd to the directory, then extract the contents of the
tar file.  This means that the tar file ought to contain top-level
files, i.e., it should contain F<./Makeppfile>, not F<I<testname>.tdir/Makeppfile>.

A test may also be the name of an existing directory.  In that case, no
archive is unpacked and no cleanup is performed after the test.

The following files within this directory are important:

=over 4

=item is_relevant.pl

If this file exists, it should be a Perl script which return trueq if this test
is relevant on this platform, and dies or false if the test is not relevant.

The first argument to this script is the full path of the makepp executable we
are testing.  The second argument is the current platform as seen by Perl.
The environment variable C<PERL> is the path to the perl executable we are
supposed to use (which is not necessarily the one in the path).

=item makepp_test_script.pl / makepp_test_script

If this file exists, it should be a Perl script or shell script which runs
makepp after setting up whatever is necessary.  If this script dies or returns
false (!= 0 for shell), then the test fails.

In a Perl script you can use the predefined function makepp() to run it with
the correct path and wanted interpreter.  It will die if makepp fails.  You
can also use the function wait_timestamp( file ... ), which will wait for both
the local clock and the timestamp of newly created files to be at least a
second later than the newest given file.  You also have the function n_files,
the first optional argument being a file name, where to write the count of
built files, the second a sub that gets called for each log line so you can
scan for messages.  File::Copy's cp is also provided.

The first argument to this shell script is the full path of the makepp
executable we are testing.  The environment variable C<PERL> is the path
to the perl executable we are supposed to use (which is not necessarily
the one in the path).

This script must be sufficiently generic to work in all test
environments.  For example:

=over 4

=item *

It must not assume that perl is in the path.  Always use PERL or $PERL instead.

=item *

It must work with the Bourne shell, i.e., it may contain no bash
extensions.

=item *

It must not use "echo -n" because that doesn't work on HP machines.  But you
should use &echo and other builtins for efficiency anyway.

=back

If this file does not exist, then we simply execute the command
S<C<$PERL makepp>>, so makepp builds all the default targets in the makefile.

If you use the C<.pl> variant, you can set C<$Mpp::mod_answer> to a hook which
will get called for each answer file, with the filename, the generated content
and the expected answer.  The hook can then modify either of the last two
arguments, to make them fit, e.g. on Windows where an extra phony target gets
counted for each compilation.

=item makeppextra.pm

If present this module is loaded into perl before the script by the makepp
function.  See F<additional_tests/2003_11_14_timestamp_md5.test> for an
example of output redirection.

=item F<Makefile> or F<Makeppfile>

Obviously this is kind of important.

=item F<hint>

Suggestions about what might be wrong if this test fails.

=item answers

This directory says what the result should be after running the test.
Each file in the answers directory, or any of its subdirectories, is
compared to a file of the same name in the test directory (or its
corresponding subdirectory).  The files must be exactly identical or the
test fails.

Files in the main test directory do not have to exist in the F<answers>
subdirectory; if not, their contents are not compared.

There is one special file in the F<answers> subdirectory: the file
F<answers/n_files> should contain three integers in ASCII format which are the
number of files that makepp ought to build, phony targets and that are
expected to have failed.  This is compared to the corresponding number of
files that it actually built, extracted from the logfile F<.makepp/log>.

=item cleanup_script.pl

If this file exists, it should be a Perl script that is executed when the test
is done.  This script is executed just before the test directory is deleted.
No cleanup script is necessary if the test directory and all the byproducts of
the test can be deleted with just C<unlink> and C<rmdir>.  (This is usually
the case, so most tests don't include a cleanup script.)

=back

=cut
