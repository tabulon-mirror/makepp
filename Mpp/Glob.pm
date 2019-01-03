# $Id: Glob.pm,v 1.49 2016/09/28 20:36:49 pfeiffer Exp $

package Mpp::Glob;

use strict;

use Mpp::File;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(chdir);	# Force our caller to use our chdir sub that
				# we inherit from Mpp::File.
our @EXPORT_OK = qw(zglob zglob_fileinfo wildcard_do);

use strict;

=head1 NAME

Mpp::Glob -- Subroutines for reading directories easily.

=head1 USAGE

  my @file_info_structs = Mpp::Glob::zglob_fileinfo('pattern'[, default dir]);
  my @filenames = Mpp::Glob::zglob('pattern'[, default dir]);
  $Mpp::Glob::allow_dot_files = 1;	# Enable returning files beginning with '.'.
  wildcard_do { my $finfo = $_[0]; ... } [\1,] @wildcards;

=head1 DESCRIPTION

=head2 Mpp::Glob::zglob

This subroutine supports some limited extended wildcards (ideas stolen from zsh).

	*		Matches any text
	?		Matches one character
	[range]		Matches a range just like the Unix wildcards.
	**		Matches an arbitrary list of directories.  This
			is a shortcut to running "find" on the directory
			tree.  For example, 'x/**/a.o' matches 'x/a.o',
			'x/y/a.o', 'x/y/z/a.o', etc.  Like find, it does
			not search through directories specified by
			symbolic links.

