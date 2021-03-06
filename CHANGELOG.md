**05.06.2022**
- Updated information
- Added TODO.md

**26.06.2022**
- Updated the algorithms in "parse_network_data" to a more robust version;
- Ditched the scapy-based approach to dhcp - instead now all connection on the dhcp ports are forwarded between the interfaces (One subshell with tcpdump still gets forked to watch for changes in the configuration);
- Started using signals:
    - intercept Ctrl-C to cleanup before exit;
    - use USR1 for stopping the script from the outside. The needed PID gets saved in an external file;
    - use USR2 to force an error state, which leads to reconfiguration;
- Started using filelocks:
    - one filelock (lock0) to control access to the script itself;
    - one filelock (lock1) to control access to the dhcp data for synchronization between the subshells;
- Use an external file ("loopcontrol") for controlling the endless while loop;
- Updated main logic;
- Development continued on a 64-bit Raspberry Pi OS;
- Various small improvements.

The very first version of this project (my bachelor thesis) can be found at https://github.com/vlzware/AKAD_BEDEN/tree/master/Bachelorarbeit
