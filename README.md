perl-total-connect-comfort
==========================

A Perl module that wraps the [Honeywell Total Connect Comfort][htcc] API. Allows you to query room temperatures and view other details like setpoints.

[htcc]: https://infoeu.mytotalconnectcomfort.com/gb

## Usage

Call the test script with ./test_api.pl *username* *password* (don't forget to single quote that password if it contains symbols).

## Database logging
**[tcc-db-logger.pl](tcc-db-logger.pl)**: Production data logger
- Fetches weather data from Google Weather API (Location-specific weather coordinates via `LATLON_<location_id>` environment variables)
- Logs zone temperatures and targets to PostgreSQL database (normalized schema)
- Runs periodically via systemd timer to track historical data
- Supports multiple locations with dynamic zone discovery

## Web front end
**[web/tcc-web.pl](web/tcc-web.pl)**: browser view of the logged data (Mojolicious, read-only)
- Overview: every zone's temperature over the last 24 hours, week or month, with outdoor temperature; page backwards and forwards in time
- Per-zone view: temperature, target, outdoor temperature, shading where the zone was calling for heat, and the same period in previous years
- Current and historical low-battery warnings, and a warning if the logger has stopped
- Plain HTTP on port 8080 by default; put TLS and authentication in front of it with a reverse proxy

## Cacti

Also includes Cacti scripts and templates to make setting up Cacti monitoring simple.

I've written a [Cacti setup guide](http://will.dollman.org/2014/10/03/totalconnectcomfort-and-cacti-setup-guide/) (because sadly it's not *that* simple).
