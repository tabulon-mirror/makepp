# $Id: FileOpt.pm,v 1.125 2014/08/03 21:10:36 pfeiffer Exp $

=head1 NAME

Mpp::FileOpt -- optional subs to complement Mpp::File

=head1 DESCRIPTION

This file defines some additional subroutines for the Mpp::File package that
are useful only within makepp.  This allows Mpp/File.pm to be used outside
of makepp itself.

=cut

package Mpp::File;

use Mpp::File;			# Our basis.

use strict;

our $build_info_subdir = '.makepp';
				# The name of the subdirectory that we store
				# build information in.

our @build_infos_to_update;	# References to all the build info files that
				# have to be flushed to disk.

our $n_last_chance_rules;       # Number of last-chance rules seen this run.

=head2 build_info_string

  my $string = build_info_string($finfo,'key');
  my @strings = build_info_string($finfo,qw'key1 key2 ...');

Returns information about this file which was saved on the last build.	This
information is stored in a separate file, and is automatically invalidated
if the file it refers to has changed.  It is intended for remembering things
like the command used to build the file when it was last built, or the
signatures of the dependencies.

See also: set_build_info_string

=cut

sub build_info_string {
  return undef unless &file_exists;

  my $binfo = $_[0]{BUILD_INFO} ||=
				# We haven't loaded the build information?
    &load_build_info_file ||	# See if there's a build info file.
    {};				# If we can't find any build information,
				# at least cache the failure so we don't try
				# again.

  if( wantarray ) {
    shift;
    @{$binfo}{@_};		# This would deliver length in scalar context.
  } else {
    $binfo->{$_[1]};
  }
}

=head2 get_rule

  my $rule = get_rule( $finfo, $no_last_chance );

Returns the rule to build the file, if there is one, or undef if there is none.
If $no_last_chance is set, then don't consider last chance rules or autoloads.

=cut

sub get_rule {
  return undef if &dont_build;
  my $mdir = $_[0]{'..'};
  exists $mdir->{MAKEINFO} or
    Mpp::Makefile::implicitly_load( $mdir ) # Make sure we've loaded a makefile for this directory.
    if $Mpp::implicitly_load_makefiles;
  # If we know the rule now, then return it.  Otherwise, try to find a "backwards inference" rule.
  return $_[0]{RULE} if exists $_[0]{RULE};
  if( $n_last_chance_rules && !$_[1] ) {
    # NOTE: Similar to Mpp::File::publish(), but we stop on the first match,
    # and there is no stale handling.
    my $finfo = $_[0];
    my $fname = $finfo->{NAME};
    my $dirinfo = $mdir;
    my $leaf = 1;
    DIR: while ($dirinfo) {
      for my $arr ( @{$dirinfo->{LAST_CHANCE}} ) {
	# my( $re, $wild_rtn, $deep, $need_dir ) = @$arr;
	next unless $leaf || $arr->[2];
	next if $fname !~ $arr->[0];
	next if $arr->[3] && !is_or_will_be_dir $finfo;
	$arr->[1]( $finfo );
	last DIR;
      }
      substr $fname, 0, 0, $dirinfo->{NAME} . '/';
      $dirinfo = $dirinfo->{'..'};
      undef $leaf;
    }
    unless( $finfo->{RULE} ) {
      if( my $minfo = $mdir->{MAKEINFO} ) {
	while( my $auto = shift @{$minfo->{AUTOLOAD} || []} ) {
	  Mpp::log AUTOLOAD => $finfo;
	  Mpp::Makefile::load( $auto, $mdir, {}, '', [], $minfo->{ENVIRONMENT}, undef, 'AUTOLOAD' );
	  last if exists $finfo->{RULE};
	}
      }
      $finfo->{RULE};
    }
  }
}

=head2 exists_or_can_be_built

=head2 exists_or_can_be_built_or_remove

  if (exists_or_can_be_built( $finfo )) { ... }

Returns true (actually, returns the Mpp::File structure) if the file
exists and is readable, or does not yet exist but can be built.	 This
function determines whether a file exists by checking the build
signature, not by actually looking in the file system, so if you set
up a signature function that can return a valid build signature for a
pseudofile (like a dataset inside an HDF file or a member of an
archive) then this function will return true.

If this is not what you want, then consider the function file_exists(), which
looks in the file system to see whether the file exists or not.

