#!/usr/bin/env perl
#
# Web front end for the tcc-db-logger PostgreSQL database.
#
# Serves a single page (public/index.html) plus a small read-only JSON API.
# Intended to sit behind a reverse proxy (nginx) that provides TLS and auth.
#
# Environment (same names as tcc-db-logger.pl):
#   DB_CONNECTION  e.g. DBI:Pg:dbname=evohome;host=localhost
#   DB_USERNAME
#   DB_PASSWORD
#
# Run:
#   ./tcc-web.pl daemon -m production -l http://*:8080
#
use strict;
use warnings;
use Mojolicious::Lite -signatures;
use DBI;
use POSIX qw(floor);
use JSON::PP ();
use FindBin;

app->static->paths([ "$FindBin::Bin/public" ]);
app->secrets([ 'tcc-web' ]);  # no sessions are used; silences the warning

my $db_connection = $ENV{DB_CONNECTION} or die "DB_CONNECTION environment variable not set\n";
my $db_username   = $ENV{DB_USERNAME}   or die "DB_USERNAME environment variable not set\n";
my $db_password   = $ENV{DB_PASSWORD}   // die "DB_PASSWORD environment variable not set\n";

# Readings arrive every 10 minutes; never bucket finer than that.
use constant MIN_STEP    => 600;
# Aim for at most this many points per series.
use constant MAX_POINTS  => 800;
# Longest window a client may ask for (a little over a year).
use constant MAX_SPAN    => 400 * 86400;
# Readings closer together than this belong to the same fault interval.
use constant FAULT_GAP   => 25 * 60;
# How far back to look for past years on the per-zone view.
use constant MAX_YEARS   => 10;

# --- Database -------------------------------------------------------------

my $dbh;
sub db {
	return $dbh if $dbh && $dbh->ping;
	$dbh = DBI->connect($db_connection, $db_username, $db_password, {
		RaiseError     => 1,
		AutoCommit     => 1,
		PrintError     => 0,
		pg_enable_utf8 => 1,
	});
	# This app only ever reads.
	$dbh->do('SET default_transaction_read_only = on');
	$dbh->do("SET TIME ZONE 'UTC'");
	return $dbh;
}

# Timestamps are stored as UTC in "timestamp without time zone" columns.
my $TS_FROM = q{(to_timestamp(?) AT TIME ZONE 'UTC')};
sub epoch_of ($col) { "extract(epoch from $col)::bigint" }

# --- Helpers --------------------------------------------------------------

sub step_for ($span) {
	my $step = int(($span / MAX_POINTS + MIN_STEP - 1) / MIN_STEP) * MIN_STEP;
	return $step < MIN_STEP ? MIN_STEP : $step;
}

# Validate from/to query params; returns (from, to, step) or renders an error.
sub window_params ($c) {
	my $from = $c->param('from') // '';
	my $to   = $c->param('to')   // '';
	unless ($from =~ /^\d{9,11}$/ && $to =~ /^\d{9,11}$/ && $to > $from && $to - $from <= MAX_SPAN) {
		$c->render(json => { error => 'from and to must be epoch seconds, from < to, span <= 400 days' }, status => 400);
		return;
	}
	return ($from, $to, step_for($to - $from));
}

# Bucket start times covering [from, to).
sub grid ($from, $to, $step) {
	my @t;
	for (my $t = floor($from / $step) * $step; $t < $to; $t += $step) { push @t, $t }
	return \@t;
}

# Spread (bucket => value) onto the grid, null where missing.
sub on_grid ($grid, $values) {
	return [ map { $values->{$_} } @$grid ];
}

sub round1 ($v) { defined $v ? 0 + sprintf('%.2f', $v) : undef }

sub resolve_location ($c) {
	my $locations = db()->selectall_arrayref(
		'SELECT location_id AS id, location_name AS name FROM locations ORDER BY location_id',
		{ Slice => {} });
	my $want = $c->param('location');
	my ($loc) = grep { defined $want && $_->{id} eq $want } @$locations;
	$loc //= $locations->[0];
	return ($loc, $locations);
}

sub zones_for ($location_id) {
	return db()->selectall_arrayref(
		'SELECT zone_id AS id, zone_name AS name FROM zones WHERE location_id = ? ORDER BY zone_id',
		{ Slice => {} }, $location_id);
}

