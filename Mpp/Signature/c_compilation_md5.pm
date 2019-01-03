# $Id: c_compilation_md5.pm,v 1.29 2012/12/29 13:54:27 pfeiffer Exp $
use strict;
package Mpp::Signature::c_compilation_md5;

use Mpp::Signature;
use Mpp::Signature::md5;
use Mpp::Text;
use Mpp::File;
use Mpp::FileOpt;
our @ISA = qw(Mpp::Signature);

=head1 NAME

Mpp::Signature::c_compilation_md5 -- a signature class that ignores changes to whitespace and comments

=head1 DESCRIPTION

Unlike the usual signature class, this class computes an MD5 checksum of all
source files, excluding whitespace and comments.  Your source files may
change, but if you use this signature class, makepp will be smart enough to
realize that certain changes don't matter.

More specifically:

=over 4

=item *

Comments are treated as if they were a single space.

=item *

Multiple spaces and tabs are collapsed to a single space (unless they are
inside quoted strings) or eliminated if they would not collapse words or
symbols like '+ +' into one.

=item *

Spaces and tabs before or after a newline are ignored.

=item *

Newlines affect the signature. This means that if you insert some lines in the
file, even if they were only comments, recompilation will occur.  Strictly
speaking, recompilation is not necessary in this case, but makepp will
recompile anyway to avoid messing up __LINE__ macros and line numbers in the
debugger.

=back

What this means is that you can freely add or change comments in your code, or
reindent your code, and as long as you don't affect the line numbers, there
will be no recompilation.  Line number changes after the last token,
e.g. comments with $Log at the end of file, will not cause a recompilation.

=cut

our $c_compilation_md5 = bless \@ISA; # Make the singleton object.
our $flow;