If the argument to zglob does not have any wildcard characters in it, the file
name is returned if the file exists; an empty list is returned if it does not
exist.	(This is different from the shell's usual globbing behaviour.)	If
wildcard characters are present, then a list of files matching the wildcard is
returned.  If no files match, an empty list is returned.

If you want a subroutine which returns something even if no files matched,
then call zglob_fileinfo_atleastone.  This has the same behavior as the Bourne
shell, which returns the wildcard or filename verbatim even if nothing
matches.

The second argument to C<zglob> is the default directory, which is used if you
specify a relative file name.  If not specified, uses the current default
directory.  C<zglob> doesn't repeatedly call Cwd::cwd to get the directory;
instead, it uses the Mpp::File package to track the current directory.  (This
means that it overrides C<chdir> in your module to be something that stores
the current directory.)

By default, C<zglob> does not return file names beginning with '.'.
You can force it to return these files by setting $Mpp::Glob::allow_dot_files=1,
or (as with the shell) by specifing a leading . in the wildcard pattern (e.g.,
'.*').

C<zglob> only returns files that exists and are readable, or can be built.

C<zglob> returns a list of file names.	It uses an internal subroutine,
C<zglob_fileinfo>, which returns a list of Mpp::File structures.  See the
Mpp::File package for more details.

=cut

our $allow_dot_files = 0;	# Don't return any files beginning with '.'.

sub zglob {
  map relative_filename($_,$_[1]), &zglob_fileinfo;
}

sub zglob_fileinfo_atleastone {
  my @files = &zglob_fileinfo;	# Get a list of files.
  @files = &file_info		# Make a fileinfo structure for whatever the
    unless @files;		# wildcard itself (or non-existent file) was,
				# if no files matched at all?
  @files;
}

#
# The third argument to zglob_fileinfo indicates whether to avoid following
# soft-linked directories ('**' never follows soft links, but other wildcards
# can).  Generally, you want to follow soft links, but because of some
# technical restrictions, wildcard_do can't do it right so in order to avoid
# having makefile bugs where things work some of the time but not all of the
# time, when we're called from wildcard_do we don't follow soft links either.
#
sub zglob_fileinfo {
  local $_ = $_[0];		# Access the filename or wildcard.
  m@^/\*\*@ and die "Refusing to expand /** as wildcard--you don't want to search every directory in the file system\n";
  my( undef, $startdir, $dont_follow_soft, $phony, $stale ) = @_;

  my $is_wildcard = 0;		# We haven't seen a wildcard yet.

  Mpp::is_windows and
    s@^(?=[A-Za-z]:)@/@;	# If on Windows, transform C: into /C: so it
				# looks like it's in the root directory.
  case_sensitive_filenames or
    tr/A-Z/a-z/ unless		# Switch to lower case to avoid problems with
                                # mixed case.

    s@^/@@ and $startdir = $Mpp::File::root; # If this is a rooted wildcard,
				# change to the top of the path.  Also,
				# strip out the leading /.
  my @pieces = split /\/+/;	# Get the pieces of the filename, and
				# examine each one of them separately.
  my @new_candidates = ($startdir || $CWD_INFO); # Directories that are possible.  At first,
				# there is only the starting directory.

  while( $_ = shift @pieces ) {
    my @candidate_dirs = $dont_follow_soft ?
      grep( $_->{DIRCONTENTS} && !Mpp::File::is_symbolic_link( $_ ) ||
	is_or_will_be_dir( $_ ),
	@new_candidates ) :
      grep( $_->{DIRCONTENTS} || is_or_will_be_dir( $_ ), @new_candidates );
				# Discard everything that isn't a directory,
				# since we have to look for files in it.
				# (Note that we will return files that are
				# in directories that don't exist yet.)

    if( $Mpp::implicitly_load_makefiles ) { # Should wildcards trigger loading?
				# We have to do this before scanning the
				# directory, since loading the makefile
				# may make extra files appear.
      exists $_->{MAKEINFO} or Mpp::Makefile::implicitly_load( $_ ) for @candidate_dirs;
    }


    @new_candidates = ();	# This will contain the files that live in
				# the candidate directories.
#
# First translate the wildcards in this piece:
#
    if ($_ eq '**') {		# Special zsh wildcard?
      for my $dir (@candidate_dirs) {
	push @new_candidates, $dir, find_all_subdirs_recursively( $dir );
      }
      next;
    }

#
# The remaining wildcards match only files within these directories.
#
    my @phony_expr = @pieces ? (0) : ($phony, $stale, 1); # Set $no_last_chance
    if( /[[?*]/ ) { # Was there actually a wildcard?
      my $re = wild_to_regex( $_, 3 ); # Convert to a regular expression.
      my $allow_dotfiles = $allow_dot_files || ord( '.' ) == ord;
				# Allow dot files if we're automatically accepting
				# them, or if they are explicitly specified.
      for my $dir ( @candidate_dirs ) { # Look for the file in each of the possible directories.
	$dir->{READDIR} or Mpp::File::read_directory $dir; # Load the list of filenames.
				# This also correctly sets the xEXISTS flag
	# Sometimes DIRCONTENTS changes inside this loop, which messes up
	# the 'each' operator.  The fix is to make a static copy:
	my %dircontents = %{$dir->{DIRCONTENTS}};
	while( my( $fname, $finfo ) = each %dircontents ) {
	  next unless $allow_dotfiles || ord( $fname ) != ord '.'
	    and $fname =~ $re;
	  Mpp::File::exists_or_can_be_built $finfo, @phony_expr and # File "exist"s, as per phony, etc.
	    push @new_candidates, $finfo;
	}
      }
      next;			# We're done with this wildcard.
    }
#
# No wildcard characters were present.	Just see if this file exists in any
# of the candidate directories.
#
    foreach my $dir (@candidate_dirs) {
      if ($_ eq '..') {		# Go up a directory?
	push @new_candidates, $dir->{'..'} || $dir; # Handle root case!
      }
      elsif ($_ eq '.') {	# Stay in same directory?
	push @new_candidates, $dir;
      }
      else {
	$dir->{READDIR} or Mpp::File::read_directory $dir; # Load the list of filenames.
	my $finfo = $dir->{DIRCONTENTS}{$_}; # See if this entry exists.
	push @new_candidates, $finfo if
	  $finfo && Mpp::File::exists_or_can_be_built $finfo, @phony_expr;
      }
    }

  }

  sort { $a->{NAME} cmp $b->{NAME} ||
	   absolute_filename( $a ) cmp absolute_filename $b } @new_candidates;
				# Return a sorted list of matching files.
}

=head2 Mpp::Glob::find_all_subdirs

  my @subdirs = Mpp::Glob::find_all_subdirs($dirinfo)

Returns Mpp::File structures for all the subdirectories immediately under
the given directory.  These subdirectories might not exist yet; we return
Mpp::File structures for any Mpp::File for which has been treated as a
directory in calls to file_info.

We do not follow symbolic links.  This is necessary to avoid infinite
recursion and a lot of other bad things.

=cut

sub find_all_subdirs {
  my $dirinfo = $_[0];	# Get a fileinfo struct for this directory.

#
# First find all the directories that currently exist.	(There may be other
# files with a DIRCONTENTS field that don't exist yet; presumably these will
# become directories.)	We make sure that all real directories have a
# DIRCONTENTS hash (even if it's empty).
#
  unless( exists $dirinfo->{xLOOKED_FOR_SUBDIRS} ) {
    undef $dirinfo->{xLOOKED_FOR_SUBDIRS};
				# Don't do this again, because we may have
				# to stat a lot of files.
    if( &is_dir ) {		# Don't even try to do this if this directory
				# itself doesn't exist yet.

      Mpp::File::mark_as_directory $_ # Make sure that it's tagged as a directory.
	for find_real_subdirs( $dirinfo );
    }
  }

#
# Now return a list of Mpp::File structures that have a DIRCONTENTS field.
#
  grep {
    $_->{DIRCONTENTS} and
      !Mpp::File::is_symbolic_link $_; # Don't return symbolic links, or else
				# we can get in trouble with infinite recursion.
  } values %{$dirinfo->{DIRCONTENTS}};
}

#
# This is an internal subroutine which finds all the subdirectories of a given
# directory as fast as possible.  Unlike find_all_subdirs, this will only
# return the subdirectories that currently exist; it will not return
# subdirectories which don't yet exist but have valid Mpp::File structures.
#
sub find_real_subdirs {
  my $dirinfo = $_[0];	# Get the directory to search.

#
# Find the number of expected subdirectories.  On all Unix file systems, the
# number of links minus 2 is the number of expected subdirectories.  This
# means that we can know without statting any files whether there are any
# subdirectories.
#
  my $dirstat = &Mpp::File::dir_stat_array;
  my $expected_subdirs = 0;
  defined($dirstat->[Mpp::File::STAT_NLINK]) and	# If this directory doesn't exist, then it
				# doesn't have subdirectories.
    $expected_subdirs = $dirstat->[Mpp::File::STAT_NLINK]-2;
				# Note that if we're on a samba-mounted
				# file system, $expected_subdirs will be -1
				# since it doesn't keep a link count.

  $expected_subdirs or return (); # Don't even bother looking if this is a
				# leaf directory.
  $dirinfo->{READDIR} or &Mpp::File::read_directory;
				# Load all the files known in the directory.

  my @subdirs;			# Where we build up the list of subdirectories.
  for( values %{$dirinfo->{DIRCONTENTS}} ) {
    if( $_->{LSTAT} && is_dir $_ ) {
      push @subdirs, $_		# Note this directory.
	if $allow_dot_files || ord( '.' ) != ord;
				# Skip dot directories.
      --$expected_subdirs;	# We got one of the expected subdirs.
      return @subdirs unless $expected_subdirs; # We got them all.
    }
  }

#
# Here we apply a simple heuristic optimization in order to avoid statting
# most of the files in the directory.  Looking for subdirectories is
# time-consuming if we have to stat every file.	 Since we know the link count
# of the parent directory, we know how many subdirectories we are looking for
# and we can stop when we find the right amount.  Furthermore, some file names
# are unlikely to be directories.  For example, files with '~' characters in
# them are usually editor backups.  Similarly, files with alphabetic
# extensions (e.g., '.c') are usually not directories.
#
# This heuristic doesn't work at all for Windows, since it doesn't maintain
# link counts.
#
# On other operating systems, this would be a lot easier since directories
# often have an extension like '.dir' that uniquely identifies them.
#
# More detailed heuristics are possible, but we have to balance the cost of
# testing the heuristics with the cost of doing the stats.
#
  my( @l1, @l2, @l3, @l4 );
  local $_;
  my $finfo;
  while( ($_, $finfo) = each %{$dirinfo->{DIRCONTENTS}} ) {
    next if $finfo->{LSTAT}; # Already checked this above.
    if( exists $finfo->{DIRCONTENTS} ||
	/^\.makepp$/ || /^includes?$/ || /^src$/ || /^libs?$/ || /^docs?$/ || /^man$/ ) {
      push @l1, $_;
    } elsif( /~$/ || /.\.bak$/ || /.\.sav$/ ) {
				# Do editor backups very last.
      push @l4, $_;
    } elsif( /[A-Za-z]\.\d$/ || /.\.[A-Za-z]+$/ ) {
				# Do man pages last.  (These can be pretty
				# expensive to stat since there's often a lot
				# of them.)  This will not skip directories
				# like "perl-5.14.1" because the period
				# must be preceded by an alphabetic char.
				# Do files with alphabetic extensions last.  Don't
				# skip files with numeric extensions, since
				# version numbers are often placed in
				# directory names.  Note that this does not
				# skip files with a leading '.'.

      push @l3, $_;
    } else {
      push @l2, $_;
    }
  }
  for( @l1, @l2, @l3, @l4 ) {
    my $finfo = $dirinfo->{DIRCONTENTS}{$_};
				# Look at each file in the directory.
    if( is_dir $finfo ) {
      push @subdirs, $finfo	# Note this directory.
	if $allow_dot_files || ord( '.' ) != ord;
				# Skip dot directories.
      --$expected_subdirs;	# We got one of the expected subdirs.
      last if !$expected_subdirs;
    }
  }

  @subdirs;
}

=head2 Mpp::Glob::find_all_subdirs_recursively

  my @subdirs = Mpp::Glob::find_all_subdirs_recursively($dirinfo);

Returns Mpp::File structures for all the subdirectories of the given
directory, or subdirectories of subdirectories of that directory,
or....

The subdirectories are returned in a breadth-first manner.  The directory
specified as an argument is not included in the list.

Subdirectories beginning with '.' are not returned unless
$Mpp::Glob::allow_dot_files is true.

=cut
sub find_all_subdirs_recursively {
  my @subdirs;

  if( $allow_dot_files ) {
    @subdirs = &find_all_subdirs; # Start with the list of our subdirs.
    for (my $subdir_idx = 0; $subdir_idx < @subdirs; ++$subdir_idx) {
				# Use this kind of loop because we'll be adding
				# to @subdirs.
      push(@subdirs, find_all_subdirs($subdirs[$subdir_idx]));
				# Look in this directory for subdirectories.
    }
  }
  else {			# Same code, except that we don't search
				# subdirectories that begin with '.'.
    @subdirs = grep($_->{NAME} !~ /^\./, &find_all_subdirs);
				# Start with the list of our subdirs.
    for (my $subdir_idx = 0; $subdir_idx < @subdirs; ++$subdir_idx) {
				# Use this kind of loop because we'll be adding
				# to @subdirs.
      push(@subdirs, grep($_->{NAME} !~ /^\./,
			  find_all_subdirs($subdirs[$subdir_idx])));
				# Look in this directory for subdirectories.
    }

  }

  @subdirs;
}

#
# This subroutine converts a wildcard to a regular expression.
#
# Arguments:
# The wildcard string to convert to a regular expression.
# Optionally 1 to anchor the wildcard at the beginning or 2 at the end or 3 both.
#
# Returns:
# The qr/regular expression/, if there was a wildcard, or the filename with
# backslashes removed, if there were no wildcards.  The returned regular
# expression does not have a leading '^' or a trailing '$'.
#
my @regexp_cache;
sub wild_to_regex {
  local $_ = $_[0];
  my $anchor = $_[1] || 0;
  return $regexp_cache[$anchor]{$_} if $regexp_cache[$anchor]{$_}; # Processed this before.

  if( $anchor || /[[?*]/ ) {	# Is it possible that there are wildcards?  If not,
				# don't bother to do the more complicated grokking.
    my $is_wildcard = 0;	# Haven't seen a wildcard yet.
    my $file_regex = '';	# A regular expression to match this level.
    pos() = 0;

    while( pos() < length ) {
      if( /\G([^\\\[\]\*\?]+)/gc ) { # Ordinary characters?
	$file_regex .= quotemeta($1); # Just add to regex verbatim, with
				# appropriate backslashes.
      } elsif( /\G(\\.)/gc ) {	# \ + some char?
	$file_regex .= $1;	# Just add it verbatim.
      } elsif( /\G\*/gc ) {	# Any number of chars?
	$is_wildcard = 1;	# We've actually seen a wildcard char.
	$file_regex .= /\G\*/gc ?
	  '(?:[^\/.][^\/]*\/)*' : # Match any number of directories.
	  '[^\/]*';		# Convert to proper regular expression syntax.
      } elsif( /\G\?/gc ) {	# Single character wildcard?
	$is_wildcard = 1;
	$file_regex .= '[^\/]';
      } else {			# Must be beginning of a character class?
	++pos();		# Skip it.
	$is_wildcard = 1;
	$file_regex .= '[';	# Begin the character class.
      CLASSLOOP:		# Nested loop for grokking the character class.
	{
	  if( /\G([^\\\]]+)/gc ) { $file_regex .= $1; redo CLASSLOOP; }
				# No quotemeta because we want it to
				# interpret '-' and '^' as wildcards, and those
				# are the only special characters within a
				# character class except \.
	  if( /\G(\\.)/gc )	  { $file_regex .= $1; redo CLASSLOOP; }
	  if( /\G\]/gc )	  { $file_regex .= ']'; }
	  else { die "$0: unterminated character class in '$_'\n" }
				# TODO: sh ] is only special 2 or more chars after [
	}
      }
    }
    if( $is_wildcard || $anchor ) { # It's a regular expression.
      if( $anchor ) {
	substr $file_regex, 0, 0, '^' if $anchor & 1;
	$file_regex .= '$' if $anchor > 1; # Cheaper than: & 2
      }
      return $regexp_cache[$anchor]{$_} = case_sensitive_filenames ?
	qr/$file_regex/ :
	qr/$file_regex/i;	# Make it case insensitive.
    }
  }

  s/\\(.)/$1/g;			# Unquote any backslashed characters.
  case_sensitive_filenames ?
    $_ :
    lc;				# Not case sensitive--switch to lc.
}

=head2 wildcard_do

You generally should not call this subroutine directly; it's intended to be
called from the chain of responsibility handled by wildcard_do.

This subroutine is the key to handling wildcards in pattern rules and
dependencies.  Usage:

  wildcard_do {
    my( $finfo, $plain ) = @_;
    ...
  } [\1|\2,] @wildcards;

The block is called once for each file that matches the wildcards.  If at some
later time, files which match the wildcard are created (or we find rules to
build them), then the block is called again.  (Internally, this is done by
Mpp::File::publish, which is called automatically whenever a file which didn't
use to exist now exists, or whenever a build rule is specified for a file
which does not currently exist.)

An optional reference as 2nd parameter, if it is \1 means this is from a last
chance rule.  If it is \2 do not return phonies.

You can specify non-wildcards as arguments to wildcard_do.  In this case, the
block is called once for each of the files explicitly listed, even if they
don't exist and there is no build command for them yet.  Use the second
argument to the block to determine whether there was actually a wildcard or
not, if you need to know.  It is true if (despite the name of this function)
there was no wildcard.

As with Mpp::Glob::zglob, wildcard_do will match files in directories which
don't yet exist, as long as the appropriate Mpp::File structures have been put
in by calls to file_info.

Of course, there are ways of creating new files which will not be detected by
wildcard_do, since it only looks at things that it expects to be modified.
For example, directories are not automatically reread (but when they are
reread, new files are noticed).  Also, creation of new symbolic links to
directories may deceive the system.

There are two restrictions on wildcards handled by this routine.  First, it
will not soft-linked directories correctly after the first wildcard.  For
example, if you do this:

   **/xyz/*.cxx

in order to match all .cxx files somewhere in a subdirectory called "xyz", and
"xyz" is actually a soft link to some other part of the file system, then your
.cxx files will not be found.  This is only true if the soft link occurs
B<after> the first wildcard; something like 'xyz/*.cxx' will work fine even if
xyz is a soft link.

Similarly, after the first wildcard specification, '..' will not work as
expected.  (It works fine if it's present before all wildcards.)  For example,
consider something like this:

   **/xyz/../*.cxx

In theory, this should find all .cxx files in directories that have a
subdirectory called xyz.  This won't work with wildcard_do (it'll work fine
with zglob_fileinfo above, however).  wildcard_do emits a warning message in
this case.

=cut

sub wildcard_do(&@) {
  my( $subr, $flags ) = splice @_, 0, ref( $_[1] ) ? 2 : 1;
  my ( $last_chance, $no_phony ) = ($$flags & 1, $$flags & 2 ? 0 : undef)
    if $flags;
  my $member = $last_chance ? 'LAST_CHANCE' : 'WILDCARD_DO';

#
# We first call the subroutine immediately with all files that we currently
# know about that match the wildcard.
#
  for my $filename (@_) {
    my $need_dir = $filename =~ /\/$/;
    if( $filename !~ /[[?*]/ ) { # no-wildcard?
      my $finfo = file_info $filename, $CWD_INFO;
      Mpp::File::mark_as_directory $finfo if $need_dir;
      &$subr( $finfo, 1 ); # Just call the subroutine directly, with the plain name flag.
      next;
    }
#
# Split this apart into the directories, and handle each layer separately.
# First handle any leading non-wildcarded directories.
#
    my( $dirinfo, @file_pieces );
    if( $filename =~ /^\// || Mpp::is_windows && $filename =~ /^[a-z]:/i ) { # Absolute path?
      @file_pieces = split /\/+(?=[^\/]*[[?*])/, $filename, 2; # last slash before wildcard
      $dirinfo = path_file_info $file_pieces[0], $CWD_INFO;
      @file_pieces = split /\/+/, $file_pieces[1];
    } else {
      $dirinfo = $CWD_INFO;	# Start at the current directory.
      @file_pieces = split /\/+/, $filename;
				# Break up into directories.

      while( @file_pieces ) {	# Loop through leading non-wildcarded dirs:
	if( $file_pieces[0] eq '..' ) { # Common trivial case
	  $dirinfo = $dirinfo->{'..'} || $Mpp::File::root;
	} elsif( $file_pieces[0] ne '.' ) { # normal case
	  my $name_or_regex = $file_pieces[0] =~ /[[?*]/ ? wild_to_regex( $file_pieces[0] ) : $file_pieces[0];
	  last if ref $name_or_regex; # Quit if we hit the first wildcard.
	  $dirinfo = exists $dirinfo->{DIRCONTENTS} && $dirinfo->{DIRCONTENTS}{$name_or_regex} ||
	    file_info $name_or_regex, $dirinfo;
	}
	shift @file_pieces;	# Get rid of that piece.
      }
    }
#
# At this point, $dirinfo is the Mpp::File entry for the file that matches the
# leading non-wildcard directories.  Convert the whole rest of the string into
# a regular expression that matches:
#
    my $idx = 0;
    while( $idx < @file_pieces ) {
      if( $file_pieces[$idx] eq '.' ) { # Remove useless './' components
	splice @file_pieces, $idx, 1; # (since they will mess up the regex).
	next;			# Go back to top without incrementing idx.
      }

      if( $file_pieces[$idx] eq '..' ) { # At least give a warning message
	warn ".. is not supported after a wildcard
  in the wildcard expression \"$filename\".
  This will only match existing files.\n";
				# Let user know this will not do what he thinks.
      }

      ++$idx;
    }

    local $_ = join '/', @file_pieces;
    $need_dir ||= 1 if $file_pieces[-1] =~ /\*\*/;
    unless( $last_chance ) {
      for my $finfo ( zglob_fileinfo $_, $dirinfo, 1, $no_phony ) {
	next if $need_dir && !Mpp::File::is_or_will_be_dir $finfo;
	$finfo->{PUBLISHED}=2 if $Mpp::rm_stale_files;
				# Don't also call $subr later if it looks like
				# a source file now, but we find a rule for it.
	&$subr( $finfo );	# Call the subroutine on each file that matches
      }				# right now.  We give an extra argument to
				# zglob_fileinfo that says not to match soft-
				# linked directories, so the behavior is at
				# least consistent and we do not have subtle
				# bugs in makefiles.  The reason is that
				# we match based on the text of the
				# filename including the directory
				# path, and (in order to make that path unique)
				# the path cannot contain soft-linked dirs.
    }
    my @extra = 1 if @file_pieces > 1 || /\*\*/; # Is pattern part multidir?
    $extra[1] = 1 if $need_dir;
    my $anchor = 0;
    if( $extra[0] ) {
      s!^\*\*/?!! or ++$anchor;
      s!/?\*\*$!! or $anchor += 2;
    } else {
      s!^\*!! or ++$anchor;
      s!/\*$!! or $anchor += 2;
    }
    push @{$dirinfo->{$member}}, [wild_to_regex( $_, $anchor ), $subr, @extra];
				# Associate a wildcard checking subroutine with
				# this directory, so that any subsequent files
				# which match also cause the subroutine to
				# be called.
  }
  1;				# Return true, because we accept all wildcards.
				# We are the last-chance handler in the chain
				# of responsibility for recognizing wildcards.
}

1;
