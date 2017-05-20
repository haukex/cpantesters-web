package CPAN::Testers::Web::Legacy::Model;
use warnings;
use strict;
use Carp;
use Try::Tiny 0.27;
use JSON 2.90;
use Metabase::Resource 0.025;
use CPAN::Testers::Report 1.999003;
use Metabase::Resource::cpan::distfile 0.025;
use Metabase::Resource::metabase::user 0.025;

=pod

=head1 NAME

CPAN::Testers::Web::Legacy::Model - a model for cpantesters-web-legacy

=head1 DESCRIPTION

This class implements a model for C<cpantesters-web-legacy>, but probably not what you would expect
for a MVC application as Mojolicious.

This model represents the logic behind the legacy C<view-report.cgi> related to retrieve and manipulating data, 
but does not breaks down each model mapping to a DB entity.

=head1 CAVEAT

This class probably should be reviewed and/or replaced in the future.

=head1 METHODS

=head2 new

Expects a single parameter: a instance of L<DBIx::Connector>.

Returns a new instance of this class.

=cut

sub new {
    my ( $class, $conn ) = @_;
    my $self = {
        conn        => $conn,
        report_data => undef,
    };
    bless $self, $class;
    return $self;
}

=head2 get_report

Recovers a report, based on the parameter given. Right now, only GUID based reports are recovered.

Returns a hash reference containing all the data from a report.

=cut

 # :TODO:19/05/2017 15:37:49:ARFREITAS: subclass this module and override this method
 # by subclasses, depending on which report type is requested: HTML, JSON or raw
 # Currently all data required by the three types is being generated
sub get_report {
    my ( $self, $guid ) = @_;
    $self->{report_data} = $self->{conn}->run(
        sub {
            my $sth = $_->prepare(
                q{SELECT fact, report FROM metabase.metabase WHERE guid = ?});
            $sth->bind_param( 1, $guid );
            $sth->execute();
            return $sth->fetchrow_arrayref;
        }
    );

# :TODO:08/05/2017 19:26:47:ARFREITAS: $data is intermediate data, it can be moved to upper to other subs and maintained in
# memory for a shorter period of time
    my ( $report, $data );

    if ( scalar( @{$self->{report_data}} ) > 0 ) {

        # has the fact
        if ( defined( $self->{report_data}->[0] ) ) {
            $report = $self->_get_serial_data(0);
            $data   = $self->_dereference_report($report);
        }
        else {
            $data   = $self->_get_serial_data(1);
            $report = {
                metadata => {
                    core => { guid => $guid, type => 'CPAN-Testers-Report' }
                }
            };

            foreach my $name ( keys( %{$data} ) ) {
                push @{ $report->{content} }, $data->{$name};
            }

        }

        my $fact;

        if (
            ref( $data->{'CPAN::Testers::Fact::LegacyReport'}->{content} ) eq
            'HASH' )
        {
            $fact =
              $self->_gen_fact( $data, 'CPAN::Testers::Fact::LegacyReport' );
        }
        elsif (
            ref( $data->{'CPAN::Testers::Fact::TestSummary'}->{content} ) eq
            'HASH' )
        {
            $fact =
              $self->_gen_fact( $data, 'CPAN::Testers::Fact::TestSummary' );
        }
        else {
            die
'Cannot process data, neither CPAN::Testers::Fact::LegacyReport or CPAN::Testers::Fact::TestSummary';
        }

        my %template;
        $template{article}->{article} = $fact->{content}->{textreport};
        $template{article}->{guid}    = $guid;

# :TODO:08/05/2017 20:46:19:ARFREITAS: this seems to be ilogical... if
# $fact is not recovered from the database, it will be created based on $data anyway
# it should be same same thing using one or another
        if ( defined( $self->{report_data}->[0] ) ) {
            $self->_map_attribs( $report, $fact );
        }
        else {
            $self->_map_attribs( $report, $data );
        }

        $template{article}->{platform} = $fact->{content}->{archname};
        $template{article}->{osvers}   = $fact->{content}->{osversion};
        $template{article}->{created} =
          $fact->{metadata}->{core}->{creation_time};
        my $dist =
          Metabase::Resource->new( $fact->{metadata}->{core}->{resource} );
        $template{article}->{htmltitle} =
            'Report for '
          . $dist->metadata->{dist_name} . '-'
          . $dist->metadata->{dist_version};
        $template{article}->{dist_name}    = $dist->metadata->{dist_name};
        $template{article}->{dist_version} = $dist->metadata->{dist_version};
        my @created = localtime(time);
        $template{copyright} =
          '1999-' . ( $created[5] + 1900 ) . ' CPAN Testers';
        $template{article}->{dist_path} =
          substr( $dist->metadata->{dist_name}, 0, 1 );
        ( $template{article}->{author}, $template{article}->{from} ) =
          $self->_get_tester( $fact->creator );

        if ( $template{article}{created} ) {
            my @created = $template{article}->{created} =~
              /(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)Z/;    # 2010-02-23T20:33:52Z
            $template{article}->{postdate} = sprintf "%04d%02d", $created[0],
              $created[1];
            $template{article}->{fulldate} = sprintf "%04d%02d%02d%02d%02d",
              $created[0], $created[1], $created[2], $created[3], $created[4];
        }
        else {
            $template{article}->{postdate} = sprintf "%04d%02d",
              $created[5] + 1900,
              $created[4] + 1;
            $template{article}->{fulldate} = sprintf "%04d%02d%02d%02d%02d",
              $created[5] + 1900, $created[4] + 1, $created[3], $created[2],
              $created[1];
        }

        $template{article}->{subject} = sprintf "%s %s-%s %s %s",
          uc( $fact->{content}->{grade} ), $dist->metadata->{dist_name},
          $dist->metadata->{dist_version}, $fact->{content}->{perl_version},
          $self->_get_osname( $fact->{content}->{osname} );

        # used by report in raw format
        $template{body}->{result}     = $self->_decode_report($report);
        $template{article}->{article} = $fact->{content}->{textreport};
        $self->{report_data}          = undef;
        return \%template;
    }
    else {
        return undef;
    }

}

