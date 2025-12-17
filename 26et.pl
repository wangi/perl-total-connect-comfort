#!/usr/bin/env perl

use warnings;
use strict;
use Device::TotalConnectComfort;
use LWP;
use JSON;
use Encode;
use POSIX;
use DBI;
use Getopt::Long;

# parse command line options
my $debug = 0;
GetOptions('debug' => \$debug) or die "Usage: $0 [--debug]\n";

# get current time, output filename
my $t     = time;
my $tfmt  = POSIX::strftime("%m/%d/%Y %H:%M:%S", gmtime($t));
my $fname = POSIX::strftime("/home/pi/data/%Y%m.csv", gmtime($t));
my $file_exists = -f $fname ? 1 : 0;

# Open file handle for writing (unless in debug mode)
my $fh;
if (!$debug) {
    open $fh, ">>$fname" or die "Cannot open $fname: $!";
}

# get configuration from environment variables
my $username = $ENV{TCC_USERNAME} or die "TCC_USERNAME environment variable not set\n";
my $password = $ENV{TCC_PASSWORD} or die "TCC_PASSWORD environment variable not set\n";
my $db_connection = $ENV{DB_CONNECTION} or die "DB_CONNECTION environment variable not set\n";
my $db_username   = $ENV{DB_USERNAME}   or die "DB_USERNAME environment variable not set\n";
my $db_password   = $ENV{DB_PASSWORD}   or die "DB_PASSWORD environment variable not set\n";

# connect to database (unless in debug mode)
my $db;
my $query;
if (!$debug) {
    $db = DBI->connect($db_connection, $db_username, $db_password, { RaiseError => 1, AutoCommit => 1 })
        or die "Cannot connect to database: $DBI::errstr\n";
    $query = $db->prepare("INSERT INTO evohome(datetime, temperature, humidity, weather, temp_living, temp_living_target, temp_kitchen, temp_kitchen_target, temp_toilet, temp_toilet_target, temp_utility, temp_utility_target, temp_freya, temp_freya_target, temp_spare, temp_spare_target, temp_landing, temp_landing_target, temp_master, temp_master_target, temp_study, temp_study_target) VALUES(to_timestamp(?), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)");
}

# get current weather: BBC, Joppa
my $URL = 'https://weather-broker-cdn.api.bbci.co.uk/en/observation/rss/2645947';
my $userAgent = LWP::UserAgent->new(keep_alive => 20);
my $resp = $userAgent->get($URL);
my $temperature  = '';
my $humidity     = '';
my $weatherstate = '';
foreach ( split "\n", decode('utf-8', $resp->content) )
{
	$temperature = $1 if( /Temperature: ([\d\-]+).C/ );
	$humidity    = $1 if( /Humidity: ([\d]+)%/ );
}

# log in
my $cn = Device::TotalConnectComfort->new( username => $username,
                                           password => $password );

# get data for all our locations
my $locations_data = $cn->get_locations;

# set default location id for other requests
my $location_id = $locations_data->[0]->{locationInfo}->{locationId};

# get data on the default location
my $status_data = $cn->get_status($location_id);
my %data = ();
for my $zone ( @{$status_data->{gateways}->[0]->{temperatureControlSystems}->[0]->{zones}} )
{
	my $name = lc $zone->{name};
	$data{$name}{temp}   = $zone->{temperatureStatus}->{temperature};
	$data{$name}{target} = $zone->{setpointStatus}->{targetHeatTemperature};
}

# prepare CSV output
my $csv_header = "unixtime,datetime,temperature,humidity,weather,living,living target,kitchen,kitchen target,toilet,toilet target,utility,utility target,freya,freya target,spare,spare target,landing,landing target,master,master target,study,study target\n";
my $csv_row = "$t,$tfmt,$temperature,$humidity,$weatherstate,$data{living}{temp},$data{living}{target},$data{kitchen}{temp},$data{kitchen}{target},$data{toilet}{temp},$data{toilet}{target},$data{utility}{temp},$data{utility}{target},$data{freya}{temp},$data{freya}{target},$data{spare}{temp},$data{spare}{target},$data{landing}{temp},$data{landing}{target},$data{master}{temp},$data{master}{target},$data{study}{temp},$data{study}{target}\n";

if ($debug) {
    # debug mode: output to terminal
    print $csv_header;
    print $csv_row;
} else {
    # normal mode: write to file and database
    print $fh $csv_header if ($file_exists == 0);
    print $fh $csv_row;
    close $fh;

    # insert into database
    $query->execute($t, $temperature, $humidity, $weatherstate, $data{living}{temp}, $data{living}{target}, $data{kitchen}{temp}, $data{kitchen}{target}, $data{toilet}{temp}, $data{toilet}{target}, $data{utility}{temp}, $data{utility}{target}, $data{freya}{temp}, $data{freya}{target}, $data{spare}{temp}, $data{spare}{target}, $data{landing}{temp}, $data{landing}{target}, $data{master}{temp}, $data{master}{target}, $data{study}{temp}, $data{study}{target});
    $db->disconnect;
}