# Things that can be overridden by a derived class:
sub build_info_key { 'C_MD5_SUM' }
sub important_comment_keywords { qw// }
sub excludes_file { is_object_or_library_name $_[1]->{NAME} }
sub recognizes_file { is_cpp_source_name $_[1]->{NAME} }

#
# This is the function that does the work of digesting C or C++ source code,
# breaking it into tokens, and computing the MD5 checksum of the tokens.  All
# tokens except words (which might be macros with __LINE__) are pulled up as
# far as possible.  If makepp_signature_C_flat even words are pulled up and
# all line control ignored.
#
sub md5sum_c_tokens {
  #my( $self, $fname ) = @_;	# Name the arguments.

  open my $infile, '<:crlf', $_[1] or # File exists?
    return '';

  my $flat = $_[2];
  # NOTE: $keywords can be used by the derived class.
  my %keywords;
  @keywords{$_[0]->important_comment_keywords} = (); # Make them exist

  local $/;			# Slurp in the whole file at once.
				# (This makes it easier to handle C-style comments.)
  local $_ = "\n" . <$infile>;	# Read it all.  Prepend newline for preproc handling.

  my $add_space;		# Need a space here.
  my $word;			# Last saw a word.
  my $n_newlines = 0;		# No newlines being held.
  my $preproc;			# On a preprocessor line.
  my $tokens = '';		# The canonical document.

  pos = 0;			# Start digesting at position 0.
  while( pos() < length ) {
    /\G[ \t]+/gc;		# Just skip space, it is added only where needed.
    my $token;			# Temp holder for things that might need space or \n before.
    if( /\G([\w\$]+)/gc ) {
      $add_space = $word;	# Put a space between words.
      $token = $1;
      $word = $1 =~ /^\D/;

    } else {
      if( /\G\n/gc ) {
	if( /\G[ \t]*#/gc ) {
	  $n_newlines = 0 if	# Reset count after #line.
	    /\G[ \t]*(?:line[ \t]*)?(\d+)\b/gc;
	  if( $1 && $flat ) {
	    /\G.*?\n/gc;
	  } elsif( "\n" eq substr $tokens, -1 ) {
	    $tokens .= $1 ? "#$1" : '#';
	    $preproc = 1;
	  } else {
	    $tokens .= $1 ? "\n#$1" : "\n#"; # Put it at bol.
	    $preproc = 1;
	  }
	} elsif( $preproc ) {
	  $tokens .= "\n";	# Go to bol.
	  $preproc = 0;
	} elsif( $flat ) {
	  redo;
	} else {
	  ++$n_newlines;	# Remember nl for later.
	}
      } elsif( $preproc && /\G\\\n/gc ) {
	++$n_newlines unless $flat; # Remember nl for later.
	redo;

      } elsif( /\G(([-+&*])\2?)/gc ) {
	$add_space = !$word;	# Keep space in what might be "a+ ++b" or "a/ *b"!
	$token = $1;

      } elsif( /\G\"/gc ) {	# Quoted string?
	my $quotepos = pos()-1;	# Remember where the string started.
	1 while pos() < length and /\G[^\\"]+/sgc || /\G\\./sgc;
				# Skip over everything between the quotes.
	$tokens .= substr $_, $quotepos, ++pos()-$quotepos;
				# Add the string to the checksum.
      } elsif( /\G\'/gc ) {	# Single quote expression?
	my $quotepos = pos()-1;	# Remember where the string started.
	1 while pos() < length and /\G[^\\']+/sgc || /\G\\./sgc;
				# Skip over everything between the quotes.
	$tokens .= substr $_, $quotepos, ++pos()-$quotepos;
				# Add the string to the checksum.

      } else {
	$token = substr $_, pos()++, 1; # Get next char.

	if( ord( $token ) == ord '/' ) { # Either division or comment.
	  if( /\G(\/.*)/gc ) { # Skip over C++ comments.
	    undef $token, next
	      unless %keywords && $1 =~ /^(\W*(\w+).*)/ && exists $keywords{$2};
	    $token .= $1;
	  } elsif( /\G\*(.*?)\*\//sgc ) { # C comment?
	    undef $token;
	    $n_newlines += ($1 =~ tr/\n//) unless $flat;
	  }
	}
      }
      undef $word;
    }

    if( defined $token ) {
      if( $word && $n_newlines && !$preproc ) {
	$tokens .= "\n" x $n_newlines;
	$n_newlines = $add_space = 0;
      } elsif( $add_space ) {
	$tokens .= ' ';
	$add_space = 0;
      }
      $tokens .= $token;
    }
  }
  Digest::MD5::md5_base64 $tokens; # Get checksum from tokens.
}

sub signature {
  my $self = shift;		# Trade stack modification for &calls below
  my $finfo = $_[0];

  if( &file_exists ) {		# Does file exist yet?
    if( !Mpp::File::is_writable $finfo->{'..'} or # Dir not writable--don't bother.
	$self->excludes_file( $finfo )) { # Looks like some kind of a binary file?
      &Mpp::File::signature;    # Use the normal signature method.
    } elsif( $self->recognizes_file( $finfo )) {
      my $build_info_key = $self->build_info_key;
      my $stored_cksum = Mpp::File::build_info_string $finfo, $build_info_key;
      unless( $stored_cksum ) {	# Don't bother redigesting if
				# we have already digested the file.
	my $mkfile = $finfo->{'..'}{MAKEINFO};
	$stored_cksum = md5sum_c_tokens $self, &absolute_filename,
	  $mkfile && $mkfile->expand_variable( 'makepp_signature_C_flat', '' );
				# Digest the file.
	Mpp::File::set_build_info_string $finfo, $build_info_key, $stored_cksum;
				# Store the checksum so we don't have to do
				# that again.
      }
      $stored_cksum;
    } elsif( -B &absolute_filename ) { # Binary file?
      &Mpp::File::signature;	# Don't use MD5 digesting.
    } else {
      # Use regular MD5 digesting if it exists, but we can't tell what it is
      # by its extension.
      &Mpp::Signature::md5::signature;
    }
  }
}

1;