The ..._or_remove variant removes the file if $Mpp::rm_stale_files is set
and the file is stale.
You shouldn't call this unless you're confident that the file's rule will not
be learned later, but it's exactly what you need for scanners, because if
you don't remove stale files from the search path, then they'll get picked
up erroneously (by the command itself, but usually *not* by the scanner)
when they are in front of the file's new directory.

Optimization: The results of exists_or_can_be_built_norecurse (and hence
exists_or_can_be_built) are cached in EXISTS_OR_CAN_BE_BUILT.  But, since this
function used to get called an obscene number of times, they don't themselves
check the cache, instead providing it to its potential caller.

There can be 3 values for phony: 0 -- no phony targets; 1 -- only phony
targets; undef -- don't care.

=cut

my %warned_stale;
sub exists_or_can_be_built_norecurse {
  my ($finfo, $phony, $stale) = @_;
  return exists $finfo->{xPHONY} && $finfo if $phony;
  return $finfo if !defined $phony and exists $finfo->{xPHONY};
				# Never return phony targets unless requested.

  # lstat and stat calls over NFS take a long time, so if we do the lstat and
  # find it doesn't exists, then we need to avoid doing the stat too. This
  # also comes into play a few lines later, where we don't check the signature
  # when we know the file doesn't exists, unless the object is of a subclass
  # where the signature method might be overridden.
  if( &is_symbolic_link ) {
    &dont_build or
      $finfo->{BUILD_INFO} ||= &load_build_info_file; # blow away bogus repository links
  } elsif( exists $finfo->{xEXISTS} &&
      !&have_read_permission) { # File exists, but can't be read, and
				# isn't a broken symbolic link?
    return $finfo->{EXISTS_OR_CAN_BE_BUILT} = 0;
				# Can't be read--ignore it.  This is used
				# to inhibit imports from repositories.
  }

  if( exists $finfo->{xEXISTS} ) { # We know it exists?
    # If we think it's a stale file when this is called, then just pretend
    # it isn't there, but don't remove it because we might find out later
    # that there is a rule for it.
    if(!$stale && $Mpp::rm_stale_files && &is_stale) {
      Mpp::log MAYBE_STALE => $finfo
	if $Mpp::log_level && !$warned_stale{sprintf '%x', $finfo} and $warned_stale{sprintf '%x', $finfo} = $finfo;
      return undef;
    }
    $finfo->{EXISTS_OR_CAN_BE_BUILT} = 1;
    return $finfo;
  }
  undef;
}
sub exists_or_can_be_built {
  # If $phony is 0, return no phony targets, if 1, only phony targets, if undef any targets.
  # If $stale is set, then return stale generated files too, even if
  # $Mpp::rm_stale_files is set.
  # If $no_last_chance is set, then don't return generated files if the only
  # rule to build them is a last-chance rule that we haven't already instanced.
  my ($finfo, $phony, $stale, $no_last_chance) = @_;

  if( &dont_build ) {
    &lstat_array;
    return unless exists $finfo->{xEXISTS};
  }
  &is_or_will_be_dir if $Mpp::File::directory_first_reference_hook;
  my $result = ($phony || !exists $finfo->{EXISTS_OR_CAN_BE_BUILT}) ?
    &exists_or_can_be_built_norecurse :
    $finfo->{EXISTS_OR_CAN_BE_BUILT} ? $finfo : 0;
  return $result || undef if defined $result;
  my $already_loaded_makefile = $finfo->{'..'}{MAKEINFO};
  return $finfo if
    $finfo->{ADDITIONAL_DEPENDENCIES} ||
				# For legacy makefiles, sometimes an idiom like
				# this is used:
				#   y.tab.c: y.tab.h
				#   y.tab.h: parse.y
				#	yacc -d parse.y
				# in order to indicate that the yacc command
				# has two targets.  We need to support this
				# by indicating that files with extra
				# dependencies are buildable, even if there
				# isn't an actual rule for them.
    get_rule( $finfo, $no_last_chance ) && (!exists $finfo->{xPHONY} xor $phony) ||
    !$already_loaded_makefile && &exists_or_can_be_built_norecurse;
				# Rule for building it (possibly undef'ed if
				# it was already built)? Note that even if it
				# looked stale to begin with, it could have
				# been built by calling get_rule.
  # Exists in repository?
  if( exists $finfo->{ALTERNATE_VERSIONS} ) {
    for( @{$finfo->{ALTERNATE_VERSIONS}} ) {
      $result = exists_or_can_be_built_norecurse $_, $phony, $stale;
      return $result ? $finfo : undef if defined $result;
    }
  }
  undef;
}
sub exists_or_can_be_built_or_remove {
  return if &dont_build && &lstat_array == $Mpp::File::empty_array;
  my $finfo = $_[0];
  $warned_stale{sprintf '%x', $finfo} = $finfo if $Mpp::rm_stale_files; # Remember for end, avoid redundant warning
  my $result = &exists_or_can_be_built;
  return $result if $result || !$Mpp::rm_stale_files;
  if( exists $finfo->{xEXISTS} || &signature ) {
    unless( &was_built_by_makepp ) {
      die '`' . &absolute_filename . "' is both a source file and a phony target\n" if exists $finfo->{xPHONY};
      return unless &have_read_permission; # Hidden from mpp.
    }
    Mpp::log DEL_STALE => $finfo
      if $Mpp::log_level;
    # TBD: What if the unlink fails?
    &unlink;
    # Remove the build info file as well, so that it won't be treated as a generated
    # file if something other than makepp puts it back with the same signature.
    CORE::unlink &build_info_fname;
  }
  $result;
}

