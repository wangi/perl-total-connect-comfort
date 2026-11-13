# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Perl module that wraps the Honeywell Total Connect Comfort API for querying thermostat data (temperatures, setpoints, schedules, etc.) and controlling heating systems.

## Core Architecture

### Main Module: Device::TotalConnectComfort

The module ([Device/TotalConnectComfort.pm](Device/TotalConnectComfort.pm)) provides an API client with the following key components:

**Authentication Flow:**
- Supports two authentication methods: username/password OR refresh_token
- OAuth-based authentication at `/Auth/OAuth/Token` endpoint
- Access tokens are stored in `$self->{access_token}` and expire after a period
- Refresh tokens allow re-authentication without credentials

**API Request Architecture:**
- `_setup_request()`: Constructs LWP::UserAgent requests with proper headers
- `_handle_request()`: Executes requests and handles HTTP errors. It dies on any status >= 300; note that a 400 from `/Auth/OAuth/Token` with `{"error":"invalid_grant"}` means bad credentials, not a bad app ID, despite the die message
- `_api_call()`: High-level wrapper combining setup and execution
- Base URL: `https://tccna.resideo.com` (hardcoded in `_setup_request()`). The old host `tccna.honeywell.com` was removed from DNS in early 2026; if requests start failing with "Can't connect ... No address associated with hostname", check whether the host has moved again.
- API base path: `/WebAPI/emea/api/v1/`
- App ID is hardcoded: `2ff150b4-a385-40d5-8899-5c6d88d2cbc2`

**Data Model Hierarchy:**
1. User Account → Multiple Locations
2. Location → Gateways → Temperature Control Systems → Zones
3. Each Zone has: temperature status, setpoint status, schedules

**Key API Methods:**
- `get_user_account()`: Retrieves user ID and account info
- `get_locations()`: Returns all locations with thermostat data
- `get_location($location_id)`: Data for specific location (no sensor data)
- `get_status($location_id)`: Real-time temperatures and zone data
- `get_gateways($location_id)`: Gateway device information
- `get_schedules($zone_id)`: Schedule for a temperature zone
- `set_schedule($zone_id, $schedule)`: Update zone schedule
- `set_mode($zone_id, $permanent, $system_mode, $time_until)`: Set override mode
- `set_heat_setpoint($zone_id, $temp, $mode, $time_until)`: Change temperature setpoint

### Example Scripts

**[test_api.pl](test_api.pl)**: Demonstration script showing basic API usage
- Logs in, retrieves locations, displays status in a table
- Shows how to use refresh tokens for re-authentication

**[tcc-db-logger.pl](tcc-db-logger.pl)**: Production data logger
- Fetches weather data from Google Weather API
- Logs zone temperatures and targets to PostgreSQL database (normalized schema)
- Runs periodically via systemd timer to track historical data
- Supports multiple locations with dynamic zone discovery
- Location-specific weather coordinates via `LATLON_<location_id>` environment variables

**[cacti-scripts/temperature.pl](cacti-scripts/temperature.pl)**: Cacti monitoring integration
- Returns all zone temperatures and setpoints in Cacti format
- Calculates boiler status (on if any zone setpoint > temperature)
- Output format: `zone_name:temp zone_name_setpoint:setpoint boiler_status:1`

**[cacti-scripts/one_temp.pl](cacti-scripts/one_temp.pl)**: Single zone temperature for Cacti
- Simplified version that outputs temperature for one configurable zone
- Zone name set via `$ZONE` variable (default: 'living room')

## Development Workflow

### Testing the Module

```bash
# Test with credentials via command line
./test_api.pl 'username' 'password'

# Or use environment variables (recommended)
export TCC_USERNAME='your_username'
export TCC_PASSWORD='your_password'
./test_api.pl
```

### Authentication Methods

When instantiating the module, you can use:

```perl
# Method 1: Username/password
my $cn = Device::TotalConnectComfort->new(
    username => $username,
    password => $password
);

# Method 2: Refresh token from previous session
my $cn = Device::TotalConnectComfort->new(
    refresh_token => $saved_refresh_token
);
```

### Debug Mode

Enable debugging in [Device/TotalConnectComfort.pm](Device/TotalConnectComfort.pm) by setting `my $DEBUG = 1` near the top of the file. This will:
- Print request details
- Cache login responses to `t/login_response` file
- Show session tokens

### Perl Module Dependencies

Required modules (based on code usage):
- `LWP::UserAgent` - HTTP requests
- `JSON` - JSON encoding/decoding
- `LWP::Protocol::https` - HTTPS support for LWP
- `URI::Escape` - URL parameter encoding
- `Text::Table` - Formatted output (test_api.pl)
- `DBI` + `DBD::Pg` - PostgreSQL access (tcc-db-logger.pl)
- `POSIX` - Date formatting (tcc-db-logger.pl)

`tcc-system-setup.sh` installs these as Debian packages.

## Deployment

The logger runs live on `evohome@evohome.home`, from a git checkout at `/home/evohome/code/perl-total-connect-comfort` that tracks GitHub (`origin` over HTTPS).

- To deploy: commit and push here, then `ssh evohome@evohome.home 'cd ~/code/perl-total-connect-comfort && git pull --ff-only'`. No restart is needed; the timer runs the script fresh each time.
- `tcc-db-logger.timer` fires every 10 minutes (`*:0/10`) and starts `tcc-db-logger.service`.
- The real credentials and settings live in a systemd drop-in (`systemctl edit tcc-db-logger.service`). The committed `.service` file only has placeholders, so never put real secrets in it.
- Check runs with `journalctl -u tcc-db-logger.service`. A successful run logs `Data logged successfully at <timestamp>`.
- First-time setup: `tcc-system-setup.sh` (packages and systemd units) and `tcc-db-setup.sh` (PostgreSQL database, user and schema).

## API Response Structure

**Zone Status Structure:**
```perl
$zone = {
    name => "Living Room",
    zoneId => "12345",
    temperatureStatus => {
        temperature => 21.0
    },
    setpointStatus => {
        targetHeatTemperature => 21.0,
        setpointMode => "FollowSchedule" | "PermanentOverride" | "TemporaryOverride"
    }
}
```

Access zones via: `$status_data->{gateways}->[0]->{temperatureControlSystems}->[0]->{zones}`

## Important Notes

- The API uses the EMEA (Europe/Middle East/Africa) endpoint
- Temperature values are in Celsius
- Zone names in responses may contain spaces - convert to lowercase and replace spaces with underscores for identifiers
- `set_heat_setpoint()` setpoint modes: 0 = cancel, 1 = permanent, 2 = set until specified time
- Time values use RFC format (e.g., "2015-09-06T06:00:00Z")
- The module does not currently implement a cool setpoint method (see the FIXME above `set_heat_setpoint()`)
