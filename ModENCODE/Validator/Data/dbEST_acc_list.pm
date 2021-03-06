package ModENCODE::Validator::Data::dbEST_acc_list;
=pod

=head1 NAME

ModENCODE::Validator::Data::dbEST_acc_list - Class for validating and updating
BIR-TAB L<Data|ModENCODE::Chado::Data> objects containing files that are lists
of ESTs to include L<Features|ModENCODE::Chado::Feature> for those ESTs.

=head1 SYNOPSIS

This class uses L<ModENCODE::Validator::Data::dbEST_acc> to validate a list of
ESTs stored in a file (one GenBank accession per line) rather than a list of
ESTs kept directly in the SDRF. When L</validate()> is called, this validator
creates a skeleton L<ModENCODE::Chado::Data> object for each EST accession in
each path referred to by a datum attached to this validator with
L<add_datum($datum,
$applied_protocol)|ModENCODE::Validator::Data::Data/add_datum($datum,
$applied_protocol)>. It then creates an internal copy of the
L<dbEST_acc|ModENCODE::Validator::Data::dbEST_acc> validator and then and adds
each skeleton datum to the L<dbEST_acc|ModENCODE::Validator::Data::dbEST_acc>
validator with L<add_datum($datum,
$applied_protocol)|ModENCODE::Validator::Data::Data/add_datum($datum,
$applied_protocol)>. Finally, it calls the
L<validate()|ModENCODE::Validator::Data::dbEST_acc/validate()> method of the
L<dbEST_acc|ModENCODE::Validator::Data::dbEST_acc> validator and returns the
result. If the EST file does not exist or cannot be parsed, then validate
returns 0.

=head1 USAGE

To use this validator in a standalone way:

  my $datum = new ModENCODE::Chado::Data({
    'value' => '/path/to/est_list.txt'
  });
  my $validator = new ModENCODE::Validator::Data::dbEST_acc_list();
  $validator->add_datum($datum, $applied_protocol);
  if ($validator->validate()) {
    my $new_datum = $validator->merge($datum);
    print $new_datum->get_features()->[0]->get_name();
  }

Note that this class is not meant to be used directly, rather it is mean to be
used within L<ModENCODE::Validator::Data>.

=head1 FUNCTIONS

=over

=item validate()

Makes sure that all of the data added using L<add_datum($datum,
$applied_protocol)|ModENCODE::Validator::Data::Data/add_datum($datum,
$applied_protocol)> have values that exist as files containing lists of GenBank
EST accessions as tested by L<ModENCODE::Validator::Data::dbEST_acc>.

=item merge($datum, $applied_protocol)

Given an original L<datum|ModENCODE::Chado::Data> C<$datum>, returns a copy of
that datum with a set of newly attached features based on EST records in either
the local modENCODE database, FlyBase, or GenBank for the list of EST accessions
in the file that is the value in that C<$datum>. Does this by calling
L<ModENCODE::Validator::Data::dbEST_acc/merge($datum, $applied_protocol)>, which
may make changes of its own.

=back

=head1 SEE ALSO

L<ModENCODE::Chado::Data>, L<ModENCODE::Validator::Data>,
L<ModENCODE::Validator::Data::Data>, L<ModENCODE::Chado::Feature>,
L<ModENCODE::Chado::CVTerm>, L<ModENCODE::Chado::Organism>,
L<ModENCODE::Chado::FeatureLoc>, L<ModENCODE::Validator::Data::BED>,
L<ModENCODE::Validator::Data::Result_File>,
L<ModENCODE::Validator::Data::SO_transcript>,
L<ModENCODE::Validator::Data::WIG>, L<ModENCODE::Validator::Data::GFF3>,
L<ModENCODE::Validator::Data::dbEST_acc>

=head1 AUTHOR

E.O. Stinson L<mailto:yostinso@berkeleybop.org>, ModENCODE DCC
L<http://www.modencode.org>.

=cut
use strict;

use base qw( ModENCODE::Validator::Data::dbEST_acc );

use Class::Std;
use ModENCODE::ErrorHandler qw(log_error);
use Carp qw(croak carp);

