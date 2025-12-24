#!/bin/bash
#
# Setup PostgreSQL database for evohome data logging
#
# Fetches weather data from Google Weather API, gets Honeywell Total Connect
# zone targets and current readings, logs to CSV and database
#
# System setup

set -e

echo "Installing packages..."
sudo apt update
sudo apt install -y perl libperl-dev libwww-perl liblwp-protocol-https-perl \
    libjson-perl libdbi-perl libdbd-pg-perl liburi-perl libtext-table-perl git

mkdir ~/data

echo "Configuring user systemd units..."
sudo cp 26et.{service,timer} 26et.timer /etc/systemd/system/
echo "Using: sudo systemctl edit 26et.service"
echo "Remember to update Environment lines!"
sudo systemctl daemon-reload
sudo systemctl enable 26et.timer

echo "Useful commands: "
echo "systemctl list-timers 26et.timer"
echo "journalctl -u 26et.service -f"
