Switch Configuration Examples for Microsoft SDN
=======
### Switch model: Mellanox SN2700
### OS: Cumulus Linux 3.7.3
### Topology: Two top-of-rack (TOR) switches with a L3 topology connected to a Spine using eBGP

       +--------+ +--------+
       | Spine1 | | Spine2 |   BGP ASN: 64807
       +--------+ +--------+
            |  \   /  |
            |   \ /   |
            |    X    |
            |   / \   |
    .Rack1..|  /   \  |...............................
    .  +--------+ +--------+                         .
    .  |  TOR1  |=|  TOR2  |   BGP ASN TOR1: 64651   .  ... TORs in additional racks 
    .  +--------+ +--------+   BGP ASN TOR2: 64651   .       can be added to the 
    .       |         |                              .        same Spine pair.
    .       |         |                              .
    .       |         |                              .
    .       |         |                              .
    .       |         |                              .
    .  +-------------------+                         .
    .  |   Hyper-V Hosts   |-+    BGP ASNs:          .
    .  +-------------------+ |-+   MUX=64652         .
    .    +-------------------+ |   GW =64652         .
    .      +-------------------+                     .
    ..................................................       

These sample configuration files use the following subnets:
<table>
 <tr>
  <td>**Subnet name**</td>
  <td>**VLAN ID**</td>
  <td>**Subnet**</td>
  <td>**Assignments**</td>
 </tr>
 <tr>
  <td>TOR1 Loopback</td>
  <td>NA</td>
  <td>10.0.1.73/32</td>
  <td>10.0.1.73 - TOR1</td>
 </tr> 
 <tr>
  <td>TOR2 Loopback</td>
  <td>NA</td>
  <td>10.0.1.74/32</td>
  <td>10.0.1.74 - TOR2</td>
 </tr>
 <tr>
  <td>SPINE1 Loopback</td>
  <td>NA</td>
  <td>10.0.1.75/32</td>
  <td>10.0.1.75 - SPINE1</td>
 </tr> 
 <tr>
  <td>SPINE2 Loopback</td>
  <td>NA</td>
  <td>10.0.1.76/32</td>
  <td>10.0.1.76 - SPINE2</td>
 </tr>  
 <tr>
  <td>Uplink TOR1 to Spine1</td>
  <td>NA</td>
  <td>NA</td>
  <td>BGP unnumbered</td>
 </tr>
  <tr>
  <td>Uplink TOR1 to Spine2</td>
  <td>NA</td>
  <td>NA</td>
  <td>BGP unnumbered</td>
 </tr>
 <tr>
  <td>Uplink TOR2 to Spine1</td>
  <td>NA</td>
  <td>NA</td>
  <td>BGP unnumbered</td>
 </tr>
 <tr>
  <td>Uplink TOR2 to Spine2</td>
  <td>NA</td>
  <td>NA</td>
  <td>BGP unnumbered</td>
 </tr>
 <tr>
  <td>Management</td>
  <td>7</td>
  <td>10.0.3.0/26</td>
  <td>10.0.3.1 - Gateway<br />10.0.3.2 - TOR1<br />10.0.3.3 - TOR2</td>
 </tr>
 <tr>
  <td>Storage 1</td>
  <td>8</td>
  <td>10.0.10.0/26</td>
  <td>10.0.10.1 - Gateway<br />10.0.10.2 - TOR1<br />10.0.10.3 - TOR2</td>
 </tr>
 <tr>
  <td>Storage 2</td>
  <td>9</td>
  <td>10.0.10.64/26</td>
  <td>10.0.10.65 - Gateway<br />10.0.10.66 - TOR1<br />10.0.10.67 - TOR2</td>
 </tr> 
  <tr>
  <td>Transit</td>
  <td>10</td>
  <td>10.0.10.128/26</td>
  <td>10.0.0.129 - Gateway<br />10.0.0.130 - TOR1<br />10.0.0.131 - TOR2</td>
 </tr> 
  <tr>
  <td>HNV PA</td>
  <td>11</td>
  <td>10.0.11.0/25</td>
  <td>10.0.11.1 - Gateway<br />10.0.11.2 - TOR1<br />10.0.11.3 - TOR2</td>
 </tr> 
  <tr>
  <td>Deploy</td>
  <td>Untagged</td>
  <td>10.0.10.192/26</td>
  <td>10.0.10.193 - Gateway<br />10.0.0.194 - TOR1<br />10.0.0.195 - TOR2</td>
 </tr> 
