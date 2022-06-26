#!/usr/bin/env bash

######################################################
#
# TODO: Write a header here...
#
######################################################
# usefull when debugging (from http://wiki.bash-hackers.org/scripting/debuggingtips)
#export PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

MAINDIR="/home/pi/BOX"
. ${MAINDIR}/conf/constants.sh                  # fixed network data

# colorizing output (the colors may vary between terminals)
YELLOW=$(tput setaf 3)
GREEN=$(tput setaf 2)
RED=$(tput setaf 1)
RESET=$(tput sgr0)

TIMESTAMP="date +%F_%T"                         # prefix in the log file
LOGFILE="${MAINDIR}/logs/log"
# uncomment if you like separate log files:
#LOGFILE="${MAINDIR}/logs/log_$(date +%F_%H%M%S)"
ERRMSG="${RED}ERROR${RESET}"                    # for grep-ing the log
MAINLOOPTICK="5"                                # time intervals for the main loop
NFTVARSFILE="${MAINDIR}/conf/variables.nft"     # to be read with nft
SHVARSFILE="${MAINDIR}/conf/variables.sh"       # to be read from bash
STATEFILE="${MAINDIR}/state"                    # save the current state here
MACSFILE="${MAINDIR}/conf/MACs_default.sh"      # original MACs
NFTNS0="${MAINDIR}/rulesets/ns0.nft"            # nftables rulesets
NFTDEFAULT="${MAINDIR}/rulesets/nsdefault.nft"
DUMPFILE="${MAINDIR}/dump"                      # tmp files
ARPREPLY="${MAINDIR}/arpreply"                  # file with arpreply in text form
PCAPACK="udp[247:4] = 0x63350105"               # pcap filter for dhcp ACKs
PIDFILE="${MAINDIR}/PID"                        # PID of this script is saved here
# The access to DHCPDUMP needs to be synchronized! See LOCK1 below
DHCPDUMP="${MAINDIR}/dhcp.pcap"                 # raw DHCP data: captured ACKs.
DHCPTS=$(date '+%s')                            # timestamp: to keep track of ip updates over dhcp
LOOPCONTROL="${MAINDIR}/loopcontrol"            # setting the contents to 0 stops the endless loop
LOCK0="${MAINDIR}/$(basename ${0}).lock0"       # to make sure only one instance of this script is running
LOCK1="${MAINDIR}/$(basename ${0}).lock1"       # to control the access to DHCPDUMP

# file handles for use with flock
declare FD0                                     # for the main lock
declare FD1                                     # for the lock on DHCPDUMP

# working states
STATEBRIDGE="bridge"
STATEWORKING="working"
STATEERROR="error"

# GPIO stuff
LEDREADY=17
LEDBRIDGE=18
LEDWORKING=27
LEDERROR=22
GPIOSWITCH=23
# simple blink
SCRIPTBLINK1="tag 123 w ${LEDWORKING} 1 mils 500 w ${LEDWORKING} 0 mils 500 jmp 123"
# long | short blink
SCRIPTBLINK2="tag 123 w ${LEDWORKING} 1 mils 500 w ${LEDWORKING} 0 mils 500 \
                      w ${LEDWORKING} 1 mils 100 w ${LEDWORKING} 0 mils 100 jmp 123"
# long | short | short | short
SCRIPTBLINK3="tag 123 w ${LEDWORKING} 1 mils 500 w ${LEDWORKING} 0 mils 500 \
                      w ${LEDWORKING} 1 mils 100 w ${LEDWORKING} 0 mils 100 \
                      w ${LEDWORKING} 1 mils 100 w ${LEDWORKING} 0 mils 100 jmp 123"
# quick blink
SCRIPTBLINK4="tag 123 w ${LEDWORKING} 1 mils 100 w ${LEDWORKING} 0 mils 100 jmp 123"
SCRIPTBLINK1ID=0
SCRIPTBLINK2ID=0
SCRIPTBLINK3ID=0
SCRIPTBLINK4ID=0
SCRIPTMAXID=31                                  # the max possible script-id on 32-bit raspi

# available commands
CMDBRIDGE="bridge"
CMDPARSE="parsenet"
CMDFULLON="fullmode"
CMDONBOOT="onboot"
CMDHELP="help"

# paths
NFT="/usr/sbin/nft"

