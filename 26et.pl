#!/usr/bin/env perl
use warnings;
use strict;
use Device::TotalConnectComfort;

# AUTHENTICATION:
# environment variable TCC_USERNAME & TCC_PASSWORD
my ($username, $password) = @ARGV;
$username = $ENV{TCC_USERNAME} unless $username;
$password = $ENV{TCC_PASSWORD} unless $password;

# Log in
my $cn = Device::TotalConnectComfort->new( username => $username,
                                           password => $password );

# Get data for all our locations
my $locations_data = $cn->get_locations;

# Set default location id for other requests
my $location_id = $locations_data->[0]->{locationInfo}->{locationId};

# Get data on the default location
my $status_data = $cn->get_status($location_id);
describe_status( $status_data );
exit;

# Describe status at a given location
sub describe_status {
    my $status_data = shift;

    for my $zone ( @{ $status_data->{gateways}->[0]->{temperatureControlSystems}->[0]->{zones} } ) {
        print "$zone->{name},$zone->{temperatureStatus}->{temperature},$zone->{setpointStatus}->{targetHeatTemperature}\n";
    }

}


