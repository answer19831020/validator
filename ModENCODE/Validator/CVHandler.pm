package ModENCODE::Validator::CVHandler;

use strict;
use Class::Std;
use Carp qw(croak carp);
use LWP::UserAgent;
use URI::Escape ();
use GO::Parser;

my %useragent                   :ATTR;
my %cvs                         :ATTR( :default<{}> );
my %cv_synonyms                 :ATTR( :default<{}> );

sub BUILD {
  my ($self, $ident, $args) = @_;
  $useragent{$ident} = new LWP::UserAgent();
}

sub get_url : PRIVATE {
  my ($self, $url) = @_;
  return $useragent{ident $self}->request(new HTTP::Request('GET' => $url));
}

sub mirror_url : PRIVATE {
  my ($self, $url, $file) = @_;
  return $useragent{ident $self}->mirror($url, $file);
}

sub parse_term {
  my ($self, $term) = @_;
  my ($name, $cv, $term) = (undef, split(/:/, $term));
  if (!defined($term)) {
    $term = $cv;
    $cv = undef;
  }
  ($term, $name) = ($term =~ m/([^\[]*)(?:\[([^\]]*)\])?/);
  $term =~ s/^\s*|\s*$//g;
  return (wantarray ? ( $cv, $term, $name) : { 'name' => $name, 'term' => $term, 'cv' => $cv });
}

sub add_cv_synonym_for_url {
  my ($self, $synonym, $url) = @_;
  my $existing_url = $self->get_url_for_cv_name($synonym);
  # might need to add a new name/synonym for this url
  my $cv = $cvs{ident $self}->{$url};
  if (!$existing_url) {
    push @{$cvs{ident $self}->{$url}->{'names'}}, $synonym;
    return 1;
  } elsif ($existing_url ne $url) {
    print STDERR "  The CV name $synonym is already used for $existing_url, but at attempt has been made to redefine it for $url. Please check your IDF.\n";
    print STDERR "  Also, please note that 'xsd', 'modencode', and 'MO' may already be predefined to refer to URLs:\n";
    print STDERR "    http://wiki.modencode.org/project/extensions/DBFields/ontologies/xsd.obo\n";
    print STDERR "    http://wiki.modencode.org/project/extensions/DBFields/ontologies/modencode-helper.obo\n";
    print STDERR "    http://www.berkeleybop.org/ontologies/obo-all/mged/mged.obo\n";
    return 0;
  } else {
    croak "Can't add synonym '$synonym' for missing CV identified by $url" unless $cv;
  }
}

sub get_db_object_by_cv_name {
  my ($self, $name) = @_;
  foreach my $cvurl (keys(%{$cvs{ident $self}})) {
    my @names = @{$cvs{ident $self}->{$cvurl}->{'names'}};
    if (scalar(grep { $_ eq $name } @names)) {
      my $db = new ModENCODE::Chado::DB({
          'name' => $cvs{ident $self}->{$cvurl}->{'names'}->[0],
          'url' => $cvs{ident $self}->{$cvurl}->{'url'},
          'description' => $cvs{ident $self}->{$cvurl}->{'urltype'},
        });
      return $db;
    }
  }
}

sub get_cv_by_name {
  my ($self, $name) = @_;
  foreach my $cvurl (keys(%{$cvs{ident $self}})) {
    my @names = @{$cvs{ident $self}->{$cvurl}->{'names'}};
    if (scalar(grep { $_ eq $name } @names)) {
      return $cvs{ident $self}->{$cvurl};
    }
  }
  return undef;
}

sub get_url_for_cv_name : PRIVATE {
  my ($self, $cv) = @_;
  foreach my $cvurl (keys(%{$cvs{ident $self}})) {
    my @names = @{$cvs{ident $self}->{$cvurl}->{'names'}};
    if (scalar(grep { $_ eq $cv } @names)) {
      return $cvurl;
    }
  }
  return undef;
}

