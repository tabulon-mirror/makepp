# $Id: Scanner.pm,v 1.66 2017/08/06 21:19:09 pfeiffer Exp $

=head1 NAME

Mpp::Scanner - Base class for makepp file scanners

=head1 SYNOPSIS

  use Mpp::Scanner;
  our @ISA = qw/Mpp::Scanner/;
  sub xscan_file {
    my( $self, $cp, $tag, $finfo, $conditional, $fh ) = @_;
    while(<$fh>) {
      # ...
    }
  }

=head1 DESCRIPTION

C<Mpp::Scanner> is a base class for makepp(1) file scanners.
It supports both conditional scanning and unconditional scanning.

The scanner for a particular language should derive from this class.
An object of this type is normally instantiated by an object of type
C<Mpp::CommandParser>.

If unconditional scanning is used, then every include statement is considered
active.
This has the advantage that scanning is simpler, and that include directives
are easily cached.
However, it has the disadvantage of possibly creating incorrect dependencies.
For example, in C the following lines should not affect the dependencies:

  #if 0
  # include "foo.h"
  #endif

Also, the following should imply a dependency on foo.h, which should itself
be scanned:

  #define NAME "foo.h"
  #include NAME

The reason that the include directives cannot easily be cached in conditional
scanning is that the same file might include different things depending on
what preceded it and what was defined on the command line.
For the same reason, it is not possible to scan include files for the same
translation in parallel if conditional scanning is employed (although that
isn't done with unconditional scanning either right now).

=cut

use strict;
package Mpp::Scanner;
use Mpp::Text ();

BEGIN {
  (*INCLUDE_DIRS, *INCLUDE_SFXS, *TAG_MAP, *SHOULD_FIND) = @Mpp::Text::N;
}

# Most C implementations use 100, but that runs into the Perl subroutine
# recursion warning limit. In well-designed code, anything over 10 deep is
# probably infinite recursion anyway, so we're very unlikely to miss
# dependencies due to this number not being large enough.
sub DEFAULT_DEPTH() { 75 }

=head1 METHODS

=head2 new

  my $scanner = Mpp::Scanner->new($rule, $dir, $conditional);

Returns a new Mpp::Scanner for rule $rule.  $dir is the directory name
(relative to the CWD of $rule's Makefile) in which files are to be
interpreted.  $conditional is TRUE if conditional scanning is to be used,
FALSE if not, and undef if it is to be determined from the rule options.  The
subclass may override this method, and may have different parameters.

=cut

my $empty_info_string = {};
sub new {
  my ($self,$rule, $dir, $conditional)=@_;
  my $class=ref($self)||$self;
  die unless ref $rule;
  die unless $dir && !ref $dir;
  $conditional=$rule->{CONDITIONAL_SCANNING} unless defined $conditional;
  # TBD: Get $conditional from command-line options
  # unless defined $conditional;
  $conditional=0 unless defined $conditional;
  bless {
    RULE => $rule,
    DIR => $dir,
    CONDITIONAL => $conditional,
    INFO_STRING => $empty_info_string, # Can get replaced by a different
				       # hashref, but never gets modified.
    SCOPES => [1],
    ACTIVE => 1,
    DEPTH => DEFAULT_DEPTH,
    VARS => {},
    PENDING => [],
  }, $class;
}

=head2 add_include_dir

  $scanner->add_include_dir($tag, $path);

Add directory $path (relative to $self->{DIR}) to the include path for tag
$tag.
Tags can be anything you want, as long as they are lowercase, for example
"user" and "sys" for the C double-quote include path and angle-bracket include
path, respectively.

An undefined $path represents the directory in which the file containing the
include directive resides.  A path matching /^in :/ is followed by an
alternate tag to look in.  A path matching /^in ;?/ is followed by an
environment variable to look in.  The optional ';' means to split on that
(even when running under Cygwin).

=cut

use Mpp::File;
use Mpp::FileOpt;
use Mpp::CommandParser;

my %dir_warnings;

sub get_tagname {
  my ($self, $tag) = @_;
  return $tag unless defined $tag;
  $self->{$tag}[TAG_MAP] ||= $self->{RULE}->get_tagname($tag);
}
sub add_include_dir {
  my ($self, $tag, $path, $front)=@_;
  if( defined $path ) {
    if( $path =~ /^in / ) {
      if( $front ) {
	unshift @{$self->{$tag}[INCLUDE_DIRS]}, $path;
      } else {
	push @{$self->{$tag}[INCLUDE_DIRS]}, $path;
      }
      $self->{RULE}->add_include_dir($self->get_tagname($tag), $path, $front);
    } else {
      my $dirinfo = $self->get_file_info( $path );
      if( is_or_will_be_dir $dirinfo ) {
	# NOTE: INCLUDE_DIRS can hold dirinfos instead of
	# directory names because if the directory from which
	# an include file is picked up changes due to a
	# retargeted symbolic link, then a re-scan gets forced
	# (once the retargeting detection logic is added).
	if( $front ) {
	  unshift @{$self->{$tag}[INCLUDE_DIRS]}, $dirinfo;
	} else {
	  push @{$self->{$tag}[INCLUDE_DIRS]}, $dirinfo;
	}
      } else {
	warn $self->{RULE}->source, ': invalid directory `' . absolute_filename( $dirinfo ) . "' mentioned in command\n"
	  unless $dir_warnings{sprintf '%x', $dirinfo}++;
				# Don't give the same warning more than
				# once.
      }
      $self->{RULE}->add_include_dir(
	$self->get_tagname($tag),
	Mpp::Lexer::relative_path( $self->{DIR}, $path ),
	$front
      );
    }
  } else {
    if($front) {
      unshift @{$self->{$tag}[INCLUDE_DIRS]}, undef;
    } else {
      push @{$self->{$tag}[INCLUDE_DIRS]}, undef;
    }
    $self->{RULE}->add_include_dir(
      $self->get_tagname($tag), undef, $front
    );
  }
}

=head2 add_include_suffix

  $scanner->add_include_suffix($tag, $suffix);

Append $suffix to the list of suffixes to append to the string
naming the file to be included (I<i.e.> the $name parameter of the include()
method).
The list starts as an empty array, but it defaults to C<('')> if a file is
sought before any suffix is added.  If the first element is '/' it means to try
the other suffixes in the list only for a name that doesn't have one (embedded SQL/C).
Directory search order takes precedence over suffix search order.
[This is used by VCS, as well as a number of other Verilog-related tools.]

=cut

my %suffix_list_cache;
sub add_include_suffix {
  my( $self, $tag, $sfx ) = @_;
  my @sfxs = @{$self->{$tag}[INCLUDE_SFXS] || []};
  push @sfxs, $sfx;
  $self->add_include_suffix_list($tag, \@sfxs);
}
sub add_include_suffix_list {
  my( $self, $tag, $sfxs ) = @_;
  $sfxs = $suffix_list_cache{"@$sfxs"} ||= $sfxs;
  $self->{$tag}[INCLUDE_SFXS] = $sfxs;
  $self->{RULE}->add_include_suffix_list( $self->get_tagname($tag), $sfxs );
}

=head2 should_find

  $scanner->should_find($tag);

Add include path tag $tag to the list of tags that should generate a warning
if the requested file is not found.
I<Not> calling this is useful, for example, for C angle-bracket includes,
wherein it is likely that the file won't be found because we don't know the
entire standard system include path.
It is assumed that files included from the system include path would I<not>
be included with double quotes, to avoid false warnings.

=cut

sub should_find {
  $_[0]{$_[1]}[SHOULD_FIND] = 1;
}

=head2 info_string

  $scanner->info_string( $hashref );

Sets the build_info_string name associated with includes using the $tag
include path to $name.
For example, in C, "user" maps to "INCLUDES" and "sys" maps to
"SYSTEM_INCLUDES".

B<NOTE:> If you assign an info_string to any tag, then you need to assign
info_string's to all the tags, or else the tags that aren't assigned will be
ignored when the cached includes are used.

=cut

sub info_string {
  $_[0]{INFO_STRING} = $_[1];
}

=head2 dont_scan

  $scanner->dont_scan($finfo, $absname);

Returns 1 if the file $finfo should be scanned.
$absname must be $finfo's absolute filename.

Files that shouldn't be scanned typically are the system include files,
as well as any files that are in a directory that can't be written by the
current user.
It is assumed that such files don't include other files that change between
clean builds.
This makes scanning go faster, and reduces the amount of "noise" emitted by
makepp.

=cut

sub dont_scan {
  #my( $self, $finfo, $absname ) = @_;
  my $case = $_[2] =~ m@^/usr/(?:X11(?:R.)?/|local/)include\b@;
				# Don't scan stuff in the system directories.
				# This can lead to problems if we build as
				# a user and then install as root.  This won't
				# completely solve the problem, but it will
				# make it much less common.
  $case = 2 unless $case || Mpp::File::is_writable( $_[1]{'..'} );
  if( $case ) {
    if( Mpp::DEBUG && !exists $_[1]->{xNOSCAN} ) {
      Mpp::log qw(SCAN_NOT_SYS SCAN_NOT_UNWRITABLE)[$case - 1], $_[1];
      undef $_[1]{xNOSCAN};
    }
    return 1;
  }
  0;
}

=head2 scan_file

  $scanner->scan_file($command_parser, $tag, $name);

Check for cached dependencies of the file given by $name (relative to the
current directory).
If they are found, then add them to the dependency list, and either scan them
recursively, or add them to the list of dependencies to scan later.
Otherwise, delegate to $self->xscan_file().

Before this method returns successfully, all of the files that are included
(possibly recursively) by the file will have been scanned.

The return value is TRUE on success, FALSE if any files to be scanned failed
to build, or if scanning failed.

=cut

sub scan_file1 {
  my ($self, $command_parser, $tag, $finfo)=@_;
  unless( $self->{CONDITIONAL} ) {
    return 1 if exists $self->{my $x = sprintf '%x', $finfo};
    undef $self->{$x};
  }
  # TBD: If we were to build scanned files in parallel,
  # then this is where we would wait for the file to finish
  # building.
  if($self->{DEPTH} <= 0) {
    warn 'Not scanning `' . absolute_filename( $finfo ) . "' because recursion depth limit exceeded\n";
    return 1;
  }
  my $cache_includes =
    (!$self->{CONDITIONAL} && keys %{$self->{INFO_STRING}});
  my $need_to_scan;
  if($cache_includes) {
    my %includes;
    (my $rescan, @includes{keys %{$self->{INFO_STRING}}}) =
      Mpp::File::build_info_string $finfo, 'RESCAN', values %{$self->{INFO_STRING}};
    if( $rescan || grep !defined, values %includes ) {
      $need_to_scan = 1;
    } else {
      for my $inctag (keys %includes) {
        for(split(' ', $includes{$inctag})) {
          $self->include(
            $command_parser, $inctag, $_, $finfo
          );
        }
      }
    }
  } else {
    $need_to_scan=1;
  }
  if( $need_to_scan && !is_dir $finfo ) {
    my $absname = absolute_filename( $finfo );
    return 1 if $self->dont_scan($finfo, $absname);
    if( open my $fh, '<', $absname ) {
      print "$Mpp::progname: Scanning `$absname'\n" unless $Mpp::quiet_flag;
      Mpp::log SCAN => $finfo
	if Mpp::DEBUG;
      # NOTE: We get away with having a single INC for the
      # Mpp::Scanner object because when we scan unconditionally,
      # there is only one file being scanned at a time.
      if($cache_includes) {
        for my $tag (keys %{$self->{INFO_STRING}}) {
          $self->{INC}{$tag} = {};
        }
      }
      --$self->{DEPTH};
      $self->xscan_file(
        $command_parser, $tag, $finfo, $self->{CONDITIONAL},
        $fh
      ) || return undef;
      ++$self->{DEPTH};
      if($cache_includes) {
        for my $tag (keys %{$self->{INFO_STRING}}) {
          my $key = $self->{INFO_STRING}{$tag};
          my $val = join(' ', sort keys %{$self->{INC}{$tag}});
          Mpp::File::set_build_info_string( $finfo, $key => $val );
        }
        delete $self->{INC};
        &Mpp::File::update_build_infos;
      }
    }
    else {
      warn "could not read $absname to scan for includes--$!\n";
    }
  }
  1;
}
sub scan_file {
  #my ($self, $command_parser, $tag, $name)=@_;
  push @{$_[0]{PENDING}}, [$_[2], $_[0]->get_file_info( $_[3] )];
  $_[1]->add_dependency( $_[3] ) ?
    defined $_[0]->continue_scanning( $_[1] ) :
    undef;
}

=head2 continue_scanning

  $scanner->continue_scanning($command_parser);

Scan pending files.
This is useful if include() is called after the last scan_file() call.
Returns TRUE if and only if any files were scanned.
Returns undef if and only if a file to be scanned failed to build, or if
scanning failed.

=cut

sub continue_scanning {
  #my ($self, $command_parser)=@_;
  my $result=0;
  while(@{$_[0]{PENDING}}) {
    $result=1;
    $_[0]{DEPTH} = DEFAULT_DEPTH;
    $_[0]->scan_file1(
      $_[1], @{shift @{$_[0]{PENDING}}}
    ) or return undef;
  }
  $result;
}

=head2 xscan_file

  $scanner->xscan_file($command_parser, $tag, $finfo, $conditional, $fh);

The derived class should define this to scan file handle $fh
and report implicit dependencies by calling the include method.

If $conditional is FALSE, then the following methods may not be called:

  push_scope
  pop_scope

Also, is_active() is guaranteed to return TRUE, and include() is guaranteed
not to call scan_file() recursively.

$fh is a file handle that is initially opened for reading at the beginning of
the file to be scanned.

This method should be called only from scan_file() and not directly, because
otherwise you have to check for cached includes yourself.  Implemented by
classes which inherit from this.

A FALSE return value is interpreted as a scanning failure.

=cut

=head2 find

  $scanner->find($tag, $name, $src_dir);

Returns the Mpp::File object associated with
the location where $name is found, or undef if $name is not found.
$tag is the include path tag, and $src is the source Mpp::File,
if any, or the source directory Mpp::File.

=cut

my %already_warned_missing;

sub find {
  my( $self, undef, $tag, $name, $src ) = @_;
  if( ord( $name ) != ord '/' ) {
    return $self->get_file_info($name) unless $tag;
    my( $src_dir, $key );
    local $Mpp::File::read_dir_before_lstat = 1;
    my @dirs = @{$self->{$tag}[INCLUDE_DIRS]};
    while( @dirs ) {
      my $base = shift @dirs;
      if( $base && $base =~ s/^in ([:;]?)// ) {
	if( $1 eq ':' ) {
	  my $finfo = find( $self, undef, $base, $name, $src );
	  return $finfo if $finfo;
	} elsif( exists $ENV{$base} ) {
	  $src_dir ||= defined( $src ) && (is_or_will_be_dir( $src ) ? $src : $src->{'..'});
	  unshift @dirs, map file_info( $_, $src_dir ), Mpp::Text::split_path 0, 0, $ENV{$base}, $1; # optionally split on ';'
	}
	next;
      }
      $base ||= $src_dir ||= defined( $src ) && (is_or_will_be_dir( $src ) ? $src : $src->{'..'})
	or next;
      my $sc = $base->{SCANNER_CACHE};
      if( $self->{$tag}[INCLUDE_SFXS] and $self->{$tag}[INCLUDE_SFXS][0] ne '/' || $name !~ /\.[^\/]*$/ ) {
	$key ||= '/' . $self->{$tag}[INCLUDE_SFXS] . '/' . $name;
	if( exists $sc->{$key} ) {
	  return $sc->{$key} if $sc->{$key};
	  next;
	}
	for my $sfx ( @{$self->{$tag}[INCLUDE_SFXS]} ) {
	  next if $sfx eq '/';
	  my $finfo = file_info $name.$sfx, $base;
	  return $sc->{$key} = $finfo if Mpp::File::exists_or_can_be_built_or_remove $finfo, 0;
	  undef $sc->{$key};
	}
      } else {
	if( exists $sc->{$name} ) {
	  return $sc->{$name} if $sc->{$name};
	  next;
	}
	my $finfo = exists $base->{DIRCONTENTS} && $base->{DIRCONTENTS}{$name} || path_file_info $name, $base;
	return $sc->{$name} = $finfo if Mpp::File::exists_or_can_be_built_or_remove $finfo, 0;
	undef $sc->{$name};
      }
    }
  } elsif( $self->{$tag}[INCLUDE_SFXS] and $self->{$tag}[INCLUDE_SFXS][0] ne '/' || $name !~ /\.[^\/]*$/ ) {
    local $Mpp::File::read_dir_before_lstat = 1;
    for my $sfx (@{$self->{$tag}[INCLUDE_SFXS]}) {
      next if $sfx eq '/';
      my $finfo=file_info $name.$sfx;
      return $finfo if Mpp::File::exists_or_can_be_built_or_remove $finfo, 0;
    }
  } else {
    return file_info $name;
  }

  if( $self->{$tag}[SHOULD_FIND] && !$already_warned_missing{$name}++ ) {
    my $path = '';
    if($self->{$tag}[INCLUDE_SFXS]) {
      $path = "\nSuffix list is: ".
        join ' ', map "`$_'", @{$self->{$tag}[INCLUDE_SFXS]};
    }
    $path .= join "\n  ", "\nInclude path [$tag] is:",
      map {
        $_ ? (ref( $_ ) ? absolute_filename( $_ ) : $_) : "[including file's directory]"
      } @{$self->{$tag}[INCLUDE_DIRS]};
    warn "can't locate file $name" .
      ($src ? ', included from `'.absolute_filename( $src )."'" : '') .
      $path . "\n";
  }
  undef;
}

=head2 include

  $scanner->include($command_parser, $tag, $name, $src);

Signals that an include file whose name is $name and whose type is $tag
was requested, but only if $self->{ACTIVE} is TRUE.
If the file is found, then a dependency is added to $self->rule and the
Mpp::File object of the file is returned.
Otherwise, 1 is returned if the file is not found, or undef is returned if
there was an error generating it or some other nested include file.

Whether this returns immediately or calls $self->xscan_file() recursively
is not guaranteed.
Currently, it is if and only if $self->{CONDITIONAL} is TRUE.

Whether this sets the build_info_string INCLUDE's of $name is not
guaranteed.
Currently, it does if and only if $self->{CONDITIONAL} is FALSE.

=cut

sub include {
  my ($self, $command_parser, $tag, $name, $src)=@_;
  return 1 unless $self->{ACTIVE} && $name ne '';	# This is an error, so don't add a dep
  my $finfo = &find;
  if( $finfo && $Mpp::log_level ) {
    if( $src ) {
      Mpp::log INCL => $src, $finfo;
    } else {
      Mpp::log INCL_WHO => $finfo;
    }
  }
  $command_parser->add_dependency(
    $finfo, $self->get_tagname($tag), $src, $name
  ) or return undef;
  if($self->{CONDITIONAL}) {
    if( $finfo ) {
      $self->scan_file1(
        $command_parser, $tag, $finfo
      ) or return undef;
    }
  } else {
    if($self->{INFO_STRING}{$tag}) {
      $self->{INC}{$tag}{$name}=1;
    }
    push @{$self->{PENDING}}, [$tag, $finfo] if $finfo && !$self->{SEEN}{$tag}{sprintf '%x', $finfo}++;
  }
  # NOTE: We don't need to return undef if this isn't found, because
  # it could come from a system path that we don't know about (which
  # presumedly wouldn't have files that change), or it could be inside
  # an inactive #ifdef directive.
  $finfo || 1;
}

=head2 rule

  my $rule=$scanner->rule;

Returns the rule object.

=cut

sub rule { $_[0]{RULE} }

=head2 dir

  my $dir=$scanner->dir;

Returns the dir name.

=cut

sub dir { $_[0]{DIR} }

=head2 get_file_info

  my $finfo=$scanner->get_file_info($name);

Returns the Mpp::File object associated with $name relative to dir().

=cut

sub get_file_info { file_info $_[1], file_info $_[0]{DIR}, $_[0]{RULE}->build_cwd }

=head2 get_context

  my $context=$scanner->get_context;

Returns a scalar representing the current scanning context, I<i.e.> the
variable settings and enclosing scopes.
The format of this scalar is not guaranteed, but you can pass it to reset().

=cut

sub get_context {
  my %vars=%{$_[0]{VARS}};
  my @scopes=@{$_[0]{SCOPES}};
  [\%vars, \@scopes, $_[0]{DEPTH}];
}

=head2 reset

  $scanner->reset;
  $scanner->reset($context);

Denotes the beginning of a new translation unit.
Reset all variables, and sets $self->{ACTIVE} to TRUE.
A C<Mpp::Scanner> object is guaranteed to be in the reset state on return
from new().
If $context (from get_context()) is specified, then reset to that context
instead of clearing everything.

=cut

sub reset {
  my $self= $_[0];
  my %vars;
  my @scopes=(1);
  my $depth=DEFAULT_DEPTH;
  if(@_ > 1) {
    %vars=%{$_[1][0]};
    @scopes=@{$_[1][1]};
    $depth=$_[1][2];
  }
  $self->{VARS}=\%vars;
  $self->{SCOPES}=\@scopes;
  $self->{ACTIVE}=$scopes[$#scopes];
  $self->{DEPTH}=$depth;
}

=head2 set_var

  $scanner->set_var($name, $value);

Sets the variable whose name in $name to $value, but only if $self->{ACTIVE}
is TRUE.

=cut

sub set_var {
  return unless $_[0]{ACTIVE};
  $_[0]{VARS}{$_[1]}=$_[2];
}

=head2 get_var

  my $value=$scanner->get_var($name);

Returns the value of the variable whose name is $name.

=cut

sub get_var { $_[0]{VARS}{$_[1]} }

=head2 push_scope

  $scanner->push_scope($act);

Push a new scope, and set $self->{ACTIVE} to $act if $self->{ACTIVE} is TRUE.
A scope is typically introduced when a preprocessor conditional
(I<e.g.> C<#ifdef>) is encountered, and the scope is inactive if its
conditional evaluated false.

=cut

sub push_scope {
  $_[0]{ACTIVE} &&= $_[1];
  push @{$_[0]{SCOPES}}, $_[0]{ACTIVE};
}

=head2 pop_scope

  $scanner->pop_scope;

Reverse the most recent push_scope().
A scope is typically closed when a preprocessor conditional
is terminated (I<e.g.> with C<#endif>).
Returns $self->{ACTIVE} before popping.

=cut

sub pop_scope {
  my $self=$_[0];
  my $s=$self->{SCOPES};
  my $result = $s->[-1];
  if(@$s > 1) {
    pop @$s;
    $self->{ACTIVE}=$s->[-1];
  } else {
    # TBD: Improve this diagnostic
    warn "Too many close scopes\n";
  }
  $result;
}

=head2 is_active

  my $act=$scanner->is_active;

Returns $self->{ACTIVE}.
The current scope is active if and only if all enclosing scopes are active.

=cut

sub is_active { $_[0]{ACTIVE} }

#=head1 FIELDS
#
#The following fields represent the current implementation of this class,
#but they may change without notice.
#Therefore, clients outside this class should using accessor methods instead.
#
#=head2 $self->{RULE}
#
#A reference to the rule object.
#
#=head2 $self->{DIR}
#
#The directory (relative to the rule object's directory) under which the
#present command being scanned will execute.
#
#=head2 $self->{CONDITIONAL}
#
#TRUE if and only if conditional scanning is in use.
#
#=head2 $self->{$tag}[INCLUDE_DIRS] (was: $self->{INCLUDE_DIRS}{$tag})
#
#An arrayref of dirinfo's to search for an include path tag.
#
#=head2 $self->{$tag}[SHOULD_FIND] (was: $self->{SHOULD_FIND}{$tag})
#
#A hashref mapping an include path tag to TRUE if and only if a warning
#should be issued if an include file is not found on the path.
#
#=head2 $self->{INFO_STRING}
#
#A hashref mapping an include path tag to the name of the build_info_string.
#
#=head2 $self->{SCOPES}
#
#An arrayref of scalars that represent the active state of enclosing scopes.
#The active state of the current scope is the last scalar, and the active
#state of the top level (which is always TRUE) is the first scalar.
#The first N elements are TRUE, and the rest are always FALSE.
#
#=head2 $self->{VARS}
#
#A hashref mapping a variable name to its value.
#
#=head2 $self->{DEPTH}
#
#The number of recursion levels remaining.
#
#=head2 $self->{ACTIVE}
#
#TRUE if and only if the current scanning scope is active.
#
#=head2 $self->{PENDING}
#
#An arrayref representing files remaining to be scanned.
#Each element consists of a 2-element arrayref whose first element is the
#include path tag and whose second element if the file name (relative to the
#current directory).
#
#=head2 $self->{sprintf '%x', objectref}
#
#Files already scanned or being scanned.  This is unlikely to collide with
#attributes or tags.

=head1 FUTURE WORK

One way to cache the scanning of include files with conditional scanning in
force is to generate a rendition of the source file that has only the
preprocessor directives in it, and scan that instead.
That file can be kept up-to-date using makepp in the usual way (more or less).
Then the amount of I/O required for scanning is then much less when the source
file hasn't been modified.
It may or may not be practical to store this in the build info structure.

=cut

1;