#=head2 clean_fileinfos

#  clean_fileinfos($dirinfo)

#Discards all the build information for all files in the given directory
#after making sure they've been written out to disk.  Also discards all
#Mpp::File objects for files which we haven't tried to build and don't have
#a build rule.

#=cut
#sub clean_fileinfos {
#
# For some reason, the code below doesn't actually save very much memory at
# all, and it occasionally causes problems like extra rebuilds or
# forgetting about rules for some targets.  I don't understand how this
# is possible, but it happened.
#

#   my $dirinfo = $_[0];		# Get the directory.

#   &update_build_infos;		# Make sure everything's written out.
#   my ($fname, $finfo);

#   my @deletable;

#   while (($fname, $finfo) = each %{$dirinfo->{DIRCONTENTS}}) {
#				# Look at each file:
#     delete $finfo->{BUILD_INFO}; # Build info can get pretty large.
#     delete $finfo->{LSTAT};	# Toss this too, because we probably won't need
#				# it again.
#     $finfo->{DIRCONTENTS} and clean_fileinfos($finfo);
#				# Recursively clean the whole tree.
#     next if exists $finfo->{BUILD_HANDLE}; # Don't forget the files we tried to build.
#     next if $finfo->{RULE};	# Don't delete something with a rule.
#     next if $finfo->{DIRCONTENTS}; # Don't delete directories.
#     next if $finfo->{ALTERNATE_VERSIONS}; # Don't delete repository info.
#     next if exists $finfo->{xPHONY};
#     next if $finfo->{ADDITIONAL_DEPENDENCIES}; # Don't forget info about
#				# extra dependencies, either.
#     next if $finfo->{TRIGGERED_WILD}; # We can't delete it if reading it back
#				# in will trigger a wildcard routine again.
#     if ($fname eq 'all') {
#	warn("I'm deleting all now!!!\n");
#     }
#     push @deletable, $fname;	# No reason to keep this finfo structure
#				# around.  (Can't delete it, though, while
#				# we're in the middle of iterating.)
#   }
#   if (@deletable) {		# Something to delete?
#     delete @{$dirinfo->{DIRCONTENTS}}{@deletable}; # Get rid of all the unnecessary Mpp::Files.
#     delete $dirinfo->{READDIR};	# We might need to reread this dir.
#   }
#}



=head2 name

  $string = $finfo->name;

Returns the absolute name of the file.  Note: other classes have this method
too, so when you're not sure you have a Mpp::File, better use method syntax.

=cut

*name = \&absolute_filename;


=head2 set_build_info_string

  set_build_info_string($finfo, $key, $value, $key, $value, ...);

Sets the build info string for the given key(s).  This can be read back in
later or on a subsequent build by build_info_string().

You should call update_build_infos() to flush the build information to disk,
or else it will never be stored.  It's a good idea to call
update_build_infos() fairly frequently, so that nothing is lost in the case of
a machine crash or someone killing your program.

=cut

