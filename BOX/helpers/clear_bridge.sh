#!/usr/bin/env bash

if [ "$(whoami)" != "root" ]; then
    >&2 echo -e "ERROR: Run this as root!" >&2
    exit 1
fi

ip link set dev eth0 nomaster
ip link set dev eth1 nomaster
ip link del br0
ip link set dev eth0 down
ip link set dev eth1 down
ip address flush dev eth0
ip address flush dev eth1
ip link set dev eth0 up
ip link set dev eth1 up

systemctl restart dhcpcd.service
