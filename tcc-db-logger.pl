#!/usr/bin/env perl
#
# Fetches weather data from Google Weather API, gets Honeywell Total Connect
# zone targets and current readings, logs to database
#
# Install:
#  ./tcc-db-setup.sh
#  sudo cp tcc-db-logger.service tcc-db-logger.timer /etc/systemd/system/
#  sudo systemctl edit tcc-db-logger.service
#  sudo systemctl daemon-reload
#  sudo systemctl enable --now tcc-db-logger.timer
#

use warnings;
use strict;
use Device::TotalConnectComfort;
use LWP::UserAgent;
use JSON;
use Encode;
use POSIX;
use DBI;
use Getopt::Long;

# Parse command line options
my $debug = 0;
GetOptions('debug' => \$debug) or die "Usage: $0 [--debug]\n";

# Get current time
my $t = time;
my $datetime = POSIX::strftime("%Y-%m-%d %H:%M:%S", gmtime($t));

# Get configuration from environment variables
my $username       = $ENV{TCC_USERNAME}    or die "TCC_USERNAME environment variable not set\n";
my $password       = $ENV{TCC_PASSWORD}    or die "TCC_PASSWORD environment variable not set\n";
my $db_connection  = $ENV{DB_CONNECTION}   or die "DB_CONNECTION environment variable not set\n";
my $db_username    = $ENV{DB_USERNAME}     or die "DB_USERNAME environment variable not set\n";
my $db_password    = $ENV{DB_PASSWORD}     or die "DB_PASSWORD environment variable not set\n";
my $google_api_key = $ENV{GOOGLE_API_KEY}  or die "GOOGLE_API_KEY environment variable not set\n";

# Default fallback coordinates (Edinburgh)
my $default_latitude  = $ENV{LATITUDE}  || '55.9533';
my $default_longitude = $ENV{LONGITUDE} || '-3.1883';

# Connect to database (unless in debug mode)
my $db;
if (!$debug) {
	$db = DBI->connect($db_connection, $db_username, $db_password,
		{ RaiseError => 1, AutoCommit => 0 })
		or die "Cannot connect to database: $DBI::errstr\n";
}

# Prepare database statements
my ($location_upsert, $zone_upsert, $weather_insert, $zone_reading_insert);
if (!$debug) {
	$location_upsert = $db->prepare(q{
		INSERT INTO locations (location_id, location_name, street_address, city, postcode, country, latitude, longitude, last_seen)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, NOW())
		ON CONFLICT (location_id) DO UPDATE
		SET location_name = EXCLUDED.location_name,
		    street_address = EXCLUDED.street_address,
		    city = EXCLUDED.city,
		    postcode = EXCLUDED.postcode,
		    country = EXCLUDED.country,
		    latitude = EXCLUDED.latitude,
		    longitude = EXCLUDED.longitude,
		    last_seen = NOW()
	});

	$zone_upsert = $db->prepare(q{
		INSERT INTO zones (zone_id, location_id, zone_name, display_name, last_seen)
		VALUES (?, ?, ?, ?, NOW())
		ON CONFLICT (zone_id) DO UPDATE
		SET zone_name = EXCLUDED.zone_name,
		    display_name = EXCLUDED.display_name,
		    last_seen = NOW()
	});

	$weather_insert = $db->prepare(q{
		INSERT INTO weather_readings (datetime, location_id, temperature, humidity, condition)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT (datetime, location_id) DO NOTHING
	});

	$zone_reading_insert = $db->prepare(q{
		INSERT INTO zone_readings (datetime, zone_id, temperature, target_temperature, setpoint_mode, metadata)
		VALUES (?, ?, ?, ?, ?, ?::jsonb)
		ON CONFLICT (datetime, zone_id) DO NOTHING
	});
}

# Build user agent string from repo name and username
my $username_prefix = $username;
$username_prefix =~ s/@.*//;  # Extract part before '@'
my $user_agent_string = "perl-total-connect-comfort/${username_prefix}";

# Log in to Total Connect Comfort API
print "Logging in to Total Connect Comfort...\n" if $debug;
my $cn = Device::TotalConnectComfort->new(
	username => $username,
	password => $password
);

# Get data for all locations
print "Fetching locations...\n" if $debug;
my $locations_data = $cn->get_locations;
print "Found " . scalar(@$locations_data) . " location(s)\n" if $debug;