sub set_build_info_string {
  my( $finfo ) = @_;

  my $binfo = $finfo->{BUILD_INFO} ||=
				# We haven't loaded the build information?
    &load_build_info_file ||	# See if there's a build info file.
    {};				# If we can't find any build information,
				# at least cache the failure so we don't try
				# again.

  my $update;
  my $i = 1;
  while ($i < $#_) {
    my( $key, $val ) = ($_[$i], $_[$i + 1]);
    $i += 2;
    die if $key eq 'END';

    unless( defined $binfo->{$key} && $binfo->{$key} eq $val ) {
      $update = 1;
      $binfo->{$key} = $val;
    }
  }
  if( $update ) {
    undef $finfo->{xUPDATE_BUILD_INFOS};
				# Remember that we haven't updated this
				# file yet.
    push @build_infos_to_update, $finfo;
  }
}

=head2 mark_build_info_for_update

  mark_build_info_for_update( $finfo );

Marks this build info for update the next time an update is done.  You only
need to call this if you modify the BUILD_INFO hash directly; if you call
set_build_info_string, it's already handled for you.

=cut

sub mark_build_info_for_update {
  undef $_[0]{xUPDATE_BUILD_INFOS}; # Remember to update
  push @build_infos_to_update, $_[0];
}

=head2 clear_build_info

  clear_build_info( $finfo );

Clears the build info strings for all keys.
The principal reason to do this would be that the file is about to be
regenerated.

=cut
sub clear_build_info {
  $_[0]{BUILD_INFO} = {};	# Clear the build information.

  # Now remove the info file, if any. It's dangerous to leave this for
  # update_build_infos, because if the timestamp of a regenerated file was
  # the same and we stop before the build info is re-written, then we could
  # pick up stale info on the next makepp run.

  CORE::unlink &build_info_fname; # Get rid of bogus file.
  # TBD: What to do if it's still there (e.g. no directory write privilege)?
  delete $_[0]{xUPDATE_BUILD_INFOS}; # No need to update at the moment.
}

=head2 set_rule

  set_rule($finfo, $rule);

Sets a rule for building the specified file.  If there is already a rule,
which rule overrides is determined by the following procedure:

=over 4

=item 1.

A rule that recursively invokes make never overrides any other rule.
This is a hack necessary to deal with some legacy makefiles which have
rules for targets that actually invoke the proper rule in some other
makefile, something which is no longer necessary with makepp.

=item 2.

If either rule is an explicit rule, and not a pattern rule or a backward
inference rule, then the explicit rule is used.	 If both rules are
explicit rules, then this is an error.

Note that a pattern rule which is specified like this:

  %.o: %.c : foreach abc.c def.c ghi.c

where no wildcards are involved is treated as an explicit rule for
abc.o, def.o, and ghi.o.

=item 3.

A pattern rule overrides a backward inference rule.  (This should never
happen, since backward inference rules should only be generated if no pattern
rule exists.)

=item 4.

A pattern rule from a "nearer" makefile overrides one from a "farther"
makefile.  Nearness is determined by the length of the relative file
name of the target compared to the makefile's cwd.

=item 5.

A pattern rule seen later overrides one seen earlier.  Thus more specific
pattern rules should be placed after the more general pattern rules.

=item 6.

A builtin rule is always overridden by any other kind of rule, and never
overrides anything.

=back

=cut

