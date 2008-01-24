package ModENCODE::Validator::TermSources;

use strict;
use Class::Std;
use Carp qw(croak carp);
use ModENCODE::Validator::CVHandler;

my %cvhandler                   :ATTR( :default<undef> );

sub BUILD {
  my ($self, $ident, $args) = @_;
  $cvhandler{$ident} = new ModENCODE::Validator::CVHandler();
}

sub merge {
  my ($self, $experiment) = @_;
  $experiment = $experiment->clone();
  $self->validate($experiment) or croak "Can't merge term sources if it doesn't validate!"; # Cache all the protocol definitions and stuff if they aren't already
  foreach my $applied_protocol_slots (@{$experiment->get_applied_protocol_slots()}) {
    foreach my $applied_protocol (@$applied_protocol_slots) {
      my $protocol = $applied_protocol->get_protocol();
      # Protocol
      if ($protocol->get_termsource()) {
        my ($term, $accession) = $self->get_term_and_accession($protocol->get_termsource(), $protocol->get_name());
        $protocol->get_termsource()->set_accession($accession);
      }
      # Protocol attributes
      foreach my $attribute (@{$protocol->get_attributes()}) {
        if ($attribute->get_termsource()) {
          my ($term, $accession) = $self->get_term_and_accession($attribute->get_termsource(), $attribute->get_value());
          $attribute->get_termsource()->set_accession($accession);
        }
      }
      # Data
      my @data = (@{$applied_protocol->get_input_data()}, @{$applied_protocol->get_output_data()});
      foreach my $datum (@data) {
        if ($datum->get_termsource()) {
          my ($term, $accession) = $self->get_term_and_accession($datum->get_termsource, $datum->get_value());
          $datum->get_termsource()->set_accession($accession);
        }
        foreach my $attribute (@{$datum->get_attributes()}) {
          if ($attribute->get_termsource()) {
            my ($term, $accession) = $self->get_term_and_accession($attribute->get_termsource(), $attribute->get_value());
            $attribute->get_termsource()->set_accession($accession);
          }
        }
      }
    }
  }
  return $experiment;
}

sub validate {
  my ($self, $experiment) = @_;
  my $success = 1;
  $experiment = $experiment->clone(); # Don't do anything to change the experiment passed in
  if (!$cvhandler{ident $self}) { $cvhandler{ident $self} = new ModENCODE::Validator::CVHandler(); }
  print STDERR "  Verifying term sources referenced in the SDRF against the terms they constrain.\n";
  foreach my $applied_protocol_slots (@{$experiment->get_applied_protocol_slots()}) {
    foreach my $applied_protocol (@$applied_protocol_slots) {
      my $protocol = $applied_protocol->get_protocol();
      # TERM SOURCES
      # Term sources can apply to protocols, data, and attributes (which is to say pretty much everything)
      # Protocol
      if ($protocol->get_termsource() && !($self->is_valid($protocol->get_termsource(), $protocol->get_name()))) {
        print STDERR "    Term source " . $protocol->get_termsource()->to_string() . " not valid as it applies to protocol " . $protocol->get_name() . "\n";
        $success = 0;
      }
      # Protocol attributes
      foreach my $attribute (@{$protocol->get_attributes()}) {
        if ($attribute->get_termsource() && !($self->is_valid($attribute->get_termsource(), $attribute->get_value()))) {
          print STDERR "    Term source " . $attribute->get_termsource()->to_string() . " not valid as it applies to attribute " . $attribute->to_string() . " of protocol " . $protocol->get_name() . "\n";
          $success = 0;
        }
      }
      # Data
      my @data = (@{$applied_protocol->get_input_data()}, @{$applied_protocol->get_output_data()});
      foreach my $datum (@data) {
        if ($datum->get_termsource() && !($self->is_valid($datum->get_termsource(), $datum->get_value()))) {
          print STDERR "    Term source " . $datum->get_termsource()->to_string() . " not valid as it applies to datum " . $datum->to_string() . " of protocol " . $protocol->get_name() . "\n";
          $success = 0;
        }
        # Data attributes
        foreach my $attribute (@{$datum->get_attributes()}) {
          if ($attribute->get_termsource() && !($self->is_valid($attribute->get_termsource(), $attribute->get_value()))) {
            print STDERR "    Term source " . $attribute->get_termsource()->to_string() . " not valid as it applies to attribute " . $attribute->to_string() . " of datum " . $datum->to_string() . " of protocol " . $protocol->get_name() . "\n";
            $success = 0;
          }
        }
      }
    }
  }
  print STDERR "    Done.\n";
  return $success;
}

sub get_term_and_accession : PRIVATE {
  my ($self, $termsource, $term, $accession) = @_;
  if (!$term && !$accession) {
    $accession = $termsource->get_accession();
  }
  if (!$accession) {
    $accession = $cvhandler{ident $self}->get_accession_for_term($termsource->get_db()->get_name(), $term);
  }
  if (!$term) {
    $term = $cvhandler{ident $self}->get_term_for_accession($termsource->get_db()->get_name(), $accession);
  }
  return (wantarray ? ($term, $accession) : { 'term' => $term, 'accession' => $accession });
}


sub is_valid : PRIVATE {
  my ($self, $termsource, $term, $accession) = @_;
  my $valid = 1;
  croak "Cannot validate a term against a termsource without a termsource object" unless $termsource && ref($termsource) eq "ModENCODE::Chado::DBXref";
  if (!$term && !$accession) {
    # Really shouldn't use is_valid with no term or accession like this
    carp "Given a termsource to validate with no term or accession; testing accession built into termsource: " . $termsource->to_string() . "\n";
    $accession = $termsource->get_accession();
    if (!$accession) {
      carp "Nothing to validate; no term or accession given, and no accession built into termsource: " . $termsource->to_string() . "\n";
      return 0;
    }
  }
  $cvhandler{ident $self}->add_cv(
    $termsource->get_db()->get_name(),
    $termsource->get_db()->get_url(),
    $termsource->get_db()->get_description(),
  );
  if ($accession) {
    if (!$cvhandler{ident $self}->is_valid_accession($termsource->get_db()->get_name(), $accession)) {
      $valid = 0;
    }
  } 
  if ($term) {
    if (!$cvhandler{ident $self}->is_valid_term($termsource->get_db()->get_name(), $term)) {
      $valid = 0;
    }
  }
  return $valid;
}

1;