sub _gen_fact {
    my ( $self, $data_ref, $fact_name ) = @_;

    try {
        $data_ref->{$fact_name}->{content} =
          encode_json( $data_ref->{$fact_name}->{content} );
        return CPAN::Testers::Fact::TestSummary->from_struct(
            $data_ref->{$fact_name} );
    }
    catch {
        die "Failed to encode $fact_name as JSON: $_";
    }

}

# used by report in raw format
sub _decode_report {
    my ( $self, $report ) = @_;
    my $hash;

    # do we have an encoded report object?
    if ( ref($report) eq 'CPAN::Testers::Report' ) {
        $hash = $report->as_struct;
        $hash->{content} = decode_json( $hash->{content} );

        foreach my $content ( @{ $hash->{content} } ) {
            $content->{content} = decode_json( $content->{content} );
        }

        return encode_json($hash);
    }

    try {

        # we have a manufactured hash, with a collection of fact objects
        foreach my $fact ( @{ $report->{content} } ) {
            $fact->{content} = decode_json( $fact->{content} );
        }

        return encode_json($report);
    }
    catch {
        confess $_;
    };

    my @facts = $report->facts();

    foreach my $fact (@facts) {
        my $name = ref($fact);
        $hash->{'CPAN::Testers::Report'}->{content}{$name} = $fact->as_struct();
    }

    return $hash;
}

sub _dereference_report {
    my ( $self, $report ) = @_;
    my %facts;
    my @facts = $report->facts();

    foreach my $fact (@facts) {
        my $name = ref($fact);
        $facts{$name} = $fact->as_struct;
        $facts{$name}{content} = decode_json( $facts{$name}{content} );
    }

    return \%facts;
}

# changes report in place
sub _map_attribs {
    my ( $self, $report, $source ) = @_;
    my @attribs =
      qw(resource schema_version creation_time valid creator update_time);
    my $source_path;

    if ( $source->isa('CPAN::Testers::Fact::LegacyReport') ) {
        $source_path = $source->{metadata}->{core};
    }
    else {
        $source_path =
          $source->{'CPAN::Testers::Fact::TestSummary'}->{metadata}->{core};
    }

    foreach my $attrib (@attribs) {
        $report->{metadata}->{core}->{$attrib} = $source_path->{$attrib};
    }
}

# :TODO:08/05/2017 21:04:10:ARFREITAS: this can be easily cached from the DB
sub _get_osname {
    my ( $self, $os_name ) = @_;
    return 'UNKNOWN' unless ( defined($os_name) ) and ( $os_name ne '' );
    my $preferred_name = $self->{conn}->run(
        sub {
            my $sth = $_->prepare(
                q{SELECT ostitle FROM cpanstats.osname where osname = ?});
            my $code = lc($os_name);
            $code =~ s/[^\w]+//g;
            $sth->bind_param( 1, $code );
            $sth->execute();
            return $sth->fetchrow_arrayref()->[0];
        }
    );

    if ( defined($preferred_name) ) {
        return $preferred_name;
    }
    else {
        return uc($os_name);
    }
}

sub _get_tester {
    my ( $self, $creator ) = @_;
    my $row_ref = $self->{conn}->run(
        sub {
 # :WORKAROUND:19/05/2017 22:13:15:ARFREITAS: used lower() function to make it able to use data from both
 # Mysql and SQLite3, since the testers.address table on Mysql is using UTF8 case insensitive collation
            my $query =
              q{SELECT mte.fullname, tp.name, tp.pause, tp.contact, mte.email
FROM metabase.testers_email mte 
LEFT JOIN testers.address ta ON lower(ta.email)=lower(mte.email)
LEFT JOIN testers.profile tp ON tp.testerid=ta.testerid 
WHERE mte.resource=?
ORDER BY tp.testerid DESC
limit 1};
            my $sth = $_->prepare($query);
            $sth->bind_param( 1, $creator );
            $sth->execute();
            return $sth->fetchrow_arrayref;
        }
    );
    unless ( scalar( @{$row_ref} ) > 0 ) {
        return $creator, $creator;
    }
    else {
        my $name = $row_ref->[0];
        $name = join( ' ', $row_ref->[1], $row_ref->[2] )
          if ( defined( $row_ref->[1] ) );
        my $email = $row_ref->[3] || $row_ref->[4] || $creator;
        $email =~ s/\'/''/g if ($email);
        $name =~ s/\@/ [at] /g;
        $email =~ s/\@/ [at] /g;
        $email =~ s/\./ [dot] /g;
        return $name, $email;
    }

}

# passing an index to get advantage of the array reference
sub _get_serial_data {
    my ( $self, $index ) = @_;
    my $serializer = Data::FlexSerializer->new(
        detect_compression => 1,
        detect_sereal      => 1,
        detect_json        => 1,
    );
    return $serializer->deserialize( $self->{report_data}->[$index] );
}

1;