sub set_rule {
  return if &dont_build;

  my( $finfo, $rule ) = @_; # Name the arguments.

  unless( defined $rule ) {	# Are we simply discarding the rule now to
				# save memory?	(There's no point in keeping
				# the rule around after we've built the thing.)
    undef $finfo->{RULE} if exists $finfo->{RULE} && !$Mpp::loop;
				# Just keep a marker around that there used
				# to be a rule.
    return;
  }

  my $rule_is_builtin = ($rule->source =~ /\bmakepp_builtin_rules\.mk:/) and
    exists $finfo->{xPHONY} and	# If we know this is a phony target, don't
				# ever let a builtin rule attempt to build it.
      return;

  if( my $oldrule = $finfo->{RULE} ) {	# Is there a previous rule?

    if( $oldrule->{LOAD_IDX} < $oldrule->{MAKEFILE}{LOAD_IDX}) {
      undef $finfo->{RULE};	# If the old rule is from a previous load
				# of a makefile, discard it without comment.
      delete $finfo->{BUILD_HANDLE}; # Avoid the warning message below.  Also,
				# if the rule has genuinely changed, we may
				# need to rebuild.
    } else {
      return if $rule_is_builtin; # Never let a builtin rule override a rule in the makefile.
      if( $oldrule->source !~ /\bmakepp_builtin_rules\.mk:/ ) { # The old rule isn't a builtin rule.
	Mpp::log RULE_ALT => $rule, $oldrule, $finfo
	  if $Mpp::log_level;

	my $new_rule_recursive = ($rule->{COMMAND_STRING} || '') =~ /\$[({]MAKE[)}]/;
	my $old_rule_recursive = ($oldrule->{COMMAND_STRING} || '') =~ /\$[({]MAKE[)}]/;
				# Get whether the rules are recursive.

	if( $new_rule_recursive && !$old_rule_recursive ) {
				# This rule does not override anything if
				# it invokes a recursive make.
	  Mpp::log RULE_IGN_MAKE => $rule
	    if $Mpp::log_level;
	  return;
	}

	if( $old_rule_recursive && !$new_rule_recursive ) {
	  Mpp::log RULE_DISCARD_MAKE => $oldrule
	    if $Mpp::log_level;

	  delete $finfo->{BUILD_HANDLE};
				# Don't give a warning message about a rule
				# which was replaced, because it's ok in this
				# case to use a different rule.
	} elsif( exists $rule->{PATTERN_RULES} ) { # New rule is pattern rule?
	  if( exists $oldrule->{PATTERN_RULES} ) { # Figure out which one should override.
	    if( $rule->{MAKEFILE} != $oldrule->{MAKEFILE} ) { # Compare the cwds
				# if they are from different makefiles.
	      if( relative_filename( $rule->build_cwd, $finfo->{'..'}, 1 ) <
		  relative_filename( $oldrule->build_cwd, $finfo->{'..'}, 1 )) {
		Mpp::log RULE_NEARER => $rule
		  if $Mpp::log_level;
	      } else {
		Mpp::log RULE_NEARER_KEPT => $oldrule
		  if $Mpp::log_level;
		return;
	      }
	    } elsif( my $cmp = @{$rule->{PATTERN_RULES}} <=> @{$oldrule->{PATTERN_RULES}} ) {
				# If they're from the same makefile, use the
				# one that has a shorter chain of inference.
	      Mpp::log RULE_SHORTER => $cmp == 1 ? $oldrule : $rule
		if $Mpp::log_level;
	      return if $cmp == 1;
	    } else {
	      warn $rule->source, ': two different ways to produce `', &absolute_filename, "'\n"
		if $rule->source eq $oldrule->source;
	    }
	  } else {
	    Mpp::log RULE_IGN_PATTERN => $rule
	      if $Mpp::log_level;
	    return;
	  }
	} elsif( exists $oldrule->{PATTERN_RULES} ) {
	  Mpp::log RULE_IGN_PATTERN => $oldrule
	    if $Mpp::log_level;
	} else {
	  warn( $rule->source, ": conflicting rule for target `", &absolute_filename, "'\n" ),
	  warn( $oldrule->source, ": info: was the previous rule\n" )
	    unless exists $rule->{xMULTIPLE_RULES_OK} &&
	      exists $oldrule->{xMULTIPLE_RULES_OK} &&
	      $rule->{COMMAND_STRING} eq $oldrule->{COMMAND_STRING};
	  # It's not safe to suppress this warning solely because the
	  # command string is the same, because it might expand differently
	  # in different makefiles.  But if the rules are marked to allow
	  # this, then we suppress anyway.
	}
      }
    }
  }

#
# If we get here, we have decided that the new rule (in $rule) should override
# the old one (if there is one).
#

  Mpp::log RULE_SET => $finfo, $rule->{DEPENDENCY_STRING}, $rule->{RULE_SOURCE}
    if Mpp::DEBUG;

  undef $finfo->{xPHONY}	# Hack to get past above restriction for xyz -> xyz.exe
    if Mpp::is_windows && $rule_is_builtin && delete $finfo->{_IS_EXE_PHONY_};

  if( exists $finfo->{BUILD_HANDLE} && UNIVERSAL::isa $finfo->{RULE}, 'Mpp::Rule' ) {
    warn $rule->source, ': rule discovered for target ', &absolute_filename, " after I had already tried to build it\n"
      unless $rule_is_builtin || exists $rule->{xMULTIPLE_RULES_OK} || UNIVERSAL::isa $rule, 'Mpp::DefaultRule';
  }

  $finfo->{RULE} = $rule;	# Store the new rule.
  $finfo->{PATTERN_RULES} = $rule->{PATTERN_RULES} if $rule->{PATTERN_RULES};
				# Remember the pattern level, so we can prevent
				# infinite loops on patterns.  This must be
				# set before calling publish(), or we'll get
				# infinite recursion.
  $rule->{LOAD_IDX} = $rule->{MAKEFILE}{LOAD_IDX};
				# Remember which makefile load it came from.
  publish $finfo, $Mpp::rm_stale_files;
				# Now we can build this file; we might not have been able to before.
}