# internal variables
COUNT="100"                                     # number of packets to gather
IFACEA=""                                       # first network interface
IFACEB=""                                       # second network interface
IFACE=""                                        # interface to listen on
MACINT=""                                       # internal device's MAC
MACEXT=""                                       # external device's MAC
IPINT=""                                        # IP of the internal device
IPEXT=""                                        # IP of the external device
IFACEINT=""                                     # interface facing the internal net
IFACEEXT=""                                     # interface facing the external net
NETMASKEXT="32"                                 # netmask external facing iface

######################################################
#
# Helper functions
#
######################################################
function die() {
    echo 0 > "${LOOPCONTROL}"
    killall tcpdump
    resetled
    pigs w "${LEDREADY}" 0
    echo "All done."
    exit
}

# logs data to a file
function log() {
    echo -e "${GREEN}$(${TIMESTAMP})${RESET} ${1}" >> "${LOGFILE}"
    #echo -e "${GREEN}$(${TIMESTAMP})${RESET} ${1}"
}

# set default LED state
function resetled() {
    pigs procs "${SCRIPTBLINK1ID}"
    pigs procs "${SCRIPTBLINK2ID}"
    pigs procs "${SCRIPTBLINK3ID}"
    pigs procs "${SCRIPTBLINK4ID}"
    pigs w "${LEDREADY}" 1 # even on error the box is still on
    pigs w "${LEDBRIDGE}" 0
    pigs w "${LEDWORKING}" 0
    pigs w "${LEDERROR}" 0
}

function error() {
    log "${ERRMSG} ${1}"
    echo "${RED}${1}${RESET}" >&2
    resetled
    pigs w "${LEDERROR}" 1
    echo "${STATEERROR}" > "${STATEFILE}"
}

function setup_GPIO() {
    log "Setting up GPIO ..."
    # clear all previous scripts
    for ((i=0; i<=SCRIPTMAXID; i++)); do
        pigs procd "${i}" > /dev/null 2>&1
    done
    # save the pigs-scripts
    SCRIPTBLINK1ID=$(pigs proc "${SCRIPTBLINK1}")
    SCRIPTBLINK2ID=$(pigs proc "${SCRIPTBLINK2}")
    SCRIPTBLINK3ID=$(pigs proc "${SCRIPTBLINK3}")
    SCRIPTBLINK4ID=$(pigs proc "${SCRIPTBLINK4}")

    # set INPUT/OUTPUT mode on the GPIO-pins
    pigs m "${LEDREADY}" w
    pigs m "${LEDBRIDGE}" w
    pigs m "${LEDWORKING}" w
    pigs m "${LEDERROR}" w

    pigs m "${GPIOSWITCH}" r
    pigs pud "${GPIOSWITCH}" u # activate internal pull-up

    resetled
    log "GPIO setup done."
}

function show_usage() {
    echo "Usage: [sudo] $0 command"
    echo
    echo "Available commands:"
    printf "\t${GREEN}%-15s${RESET} sets the box in bridge mode; single run\n" "${CMDBRIDGE}"
    printf "\t${GREEN}%-15s${RESET} tries to guess the network settings (this should be run from bridge mode); single run\n" "${CMDPARSE}"
    printf "\t${GREEN}%-15s${RESET} sets the IPs, MACs, routes and firewall rules for full operational mode; single run, not watching for dhcp updates\n" "${CMDFULLON}"
    printf "\t${GREEN}%-15s${RESET} endless loop of 'fullmode' with additional saving of the original MACs; watching for dhcp updates\n" "${CMDONBOOT}"
    printf "\t${GREEN}%-15s${RESET} prints this message\n" "${CMDHELP}"
    echo
}

function find_net_devices() {
    IFACES=$(ip -br l | grep -v "lo\|wl\|veth\|br" | cut -d ' ' -f 1)
    IFACESCNT=$(echo "${IFACES}" | wc -l)
    if [[ "${IFACESCNT}" -lt 2 ]]; then
        error "Can't find enough usable network interfaces!"
        return 1
    fi
    IFACEA=$(echo "${IFACES}" | sed -n '1p')
    IFACEB=$(echo "${IFACES}" | sed -n '2p')

    IFACE="${IFACEA}" # doesn't matter if A or B, as we are bridging at this point
    log "Found ${IFACESCNT} ethernet devices. Using ${IFACEA} and ${IFACEB}. Tcpdump will run on ${IFACE}."
}