# Battery (and any other) faults as merged intervals per zone and fault type.
sub fault_intervals ($zone_ids, $from, $to) {
	return [] unless @$zone_ids;
	my $in = join ',', ('?') x @$zone_ids;
	my $rows = db()->selectall_arrayref(qq{
		SELECT r.zone_id, z.zone_name, @{[ epoch_of('r.datetime') ]} AS t, f->>'faultType' AS type
		FROM zone_readings r
		JOIN zones z USING (zone_id)
		CROSS JOIN LATERAL jsonb_array_elements(r.metadata->'active_faults') f
		WHERE r.zone_id IN ($in)
		  AND r.datetime >= $TS_FROM AND r.datetime < $TS_FROM
		  AND jsonb_typeof(r.metadata->'active_faults') = 'array'
		ORDER BY r.zone_id, type, r.datetime
	}, { Slice => {} }, @$zone_ids, $from, $to);

	my @out;
	for my $r (@$rows) {
		my $last = $out[-1];
		if ($last && $last->{zone_id} == $r->{zone_id} && $last->{type} eq $r->{type}
			&& $r->{t} - $last->{last} <= FAULT_GAP) {
			$last->{last} = $r->{t};
			$last->{readings}++;
		} else {
			push @out, { zone_id => $r->{zone_id}, zone => $r->{zone_name}, type => $r->{type},
				start => $r->{t}, last => $r->{t}, readings => 1 };
		}
	}
	# A reading covers the 10 minutes after it.
	$_->{end} = delete($_->{last}) + MIN_STEP for @out;
	return \@out;
}

sub outdoor_series ($location_id, $from, $to, $step, $grid) {
	my $rows = db()->selectall_arrayref(qq{
		SELECT floor(extract(epoch from datetime) / ?)::bigint * ? AS t, avg(temperature)
		FROM weather_readings
		WHERE location_id = ? AND datetime >= $TS_FROM AND datetime < $TS_FROM
		GROUP BY 1
	}, undef, $step, $step, $location_id, $from, $to);
	return on_grid($grid, { map { $_->[0] => round1($_->[1]) } @$rows });
}

# --- Routes ---------------------------------------------------------------

get '/' => sub ($c) { $c->reply->static('index.html') };

# Current state: locations, latest reading per zone, latest weather.
get '/api/summary' => sub ($c) {
	my ($loc, $locations) = resolve_location($c);
	return $c->render(json => { error => 'no locations in database' }, status => 404) unless $loc;

	my $zones = db()->selectall_arrayref(qq{
		SELECT z.zone_id AS id, z.zone_name AS name,
		       @{[ epoch_of('r.datetime') ]} AS time,
		       r.temperature, r.target_temperature AS target, r.setpoint_mode AS mode,
		       r.metadata
		FROM zones z
		-- one index probe per zone, rather than reading every row
		CROSS JOIN LATERAL (
			SELECT * FROM zone_readings r WHERE r.zone_id = z.zone_id
			ORDER BY r.datetime DESC LIMIT 1
		) r
		WHERE z.location_id = ?
		ORDER BY z.zone_id
	}, { Slice => {} }, $loc->{id});

	my $json = JSON::PP->new;
	for my $z (@$zones) {
		my $meta = $z->{metadata} ? $json->decode(delete $z->{metadata}) : {};
		delete $z->{metadata};
		$z->{faults}      = [ map { { type => $_->{faultType}, since => $_->{since} } } @{ $meta->{active_faults} || [] } ];
		$z->{system_mode} = $meta->{system_mode};
		$z->{$_} = round1($z->{$_}) for qw(temperature target);
	}

	my $weather = db()->selectrow_hashref(qq{
		SELECT @{[ epoch_of('datetime') ]} AS time, temperature, humidity, condition
		FROM weather_readings WHERE location_id = ?
		ORDER BY datetime DESC LIMIT 1
	}, undef, $loc->{id});
	$weather->{temperature} = round1($weather->{temperature}) if $weather;

	my ($first) = db()->selectrow_array(qq{
		SELECT @{[ epoch_of('min(f.datetime)') ]}
		FROM zones z
		CROSS JOIN LATERAL (
			SELECT r.datetime FROM zone_readings r WHERE r.zone_id = z.zone_id
			ORDER BY r.datetime LIMIT 1
		) f
		WHERE z.location_id = ?
	}, undef, $loc->{id});

	$c->render(json => {
		location  => $loc,
		locations => $locations,
		zones     => $zones,
		weather   => $weather,
		first     => $first,
		now       => time,
	});
};

