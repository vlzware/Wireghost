#!/usr/bin/env bash
for IFACE in $(find "/proc/sys/net/ipv4/conf/" -name "proxy_arp*" | sort); do
    echo "${IFACE} : $(cat ${IFACE})"
done