</table>

In addition, each switch device has a connection to an additional switch (not shown here) which gives management access to the device.  So in addition, a management IP address is also assigned to the device on this externally configured switch management subnet:

<table>
<tr><td>Device</td><td>IP Address</td><td>Gateway</td></tr>
<tr><td>TOR1</td><td>10.0.0.149/28</td><td>10.0.0.145</td></tr>
<tr><td>TOR2</td><td>10.0.0.150/28</td><td>10.0.0.145</td></tr>
<tr><td>SPINE1</td><td>10.0.0.151/28</td><td>10.0.0.145</td></tr>
<tr><td>SPINE2</td><td>10.0.0.152/28</td><td>10.0.0.145</td></tr>
</table>
 
When modifying the configuration files you will need to modify them to use the subnets you've allocoated from yoru  

## Top of rack switch (TOR) configuration file details

This section will walk through details on the parts of the configuraiton file you will need to change or be aware of:

Update the host name to match your organization's naming convention:

      net add hostname TOR1



### Physical port configuration

Each physical port must be configured to act as a switchport and have the mode set to trunk to allow multiple VLANs to be sent to the host.  For RDMA Priority-flow-control must be on and the service-policy must point to the input queue that you will define below.

<table>
 <tr>
  <td>Port</td>
  <td>Usage</td>
 </tr>
 <tr>
  <td>1-16</td>
  <td>Hpyer-V Hosts</td>
 </tr>
 <tr>
  <td>17-18</td>
  <td>clag Peerlinks</td>
 </tr>
 <tr>
  <td>31-32</td>
  <td>Uplinks to Spines</td>
 </tr>
</table>

Update each Ethernet port to match the above wherever there is a Hyper-V host connected.

    net add interface swp1-18,swp31-32 mtu 9216

The management port (eth0) has an ip address assigned directly on it.  This address is allocated from your switch management subnet.

    net add interface eth0 ip address 10.0.0.149/28
    net add interface eth0 ip gateway 10.0.0.145
    net add interface eth0 vrf mgmt


All switches require a loopback interface with a /32 subnet assigned to it. Update the loopback sections to match your assigned loopback addresses.
The loopback address will also be used as BGP router ID and will be advertised into BGP so it will shown within a traceroute log.

    net add loopback lo ip address 10.0.1.73/32

BGP is utilized extensively by the Microsoft SDN infrastructure.  While it is only required for peering between the Muxes/Gateways and the top-of-rack switches, it is also useful for peering to Spineregate switches and into the rest of the datacenter as it provides dyanmic route updates and keepalives for the detection of dead links.<br />

Each layer of a network that provides access to the same set of subnets is assigned a uniqe ASN.  Since all Spine switches that are working together for a common set of racks can be equally used for routing, they all share the same ASN.  In this example this Spineregate layer is assigned 64807.

Each device that is to act as a peer needs to be added to the BGP router to allow the dynamic exchange of routes.  Each link to a Spine switch is added here.

    net add bgp autonomous-system 64651
    net add bgp router-id 10.0.1.73/32
    net add bgp bestpath as-path multipath-relax
    net add bgp neighbor ISL peer-group
    net add bgp neighbor ISL remote-as external
    net add bgp neighbor MSSDN peer-group
    net add bgp neighbor MSSDN remote-as 64652
    net add bgp neighbor swp31 interface peer-group ISL
    net add bgp neighbor swp32 interface peer-group ISL
    net add bgp listen range 10.0.10.128/26 peer-group MSSDN
    net add bgp ipv4 unicast network 10.0.1.73/32 
    net add bgp ipv4 unicast redistribute connected route-map ACCEPT_DC_LOCAL
    net add bgp ipv6 unicast neighbor ISL activate
 
For the SDN gateways (Software Load Balancer (SLB) MUX and Multi-tenant gateways) since these will be scaled out it is not practical to add each one individually here, so instead we create a peer group which tells the switch that any member of this subnet can peer. 
 
    

NTP servers are required to give the switch an accurate clock.  Update this section with a set of NTP servers provided by your organization.  If you don't have a dedicated NTP server, an Active Directory server can be used as an NTP server.  Add or remove rows here to match the number of servers you have.

    net add time ntp server 10.0.2.7 iburst
    
