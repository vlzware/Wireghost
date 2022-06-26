#!/usr/bin/env bash

if [ "$(whoami)" != "root" ]; then
    >&2 echo -e "ERROR: Run this as root!"
    exit 1
fi

set -xe

cd /home/pi/cloudflared

# get and install the "cloudflared" binary
#wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm
wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64
#cp ./cloudflared-linux-arm /usr/local/bin/cloudflared
cp ./cloudflared-linux-arm64 /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared
cloudflared -v

# add new user for use with cloudflared
useradd -s /usr/sbin/nologin -r -M cloudflared
cp etc.default.cloudflared /etc/default/cloudflared
chown cloudflared:cloudflared /etc/default/cloudflared
chown cloudflared:cloudflared /usr/local/bin/cloudflared

# setup as system service
cp etc.systemd.system.cloudflared.service /etc/systemd/system/cloudflared.service
systemctl enable cloudflared
systemctl start cloudflared

# setup updates
cp update_cloudflared.sh /etc/cron.weekly/cloudflared-updater
chmod +x /etc/cron.weekly/cloudflared-updater
chown root:root /etc/cron.weekly/cloudflared-updater

# test
dig @127.0.0.1 -p 5053 google.com
