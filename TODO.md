## Current limitations/problems

**ARP**
- The script currently answers all ARP requests with its own MAC address. The reason behind this implementation is just because of the simplicity of it. As in the concept of Wireghost, the perfect solution would be a custom software which sends and receives ARP requests in both namespaces on both interfaces and also takes care of updating the ARP table of the device.

**DHCP**
- The later stages of the DHCP communication are not guaranteed to be multicast. Right now the script simply passes all requests from the relevant ports between the interfaces (internal 67 => external 68). Because of the current ARP solution (see the comment on ARP above), this may lead to problems if the DHCP server is not the same device as the gateway and some parts of the request are as unicast.

**Port forwarding**
- Right now the firewall blocks all non-related traffic from the outside. Wireghost needs to have an option for port forwarding for reaching the internal device. As in the concept, when connected directly after the home network router this may be nod needed. The router could, in this case, be bypassed by setting a ssh tunnel (home network device => wireghost => outside device). However, in other use cases port forwarding may be necessary. Implementing this may be more difficult than it seemes, because of the difficulties recognizing the correct traffic coming from the inside network.

**Documentaion**
- The documentation about the concept behind Wireghost and its implementation is very detailed, but in german (my bachelor thesis). The project also evolved and some things are different (see the CHANGELOG). Need to combine the documentation about the concept, about the implementation and about the usage in a single place.

## More features

** Invidious **
- Invidious works perfectly fine on a Pi4 using a docker image. However docker messes up heavily the routing and the firewall on the device where it is installed. So, either find a way to confine docker, or install invidious manually.
