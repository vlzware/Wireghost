#!/usr/bin/env bash
echo "0 */4 * * * pi /home/pi/duckdns/duck.sh >/dev/null 2>&1" | sudo tee /etc/cron.d/duckdns
