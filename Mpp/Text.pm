# $Id: Text.pm,v 1.75 2017/11/08 22:08:14 pfeiffer Exp $

=head1 NAME

Mpp::Text - Subs for manipulating typical makefile text

=cut

package Mpp::Text;

require Exporter;
@ISA = qw(Exporter);

@EXPORT = qw(find_unquoted rfind_unquoted split_on_whitespace join_with_protection
	     split_on_colon split_commands unquote unquote_split_on_whitespace
	     format_exec_args hash_neq is_cpp_source_name is_object_or_library_name);

use Config;

BEGIN {
  # Keep it here, as this is the common to all mpp* utilities.
  our $BASEVERSION = 2.1;
#@@setVERSION
  our $VERSION = '2.0.99.2';

#
# Not installed, so grep all our sources for the checkin date.  Make a
# composite version consisting of the three most recent dates (shown as (yy)mmdd,
# but sorted including year) followed by the count of files checked in that
# day.
#
  $Mpp::datadir ||= (grep -f "$_/Mpp.pm", @INC)[0] or
    die "Can't find our libraries in \@INC.\n";
  if( $VERSION =~ tr/a-z//d ) {
    my %VERSION = qw(0/00/00 0 00/00/00 0); # Default in case all modules change on same day.
    for( <$Mpp::datadir/makep*[!~] $Mpp::datadir/Mpp{,/*,/*/*}.pm> ) {
      open my $fh, '<', $_;
      while( <$fh> ) {
	if( /\$Id: .+,v [.0-9]+ ([\/0-9]+)/ ) {
	  $VERSION{$1}++;
	  last;
	}
      }
    }
    my $year = '';
    $VERSION .= join '-', '',
      grep { s!\d\d(\d+)/(\d+)/(\d+)!($year eq $1 ? '' : ($year = $1))."$2$3:$VERSION{$_}"!e }
	(reverse sort keys %VERSION)[0..2];
  }
#@@

# Centrally provide constants which are needed repeatedly for aliasing, since
# Perl implements them as subs, and each sub takes about 1.5kb RAM.
  our @N = map eval( "sub(){$_}" ), 0..6; # More are defined in Mpp/BuildCacheControl.pm
  *Mpp::is_windows =
    $^O eq 'cygwin' ? sub() { -1 } : # Negative for Unix like
    $^O eq 'msys' ? sub() { -2 } :   # MinGW with sh & coreutils
    $N[$^O =~ /^MSWin/ ? (exists $ENV{SHELL} && $ENV{SHELL} =~ /sh(?:\.exe)?$/i ? 1 : 2) : 0];
  *Mpp::DEBUG = $N[$ENV{MAKEPP_DEBUG} || 0];

  my $perl = $ENV{PERL};
  if( $perl ) {			# Overridden.
  } elsif( -x $^X ) {		# Use same as ourself.
    $^X =~ tr/\\/\// if Mpp::is_windows() > 0;
    $perl = (Mpp::is_windows() ? $^X =~ /^(?:\w:)?\// : $^X =~ /^\//) ?
      $^X :
      eval "use Cwd; cwd . '/$^X'";
  } else {			# Emergency fallback.
    $perl = $Config{perlpath};	# Prefer appended version number for precision.
    my $version = sprintf '%vd', $^V;
    $perl .= $version if -x "$perl$version";
  }
  eval "sub Mpp::PERL() { '$perl' }";
}

#
# This module contains a few subroutines for manipulating text, mostly for
# dealing with quoted strings and make expressions.
#

=head2 pattern_substitution

  @pieces = pattern_substitution($pattern, $dest, @words)

Performs a pattern substitution like the C<$(patsubst )> function (in fact,
C<$(patsubst )> is implemented using this.  $pattern contains a C<%> as a
wildcard, and $dest contains a matching C<%>.  The substitution is applied to
each word in @words, and the result returned as an array.

For example:

  @pieces = pattern_substitution('%.c', '%.o', 'file1.c', 'file2.c')

returns ('file1.o', 'file2.o').

=cut

our $set_stem;
sub pattern_substitution {
  my ($src, $dest, @words) = @_; # Name the arguments.
  my $percent_pos = index $src, '%'; # Find the percent char.
  $percent_pos < 0 and
    die "\$(patsubst ...) called with '$src' as first argument\n";

  chop( my $src_prefix = substr $src, 0, $percent_pos+1, '' );

  for my $word (@words) {
    my $len_diff = length( $word ) - length $src;
    if( $len_diff >= $percent_pos &&	# Make sure prefix & suffix don't overlap.
	substr( $word, 0, $percent_pos ) eq $src_prefix &&
	substr( $word, $len_diff ) eq $src ) {
      my $pattern_stem = substr $word, $percent_pos, $len_diff - $percent_pos;
      ($word = $dest) =~ s/%/$pattern_stem/g;
				# Replace all occurrences of % with the stem.
				# Save the resulting word(s).  TODO: this is a
				# hack for multitarget rules, allow multiple %-pairs.
      $Mpp::Subs::rule->{PATTERN_STEM} ||= $pattern_stem
	if defined $set_stem;	# Set it up so $* can return the stem.
    }
  }

  @words;
}

# Rather than cascade if( /\Gx/gc ), just look up the action
my @skip_over;
$skip_over[ord "'"] = \&skip_over_squote;
$skip_over[ord '"'] = \&skip_over_dquote;
$skip_over[ord '$'] = \&skip_over_make_expression;
$skip_over[ord '\\'] = sub { ++pos };

=head2 find_unquoted

  my $index = find_unquoted string, 'char'[, position[, type];

Works like C<index $string, 'char'[, position]>, except that the char is to be
found outside quotes or make expressions.

If type is C<1>, char may be inside a make expression (for historical
reasons opposite to split_on_whitespace).

If type is C<2>, ignores only the characters in C<''> and the one after C<\>,
i.e. makes the same difference between single and double quotes as does the
Shell or Perl.

=cut

sub find_unquoted {
  local *_ = \$_[0];
  my $opos = pos;
  my $ret = 0;
  pos = $_[2] || 0;
  my $char = $_[1];
  my $re = (qr/["'\\\$$char]/, qr/['\\$char]/, qr/["'\\$char]/)[$_[3] || 0];
  while( /$re/gc ) {
    $ret = pos, $_[4] ? next : last if $& eq $char;
    &{$skip_over[ord $&]};
  }
  pos = $opos;
  $ret - 1;
}

=head2 rfind_unquoted

Like C<find_unquoted>, except that it returns the index to the last
instance rather than the first.

=cut

sub rfind_unquoted {
  $_[4] = 1;
  &find_unquoted;
}

=head2 split_on_whitespace

  @pieces = split_on_whitespace $string[, type];

Works like

  @pieces = split ' ', $string

except that whitespace inside quoted strings is not counted as whitespace.
This should be called after expanding all make variables; it does not know
anything about things like "$(make expressions)".

There are three kinds of quoted strings, as in the shell.  Single quoted
strings are terminated by a matching single quote.  Double quoted strings are
terminated by a matching double quote that isn't escaped by a backslash.
Backquoted strings are terminated by a matching backquote that isn't escaped
by a backslash.

If type is C<1>, doesn't split inside make expressions (for historical reasons
opposite to find_unquoted).

=cut

sub unquote_split_on_whitespace {
  # Can't call unquote when pushing because both use \G and at least in 5.6
  # localizing $_ doesn't localize \G
  map unquote(), &split_on_whitespace;
}
my @ws_re = (qr/\s+()|["'\\]/, qr/\s+()|[\$"'\\]/, qr/[;|&()]+(?<![<>]&)()|[\$"'\\`]/);
sub split_on_whitespace {
  my @pieces;
  my $cmds = $_[1] || 0;
  local *_ = \$_[0];
  my $opos = pos;

  pos = 0;			# Start at the beginning.
  $cmds == 2 ? m/^[;|&]+/gc : /^\s+/gc; # Skip over leading whitespace.
  my $last_pos = pos;

  while( m/${ws_re[$cmds]}/gc ) {
    my $cur_pos = pos;		# Remember the current position.
    my $chr = ord $&;
    if( defined $1 ) {		# Found some whitespace?
      push @pieces, substr $_, $last_pos, $cur_pos-$last_pos-length $&;
      $last_pos = pos;		# Beginning of next string is after this space.
    } elsif( $cmds < 2 and $chr == ord '"' ) { # Double quoted string?
      ++pos while /[\\"]/gc && $& ne '"'; # Skip char after backslash.
    } elsif( $chr == ord "'" ) { # Skip until end of single quoted string.
      /'/gc;
    } elsif( $chr == ord '`' ) { # Back quoted string?
      ++pos while /[\\`]/gc && $& ne '`'; # Skip char after backslash.
    } else {			# It's one of the standard cases ", \ or $.
      # $ only gets here in commands, where we use the similarity of make expressions
      # to skip over $(cmd; cmd), $((var|5)), ${var:-foo&bar}.
      # " only gets here in commands, where we need to catch nested things like
      # "$(cmd "foo;bar")"
      &{$skip_over[$chr]};
    }
  }

  pos = $opos;
  return @pieces, substr $_, $last_pos
    if $last_pos < length;	# Anything left at the end of the string?

  @pieces;
}
sub split_commands {
  split_on_whitespace $_[0], 2;
}

=head2 join_with_protection

  $string = join_with_protection(@pieces);

Works like

  $string = join ' ', @pieces

except that strings in @pieces that contain shell metacharacters are protected
from the shell.

=cut

sub join_with_protection {
  join ' ',
    map {
      $_ eq '' ? "''" :
      /'/ ? map { s/'/'\\''/g; "'$_'" } "$_" : # Avoid modifying @_
      m|[^\w/.@%\-+=:]| ? "'$_'" :
      $_;
    } @_;
}

=head2 split_on_colon

  @pieces = split_on_colon('string');

Works like

  @pieces = split /:+/, 'string'

except that colons inside double quoted strings or make expressions are passed
over.  Also, a semicolon terminates the expression; any colons after a
semicolon are ignored.	This is to support grokking of this rule:

  $(srcdir)/cat-id-tbl.c: stamp-cat-id; @:

=cut

sub split_on_colon {
  my @pieces;
  local *_ = \$_[0];
  my $opos = pos;
  pos = my $last_pos = 0;
  while( /[;:"'\\\$]/gc ) {
    last if $& eq ';';
    if( $& eq ':' ) {
      push @pieces, substr $_, $last_pos, pos() - $last_pos - 1;
      /\G:+/gc;
      $last_pos = pos;
    } else {
      &{$skip_over[ord $&]};
    }
  }
  pos = $opos;
  return @pieces, substr $_, $last_pos
    if $last_pos < length;	# Anything left at the end of the string?
  @pieces;
}

#
# This routine splits the PATH according to the current systems syntax.  An
# object may be optionally passed.  If that contains a non-empty entry {PATH},
# that is used instead of $ENV{PATH}.  Empty elements are returned as '.'.
# A second optional argument may be an alternative string to 'PATH'.
# A third optional argument may be an alternative literal path.
# A fourth optional argument means split on ';' even though is_windows < 0.
#
sub split_path {
  my $var = $_[1] || 'PATH';
  my $path = $_[2] || ($_[0] && $_[0]{$var} || $ENV{$var});
  if( Mpp::is_windows ) {
    map { tr!\\"!/!d; $_ eq '' ? '.' : $_ }
      Mpp::is_windows > 0 || $_[3] ?
	split /;/, "$path;" :	# "C:/a b";C:\WINNT;C:\WINNT\system32
	split_on_colon "$path:"; # "C:/a b":"C:/WINNT":/cygdrive/c/bin
  } else {
    map { $_ eq '' ? '.' : $_ } split /:/, "$path:";
  }
}

#
# This routine is used to skip over a make expression.	A make expression
# is a variable, like "$(CXX)", or a function, like $(patsubst %.o, %.c, sdaf).
#
# The argument should be passed in the global variable $_ (not @_, as usual),
# and pos($_) should be the character immediately after the dollar sign.
# On return, pos($_) is the first character after the end of the make
# expression.
#
# This returns the length of the opening parens, i.e.: $@ = 0; $(VAR) = 1 and
# $((perl ...)) = 2, or undef if the closing parens don't match.
#
# Reuse same mechanism:
$skip_over[ord '('] = [qr/[)"'\$]|(?=\()/, qr/\)\)|["'\$]/, qr/\)/];
$skip_over[ord '{'] = [qr/[}"'\$]|(?=\{)/, qr/\}\}|["'\$]/, qr/\}/];
$skip_over[ord '['] = [qr/[]"'\$]|(?=\[)/, qr/\]\]|["'\$]/, qr/\]/];
sub skip_over_make_expression {
  /\G[({[]/gc or
      ++pos, return 0;	# Must be a single character variable to skip over.
  my $open = ord $&;
  my $double = /\G[$&]/gc || 0;	# Does the expression begin with $((, ${{ or $[[?;

  my $re = $skip_over[$open][$double];
  if( /\G(?:perl|map())\s+/gc ) { # Is there plain Perl code we must skip blindly?
    if( defined $1 ) {		# The first arg to map is normal make stuff.
      &{$skip_over[ord $&]} while /["'\$,]/gc && $& ne ',';
    }
    $re = $skip_over[$open][2];
    $double ? /$re$re/gc : /$re/gc;
    return $double + 1;
  }

  &{$skip_over[ord $& or ord '$'] or return $double + 1} # 0 means looking at paren, not found must be closing paren
    while /$re/gc;
  undef;
}


#
# This subroutine is used to skip over a double quoted string.	A double
# quoted string may have a make expression inside of it; we also skip over
# any such nested make expressions.
#
# The argument should be passed in the global variable $_ (not @_, as usual),
# and pos($_) should be the character immediately after the quote.
# On return, pos($_) is the first character after the closing quote.
#
sub skip_over_dquote {
  &{$skip_over[ord $&]} while /["\\\$]/gc && $& ne '"';
}

#
# This subroutine is used to skip over a single quoted string.	A single
# quoted string may have a make expression inside of it; we also skip over
# any such nested make expressions.  The difference between a single and double
# quoted string is that a backslash is used to escape special chars inside
# a double quoted string, whereas it has no meaning in a single quoted string.
#
# The argument should be passed in the global variable $_ (not @_, as usual),
# and pos($_) should be the character immediately after the quote.
# On return, pos($_) is the first character after the closing quote.
#
sub skip_over_squote {
##################################################################################################
  &{$skip_over[ord $&]} while /['\$]/gc && $& ne "'";
}

=head2 unquote

  $text = unquote($quoted_text)

or on an implicit C<$_>:

  $text = unquote

Removes quotes and escaping backslashes from a name.  Thus if you give it as
an argument
    \""a bc"'"'

it will return the string

    "a bc"

You must already have expanded all of the make variables in the string.
unquote() knows nothing about make expressions.  In the 1st variant, you may
not pass anny regextp special vars, because it uses regexps directly on the
argument.

=cut

sub unquote {
  my $ret_str = '';

  local *_ = \$_[0] if @_;
  my $opos = pos;
  pos = my $last_pos = 0;	# Start at beginning of string.

  while( /["'\\]/gc ) {
    my $len = pos() - $last_pos - 1;
    $ret_str .= substr $_, $last_pos, $len if $len;

    if( $& eq '"' ) {		# Double quoted section of the string?
      $last_pos = pos;
      while( /["\\]/gc ) {
	$len = pos() - $last_pos - 1;
	$ret_str .= substr $_, $last_pos, $len if $len;
	if( $& eq '"' ) {	# Ending double quote
	  $last_pos = pos;
	  last;
	} elsif( length() <= pos ) {
	  die "lone backslash at end of string '$_'\n";
	} else {		# Other character escaped with backslash.
	  $last_pos = pos()++;	# Put it in verbatim together with what follows.
	}
      }
    } elsif( $& eq "'" ) {	# Single quoted string?
      $last_pos = pos;
      /'/gc or last;		# End of string w/o matching quote.
      $len = pos() - $last_pos - 1;
      $ret_str .= substr $_, $last_pos, $len if $len;
      $last_pos = pos;

    } elsif( /\G[0-7]{1,3}/gc ) { # Backslash.  Octal character code?
      $ret_str .= chr oct $&;	# Convert to character.
      $last_pos = pos;
    } elsif( /\G[*?[\]]/gc ) {	# Don't weed out backslashed wildcards here,
      $last_pos = pos() - 2;	# because they're recognized separately in
				# the wildcard routines.
    } elsif( length() <= pos ) {
      die "lone backslash at end of string '$_'\n";
    } else {			# Other character escaped with backslash.
      $last_pos = pos()++;	# Put it in verbatim together with what follows.
    }
  }

  my $len = length() - $last_pos;
  pos = $opos;
  return $ret_str . substr $_, $last_pos if $len;
  $ret_str;
}

#
# Perl contains an optimization where it won't run a shell if it thinks the
# command has no shell metacharacters.	However, its idea of shell
# metacharacters is a bit too limited, since it doesn't realize that something
# like "XYZ=abc command" does not mean to execute the program "XYZ=abc".
# Also, Perl's system command doesn't realize that ":" is a valid shell
# command.  So we do a bit more detailed check for metacharacters and
# explicitly pass it off to a shell if needed.
#
# This subroutine takes a shell command to execute, and returns an array
# of arguments suitable for exec() or system().
#
sub format_exec_args {
  my( $cmd ) = @_;
  return $cmd			# No Shell available.
    if Mpp::is_windows > 1;
  if( Mpp::is_windows == 1 && $cmd =~ /[%"\\]/ ) { # Despite multi-arg system(), these chars mess up command.com
    require Mpp::Subs;
    my $tmp = Mpp::Subs::f_mktemp( '' );
    open my $fh, '>', $tmp;
    print $fh $cmd;
    return ($ENV{SHELL}, $tmp);
  }
  return ($ENV{SHELL}, '-c', $cmd)
    if Mpp::is_windows == -2 || Mpp::is_windows == 1 ||
      $cmd =~ /[()<>\\"'`;&|*?[\]#]/ || # Any shell metachars?
      $cmd =~ /\{.*,.*\}/ || # Pattern in Bash (blocks were caught by ';' above).
      $cmd =~ /^\s*(?:\w+=|[.:!](?:\s|$)|e(?:val|xec|xit)\b|source\b|test\b)/;
				# Special commands that only
				# the shell can execute?

  return $cmd;			# Let Perl do its optimization.
}

#
# Compute the length of whitespace when it may be composed of spaces or tabs.
# The leading whitespace is removed from $_.
# Usage:
#	$len = strip_indentation;
#
# If $_ is not all tabs and spaces, returns the length of the
# whitespace up to the first non-white character.
#

sub strip_indentation() {
  my $white_len = 0;
  pos = 0;			# Start at the beginning of the string.
  while( /\G(?:( +)|(\t+))/gc ) {
    if( $1 ) {			# Spaces?
      $white_len += length $1;
    } else {			# Move over next tab stops.
      $white_len = ($white_len + 8*length $2) & ~7;
				# Cheap equivalent for 8*int(.../8)
    }
  }
  substr $_, 0, pos, '';
  $white_len;
}

=head2 hash_neq

  if (hash_neq(\%a, \%b)) { ... }

Returns true (actually, returns the first key encountered that's different) if
the two associative arrays are unequal, and '' if not.

=cut

sub hash_neq {
  my ($a, $b, $ignore_empty ) = @_;
#
# This can't be done simply by stringifying the associative arrays and
# comparing the strings (e.g., join(' ', %a) eq join(' ', %b)) because
# the order of the key/value pairs in the list returned by %a differs.
#
  my %a_not_b = %$a;		# Make a modifiable copy of one of them.
  delete @a_not_b{grep !length $a_not_b{$_}, keys %a_not_b}
    if $ignore_empty;
  foreach (keys %$b) {
    next if $ignore_empty && !length $b->{$_};
    exists $a_not_b{$_} or return $_ || '0_'; # Must return a true value.
    $a_not_b{$_} eq $b->{$_} or return $_ || '0_';
    delete $a_not_b{$_};	# Remember which things we've compared.
  }

  if (scalar %a_not_b) {	# Anything left over?
    return (%a_not_b)[0] || '0_'; # Return the first key value.
  }
  '';				# No difference.
}

=head2 is_cpp_source_name

  if (is_cpp_source_name($filename))  { ... }

Returns true if the given filename has the appropriate extension to be
a C or C++ source or include file.

=cut

# NOTE: NVIDIA uses ".pp" for generic files (not necessarily programs)
# that need to pass through cpp.
sub is_cpp_source_name {
  $_[0] =~ /\.(?:[ch](|[xp+])\1|([chp])\2|moc|x[bp]m|idl|ii?|mi)$/i;
				# i, ii, and mi are for the GNU C preprocessor
				# (see cpp(1)).	 moc is for qt.
}

=head2 is_object_or_library_name

  if (is_object_or_library_name($filename)) { ... }

Returns true if the given filename has the appropriate extension to be some
sort of object or library file.

=cut

sub is_object_or_library_name {
  $_[0] =~ /\.(?:l?[ao]|s[aol](?:\.[\d.]+)?)$/;
}

=head2 getopts

  getopts %vars, strictflag, [qw(o optlong), \$var, wantarg, handler], ...

Almost as useful as Getopt::Long and much smaller :-)

%vars is optional, any VAR=VALUE pairs get stored in it if passed.

strictflag is optional, means to stop at first non-option.

Short opt may be empty, longopt may be a regexp (grouped if alternative).

$var gets incremented for each occurrence of this option or, if optional
wantarg is true, it gets set to the argument.  This can be undef if you don't
need it.

If an optional handler is given, it gets called after assigning $var, if it is
a ref (a sub).  Any other value is assigned to $var.

=cut

my $args;
my $argfile =
  ['A', qr/arg(?:ument)?s?[-_]?file/, \$args, 1,
   sub {
     open my $fh, '<', $args or die "$0: cannot open args-file `$args'--$!\n";
     local $/;
     unshift @ARGV, unquote_split_on_whitespace <$fh>;
     close $fh;
   }];
sub getopts(@) {
  my $hash = 'HASH' eq ref $_[0] and
    my $vars = shift;
  my $mixed = ref $_[0]
    or shift;
  my( @ret, %short );
  while( @ARGV ) {
    my $opt = shift @ARGV;
    if( $opt =~ s/^-(-?)// ) {
      my $long = $1;
      if( $opt eq '' ) {	# nothing after -(-)
	if( $long ) {		# -- explicit end of opts
	  unshift @ARGV, @ret;
	  return;
	}
	push @ret, '-';		# - stdin; TODO: this assumes $mixed
	next;
      }
    SPECS: for my $spec ( @_, $argfile, undef ) {
	die "$0: unknown option -$long$opt\n" unless defined $spec;
	if( $long ) {
	  if( $$spec[3] ) {
	    next unless $opt =~ /^$$spec[1](?:=(.*))?$/;
	    ${$$spec[2]} = defined $1 ? $1 : @ARGV ? shift @ARGV :
	      die "$0: no argument to --$opt\n";
	  } else {		# want no arg
	    next unless $opt =~ /^$$spec[1]$/;
	    ${$$spec[2]}++;
	  }
	} else {		# short opt
	  next unless $$spec[0] && $opt =~ s/^$$spec[0]//;
	  if( $$spec[3] ) {
	    ${$$spec[2]} = $opt ne '' ? $opt : @ARGV ? shift @ARGV :
	      die "$0: no argument to -$$spec[0]\n";
	    $opt = '';
	  } else {
	    ${$$spec[2]}++;
	  }
	  print STDERR "$0: -$$spec[0] is short for --"._getopts_long($spec)."\n"
	    if $Mpp::verbose && !$short{$$spec[0]};
	  $short{$$spec[0]} = 1;
	}
	ref $$spec[4] ? &{$$spec[4]} : (${$$spec[2]} = $$spec[4]) if exists $$spec[4];
	goto SPECS if !$long && length $opt;
	last;
      }
    } elsif( $hash and $opt =~ /^(\w[-\w.]*)=(.*)/ ) {
      $vars->{$1} = $2;
    } elsif( $mixed ) {
      push @ret, $opt;
    } else {
      unshift @ARGV, $opt;
      return;
    }
  }
  @ARGV = @ret;
}

# Transform regexp to be human readable.
sub _getopts_long($) {
  my $str = "$_[0][1]";
  $str =~ s/.*?://;		# remove qr// decoration
  $str =~ s/\[-_\]\??/-/g;
  $str =~ s/\(\?:([^(]+)\|[^(]+?\)/$1/g; # reduce inner groups (?:...|...) to 1st variant
  $str =~ s/\|/, --/g;
  $str =~ tr/()?://d;
  $str;
}


sub help {
#@@eliminate
  $ENV{_MAKEPP_INSTALL} or
#@@
    print "usage: $Mpp::progname ";
  local $/;
  print <Mpp::DATA>;
  our $pod ||= $Mpp::progname;
  our $extraman ||= '';
  my $htmldir = '@htmldir@';
  my $noman = '@noman@';
  my $helpend =
#@@eliminate
    $ENV{_MAKEPP_INSTALL} ? '' :
    $htmldir ne '@htmldir@' &&
#@@
    $htmldir ne 'none' ? "
For details look at $htmldir/$pod.html
or" : "
For details look";
#@@eliminate
  if( $helpend ) {
#@@
  our $helpline ||= 'For general info, click on sidebar "Overview" or top tab "Documentation".';
  $helpend .= " at http://makepp.sourceforge.net/\@BASEVERSION@/$pod.html\n$helpline\n";
  $helpend .= "Or type \"man $pod\" or \"man makepp$extraman\".\n"
    unless $noman;
#@@eliminate
  }
  $helpend =~ s/\@BASEVERSION\@/$BASEVERSION/;
  our $opts ||= $pod;
  print "\n";
  open my $fh, '<', "$Mpp::datadir/pod/$opts.pod" or die $!;
  my $opt = $/ = '';
  my $found;
  while( <$fh> ) {		# skip to before 1st opt
    $found = 1 if /Valid options are|^=head1 OPTIONS/;
    last if $found && /^=over/;
  }
  while( <$fh> ) {
    if( /^=over/ ) {
      while( <$fh> ) { last if /^=back/ } # skip nested list
    } elsif( /^=back/ ) {
      last;
    } elsif( s/^=item // ) {
      chomp;
      s/ ?X<.*?>//g;
      s/I<(.*?)>/$1/g;
      if( $opt ) { $opt .= ", $_" } else { $opt = $_ }
    } elsif( $opt ) {
      s/\.\s.*/./s;
      s!L<(.*)/(.*?)>!$2 in $1!g;
      s/[BCFILZ]<(.*?)>/$1/g;
      tr/\n/ /;
      pos() = 0;
      s/\G(.{1,72})(?: |$)/    $1\n/g; # indent & word wrap
      print "$opt\n$_";
      $opt = '';
    }
  }
#@@
  print $helpend;
  exit 0;
}

our @common_opts =
 ([qr/[h?]/, 'help', undef, undef, \&help],

  [qw(V version), undef, undef, sub { $0 =~ s!.*/!!; my $typ = $VERSION =~ /[-:]/ ? 'cvs-version' : $VERSION !~ /\.9([89])\./ ? 'version' : $1 == 8 ? 'snapshot' : "$BASEVERSION release-candidate"; print <<EOS; exit 0 }]);
$0 $typ $VERSION
Makepp may be copied only under the terms of either the Artistic License or
the GNU General Public License, either version 2, or (at your option) any
later version.
For more details, see the makepp homepage at http://makepp.sourceforge.net.
EOS

1;