Set the timezone to match your local timezone.

    net add time zone Europe/Zurich


### TOR Redundancy

In order for the two TOR switches to provide the same L2 network to the Hyper-V hosts, they must have (2) dedicated physical links directly connecting each other together.  Since inbound traffic can arrive on either TOR, but must be sent on the physical link to the host where the MAC address was learned, about 50% of the inbound traffic for the hyper-v hosts will traverse the direct connection between the hosts. 


    net add interface peerlink.4094 clag backup-ip 10.0.0.150/28 vrf mgmt
    net add bond peerlink bond slaves swp17,swp18
    net add interface peerlink.4094 clag peer-ip 169.254.1.2
    net add interface peerlink.4094 clag sys-mac 44:38:39:ff:00:01
    net add interface peerlink.4094 ip address 169.254.1.1/30



### VLAN Definition

Each VLAN that is available for the host to use is defined as a VLAN interface.

Update the IP address and subnet to match the subnets that you've allocated for your deployment.  Make sure that the IP address specified is different for each TOR.  In this example TOR1 uses the second address in the subnet and TOR2 uses the third address.  The first address will be used for the redundant router (VRR). For VRR to work properly a unique MAC address is defined for each VLAN virtual IP address. 

    net add bridge bridge ports peerlink,swp1-16

    net add vlan 7 ip address 10.0.3.2/26
    net add vlan 7 ip address-virtual 00:00:5e:00:01:01 10.0.3.1/26
    net add vlan 7 vlan-id 7

    net add vlan 8 ip address 110.0.10.2/26
    net add vlan 8 ip address-virtual 00:00:5e:00:01:02 10.0.10.1/26
    net add vlan 8 vlan-id 8

    net add vlan 9 ip address 110.0.10.66/26
    net add vlan 9 ip address-virtual 00:00:5e:00:01:03 10.0.10.65/26
    net add vlan 9 vlan-id 9

    net add vlan 10 ip address 10.0.10.130/26
    net add vlan 10 ip address-virtual 00:00:5e:00:01:04 10.0.10.129/26
    net add vlan 10 vlan-id 10

    net add vlan 11 ip address 10.0.11.2/25
    net add vlan 11 ip address-virtual 00:00:5e:00:01:05 10.0.11.1/25
    net add vlan 11 vlan-id 11






### Quality of Service for RDMA

For RDMA based storage to function properly, traffic classes must be defined to separate the RDMA based storage traffic from the rest of the host and VM traffic.  This example configures the switch to use 802.1p (-PriorityValue8021Action parameter with new-netqospolicy on the host) value 3 and DSCP (-DSCPAction parameter with new-netqospolicy on the host) value 42 for storage traffic classification. 

