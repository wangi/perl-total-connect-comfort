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
mkdir -p ~/.config/systemd/user
cp 26et.service 26et.timer ~/.config/systemd/user/
echo "vi ~/.config/systemd/user/26et.service"
echo "Remember to update Environment lines!"
systemctl --user daemon-reload
systemctl --user enable --now 26et.timer

echo "Useful commands: "
echo "systemctl --user list-timers 26et.timer"
echo "journalctl --user -u 26et.service -f"