# All zones for a location over a window.
get '/api/overview' => sub ($c) {
	my ($from, $to, $step) = window_params($c) or return;
	my ($loc) = resolve_location($c);
	return $c->render(json => { error => 'no locations in database' }, status => 404) unless $loc;

	my $zones = zones_for($loc->{id});
	my $grid  = grid($from, $to, $step);

	my $rows = db()->selectall_arrayref(qq{
		SELECT r.zone_id, floor(extract(epoch from r.datetime) / ?)::bigint * ? AS t, avg(r.temperature)
		FROM zone_readings r JOIN zones z USING (zone_id)
		WHERE z.location_id = ? AND r.datetime >= $TS_FROM AND r.datetime < $TS_FROM
		GROUP BY 1, 2
	}, undef, $step, $step, $loc->{id}, $from, $to);

	my %by_zone;
	$by_zone{ $_->[0] }{ $_->[1] } = round1($_->[2]) for @$rows;

	$c->render(json => {
		from    => $from, to => $to, step => $step,
		times   => $grid,
		zones   => [ map { { id => $_->{id}, name => $_->{name}, temperature => on_grid($grid, $by_zone{ $_->{id} } || {}) } } @$zones ],
		outdoor => outdoor_series($loc->{id}, $from, $to, $step, $grid),
		faults  => fault_intervals([ map { $_->{id} } @$zones ], $from, $to),
	});
};

# One zone over a window, with target, outdoor and the same window in past years.
get '/api/zone/:id' => [id => qr/\d+/] => sub ($c) {
	my ($from, $to, $step) = window_params($c) or return;
	my $zone = db()->selectrow_hashref(
		'SELECT zone_id AS id, zone_name AS name, location_id FROM zones WHERE zone_id = ?',
		undef, $c->param('id'));
	return $c->render(json => { error => 'unknown zone' }, status => 404) unless $zone;

	my $grid = grid($from, $to, $step);

	# Shift readings forward by $years so they land on this window's grid.
	my $sth = db()->prepare(qq{
		SELECT floor(extract(epoch from r.datetime + make_interval(years => ?)) / ?)::bigint * ? AS t,
		       avg(r.temperature), avg(r.target_temperature)
		FROM zone_readings r
		WHERE r.zone_id = ?
		  AND r.datetime >= $TS_FROM - make_interval(years => ?)
		  AND r.datetime <  $TS_FROM - make_interval(years => ?)
		GROUP BY 1
	});
	my $fetch = sub ($years) {
		$sth->execute($years, $step, $step, $zone->{id}, $from, $years, $to, $years);
		my (%temp, %target);
		while (my ($t, $temp, $target) = $sth->fetchrow_array) {
			$temp{$t}   = round1($temp);
			$target{$t} = round1($target);
		}
		return (\%temp, \%target);
	};

	my ($temp, $target) = $fetch->(0);

	# Which earlier years have any data at all for this zone?
	my ($first) = db()->selectrow_array(
		qq{SELECT @{[ epoch_of('min(datetime)') ]} FROM zone_readings WHERE zone_id = ?}, undef, $zone->{id});
	my @years;
	if (defined $first) {
		my $this_year  = (gmtime(($from + $to) / 2))[5] + 1900;
		my $first_year = (gmtime($first))[5] + 1900;
		for my $k (1 .. MAX_YEARS) {
			last if $this_year - $k < $first_year - 1;
			my ($t) = $fetch->($k);
			next unless %$t;
			push @years, { years_ago => $k, label => '' . ($this_year - $k), temperature => on_grid($grid, $t) };
		}
	}

	$c->render(json => {
		from        => $from, to => $to, step => $step,
		zone        => { id => $zone->{id}, name => $zone->{name} },
		times       => $grid,
		temperature => on_grid($grid, $temp),
		target      => on_grid($grid, $target),
		outdoor     => outdoor_series($zone->{location_id}, $from, $to, $step, $grid),
		years       => \@years,
		faults      => fault_intervals([ $zone->{id} ], $from, $to),
	});
};

app->start;