sub add_cv {
  my ($self, $cv, $cvurl, $cvurltype) = @_;

  if (!$cvurl || !$cvurltype) {
    # Fetch canonical URL
    my $res = $useragent{ident $self}->request(new HTTP::Request('GET' => 'http://wiki.modencode.org/project/extensions/DBFields/DBFieldsCVTerm.php?get_canonical_url=' . URI::Escape::uri_escape($cv)));
    if (!$res->is_success) { carp "Couldn't connect to canonical URL source: " . $res->status_line; return 0; }
    ($cvurl) = ($res->content =~ m/<canonical_url>\s*(.*)\s*<\/canonical_url>/);
    ($cvurltype) = ($res->content =~ m/<canonical_url_type>\s*(.*)\s*<\/canonical_url_type>/);
  }

  if ($cvurl && $cv) {
    my $existing_cv = $self->get_cv_by_name($cv);
    if ($existing_cv->{'url'} && $existing_cv->{'url'} ne $cvurl) {
      print STDERR "  The CV name $cv is already used for " . $existing_cv->{'url'} . ", but at attempt has been made to redefine it for $cvurl. Please check your IDF.\n";
      print STDERR "  Also, please note that 'xsd', 'modencode', and 'MO' may already be predefined to refer to URLs:\n";
      print STDERR "    http://wiki.modencode.org/project/extensions/DBFields/ontologies/xsd.obo\n";
      print STDERR "    http://wiki.modencode.org/project/extensions/DBFields/ontologies/modencode-helper.obo\n";
      print STDERR "    http://www.berkeleybop.org/ontologies/obo-all/mged/mged.obo\n";
      return 0;
    }
  }


  if ($cvs{ident $self}->{$cvurl}) {
    # Already loaded
    if ($cv) {
      # Might need to add a new name/synonym for this URL
      return $self->add_cv_synonym_for_url($cv, $cvurl);
    }
    return 1;
  }

  my $newcv = {};
  $newcv->{'url'} = $cvurl;
  $newcv->{'urltype'} = $cvurltype;
  $newcv->{'names'} = [ $cv ];

  if ($cvurltype =~ m/^URL/i) {
    # URL-type controlled vocabs
    $cvs{ident $self}->{$cvurl} = $newcv;
    return 1;
  }

  # Have we already fetched this URL?
  my $root_dir = $0;
  $root_dir =~ s#/[^/]*$#/#;
  my $cache_filename = $cvurl . "." . $cvurltype;
  $cache_filename =~ s/\//!/g;
  $cache_filename = $root_dir . "ontology_cache/" . $cache_filename;

  # Fetch the file (mirror uses the If-Modified-Since header so we only fetch if needed)
  my $res = $self->mirror_url($cvurl, $cache_filename);
  if (!$res->is_success) {
    if ($res->code == 304) {
      print STDERR "    Using cached copy of CV for $cv; no change on server.\n";
    } else {
      carp "Can't fetch or check age of canonical CV source file for '$cv' at url '" . $newcv->{'url'} . "': " . $res->status_line;
      if (!(-r $cache_filename)) {
        carp "Couldn't fetch canonical source file '" . $newcv->{'url'} . "', and no cached copy found";
        return 0;
      }
    }
  }

  # Parse the ontology file
  if ($cvurltype =~ m/^OBO$/i) {
    my $parser = new GO::Parser({ 'format' => 'obo_text', 'handler' => 'obj' });
    # Disable warning outputs here
    open OLDERR, ">&", \*STDERR or croak "Can't hide STDERR output from GO::Parser";
    print STDERR "(Parsing $cv...)";
    close STDERR;
    $parser->parse($cache_filename);
    open STDERR, ">&", \*OLDERR or croak "Can't reopen STDERR output after closing before GO::Parser";
    print STDERR "(Done.)";
    croak "Cannot parse '" . $cache_filename . "' using " . ref($parser) unless $parser->handler->graph;
    $newcv->{'nodes'} = $parser->handler->graph->get_all_nodes;
  } elsif ($cvurltype =~ m/^OWL$/i) {
    croak "Can't parse OWL files yet, sorry. Please update your IDF to point to an OBO file.";
  } elsif ($cvurl =~ m/^\s*$/ || $cvurltype =~ m/^\s*$/) {
    return 0;
  } else {
    croak "Don't know how to parse the CV at URL: '" . $cvurl . "' of type: '" . $cvurltype . "'";
  }

  $cvs{ident $self}->{$cvurl} = $newcv;
  return 1;
}