use constant ESTS_AT_ONCE => 200;
use constant MAX_TRIES => 4;

my %seen_data                   :ATTR( :default<{}> );
my %cached_est_files            :ATTR( :default<{}> );

my %est_names :ATTR( :default<[]> );
my %est_cursor_position :ATTR( :default<0> );

sub validate {
  my ($self) = @_;
  my $success = 1;
  log_error "Validating list(s) of dbEST accessions.", "notice", ">";

  while (my $ap_datum = $self->next_datum) {
    my ($applied_protocol, $direction, $datum) = @$ap_datum;
    next if $seen_data{$datum->get_id}++; # Don't re-update the same datum

    my $datum_obj = $datum->get_object;

    if (!length($datum_obj->get_value())) {
      log_error "No EST list file for " . $datum_obj->get_heading(), 'warning';
      next;
    } elsif (!-r $datum_obj->get_value()) {
      log_error "Cannot find EST list file " . $datum_obj->get_value() . " for column " . $datum_obj->get_heading() . " [" . $datum_obj->get_name . "].", "error";
      $success = 0;
      next;
    } elsif ($cached_est_files{ident $self}->{$datum_obj->get_value()}++) {
      log_error "Referring to the same EST list file (" . $datum_obj->get_value . ") in two different data columns!", "error";
      $success = 0;
      next;
    }

    log_error "Reading list of ESTs from " . $datum_obj->get_value . ".", "notice", ">";
    unless (open(ESTS, $datum_obj->get_value)) {
      log_error "Couldn't open EST list file " . $datum_obj->get_value . " for reading.", "error";
      $success = 0;
      next;
    }

    my $i = 0;
    $est_names{ident $self} = []; # Reset for each datum
    while (defined(my $est = <ESTS>)) {
      if (!(++$i % 1000)) { log_error "Parsed line $i.", "notice"; }
      $est =~ s/\s*//g; # Strip whitespace
      next unless length($est); # Skip blank lines
      next if $est =~ m/^#/; # Skip comments
      $self->add_est_name($est);
    }

    log_error "Validating presence of ESTs in " . $self->num_data . " files.", "notice", ">";

    log_error "Checking Chado databases...", "notice", ">";
    foreach my $parse (
      ['modENCODE', $self->get_modencode_chado_parser()],
      ['FlyBase', $self->get_flybase_chado_parser()],
      ['WormBase',  $self->get_wormbase_chado_parser()],
    ) {
      my ($parser_name, $parser) = @$parse;
      if (!$parser) {
        log_error "Can't check ESTs against the $parser_name database; skipping.", "warning";
        next;
      }

      log_error "Checking for " . $self->num_est_names . " ESTs already in the $parser_name database...", "notice", ">";
      my $est_num = 0;
      my $now = time();
      while (my $accession = $self->next_est_name) {
        if (++$est_num % 1000 == 0) {
          log_error "Processed " . $est_num . " ESTs in " . (time() - $now) . " seconds.", "notice";
          $now = time();
        }
        my $feature = $parser->get_feature_by_genbank_id($accession);
        next unless $feature;

        log_error "Found feature in $parser_name for $accession.", "debug";
        my $cvterm = $feature->get_object->get_type(1)->get_name;
        my $cv = $feature->get_object->get_type(1)->get_cv(1)->get_name;
        my $canonical_cvname = ModENCODE::Config::get_cvhandler()->get_cv_by_name($cv)->{'names'}->[0];

        if ($cvterm ne "EST" && $cvterm ne "mRNA" && $cvterm ne "cDNA") {
          log_error "Found a feature for " . $accession . " in $parser_name, but it is of type '$cv:$cvterm', not 'SO:EST'. Using it anyway.", "warning";
        }
        if ($canonical_cvname ne "SO") {
          # TODO: Use this and update the CV type?
          log_error "Found a feature for " . $accession . " in $parser_name, but it is of type '$cv:$cvterm', not 'SO:EST'. Not using it.", "warning";
          next;
        }

        # If we found it, don't need to keep trying to validate it
        $datum->get_object->add_feature($feature);
        $self->remove_current_est_name;
      }
      log_error "Done; " . $self->num_est_names . " ESTs still to be found.", "notice", "<";

      $self->rewind_est_names();
    }
    log_error "Done.", "notice", "<";

    unless ($self->num_est_names) {
      log_error "Done.", "notice", "<";
      return $success;
    }

    # Validate remaining ESTs against GenBank by primary ID
    log_error "Looking up " . $self->num_est_names . " ESTs in dbEST.", "notice", ">";

    my @not_found_by_acc;
    while ($self->num_est_names) {
      # Get 40 ESTs at a time and search for them at dbEST
      my @batch_query;
      my $num_ests = 0;
      while (my $accession = $self->next_est_name) {
        push @batch_query, $accession;
        $self->remove_current_est_name; # This is the last change this EST gets to be found
        last if (++$num_ests >= ESTS_AT_ONCE);
      }
      croak "Whut" unless scalar(@batch_query);

      log_error "Fetching batch of " . scalar(@batch_query) . " ESTs, " . $self->num_est_names . " remaining.", "notice", ">";

      my $done = 0;
      while ($done++ < MAX_TRIES) {

        # Run query (est1,est2,...) and get back the cookie that will let us fetch the result:
        my $fetch_query = join(",", @batch_query);
        my $fetch_results;
        eval {
          $fetch_results = $self->get_soap_client->run_eFetch({
              'eFetchRequest' => {
                'db' => 'nucest',
                'id' => $fetch_query,
                'tool' => 'modENCODE pipeline',
                'email' => 'yostinso@berkeleybop.org',
                'retmax' => 400,
              }
            });
        };

        if (!$fetch_results) {
          # Couldn't get anything useful back (bad network connection?). Wait 30 seconds and retry.
          log_error "Couldn't retrieve any ESTs by ID; got no response from NCBI. Retrying in 30 seconds.", "notice";
          sleep 30;
          next;
        }

        if ($fetch_results->fault) {
          # Got back a SOAP fault, which means our query got through but NCBI gave us junk back.
          # Wait 30 seconds and retry - this seems to just happen sometimes.
          log_error "Couldn't fetch ESTs by primary ID; got response \"" . $fetch_results->faultstring . "\" from NCBI. Retrying in 30 seconds.", "notice";
          sleep 30;
          next;
        }

        # No errors, pull out the results
        $fetch_results->match('/Envelope/Body/eFetchResult/GBSet/GBSeq');
        if (!length($fetch_results->valueof())) {
          if (!$fetch_results->match('/Envelope/Body/eFetchResult')) {
            # No eFetchResult result at all, which means we got back junk. Wait 30 seconds and retry.
            log_error "Couldn't retrieve EST by ID; got a junk response from NCBI. Retrying in 30 seconds.", "notice";
            sleep 30;
            next;
          } else {
            # Got an empty result
            log_error "None of the " . scalar(@batch_query) . " ESTs found at NCBI using using query '" . $fetch_query . "'. Retrying, just in case.", "warning";
            sleep 5;
            next;
          }
        }

        # Got back an array of useful results. Figure out which of our current @term_set actually
        # got returned. Record ones that we didn't get back in @data_left.
        my ($not_found, $false_positives) = handle_search_results($fetch_results, $datum, @batch_query);

        if (scalar(@$false_positives)) {
          # TODO: Do more here?
          log_error "Found " . scalar(@$false_positives) . " false positives at GenBank.", "warning";
        }

        # Keep track of $not_found and to pass on to next segment
        push @not_found_by_acc, @$not_found;

        last; # Exit the retry 'til MAX_TRIES loop
      }
      if ($done > MAX_TRIES) {
        # ALL of the queries failed, so pass on all the ESTs being queried to the next section
        log_error "Couldn't fetch ESTs by ID after " . MAX_TRIES . " tries.", "warning";
        @not_found_by_acc = @batch_query;
      }
      # If we found everything, move on to the next batch of ESTs
      unless (scalar(@not_found_by_acc)) {
        sleep 5; # Make no more than one request every 3 seconds (2 for flinching, Milo)
        log_error "Done.", "notice", "<";
        next; # SUCCESS
      }


      @batch_query = @not_found_by_acc;
      @not_found_by_acc = ();

      ###### FALL BACK TO SEARCH INSTEAD OF LOOKUP ######

      # Do we need to fall back to searching because we couldn't find by accession?
      log_error "Falling back to pulling down " . scalar(@batch_query) . " EST information from Genbank by searching...", "notice", ">";
      $done = 0;

      while ($done++ < MAX_TRIES) {
        log_error "Searching for remaining batch of " . scalar(@batch_query) . " ESTs.", "notice";

        # Run query (est1,est2,...) and get back the cookie that will let us fetch the result:
        my $search_query = join(" OR ", @batch_query);
        # Run query and get back the cookie that will let us fetch the result:
        my $search_results;
        eval {
          $search_results = $self->get_soap_client->run_eSearch({
              'eSearchRequest' => {
                'db' => 'nucleotide',
                #   'rettype' => 'native',
                'term' => $search_query,
                'tool' => 'modENCODE pipeline',
                'email' => 'yostinso@berkeleybop.org',
                'usehistory' => 'y',
                'retmax' => 400,
              }
            });
        };
        if (!$search_results) {
          # Couldn't get anything useful back (bad network connection?). Wait 30 seconds and retry.
          log_error "Couldn't retrieve any ESTs by searching; got no response from NCBI. Retrying in 30 seconds.", "notice";
          sleep 30;
          next;
        }

        if ($search_results->fault) {
          # Got back a SOAP fault, which means our query got through but NCBI gave us junk back.
          # Wait 30 seconds and retry - this seems to just happen sometimes.
          log_error "Couldn't search for ESTs by primary ID; got response \"" . $search_results->faultstring . "\" from NCBI. Retrying in 30 seconds.", "notice";
          sleep 30;
          next;
        }

        # Pull out the cookie and query key that will allow us to actually fetch the results proper
        $search_results->match('/Envelope/Body/eSearchResult/WebEnv');
        my $webenv = $search_results->valueof();
        $search_results->match('/Envelope/Body/eSearchResult/QueryKey');
        my $querykey = $search_results->valueof();

        if (!length($querykey) || !length($webenv)) {
          # If we didn't get a valid query key or cookie, something screwy happened without a fault.
          # Wait 30 seconds and retry.
          log_error "Couldn't get a search cookie when searching for ESTs; got an unexpected response from NCBI. Retrying in 30 seconds.", "notice";
          sleep 30;
          next;
        }

        ######################################################################################

        # Okay, got a valid query key and cookie, go ahead and fetch the actual results.

        my $fetch_results;
        eval {
          $fetch_results = $self->get_soap_client->run_eFetch({
              'eFetchRequest' => {
                'db' => 'nucleotide',
                #'rettype' => 'native',
                'WebEnv' => $webenv,
                'query_key' => $querykey,
                'tool' => 'modENCODE pipeline',
                'email' => 'yostinso@berkeleybop.org',
                'retmax' => 1000,
              }
            });
        };

        if (!$fetch_results) {
          # Couldn't get anything useful back (bad network connection?). Wait 30 seconds and retry.
          log_error "Couldn't retrieve any ESTs by search result; got no response from NCBI. Retrying in 30 seconds.", "notice";
          sleep 30;
          next;
        }

        if ($fetch_results->fault) {
          # Got back a SOAP fault, which means our query got through but NCBI gave us junk back.
          # Sadly, this is also what happens when there are no results. The standard Eutils response 
          # is "Error: download dataset is empty", which apparently translates to a SOAP fault. Since
          # the search itself worked, we'll assume that NCBI didn't just die and that what we're really
          # seeing is a lack of results, in which all of the ESTs being searched for failed.
          log_error "Couldn't fetch ESTs by primary ID; got response \"" . $fetch_results->faultstring . "\" from NCBI. Retrying, just in case.", "error";
          sleep 5;
          last;
        }

        if (!length($fetch_results->valueof())) {
          if (!$fetch_results->match('/Envelope/Body/eFetchResult')) {
            # No eFetchResult result at all, which means we got back junk. Wait 30 seconds and retry.
            log_error "Couldn't retrieve EST by ID; got an unknown response from NCBI. Retrying.", "notice";
            sleep 30;
            next;
          } else {
            # Got an empty result (this is what we're hoping for instead of the fault mentioned above)
            log_error "None of the " . scalar(@batch_query) . " ESTs found at NCBI using using query '" . $search_query . "'. Retrying, just in case.", "warning";
            sleep 5;
            next;
          }
        }

        # Got back an array of useful results. Figure out which of our current @term_set actually
        # got returned. Record ones that we didn't get back in @data_left.
        my ($not_found, $false_positives) = handle_search_results($fetch_results, $datum, @batch_query);

        if (scalar(@$false_positives)) {
          # TODO: Do more here?
          log_error "Found " . scalar(@$false_positives) . " false positives at GenBank.", "warning";
        }

        # Keep track of $not_found and to pass on to next segment
        push @not_found_by_acc, @$not_found;

        last; # Exit the retry 'til MAX_TRIES loop
      }
      if ($done > MAX_TRIES) {
        # ALL of the queries failed, so pass on all the ESTs being queried to the next section
        log_error "Couldn't fetch ESTs by ID after " . MAX_TRIES . " tries.", "warning";
        @not_found_by_acc = @batch_query;
      }
      # If we found everything, move on to the next batch of ESTs
      unless (scalar(@not_found_by_acc)) {
        sleep 5; # Make no more than one request every 3 seconds (2 for flinching, Milo)
        log_error "Done.", "notice", "<";
        next; # SUCCESS
      }
      log_error "Done.", "notice", "<";
      ###### ERROR - DIDN'T FIND ALL ESTS ######
      $success = 0;
      foreach my $missing_est (@not_found_by_acc) {
        log_error "Didn't find EST " . $missing_est . " anywhere!", "error";
      }
      return $success;
      log_error "Done.", "notice", "<";
    }
    log_error "Done.", "notice", "<";

    log_error "Done.", "notice", "<";
  }
  log_error "Done.", "notice", "<";
  return $success
}