=head2 signature

   $str = signature( $fileinfo )

Returns a signature for this file that can be used to know when the file has
changed.  The signature consists of the file modification time and the file
size concatenated.

Returns undef if the file doesn't exist.

This signature is used for several purposes:

=over 4

=item *

If this signature changes, then we discard the build info for the file because
we assume it has changed.

=item *

This is currently the default signature if we are not doing compilation of
source code.

=back

=cut


sub signature {
  my $stat = $_[0]{LSTAT};
  $stat = &stat_array if !$stat || exists $_[0]{LINK_DEREF};
				# Get everything we can get about the file
				# without actually opening it.
  !@$stat ? (@{$stat = $_[0]{LSTAT}} ? # Dangling symlink, prepend 0 as marker
	     "0$stat->[STAT_MTIME],$stat->[STAT_SIZE]" :
	     undef) :		# Undef means file doesn't exist.
    S_ISDIR( $stat->[STAT_MODE] ) ? 1 :
				# If this is a directory, the modification time
				# is meaningless (it's inconsistent across
				# file systems, and it may change depending
				# on whether the contents of the directory
				# has changed), so just return a non-zero
				# constant.
    # NOTE: This has to track Mpp/BuildCheck/target_newer.pm, and Mpp/BuildCache.pm
    # in a couple of places:
    "$stat->[STAT_MTIME],$stat->[STAT_SIZE]";
}

=head2 update_build_infos

  Mpp::File::update_build_infos();

Flushes our cache of build information to disk.	 You should call this fairly
frequently, or else if the machine crashes or some other bad thing happens,
some build information may be lost.

=cut

sub write_build_info_file {
  my ($build_info_fname, $build_info) = @_;
  open my $fh, '>', $build_info_fname or return undef;
  my $contents = '';
  while( my($key, $val) = each %$build_info ) {
    $val =~ tr/\n/\cC/;		# Protect newline.  Keys must not have any.
				# (This does not modify the value inside the BUILD_INFO hash.)
    $contents .= $key . '=' . $val . "\n";
  }
  # This provides proof that the writing of the build info file was not
  # interrupted.
  print $fh $contents . 'END=' or return undef;
  close($fh) or return undef;
}

sub update_build_infos {
  foreach my $finfo (@build_infos_to_update) {
    next unless exists $finfo->{xUPDATE_BUILD_INFOS};
				# Skip if we already updated it.  If two
				# build info strings for the same file are
				# changed, it can get on the list twice.
    delete $finfo->{xUPDATE_BUILD_INFOS}; # Do not update it again.
    if( !in_sandbox( $finfo ) || ($Mpp::virtual_sandbox_flag && !$finfo->{BUILDING}) ) {
      # If we cached some info about a file outside of our sandbox, then
      # don't flush the info, but don't write it either, because then we could
      # have a race with another makepp process. (That's what sandboxing is
      # all about.)
      Mpp::log NOT_IN_SANDBOX => $finfo
	if $Mpp::log_level;
      next;
    }

    &mkdir			# Make sure the build info subdir exists.
      ($finfo->{'..'}{DIRCONTENTS}{$build_info_subdir} ||=
       bless { NAME => $build_info_subdir, '..' => $finfo->{'..'} });

    my $build_info_fname = absolute_filename_nolink( $finfo->{'..'} ) .
      "/$build_info_subdir/$finfo->{NAME}.mk"; # Form the name of the build info file.

    my $build_info = $finfo->{BUILD_INFO}; # Access the hash.
    $build_info->{SIGNATURE} ||= signature( $finfo ) ||
				# Make sure we have a valid signature. Use ||=
				# instead of just = because when we're called
				# to write the build info for a file from a
				# repository, the build info is created before
				# the link to avoid the race condition where a
				# soft link is created and we are interrupted
				# before marking it as from a repository.
      defined $build_info->{BUILD_SIGNATURE} && $build_info->{BUILD_SIGNATURE} eq 'FAILED' && '0,0' or
	next;			# If the file has been deleted, don't bother
				# writing the build info stuff.
    write_build_info_file($build_info_fname, $build_info);
				# Ignore failure to write.  TBD: warn here?
  }
  @build_infos_to_update = ();	# Clean out the list of files to update.
}
END {
  &update_build_infos;
  for my $finfo ( values %warned_stale ) {
    if( is_stale $finfo and file_exists $finfo ) {
      # After all, it is still stale and not hidden from mpp.
      Mpp::log DEL_STALE => $finfo
	if $Mpp::log_level;
      &unlink( $finfo );
      CORE::unlink build_info_fname( $finfo );
    }
  }
}