sub is_valid_term {
  my ($self, $cvname, $term) = @_;
  my $cv = $self->get_cv_by_name($cvname);
  if (!$cv) {
    # This CV isn't loaded, so attempt to load it
    my $cv_exists = $self->add_cv($cvname);
    if (!$cv_exists) {
      print STDERR "Cannot find the '$cvname' ontology, so '$term' is not valid.\n";
      return 0;
    }
    $cv = $self->get_cv_by_name($cvname);
  }
  if (!$cv->{'terms'}->{$term}) {
    # Haven't validated this term one way or the other
    if ($cv->{'urltype'} =~ m/^URL/) {
      # URL term; have to try to get it
      my $res = $self->get_url($cv->{'url'} . $term);
      if ($res->is_success) {
        $cv->{'terms'}->{$term} = 1;
      } else {
        $cv->{'terms'}->{$term} = 0;
      }
    } else {
      if (scalar(grep { $_->name =~ m/:?\Q$term\E$/ || $_->acc =~ m/:\Q$term\E$/ }  @{$cv->{'nodes'}})) {
        $cv->{'terms'}->{$term} = 1;
      } else {
        $cv->{'terms'}->{$term} = 0;
      }
    }
  }
  return $cv->{'terms'}->{$term};
}

sub is_valid_accession {
  my ($self, $cvname, $accession) = @_;
  my $cv = $self->get_cv_by_name($cvname);
  if (!$cv) {
    # This CV isn't loaded, so attempt to load it
    my $cv_exists = $self->add_cv($cvname);
    if ($cv_exists == 0) {
      print STDERR "Cannot find the '$cvname' ontology, so accession $accession is not valid.\n";
      return 0;
    }

    $cv = $self->get_cv_by_name($cvname);
  }
  if (!$cv->{'accessions'}->{$accession}) {
    # Haven't validated this accession one way or the other
    if (scalar(grep { $_->acc =~ m/:\Q$accession\E$/ }  @{$cv->{'nodes'}})) {
      $cv->{'accessions'}->{$accession} = 1;
    } else {
      $cv->{'accessions'}->{$accession} = 0;
    }
  }
  return $cv->{'accessions'}->{$accession};
}

sub get_accession_for_term {
  my ($self, $cvname, $term) = @_;
  my $cv = $self->get_cv_by_name($cvname);
  croak "Can't find CV $cvname, even though we should've validated by now" unless $cv;
  if ($cv->{'urltype'} =~ m/^URL/i) {
    return $term; # No accession other than the term for URL-based ontologies
  }
  my ($matching_node) = grep { $_->name =~ m/:?\Q$term\E$/ || $_->acc =~ m/:\Q$term\E$/ } @{$cv->{'nodes'}};
  croak "Unable to find accession for $term in $cvname" unless $matching_node;
  my $accession = $matching_node->acc;
  $accession =~ s/^.*://;
  return $accession;
}

sub get_term_for_accession {
  my ($self, $cvname, $accession) = @_;
  my $cv = $self->get_cv_by_name($cvname);
  croak "Can't find CV $cvname, even though we should've validated by now" unless $cv;
  if ($cv->{'urltype'} =~ m/^URL/i) {
    return $accession; # No term other than the accession for URL-based ontologies
  }
  my ($matching_node) = grep { $_->acc =~ m/:\Q$accession\E$/ }  @{$cv->{'nodes'}};
  croak "Can't find matching node for accession $accession in $cvname" unless $matching_node;
  my $term = ($matching_node->name ? $matching_node->name : $matching_node->acc);
  $term =~ s/^.*://;
  return $term;
}

1;
