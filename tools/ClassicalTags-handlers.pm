# ClassicalTags plugin — Stage 3 handlers
#
# Paste these two handlers into your existing plugin file on the LMS server:
#   /home/doa/docker/lyrion/config/Plugins/ClassicalTags/Plugin.pm
#
# Wire them up inside the plugin's `initPlugin` (or wherever the existing
# handler dispatch lives). After saving:
#
#   docker compose restart lyrion
#
# and verify with:
#
#   curl -s "http://localhost:9000/plugins/ClassicalTags/soloists" | jq .
#   curl -s "http://localhost:9000/plugins/ClassicalTags/tracks?soloist=Mutter" | jq .
#
# Hyperion's iOS-side fetchAllSoloists / fetchTracksWithSoloist hit these
# endpoints. While they're absent the iOS browser shows its empty state.

use strict;
use warnings;
use JSON::XS qw(encode_json);
use DBI;

# --------------------------------------------------------------------------
# Dispatch wiring (place inside initPlugin or your existing dispatch block)
# --------------------------------------------------------------------------
#
# Slim::Web::Pages->addRawFunction(
#     qr{plugins/ClassicalTags/soloists},
#     \&handle_soloists_list
# );
# Slim::Web::Pages->addRawFunction(
#     qr{plugins/ClassicalTags/tracks},
#     \&handle_tracks_by_soloist
# );

# --------------------------------------------------------------------------
# GET /plugins/ClassicalTags/soloists
#
# Returns a JSON array of every unique soloist name in the classical_tags
# table along with the number of tracks each appears on. The soloist field
# is semicolon-separated in the source table, so we split + flatten + count
# distinct names server-side.
# --------------------------------------------------------------------------
sub handle_soloists_list {
    my ($httpClient, $response) = @_;

    my $dbh = open_classical_tags_db();
    unless ($dbh) {
        send_json_response($httpClient, $response, 500, { error => 'classical_tags.db unavailable' });
        return;
    }

    my %counts;
    my $sth = $dbh->prepare("SELECT soloist FROM classical_tags WHERE soloist IS NOT NULL");
    $sth->execute;
    while (my ($soloist) = $sth->fetchrow_array) {
        next unless defined $soloist && length $soloist;
        for my $name (split /;/, $soloist) {
            $name =~ s/^\s+|\s+$//g;
            next unless length $name;
            $counts{$name}++;
        }
    }
    $sth->finish;
    $dbh->disconnect;

    my @rows = map {
        { name => $_, track_count => $counts{$_} + 0 }
    } sort { lc($a) cmp lc($b) } keys %counts;

    send_json_response($httpClient, $response, 200, \@rows);
}

# --------------------------------------------------------------------------
# GET /plugins/ClassicalTags/tracks?soloist=NAME
#
# Returns a JSON object with one key, track_ids, listing every track whose
# soloist field LIKE %NAME% — matches both standalone names and combined
# entries like "Anne-Sophie Mutter; Yo-Yo Ma".
# --------------------------------------------------------------------------
sub handle_tracks_by_soloist {
    my ($httpClient, $response) = @_;

    my $params = $response->request->uri->query_form_hash;
    my $name   = $params->{soloist};
    unless (defined $name && length $name) {
        send_json_response($httpClient, $response, 400, { error => 'soloist parameter required' });
        return;
    }

    my $dbh = open_classical_tags_db();
    unless ($dbh) {
        send_json_response($httpClient, $response, 500, { error => 'classical_tags.db unavailable' });
        return;
    }

    my $sth = $dbh->prepare(
        "SELECT track_id FROM classical_tags WHERE soloist LIKE ?"
    );
    $sth->execute('%' . $name . '%');

    my @ids;
    while (my ($track_id) = $sth->fetchrow_array) {
        push @ids, $track_id + 0;
    }
    $sth->finish;
    $dbh->disconnect;

    send_json_response($httpClient, $response, 200, { track_ids => \@ids });
}

# --------------------------------------------------------------------------
# Helpers — adapt paths/db filename to wherever the existing plugin stores
# classical_tags.db. The connect line is the only place that needs editing.
# --------------------------------------------------------------------------
sub open_classical_tags_db {
    my $path = '/var/lib/squeezeboxserver/cache/classical_tags.db';  # ← adjust to taste
    return DBI->connect(
        "dbi:SQLite:dbname=$path", '', '',
        { RaiseError => 0, PrintError => 0, AutoCommit => 1 }
    );
}

sub send_json_response {
    my ($httpClient, $response, $status, $body) = @_;
    my $json = encode_json($body);
    $response->code($status);
    $response->content_type('application/json');
    $response->content($json);
    Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$json);
}

1;
