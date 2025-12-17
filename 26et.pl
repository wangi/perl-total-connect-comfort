#!/usr/bin/env perl

use warnings;
use strict;
use Device::TotalConnectComfort;
use LWP;
use JSON;
use Encode;
use POSIX;
use DBI;

## get current time, output filename
my $t     = time;
my $tfmt  = POSIX::strftime("%m/%d/%Y %H:%M:%S", gmtime($t));
my $fname = POSIX::strftime("/home/pi/data/%Y%m.csv", gmtime($t));
my $file_exists = -f $fname ? 1 : 0;
open my $fh, ">>$fname" or die;

# AUTHENTICATION:
# environment variable TCC_USERNAME & TCC_PASSWORD
my ($username, $password, $DBUSER, $DBPASS) = @ARGV;
$username = $ENV{TCC_USERNAME} unless $username;
$password = $ENV{TCC_PASSWORD} unless $password;
$DBUSER   = $ENV{DBUSER}       unless $DBUSER;
$DBUSER   = $ENV{DBPASS}       unless $DBPASS;
my $DBNAME = 'evohome';
my $DBHOST = 'localhost';

# connect to db
my $db = DBI->connect("DBI:Pg:dbname=$DBNAME;host=$DBHOST", $DBUSER, $DBPASS);
my $query = $db->prepare("INSERT INTO evohome(datetime, temperature, humidity, weather, temp_living, temp_living_target, temp_kitchen, temp_kitchen_target, temp_toilet, temp_toilet_target, temp_utility, temp_utility_target, temp_freya, temp_freya_target, temp_spare, temp_spare_target, temp_landing, temp_landing_target, temp_master, temp_master_target, temp_study, temp_study_target) VALUES(to_timestamp(?), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)");

## get current weather: BBC, Joppa
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

# Log in
my $cn = Device::TotalConnectComfort->new( username => $username,
                                           password => $password );

# Get data for all our locations
my $locations_data = $cn->get_locations;

# Set default location id for other requests
my $location_id = $locations_data->[0]->{locationInfo}->{locationId};

# Get data on the default location
my $status_data = $cn->get_status($location_id);
my %data = ();
for my $zone ( @{$status_data->{gateways}->[0]->{temperatureControlSystems}->[0]->{zones}} )
{
	my $name = lc $zone->{name};
	$data{$name}{temp}   = $zone->{temperatureStatus}->{temperature};
	$data{$name}{target} = $zone->{setpointStatus}->{targetHeatTemperature};
}

print $fh "unixtime,datetime,temperature,humidity,weather,living,living target,kitchen,kitchen target,toilet,toilet target,utility,utility target,freya,freya target,spare,spare target,landing,landing target,master,master target,study,study target\n" if( $file_exists == 0 );
print $fh "$t,$tfmt,$temperature,$humidity,$weatherstate,$data{living}{temp},$data{living}{target},$data{kitchen}{temp},$data{kitchen}{target},$data{toilet}{temp},$data{toilet}{target},$data{utility}{temp},$data{utility}{target},$data{freya}{temp},$data{freya}{target},$data{spare}{temp},$data{spare}{target},$data{landing}{temp},$data{landing}{target},$data{master}{temp},$data{master}{target},$data{study}{temp},$data{study}{target}\n";
close $fh;

$query->execute($t, $temperature, $humidity, $weatherstate, $data{living}{temp}, $data{living}{target}, $data{kitchen}{temp}, $data{kitchen}{target}, $data{toilet}{temp}, $data{toilet}{target}, $data{utility}{temp}, $data{utility}{target}, $data{freya}{temp}, $data{freya}{target}, $data{spare}{temp}, $data{spare}{target}, $data{landing}{temp}, $data{landing}{target}, $data{master}{temp}, $data{master}{target}, $data{study}{temp}, $data{study}{target});

__DATA__