=head2 was_built_by_makepp

   $built = was_built_by_makepp( $fileinfo );

Returns TRUE iff the file was put there by makepp and not since modified.

=cut

sub was_built_by_makepp {
  defined and return 1
    for build_info_string $_[0], qw'BUILD_SIGNATURE FROM_REPOSITORY';
  if( exists $_[0]{TEMP_BUILD_INFO} ) {
    defined and return 1
      for @{$_[0]{TEMP_BUILD_INFO}}{qw'BUILD_SIGNATURE FROM_REPOSITORY'};
  }
  0;
}

=head2 is_stale

   $stale = is_stale( $fileinfo );

Returns TRUE iff the file was put there by makepp and not since modified, but
now there is no rule for it, or it is not from a repository and the only
rule for it is to get it from a repository.

=cut

# is_stale( $finfo )
# Note that load_build_info_file may need to track changes to is_stale.
sub is_stale {
  (exists $_[0]{xPHONY} ||
   !exists $_[0]{RULE} && !$_[0]{ADDITIONAL_DEPENDENCIES})
  && !&dont_build && &was_built_by_makepp &&
    (defined &Mpp::Repository::no_valid_alt_versions ? &Mpp::Repository::no_valid_alt_versions : 1)
  && (exists $_[0]->{LINK_DEREF} || # don't test possibly dangling symlink
      have_read_permission $_[0]); # hidden by user can't be stale
}

=head2 assume_unchanged

Returns TRUE iff the file or directory is assumed to be unchanged.
A file or directory is assumed to be unchanged if any of its ancestor
directories are assumed unchanged.

=head2 dont_build

Returns TRUE iff the file or directory is marked for don't build.
A file or directory is treated as marked for don't build if any of its ancestor
directories are so marked and the youngest such ancestor is not older than
the youngest ancestor that is marked for do build.

=head2 in_sandbox

Returns TRUE iff the file or directory is marked for in-sandbox (or if
sandboxing isn't enabled).
A file or directory is treated as marked for in-sandbox if any of its ancestor
directories are so marked and the youngest such ancestor is not older than
the youngest ancestor that is marked for out-of-sandbox.

=head2 dont_read

Returns TRUE iff the file or directory is marked for don't read.
A file or directory is treated as marked for don't read if any of its ancestor
directories are so marked and the youngest such ancestor is not older than
the youngest ancestor that is marked for do read.

=cut

BEGIN {
  for( qw(assume_unchanged dont_build in_sandbox~!$Mpp::sandbox_enabled_flag dont_read) ) {
    my( $fn, $fail ) = split '~';
    $fail ||= 'undef';
    my $key = uc $fn;
    eval "sub $fn {
      exists( \$_[0]{$key} ) ?
	\$_[0]{$key} :
      (\$Mpp::${fn}_dir_flag && \$_[0] != \$Mpp::File::root) ?
	(\$_[0]{$key} = $fn( \$_[0]{'..'} )) :
	$fail;
    }";
  }
}


###############################################################################
#
# Internal subroutines (don't call these):
#


sub build_info_fname { "$_[0]{'..'}{FULLNAME}/$build_info_subdir/$_[0]{NAME}.mk" }