function save_network_data() {
    echo "Saving network data ..."
    cat <<EOF  > "${NFTVARSFILE}"
define IFACEINT = "${IFACEINT}"
define IFACEEXT = "${IFACEEXT}"
define IPINT = "${IPINT}"
define IPEXT = "${IPEXT}"
define MACINT = "${MACINT}"
EOF

    cat <<EOF > "${SHVARSFILE}"
MACINT="${MACINT}"
MACEXT="${MACEXT}"
IPINT="${IPINT}"
IPEXT="${IPEXT}"
IFACEINT="${IFACEINT}"
IFACEEXT="${IFACEEXT}"
NETMASKEXT="${NETMASKEXT}"
EOF
}

# this function expects that the network interfaces exist and
# are assigned to the namespaces
function set_ip_route_nft() {
    log "Setting IPs, routes and nft rules ..."

    ip netns exec ns0 ip a flush dev "${IFACEINT}"
    ip a flush dev "${IFACEEXT}"
    ip netns exec ns0 ip a flush dev veth0
    ip a flush dev veth1

    ip -n ns0 addr add "${VETH0IP}"/"${NETMASKVETH}" dev veth0
    ip addr add "${VETH1IP}"/"${NETMASKVETH}" dev veth1

    ip -n ns0 addr add "${IPVIRTINT}"/"${NETMASKINT}" dev "${IFACEINT}"
    #ip -n ns0 addr add "${IPEXT}"/32 dev "${IFACEINT}" # TODO
    ip addr add "${IPINT}"/"${NETMASKEXT}" dev "${IFACEEXT}"

    ip -n ns0 route add "${IPINT}"/32 dev "${IFACEINT}"
    ip route add "${IPEXT}"/32 dev "${IFACEEXT}"

    ip -n ns0 route add default via "${VETH1IP}" dev veth0
    ip route add default via "${IPEXT}" dev "${IFACEEXT}"

    save_network_data
    ip netns exec ns0 "${NFT}" -f "${NFTNS0}"
    "${NFT}" -f "${NFTDEFAULT}"
}

function fork_tcpdump() {
    log "Forking tcpdump to watch for dhcp updates ..."
    echo 1 > "${LOOPCONTROL}"
    while true; do
        tcpdump -c 1 -U -i "${IFACEEXT}" -w "${DHCPDUMP}.tmp.pcap" "${PCAPACK} and ether dst ${MACINT}" 2>/dev/null

        flock "${FD1}"
        cp "${DHCPDUMP}.tmp.pcap" "${DHCPDUMP}"
        flock -u "${FD1}"

        if [[ $(cat "${LOOPCONTROL}") == 0 ]]; then
            break
        fi
    done &
}

######################################################
#
# parse_dhcp_data
#
# This checks if new configuration has arrived over DHCP
# and adjust the correspondig variables
#
######################################################
function parse_dhcp_data() {
# Expected result from tcpdump:
#    77.77.77.1.67 > 77.77.77.28.68: BOOTP/DHCP, Reply, length 310, xid 0xcc2df5d4, secs 1, Flags [none]
#          Your-IP 77.77.77.28
#          Server-IP 77.77.77.1
#          Client-Ethernet-Address XX:XX:XX:XX:XX:XX
#          Vendor-rfc1048 Extensions
#            Magic Cookie 0x63825363
#            DHCP-Message (53), length 1: ACK
#            Server-ID (54), length 4: 77.77.77.1
#            Lease-Time (51), length 4: 86400
#            RN (58), length 4: 43200
#            RB (59), length 4: 75600
#            Subnet-Mask (1), length 4: 255.255.255.0
#            BR (28), length 4: 77.77.77.255
#            Domain-Name-Server (6), length 4: 77.77.77.1
#            Hostname (12), length 13: "XXXXXXXXXXXXX"
#            Unknown (252), length 1: 10
#            Default-Gateway (3), length 4: 77.77.77.1

    # for a multiline dump:
    #local DHCPDATA=$(tcpdump -r ${DHCPDUMP} -vns0 "${PCAPACK} and ether dst ${MACINT}" 2>/dev/null | tac | sed "/.68: BOOTP\/DHCP, Reply/Q" | tac)

    flock "${FD1}"
    local DHCPDATA=$(tcpdump -r ${DHCPDUMP} -vns0 "${PCAPACK} and ether dst ${MACINT}" 2>/dev/null)
    flock -u "${FD1}"

    echo "DHCPDATA:"
    echo "${DHCPDATA}"

    if [ -n "${DHCPDATA}" ]; then
        log "Reading dhcp data ..."
        local NEWIP=$(echo "${DHCPDATA}" | grep "Your-IP" | awk '{print $2}')
        local NEWGW=$(echo "${DHCPDATA}" | grep "Default-Gateway" | awk '{print $5}')
        local NEWNM=$(echo "${DHCPDATA}" | grep "Subnet-Mask" | awk '{print $5}')
        if [ -n "${NEWIP}" ] && [ -n "${NEWGW}" ] && [ -n "${NEWNM}" ]; then
            if [[ ! "${NEWIP}" == "${IPINT}" ]] || [[ ! "${NEWGW}" == "${IPEXT}" ]] || [[ ! "${NEWNM}" == "${NETMASKEXT}" ]]; then
                log "New data from dhcp - updating ..."
                IPINT="${NEWIP}"
                IPEXT="${NEWGW}"
                NETMASKEXT="${NEWNM}"
                local MSTATE=$(cat "${STATEFILE}")
                if [[ "${MSTATE}" == "${STATEWORKING}" ]]; then
                    set_ip_route_nft
                fi
            fi
        fi
    fi
}