The confiugration is done within a file called "traffic.conf" which hast to be copied to "/etc/cumulus/datapath/"

    #
    # /etc/cumulus/datapath/traffic.conf
    # Copyright 2014, 2015, 2016, 2017, Cumulus Networks, Inc.  All rights reserved.
    #

    # packet header field used to determine the packet priority level
    # fields include {802.1p, dscp}
    traffic.packet_priority_source_set = [802.1p,dscp]

    # packet priority source values assigned to each internal cos value
    # internal cos values {cos_0..cos_7}
    # (internal cos 3 has been reserved for CPU-generated traffic)
    #
    # 802.1p values = {0..7}
    traffic.cos_0.priority_source.8021p = [0]
    traffic.cos_1.priority_source.8021p = [1]
    traffic.cos_2.priority_source.8021p = [2]
    traffic.cos_3.priority_source.8021p = []
    traffic.cos_4.priority_source.8021p = [3]
    traffic.cos_5.priority_source.8021p = [4,5]
    traffic.cos_6.priority_source.8021p = [6]
    traffic.cos_7.priority_source.8021p = [7]

    # dscp values = {0..63}
    traffic.cos_0.priority_source.dscp = [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63]
    traffic.cos_1.priority_source.dscp = []
    traffic.cos_2.priority_source.dscp = []
    traffic.cos_3.priority_source.dscp = []
    traffic.cos_4.priority_source.dscp = [42]
    traffic.cos_5.priority_source.dscp = []
    traffic.cos_6.priority_source.dscp = []
    traffic.cos_7.priority_source.dscp = []

    # remark packet priority value
    # fields include {802.1p, dscp}
    traffic.packet_priority_remark_set = []

    # packet priority remark values assigned from each internal cos value
    # internal cos values {cos_0..cos_7}
    # (internal cos 3 has been reserved for CPU-generated traffic)
    #
    # 802.1p values = {0..7}
    #traffic.cos_0.priority_remark.8021p = [0]
    #traffic.cos_1.priority_remark.8021p = [1]
    #traffic.cos_2.priority_remark.8021p = [2]
    #traffic.cos_3.priority_remark.8021p = [3]
    #traffic.cos_4.priority_remark.8021p = [4]
    #traffic.cos_5.priority_remark.8021p = [5]
    #traffic.cos_6.priority_remark.8021p = [6]
    #traffic.cos_7.priority_remark.8021p = [7]

    # dscp values = {0..63}
    #traffic.cos_0.priority_remark.dscp = [0]
    #traffic.cos_1.priority_remark.dscp = [8]
    #traffic.cos_2.priority_remark.dscp = [16]
    #traffic.cos_3.priority_remark.dscp = [24]
    #traffic.cos_4.priority_remark.dscp = [32]
    #traffic.cos_5.priority_remark.dscp = [40]
    #traffic.cos_6.priority_remark.dscp = [48]
    #traffic.cos_7.priority_remark.dscp = [56]

    # source.port_group_list = [source_port_group]
    # source.source_port_group.packet_priority_source_set = [dscp]
    # source.source_port_group.port_set = swp1-swp4,swp6
    # source.source_port_group.cos_0.priority_source.dscp = [0,1,2,3,4,5,6,7]
    # source.source_port_group.cos_1.priority_source.dscp = [8,9,10,11,12,13,14,15]
    # source.source_port_group.cos_2.priority_source.dscp = [16,17,18,19,20,21,22,23]
    # source.source_port_group.cos_3.priority_source.dscp = [24,25,26,27,28,29,30,31]
    # source.source_port_group.cos_4.priority_source.dscp = [32,33,34,35,36,37,38,39]
    # source.source_port_group.cos_5.priority_source.dscp = [40,41,42,43,44,45,46,47]
    # source.source_port_group.cos_6.priority_source.dscp = [48,49,50,51,52,53,54,55]
    # source.source_port_group.cos_7.priority_source.dscp = [56,57,58,59,60,61,62,63]

    # remark.port_group_list = [remark_port_group]
    # remark.remark_port_group.packet_priority_remark_set = [dscp]
    # remark.remark_port_group.port_set = swp1-swp4,swp6
    # remark.remark_port_group.cos_0.priority_remark.dscp = [0]
    # remark.remark_port_group.cos_1.priority_remark.dscp = [8]
    # remark.remark_port_group.cos_2.priority_remark.dscp = [16]
    # remark.remark_port_group.cos_3.priority_remark.dscp = [24]
    # remark.remark_port_group.cos_4.priority_remark.dscp = [32]
    # remark.remark_port_group.cos_5.priority_remark.dscp = [40]
    # remark.remark_port_group.cos_6.priority_remark.dscp = [48]
    # remark.remark_port_group.cos_7.priority_remark.dscp = [56]

    # priority groups
    traffic.priority_group_list = [control, service, bulk]

    # internal cos values assigned to each priority group
    # each cos value should be assigned exactly once
    # internal cos values {0..7}
    priority_group.control.cos_list = [7]
    priority_group.service.cos_list = [4]
    priority_group.bulk.cos_list = [0,1,2,3,5,6]

    # to configure priority flow control on a group of ports:
    # -- assign cos value(s) to the cos list
    # -- add or replace a port group names in the port group list
    # -- for each port group in the list
    #    -- populate the port set, e.g.
    #       swp1-swp4,swp8,swp50s0-swp50s3
    #    -- set a PFC buffer size in bytes for each port in the group
    #    -- set the xoff byte limit (buffer limit that triggers PFC frames transmit to start)
    #    -- set the xon byte delta (buffer limit that triggers PFC frames transmit to stop)
    #    -- enable PFC frame transmit and/or PFC frame receive

    # priority flow control
    pfc.port_group_list = [pfc_port_group]
    pfc.pfc_port_group.cos_list = [4]
    pfc.pfc_port_group.port_set = swp1-swp32
    pfc.pfc_port_group.port_buffer_bytes = 70000
    pfc.pfc_port_group.xoff_size = 18000
    pfc.pfc_port_group.xon_delta = 0
    pfc.pfc_port_group.tx_enable = true
    pfc.pfc_port_group.rx_enable = true

    # to configure pause on a group of ports:
    # -- add or replace port group names in the port group list
    # -- for each port group in the list
    #    -- populate the port set, e.g.
    #       swp1-swp4,swp8,swp50s0-swp50s3
    #    -- set a pause buffer size in bytes for each port
    #    -- set the xoff byte limit (buffer limit that triggers pause frames transmit to start)
    #    -- set the xon byte delta (buffer limit that triggers pause frames transmit to stop)
    #    -- enable pause frame transmit and/or pause frame receive

    # link pause
    # link_pause.port_group_list = [pause_port_group]
    # link_pause.pause_port_group.port_set = swp1-swp4,swp6
    # link_pause.pause_port_group.port_buffer_bytes = 25000
    # link_pause.pause_port_group.xoff_size = 10000
    # link_pause.pause_port_group.xon_delta = 2000
    # link_pause.pause_port_group.rx_enable = true
    # link_pause.pause_port_group.tx_enable = true

    # Explicit Congestion Notification
    # to configure ECN and RED on a group of ports:
    # -- add or replace port group names in the port group list
    # -- assign cos value(s) to the cos list
    # -- for each port group in the list
    #    -- populate the port set, e.g.
    #       swp1-swp4,swp8,swp50s0-swp50s3
    # -- to enable RED requires the latest traffic.conf
    ecn_red.port_group_list = [ecn_red_port_group]
    ecn_red.ecn_red_port_group.cos_list = [4]
    ecn_red.ecn_red_port_group.port_set = swp1-swp32
    ecn_red.ecn_red_port_group.ecn_enable = true
    ecn_red.ecn_red_port_group.red_enable = false
    ecn_red.ecn_red_port_group.min_threshold_bytes = 153600
    ecn_red.ecn_red_port_group.max_threshold_bytes = 1536000
    ecn_red.ecn_red_port_group.probability = 100

    # scheduling algorithm: algorithm values = {dwrr}
    scheduling.algorithm = dwrr

    # traffic group scheduling weight
    # weight values = {0..127}
    # '0' indicates strict priority
    priority_group.control.weight = 0
    priority_group.service.weight = 16
    priority_group.bulk.weight = 16

    # To turn on/off Denial of service (DOS) prevention checks
    dos_enable = false

    # Cut-through is disabled by default on all chips with the exception of
    # Spectrum.  On Spectrum cut-through cannot be disabled.
    #cut_through_enable = false

    # Enable resilient hashing
    #resilient_hash_enable = FALSE

    # Resilient hashing flowset entries per ECMP group
    # Valid values - 64, 128, 256, 512, 1024
    #resilient_hash_entries_ecmp = 128

    # Enable symmetric hashing
    #symmetric_hash_enable = TRUE

    # Set sflow/sample ingress cpu packet rate and burst in packets/sec
    # Values: {0..16384}
    #sflow.rate = 16384
    #sflow.burst = 16384

    #Specify the maximum number of paths per route entry.
    #  Maximum paths supported is 200.
    #  Default value 0 takes the number of physical ports as the max path size.
    #ecmp_max_paths = 0

    #Specify the hash seed for Equal cost multipath entries
    # Default value 0
    # Value Rang: {0..4294967295}
    #ecmp_hash_seed = 42

    # Specify the forwarding table resource allocation profile, applicable
    # only on platforms that support universal forwarding resources.
    #
    # /usr/cumulus/sbin/cl-resource-query reports the allocated table sizes
    # based on the profile setting.
    #
    #   Values: one of {'default', 'l2-heavy', 'v4-lpm-heavy', 'v6-lpm-heavy',
    #                   'ipmc-heavy'}
    #   Default value: 'default'
    #   Note: some devices may support more modes, please consult user
    #         guide for more details
    #
    #forwarding_table.profile = default


The above enables DCB and defines the necessary traffic classes to allow RDMA to function.  50% of the bandwidth on each host port will be reserved for storage (priority_group.service.weigh) and 50% for host/VM traffic (priority_group.bulk.weight) .  Adjust the bandwidth weight parameters based on the requirements of your workload.  


___
**IMPORTANT**

The bandwidth weight parameters allocated here must match the DCB QOS percentage settings you apply on the Hyper-V host physical adapters or RDMA will not function properly.
