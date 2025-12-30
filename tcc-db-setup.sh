#!/bin/bash
#
# Setup PostgreSQL database for evohome data logging (Version 2 - Normalized Schema)
#

set -e

echo "Installing PostgreSQL..."
sudo apt-get update
sudo apt-get install -y postgresql postgresql-client

echo "Starting PostgreSQL service..."
sudo systemctl enable postgresql
sudo systemctl start postgresql

# Database credentials (change these!)
DB_NAME="evohome"
DB_USER="evohome"
DB_PASS="evohome"

echo "Creating database and user..."
sudo -u postgres psql <<EOF
-- Create user if not exists
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
    CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';
  END IF;
END
\$\$;

-- Create database if not exists
SELECT 'CREATE DATABASE ${DB_NAME} OWNER ${DB_USER}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB_NAME}')\gexec

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
EOF

echo "Creating normalized schema..."
sudo -u postgres psql -d ${DB_NAME} <<EOF
-- Create locations table
CREATE TABLE IF NOT EXISTS locations (
    location_id BIGINT PRIMARY KEY,
    location_name VARCHAR(100),
    street_address VARCHAR(200),
    city VARCHAR(100),
    postcode VARCHAR(20),
    country VARCHAR(50),
    latitude NUMERIC(10, 7),
    longitude NUMERIC(10, 7),
    created_at TIMESTAMP DEFAULT NOW(),
    last_seen TIMESTAMP DEFAULT NOW()
);

-- Create zones table
CREATE TABLE IF NOT EXISTS zones (
    zone_id BIGINT PRIMARY KEY,
    location_id BIGINT NOT NULL REFERENCES locations(location_id),
    zone_name VARCHAR(50) NOT NULL,
    display_name VARCHAR(100),
    created_at TIMESTAMP DEFAULT NOW(),
    last_seen TIMESTAMP DEFAULT NOW(),
    UNIQUE(location_id, zone_name)
);

-- Create weather readings table
CREATE TABLE IF NOT EXISTS weather_readings (
    datetime TIMESTAMP NOT NULL,
    location_id BIGINT NOT NULL REFERENCES locations(location_id),
    temperature REAL,
    humidity SMALLINT,
    condition VARCHAR(32),
    PRIMARY KEY (datetime, location_id)
);

-- Create zone readings table
CREATE TABLE IF NOT EXISTS zone_readings (
    datetime TIMESTAMP NOT NULL,
    zone_id BIGINT NOT NULL REFERENCES zones(zone_id),
    temperature REAL,
    target_temperature REAL,
    setpoint_mode VARCHAR(32),
    metadata JSONB,
    PRIMARY KEY (datetime, zone_id)
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_zone_readings_zone_datetime ON zone_readings(zone_id, datetime DESC);
CREATE INDEX IF NOT EXISTS idx_zone_readings_datetime ON zone_readings(datetime DESC);
CREATE INDEX IF NOT EXISTS idx_weather_readings_location_datetime ON weather_readings(location_id, datetime DESC);
CREATE INDEX IF NOT EXISTS idx_zones_location ON zones(location_id);

-- Grant privileges to user
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${DB_USER};
GRANT USAGE ON SCHEMA public TO ${DB_USER};
EOF

echo ""
echo "Database setup complete!"
echo ""
echo "Database connection details:"
echo "  DB_CONNECTION=\"DBI:Pg:dbname=${DB_NAME};host=localhost\""
echo "  DB_USERNAME=\"${DB_USER}\""
echo "  DB_PASSWORD=\"${DB_PASS}\""
echo ""
echo "Add these to your /etc/systemd/system/tcc-db-logger.service file"
echo ""
echo "To install the systemd service:"
echo "  sudo cp tcc-db-logger.service tcc-db-logger.timer /etc/systemd/system/"
echo "  sudo systemctl edit tcc-db-logger.service  # Add credentials"
echo "  sudo systemctl daemon-reload"
echo "  sudo systemctl enable --now tcc-db-logger.timer"
echo ""