######################################################
#
# set_bridge: Setup a bridge
#
# TODO: notify the user if there are less than two NICs
#
######################################################
function set_bridge() {
    log "${YELLOW}Setting up a clean state (bridge) ...${RESET}"

    # enable ip forwarding
    echo 1 > /proc/sys/net/ipv4/ip_forward

    echo 0 > "${LOOPCONTROL}"
    killall tcpdump 2>/dev/null

    # clear all nftables rules
    "${NFT}" flush ruleset

    ip link del veth1 2>/dev/null
    ip netns del ns0 2>/dev/null
    ip link del br0 2>/dev/null
    sleep 3 # allow time for shutting the namespace down

    ALLDEVS=$(ip -br link | grep -v "lo\|br\|wlan\|veth" | cut -d ' ' -f 1)
    for DEV in ${ALLDEVS}; do
        ip link set dev "${DEV}" down
        ip link set dev "${DEV}" nomaster
        ip address flush dev "${DEV}"
    done

    # restore MACs
    while IFS= read -r line; do
        I=$(echo "${line}" | cut -d ' ' -f 1)
        M=$(echo "${line}" | cut -d ' ' -f 2)
        ip link set dev "${I}" addr "${M}"
    done < "${MACSFILE}"

    # create a virtual bridge
    ip link add name br0 type bridge
    ip link set dev br0 up

    # assign devives to the bridge
    for DEV in ${ALLDEVS}; do
        ip link set dev "${DEV}" master br0
        ip link set dev "${DEV}" up
    done

    pigs w "${LEDBRIDGE}" 1
    pigs w "${LEDWORKING}" 0
    log "${YELLOW}Bridge setup finished.${RESET}"
}