sub handle_search_results {
  my ($fetch_results, $datum, @est_list) = @_;
  my @ests_not_found;
  my @unmatched_result_accs = $fetch_results->valueof();
  foreach my $est_name (@est_list) {
    if ($est_name eq "AH001028") {
      #special case - we hope to never see this id again
      log_error "AH001028 (specifically) is a very strange GenBank entry that we cannot deal with. Skipping it.", "warning";
      next;
    }

    my ($genbank_feature) = grep { $est_name eq $_->{'GBSeq_primary-accession'} } $fetch_results->valueof();
    if (!$genbank_feature) {
      push @ests_not_found, $est_name;
      next;
    }
    @unmatched_result_accs = grep { $est_name ne $_->{'GBSeq_primary-accession'} } @unmatched_result_accs;

    # Pull out enough information from the GenBank record to create a Chado feature
    my ($seq_locus) = $genbank_feature->{'GBSeq_locus'};
    my ($genbank_gb) = grep { $_ =~ m/^gb\|/ } @{$genbank_feature->{'GBSeq_other-seqids'}->{'GBSeqid'}}; $genbank_gb =~ s/^gb\|//;
    my ($genbank_gi) = grep { $_ =~ m/^gi\|/ } @{$genbank_feature->{'GBSeq_other-seqids'}->{'GBSeqid'}}; $genbank_gi =~ s/^gi\|//;
    my $genbank_acc = $genbank_feature->{'GBSeq_primary-accession'};
    my ($est_name) = ($genbank_feature->{'GBSeq_definition'} =~ m/^(\S+)/);
    my $sequence = $genbank_feature->{'GBSeq_sequence'};
    my $seqlen = length($sequence);
    my $timeaccessioned = $genbank_feature->{'GBSeq_create-date'};
    my $timelastmodified = $genbank_feature->{'GBSeq_update-date'};
    my ($genus, $species) = ($genbank_feature->{'GBSeq_organism'} =~ m/^(\S+)\s+(.*)$/);

    if (!($seq_locus)) {      
      if ($genbank_gb) {
        log_error "dbEST id for " . $est_name . " is not the primary identifier, but matches GenBank gb: $genbank_gb.", "warning";
      } elsif ($genbank_gi) {
        log_error "dbEST id for " . $est_name . " is not the primary identifier, but matches GenBank gi: $genbank_gi.", "warning";
      } else {
        log_error "Found a record with matching accession for " . $est_name . ", but no GBSeq_locus entry, so it's invalid", "error";
        push @ests_not_found, $est_name;
        next;
      }
    }

    # Create the Chado feature
    # Check to see if this feature has already been found (in, say GFF)
    my $organism = new ModENCODE::Chado::Organism({ 'genus' => $genus, 'species' => $species });
    my $type = new ModENCODE::Chado::CVTerm({ 'name' => 'EST', 'cv' => new ModENCODE::Chado::CV({ 'name' => 'SO' }) });

    my $feature = ModENCODE::Cache::get_feature_by_uniquename_and_type($est_name, $type);
    if ($feature) {
      log_error "Found already created feature " . $est_name . " to represent EST feature.", "debug";
      if ($organism->get_id == $feature->get_object->get_organism_id) {
        log_error "  Using it because unique constraints are identical.", "debug";
        # Add DBXrefs
        $feature->get_object->add_dbxref(new ModENCODE::Chado::DBXref({
              'accession' => $genbank_gi,
              'db' => new ModENCODE::Chado::DB({
                  'name' => 'dbEST',
                  'description' => 'dbEST gi IDs',
                }),
            })
        );
        $feature->get_object->add_dbxref(new ModENCODE::Chado::DBXref({
              'accession' => $genbank_acc,
              'db' => new ModENCODE::Chado::DB({
                  'name' => 'GB',
                  'description' => 'GenBank',
                }),
            }),
        );
      } else {
        log_error "  Not using it because organisms (new: " .  $organism->get_object->to_string . ", existing: " .  $feature->get_object->get_organism(1)->to_string . ") differ.", "debug";
        $feature = undef;
      }
    }

    if (!$feature) {
      $feature = new ModENCODE::Chado::Feature({
          'name' => $est_name,
          'uniquename' => $genbank_acc,
          'residues' => $sequence,
          'seqlen' => $seqlen,
          'timeaccessioned' => $timeaccessioned,
          'timelastmodified' => $timelastmodified,
          'type' => $type,
          'organism' => $organism,
          'primary_dbxref' => new ModENCODE::Chado::DBXref({
              'accession' => $genbank_acc,
              'db' => new ModENCODE::Chado::DB({
                  'name' => 'GB',
                  'description' => 'GenBank',
                }),
            }),
          'dbxrefs' => [ new ModENCODE::Chado::DBXref({
              'accession' => $genbank_gi,
              'db' => new ModENCODE::Chado::DB({
                  'name' => 'dbEST',
                  'description' => 'dbEST gi IDs',
                }),
            }),
          ],
        });
    }

    # Add the feature to the datum
    $datum->get_object->add_feature($feature);
  }
  @unmatched_result_accs = map { $_->{'GBSeq_primary-accession'} } @unmatched_result_accs;

  return (\@ests_not_found, \@unmatched_result_accs);
}


sub add_est_name {
  my ($self, $est_name) = @_;
  push @{$est_names{ident $self}}, $est_name;
}

sub rewind_est_names {
  my $self = shift;
  $est_cursor_position{ident $self} = 0;
}

sub next_est_name {
  my $self = shift;
  my $est_name = $est_names{ident $self}->[$est_cursor_position{ident $self}++];
  return $est_name;
}

sub remove_current_est_name {
  my $self = shift;
  splice @{$est_names{ident $self}}, --$est_cursor_position{ident $self}, 1;
}

sub num_est_names {
  my $self = shift;
  return scalar(@{$est_names{ident $self}});
}


1;