# Process each location
foreach my $location (@$locations_data) {
	my $loc_info = $location->{locationInfo};
	my $location_id = $loc_info->{locationId};
	my $location_name = $loc_info->{name} || '';
	my $street_address = $loc_info->{streetAddress} || '';
	my $city = $loc_info->{city} || '';
	my $postcode = $loc_info->{postcode} || '';
	my $country = $loc_info->{country} || '';

	print "\nProcessing location: $location_name ($location_id)\n" if $debug;

	# Get lat/lon for this location
	# Check for location-specific env var: LATLON_<location_id>
	my $latlon_var = "LATLON_${location_id}";
	my ($latitude, $longitude);

	if (exists $ENV{$latlon_var} && $ENV{$latlon_var}) {
		($latitude, $longitude) = split(/,/, $ENV{$latlon_var});
		$latitude =~ s/^\s+|\s+$//g;   # Trim whitespace
		$longitude =~ s/^\s+|\s+$//g;
		print "  Using location-specific coordinates from $latlon_var: $latitude, $longitude\n" if $debug;
	} else {
		$latitude = $default_latitude;
		$longitude = $default_longitude;
		print "  Using default coordinates: $latitude, $longitude\n" if $debug;
	}

	# Upsert location
	if (!$debug) {
		$location_upsert->execute($location_id, $location_name, $street_address,
			$city, $postcode, $country, $latitude, $longitude);
	}

	# Fetch weather data for this location with retries
	print "  Fetching weather data...\n" if $debug;
	my $weather_url = "https://weather.googleapis.com/v1/currentConditions:lookup?location.latitude=${latitude}&location.longitude=${longitude}&key=${google_api_key}";
	my $userAgent = LWP::UserAgent->new(keep_alive => 20);
	$userAgent->agent($user_agent_string);

	my $temperature = undef;
	my $humidity = undef;
	my $weatherstate = undef;

	my $max_retries = 3;
	my $retry_delay = 5;  # seconds

	for my $attempt (1 .. $max_retries) {
		my $resp = $userAgent->get($weather_url);

		if ($resp->is_success) {
			my $weather_data = from_json($resp->content);

			$temperature = $weather_data->{temperature}->{degrees}
				if exists $weather_data->{temperature}->{degrees};
			$humidity = $weather_data->{relativeHumidity}
				if exists $weather_data->{relativeHumidity};
			$weatherstate = $weather_data->{weatherCondition}->{description}->{text}
				if exists $weather_data->{weatherCondition}->{description}->{text};

			print "  Weather: $temperature°C, $humidity%, $weatherstate\n" if $debug;
			last;  # Success, exit retry loop
		} else {
			warn "  Weather API attempt $attempt/$max_retries failed: " . $resp->status_line . "\n";
			if ($attempt < $max_retries) {
				warn "  Retrying in $retry_delay seconds...\n";
				sleep $retry_delay;
			} else {
				warn "  Failed to fetch weather data after $max_retries attempts\n";
			}
		}
	}

	# Insert weather reading
	if (!$debug && defined $temperature) {
		$weather_insert->execute($datetime, $location_id, $temperature, $humidity, $weatherstate);
	}

	# Get zone status for this location
	print "  Fetching zone status...\n" if $debug;
	my $status_data = $cn->get_status($location_id);

	# Process zones
	for my $gateway (@{$status_data->{gateways}}) {
		for my $tcs (@{$gateway->{temperatureControlSystems}}) {
			for my $zone (@{$tcs->{zones}}) {
				my $zone_id = $zone->{zoneId};
				my $zone_name = $zone->{name};
				my $display_name = "${location_name} - ${zone_name}";

				my $temp = $zone->{temperatureStatus}->{temperature};
				my $target = $zone->{setpointStatus}->{targetHeatTemperature};
				my $setpoint_mode = $zone->{setpointStatus}->{setpointMode} || '';

				# Build metadata JSON with additional zone information
				my $metadata = {
					temperature_is_available => $zone->{temperatureStatus}->{isAvailable} ? JSON::true : JSON::false,
					active_faults => $zone->{activeFaults} || [],
				};

				# Add system mode status if available
				if ($tcs->{systemModeStatus}) {
					$metadata->{system_mode} = $tcs->{systemModeStatus}->{mode};
					$metadata->{system_mode_permanent} = $tcs->{systemModeStatus}->{isPermanent} ? JSON::true : JSON::false;
				}

				my $metadata_json = to_json($metadata);

				print "    Zone: $display_name ($zone_id) - ${temp}°C / ${target}°C [$setpoint_mode]\n" if $debug;

				# Upsert zone
				if (!$debug) {
					$zone_upsert->execute($zone_id, $location_id, $zone_name, $display_name);
					$zone_reading_insert->execute($datetime, $zone_id, $temp, $target, $setpoint_mode, $metadata_json);
				}
			}
		}
	}
}

# Commit transaction
if (!$debug) {
	$db->commit();
	$db->disconnect();
	print "\nData logged successfully at $datetime\n";
} else {
	print "\nDebug mode - no data written to database\n";
}