######################################################
#
# parse_network_data:
# Figure which device is which, also what IPs and MACs
# are being used on the network.Try to guess whom they
# belong to.
#
######################################################
function parse_network_data() {
    log "${YELLOW}Network parsing started ...${RESET}"
    log "Collecting raw data ..."
    resetled
    pigs procr "${SCRIPTBLINK1ID}" # start blink mode 1

    # collect raw data
    # expected data format:
    # MACAddressA > MACAddressB, IPv4, length xxx: IPAddress.Port > IPAddrress.Port: tcp xxx...
    log "Forking one tcpdump to collect incoming data on '${IFACE}' ..."
    tcpdump -i "${IFACE}" -nqte ip -c "${COUNT}" -Q "in" > "${DUMPFILE}".in 2>/dev/null &
    local PID1="$!"
    echo "PID1: ${PID1}"

    # TODO: update the use of blinking modes
    #pigs procs "${SCRIPTBLINK1ID}"
    #pigs procr "${SCRIPTBLINK2ID}" # start blink mode 2

    log "Forking one tcpdump to collect outgoing data on '${IFACE}' ..."
    tcpdump -i "${IFACE}" -nqte ip -c "${COUNT}" -Q "out" > "${DUMPFILE}".out 2>/dev/null &
    local PID2="$!"
    echo "PID2: ${PID2}"

    wait "${PID1}" "${PID2}"

    # Build the combinations MAC/IP for sender and receiver for both directions
    #
    # Inside Device < =1= > BOX < =2= > Gateway/Outside Device/s
    #
    # For 1, the following should be valid:
    #   Traffic into the box:
    #       Source: single MAC (inside device), single IP (inside device)
    #       Destination: single MAC (gateway), multiple IPs
    #   Traffic from the box:
    #       reversed
    # For 2, the above applies mirrored
    #
    # Note: all this relies on the network operating normally (no bogus packets)
    # Note2: the algorithm assumes also that the main traffic is with the internet

    local INFROM INTO OUTFROM OUTTO INFROMCNT INTOCNT OUTFROMCNT OUTTOCNT
    # the additional 'sort | uniq..' at the end is to ensure a sort by most used
    # TODO: make somehow less ugly...
    INFROM=$(awk -F'[ ,]' '{ print $1 " " $9 }' "${DUMPFILE}".in | cut -d '.' -f 1-4 | sed 's/:$//' | sort | uniq -c | sort -rn | cut -c9- | grep -v "255.255.255.255\|224.0.0.251")
    INTO=$(awk -F'[ ,]' '{ print $3 " " $11 }' "${DUMPFILE}".in | cut -d '.' -f 1-4 | sed 's/:$//' | sort | uniq -c | sort -rn | cut -c9-  | grep -v "255.255.255.255\|224.0.0.251")
    OUTFROM=$(awk -F'[ ,]' '{ print $1 " " $9 }' "${DUMPFILE}".out | cut -d '.' -f 1-4 | sed 's/:$//' | sort | uniq -c | sort -rn | cut -c9- | grep -v "255.255.255.255\|224.0.0.251")
    OUTTO=$(awk -F'[ ,]' '{ print $3 " " $11 }' "${DUMPFILE}".out | cut -d '.' -f 1-4 | sed 's/:$//' | sort | uniq -c | sort -rn | cut -c9- | grep -v "255.255.255.255\|224.0.0.251")
    log "INFROM:\n${INFROM}"
    log "INTO:\n${INTO}"
    log "OUTFROM:\n${OUTFROM}"
    log "OUTTO:\n${OUTTO}"

    INFROMCNT=$(echo "${INFROM}" | wc -l)
    INTOCNT=$(echo "${INTO}" | wc -l)
    OUTFROMCNT=$(echo "${OUTFROM}" | wc -l)
    OUTTOCNT=$(echo "${OUTTO}" | wc -l)

    local SECIFACE=""
    if [[ "${IFACE}" == "${IFACEA}" ]]; then
        SECIFACE="${IFACEB}"
    else
        SECIFACE="${IFACEA}"
    fi

    # the collected data was from the "left" interface
    if [ "${INFROMCNT}" -eq 1 ] && [ "${INTOCNT}" -ge 2 ] && [ "${OUTFROMCNT}" -ge 2 ] && [ "${OUTTOCNT}" -eq 1 ]; then
        MACINT=$(echo "${INFROM}" | cut -d ' ' -f 1)
        IPINT=$(echo "${INFROM}" | cut -d ' ' -f 2)
        MACEXT=$(echo "${INTO}" | cut -d ' ' -f 1 | head -n 1)
        IFACEINT="${IFACE}"
        IFACEEXT="${SECIFACE}"
    # the collected data was from the "right" interface
    elif [ "${INFROMCNT}" -ge 2 ] && [ "${INTOCNT}" -eq 1 ] && [ "${OUTFROMCNT}" -eq 1 ] && [ "${OUTTOCNT}" -ge 2 ]; then
        MACINT=$(echo "${INTO}" | cut -d ' ' -f 1)
        IPINT=$(echo "${INTO}" | cut -d ' ' -f 2)
        MACEXT=$(echo "${OUTTO}" | cut -d ' ' -f 1 | head -n 1)
        IFACEINT="${SECIFACE}"
        IFACEEXT="${IFACE}"
    else
        error "Can't determine MACs and IPs!"
        return 1
    fi
    log "MACINT: ${MACINT} | MACEXT: ${MACEXT} | IPINT: ${IPINT}"
    log "${IFACEINT} is facing the INTERNAL device"
    log "${IFACEEXT} is facing the EXTERNAL device"

    # now start wating for an ARP-Reply from the external device
    log "Waiting for an ARP-reply on '${IFACE}' ..."

    pigs procs "${SCRIPTBLINK2ID}"
    pigs procr "${SCRIPTBLINK3ID}" # blink mode 3

    tcpdump -i "${IFACE}" -nqte -c 1 arp and arp[6:2] == 2 and ether src "${MACEXT}" > "${ARPREPLY}" 2>/dev/null
    IPEXT=$(cut -d ' ' -f 8 "${ARPREPLY}")
    log "IPEXT: ${IPEXT}"

    pigs w "${LEDBRIDGE}" 1
    pigs w "${LEDWORKING}" 0
    pigs procs "${SCRIPTBLINK3ID}"
    log "${YELLOW}Parsing finished.${RESET}"
}

