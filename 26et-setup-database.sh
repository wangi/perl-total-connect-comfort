#!/bin/bash
#
# Setup PostgreSQL database for evohome data logging
#
# Fetches weather data from Google Weather API, gets Honeywell Total Connect
# zone targets and current readings, logs to CSV and database
#
# System setup

set -e

# Database credentials (change these!)
DB_NAME="evohome"
DB_USER="evohome_user"
DB_PASS="change_this_password"

echo "Installing PostgreSQL..."
sudo apt update
sudo apt install -y postgresql postgresql-client

echo "Starting PostgreSQL service..."
sudo systemctl enable postgresql
sudo systemctl start postgresql

echo "Creating database and user..."
sudo -u postgres psql <<EOF
-- Create user
CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';

-- Create database
CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
EOF

echo "Creating schema..."
sudo -u postgres psql -d ${DB_NAME} <<EOF
-- Create the evohome table
CREATE TABLE IF NOT EXISTS public.evohome (
    datetime TIMESTAMP WITH TIME ZONE NOT NULL,
    humidity SMALLINT,
    temperature REAL,
    weather CHARACTER VARYING(32),
    temp_living REAL,
    temp_living_target REAL,
    temp_kitchen REAL,
    temp_kitchen_target REAL,
    temp_toilet REAL,
    temp_toilet_target REAL,
    temp_utility REAL,
    temp_utility_target REAL,
    temp_freya REAL,
    temp_freya_target REAL,
    temp_spare REAL,
    temp_spare_target REAL,
    temp_landing REAL,
    temp_landing_target REAL,
    temp_master REAL,
    temp_master_target REAL,
    temp_study REAL,
    temp_study_target REAL,
    PRIMARY KEY (datetime)
);

-- Create index on datetime
CREATE INDEX IF NOT EXISTS evohome_pkey ON public.evohome USING btree (datetime);

-- Grant privileges to user
GRANT ALL PRIVILEGES ON TABLE public.evohome TO ${DB_USER};

-- Grant usage on schema
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
echo "Add these to your service file"
echo ""
