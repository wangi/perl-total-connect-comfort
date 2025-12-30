#!/bin/bash
#
# System setup for Total Connect Comfort data logger
#
# Installs dependencies and configures systemd service
#

set -e

echo "Installing Perl dependencies..."
sudo apt update
sudo apt install -y perl libperl-dev libwww-perl liblwp-protocol-https-perl \
    libjson-perl libdbi-perl libdbd-pg-perl liburi-perl libtext-table-perl git

echo "Installing systemd units..."
sudo cp tcc-db-logger.service tcc-db-logger.timer /etc/systemd/system/
echo ""
echo "Configure credentials with: sudo systemctl edit tcc-db-logger.service"
echo "Remember to update Environment lines!"
echo ""
sudo systemctl daemon-reload
sudo systemctl enable tcc-db-logger.timer

echo ""
echo "Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Run: sudo systemctl edit tcc-db-logger.service"
echo "  2. Add your credentials to the Environment variables"
echo "  3. Run: sudo systemctl start tcc-db-logger.timer"
echo ""
echo "Useful commands:"
echo "  sudo systemctl list-timers tcc-db-logger.timer"
echo "  sudo journalctl -u tcc-db-logger.service -f"
echo ""