######################################################
#
# set_full_mode: Setting devices, routes and firewall
#
######################################################
function set_full_mode() {
    log "${YELLOW}Setting devices, routes and firewall rules ...${RESET}"
    resetled
    pigs procr "${SCRIPTBLINK4ID}" # blink mode 4

    echo 1 > /proc/sys/net/ipv4/ip_forward

    log "Shutting network devices off ..."
    ip link set dev "${IFACEINT}" down
    ip link set dev "${IFACEEXT}" down
    ip link set dev "${IFACEINT}" nomaster
    ip link set dev "${IFACEEXT}" nomaster
    ip link del br0 # TODO: rewrite with some check

    log "Mirroring the MACs on the opposite sides ..."
    ip link set dev "${IFACEINT}" addr "${MACEXT}"
    ip link set dev "${IFACEEXT}" addr "${MACINT}"

    log "Creating a new namespace and the virtual devices pair ..."
    # namespace ns0 is facing the internal net,
    # the default namespace - the external one
    ip netns add ns0
    ip link add veth0 type veth peer name veth1
    ip link set veth0 netns ns0
    ip link set "${IFACEINT}" netns ns0

    log "Bringing all devices up ..."
    ip -n ns0 link set dev veth0 up
    ip link set dev veth1 up
    ip -n ns0 link set dev "${IFACEINT}" up
    ip link set dev "${IFACEEXT}" up

    set_ip_route_nft

    log "Switching proxy_arp on ..."
    # TODO: check and adjust
    #ip netns exec ns0 bash -c "echo 1 > /proc/sys/net/ipv4/conf/"${IFACEINT}"/proxy_arp_pvlan"
    ip netns exec ns0 bash -c "echo 1 > /proc/sys/net/ipv4/conf/${IFACEINT}/proxy_arp"

    # (Re)starting DHCP server
    #stop_dhcp
    #start_dhcp

    # use our pi.hole dns
    # EDIT: manually edited and protected resolv.conf (chattr +i)
    #echo "nameserver 127.0.0.1" > /etc/resolv.conf
    #sudo systemctl restart systemd-resolved.service

    pigs procs "${SCRIPTBLINK4ID}"
    pigs w "${LEDBRIDGE}" 0
    pigs w "${LEDWORKING}" 1
    log "${YELLOW}Devices, routes and firewall setup finisched.${RESET}"
}

######################################################
#
# Wrappers
#
# TODO: make error checking actually meaningfull...
######################################################
function enter_bridge_mode() {
    log "Entering bridge mode ..."
    if ! set_bridge; then
        error "Error in 'set_bridge'"
        return 1
    fi
    echo "${STATEBRIDGE}" > "${STATEFILE}"
}

function enter_full_mode() {
    log "Entering full mode ..."
    if ! set_full_mode; then
        error "Error in 'set_full_mode'"
        return 1
    fi
    echo "${STATEWORKING}" > "${STATEFILE}"
}

######################################################
#
# Main logic
# Note: all options except CMDONBOOT are meant for debugging
#   When everything is fine this script should be called from
#   cron on @reboot
#
######################################################
exec {FD0}>"${LOCK0}" || { echo "Can't aquire file handle on ${LOCK0}!" >&2; exit 1; }
if ! flock -xn "${FD0}"; then
    echo "Another instance of ${0} is running!" >&2
    exit 1
fi

exec {FD1}>"${LOCK1}" || { echo "Can't aquire file handle on ${LOCK1}!" >&2; exit 1; }