sub grok_build_info_file {
  local $/;
  no warnings 'closed';		# How can fh (rarely in bc stress) be closed?
  my $file = readline( $_[0] ) || '';
  close $_[0];
  my %build_info;
  ($build_info{$1} = $2) =~ tr/\cC/\n/
    while $file =~ /\G(.+?)=(.*)\n/gc;	# Parse the format.
  $file =~ /\GEND=/gc ? \%build_info : undef;
}

#
# Load a build info file, if it matches the signature on the actual file.
# Returns undef if this build info file didn't exist or wasn't valid,
# except if called from mppr, in which case it deletes SIGNATURE.
# Arguments:
# a) The Mpp::File struct for the file.
#
sub load_build_info_file {
  my $build_info_fname = &build_info_fname;
  open my $fh, '<:crlf', $build_info_fname or
    return;

  my $build_info = grok_build_info_file $fh;
  if( $build_info ) {
    my( $finfo ) = @_;
    my $sig = &signature || '';	# Calculate the signature for the file, so
				# we know whether the build info has changed.
    my $sig_match = ($build_info->{SIGNATURE} || '') eq $sig;

    if( exists $build_info->{FROM_REPOSITORY} ) {
      # If we linked the file in from a repository, but it was since modified in
      # the repository, then we need to remove the link to the repository now,
      # because otherwise we won't remove the link before the target gets built.
      # Note that this code may need to track changes to is_stale.
      unless( $sig_match && (Mpp::MAKEPP ? exists $finfo->{ALTERNATE_VERSIONS} : 1) || &dont_build ) {
	if( &dereference != file_info $build_info->{FROM_REPOSITORY}, $finfo->{'..'} ) {
	  undef $sig_match;	# The symlink was modified outside of makepp
	} elsif( &in_sandbox || !-e &absolute_filename ) {
	  # If the symlink points nowhere, then there is no race here even
	  # if it is out of sandbox, because the result is the same no matter
	  # who wins the race.  However, this probably isn't 100%
	  # bulletproof, because some makepp process other than the one that
	  # deletes the file might think that it still exists after it and
	  # its build info file have been removed.  That's probably still
	  # better than getting permanently stuck when a repository file is
	  # deleted.
	  Mpp::log REP_OUTDATED => $finfo
	    if $Mpp::log_level;
	  &unlink;
	} else {
	  warn $Mpp::sandbox_warn_flag ? '' : 'error: ',
	    "Can't remove outdated repository link " . &absolute_filename . " because it's out of my sandbox\n";
	  die unless $Mpp::sandbox_warn_flag;
	}
      }
    }

    unless( $sig_match ) {	# Exists but has the wrong signature?
      if( !Mpp::MAKEPP && $Mpp::progname =~ /^makepp(?:info|replay)$/ ) {
	$build_info->{invalidated_SIGNATURE} =
	  delete $build_info->{SIGNATURE}; # Remember to handle this later in makeppreplay.
      } elsif( $build_info->{SYMLINK} ) {
				# Signature is that of linked file.  The symlink
				# is checked before possibly rebuilding it.
	if( $sig or not $Mpp::rm_stale_files || $build_info->{FROM_REPOSITORY} ) {
				# Link and linkee exist or not supposed to wipe.
	  $build_info->{SIGNATURE} = $sig;
	  $finfo->{TEMP_BUILD_INFO} = $build_info; # Mpp::Rule::execute will pick it up.
	} else {
	  Mpp::log DEL_STALE => $finfo
	    if $Mpp::log_level;
	  &unlink;
	  CORE::unlink $build_info_fname;
	}
	return undef;
      } else {
	Mpp::log OUT_OF_DATE => $finfo
	  if $Mpp::log_level;
	CORE::unlink $build_info_fname; # Get rid of bogus file.
	# NOTE: We assume that if we failed to unlink $finfo, then we'll fail to
	# unlink $build_info_fname as well, so that the FROM_REPOSITORY turd will
	# remain behind, which is what we want. Furthermore, because we remember
	# that we tried to unlink $finfo, it should appear to makepp that it
	# no longer exists, which is also what we want.
	return undef;
      }
    }
  } else {
    warn "$build_info_fname: build info file corrupted\n";
    CORE::unlink $build_info_fname; # Get rid of bogus file.
  }
  $build_info;
}

1;