if [ "$(whoami)" != "root" ]; then
    echo -e "ERROR: Run this as root!" >&2
    exit 1
fi

CMD="${1}"
if [[ "$#" -eq 0 ]] || [[ "${CMD}" == "help" ]]; then
    show_usage
    exit 1
fi

case "${CMD}" in
    "${CMDPARSE}" | "${CMDONBOOT}" | "${CMDBRIDGE}" | "${CMDFULLON}" )
        : ;;
    *)
        echo
        echo "${ERRMSG}: unknown command '${1}'" >&2
        echo
        show_usage
        exit 1
        ;;
esac

# Setup
# TODO: make some kind of setup/first run
#systemctl mask dhcpcd.service
#systemctl mask nftables.service
systemctl stop dhcpcd.service
systemctl stop nftables.service
trap 'die' SIGINT # Ctrl+C
trap 'die' USR1 # for stopping from outside the script
trap 'error "Interrupted!"' USR2
echo $$ > "${PIDFILE}"
echo 0 > "${DHCPDUMP}"
echo 0 > "${LOOPCONTROL}"
echo "${STATEBRIDGE}" > "${STATEFILE}"          # default state is bridge mode

# save the original MACs
if [[ "${CMD}" == "${CMDONBOOT}" ]]; then
    log "${YELLOW}Device rebooted${RESET}"
    if [ ! -f "${MACSFILE}" ]; then
        ip -br link | grep -v "lo\|wl" | awk -F'[ ]+' '{print $1 " " $3}' > "${MACSFILE}"
        log "MACs saved"
    fi
fi
log "${YELLOW}$0 started ...${RESET}"

# GPIO should always be started
if ! setup_GPIO; then
    error "Error in 'setup_GPIO'"
    exit 1
fi

# Clean state (bridge mode) should always be the initial state
if ! enter_bridge_mode; then
    exit 1
fi

# We need the available devices in any case
log "Reading net devices ..."
if ! find_net_devices; then
    error "Error in 'find_net_devices'"
    exit 1
fi

# Both the pi and the user need some time
if [[ "${CMD}" == "${CMDONBOOT}" ]]; then
    sleep 20
fi

# Single bridge mode does not need parsing and the full cycle calls parse on its own
if [[ ! "${CMD}" == "${CMDBRIDGE}" ]] && [[ ! "${CMD}" == "${CMDONBOOT}" ]]; then
    if ! parse_network_data; then
        exit 1
    fi
fi

if [[ "${CMD}" == "${CMDFULLON}" ]]; then
    if ! enter_full_mode; then
        exit 1
    fi
fi

# Up until now everything needed should be ready (GPIO, devices, network data)
if [[ "${CMD}" == "${CMDONBOOT}" ]]; then
    log "Going in the interactive loop ..."
    sp='.....'
    sc=0
    while true; do
        READINPUT=$(pigs r "${GPIOSWITCH}")
        MSTATE=$(cat "${STATEFILE}")

        # try to recover on error: go to bridge mode
        if [[ "${MSTATE}" == "${STATEERROR}" ]]; then
            echo "ERROR RECOVERY started ..."
            sc=0
            until enter_bridge_mode; do
                :
            done
        fi

        # bridge mode
        if [[ "${READINPUT}" -eq 1 ]] && [[ "${MSTATE}" == "${STATEWORKING}" ]]; then
            echo "User command: Entering bridge mode"
            sc=0
            enter_bridge_mode
        fi

        # full mode
        if [[ "${READINPUT}" -eq 0 ]] && [[ "${MSTATE}" == "${STATEBRIDGE}" ]]; then
            echo "User command: Entering full mode"
            sc=0
            if ! parse_network_data; then
                error "Error in 'parse_network_data'"
            else
                fork_tcpdump
                enter_full_mode
            fi
        fi

        printf '\rSleeping %s    \r' "${sp:0:++sc}"
        ((sc==${#sp})) && sc=0
        sleep "${MAINLOOPTICK}"

        # the tcpdump writes cptured ACKs to the DHCPDUMP file
        # we use the file's timestamp as a reminder to update the data
        flock "${FD1}"
        TMP=$(date -r "${DHCPDUMP}" '+%s')
        flock -u "${FD1}"
        if ((DHCPTS < TMP)); then
            DHCPTS="${TMP}"
            parse_dhcp_data
        fi
    done
fi
