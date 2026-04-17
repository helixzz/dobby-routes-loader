# Non-ChnRoutes Loader

I have some scripts running on VyOS routers to inject special routes into kernel routing table and let them spread over BGP peers.

I want to further improve these scripts to make it more efficient and make use of my another project which provides daily latest updated routing tables.

## Existing Gears

VyOS Config Snippet

``` bash
set system task-scheduler task load-routes executable path '/config/scripts/route-loader/restore.sh'
set system task-scheduler task load-routes interval '2h'
```

/config/scripts/route-loader/restore.sh

``` bash
#!/bin/bash
/usr/sbin/ip route restore table 111 < /config/scripts/route-loader/routes4.save
```

/config/scripts/route-loader/loader.sh

```
#! /bin/bash
# Loader script for routing table

# Definition
OUTGOING_INTERFACE="eth0"
NEXT_HOP_IPv4="192.0.2.1"
NEXT_HOP_IPv6=""
EXCLUDE_IP="192.0.2.0/24"
TABLE=" table 111"
EXPIRE=" expires 7200"

cd $(dirname $0)

# Load resources
# curl -o delegated-apnic-latest https://ftp.apnic.net/stats/apnic/delegated-apnic-latest
# curl -o china_ip_list.txt https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt
# echo "$EXCLUDE_IP" >> china_ip_list.txt
# python3 produce_clean.py
#
# wget -O routes4_add.list https://raw.githubusercontent.com/metowolf/iplist/refs/heads/master/data/country/US.txt
cat routes4.conf routes4_add.list > routes4.list
# cat usa_full.list | ./cidr-merger-linux-amd64 -o routes4.list

if [ -n "$NEXT_HOP_IPv4" ]; then
    for route in $(cat routes4.list | grep -v '#')
    do
        ip route replace $route dev $OUTGOING_INTERFACE via $NEXT_HOP_IPv4 $TABLE $EXPIRE
    done
fi

if [ -n "$NEXT_HOP_IPv6" ]; then
    for route in $(cat routes6.list | grep -v '#')
    do
        ip route replace $route dev $OUTGOING_INTERFACE via $NEXT_HOP_IPv6 $TABLE $EXPIRE
    done
fi

ip route save $TABLE > routes4.save
```

Private CIDRs
``` python
RESERVED = [
    IPv4Network('0.0.0.0/8'),
    IPv4Network('10.0.0.0/8'),
    IPv4Network('127.0.0.0/8'),
    IPv4Network('169.254.0.0/16'),
    IPv4Network('172.16.0.0/12'),
    IPv4Network('192.0.0.0/29'),
    IPv4Network('192.0.0.170/31'),
    IPv4Network('192.0.2.0/24'),
    IPv4Network('192.168.0.0/16'),
    IPv4Network('198.18.0.0/15'),
    IPv4Network('198.51.100.0/24'),
    IPv4Network('203.0.113.0/24'),
    IPv4Network('240.0.0.0/4'),
    IPv4Network('255.255.255.255/32'),
    IPv4Network('169.254.0.0/16'),
    IPv4Network('127.0.0.0/8'),
    IPv4Network('224.0.0.0/4'),
    IPv4Network('100.64.0.0/10'),
]
```


## Improved Online Route Table

Git Repo: https://github.com/helixzz/dobby-routes
Link to latest desired routing table: https://raw.githubusercontent.com/helixzz/dobby-routes/data/cn_routes_inverse.txt

## Requirements

- I want the script to update routing table every day, while cleaning out stale routes (that doesn't exist in the online list any more) while adding new ones, and keep the update operation smooth to avoid massive BGP flappings.
- The script should check if the online routing table contains any of private network CIDRs as a safety guard. Any private subnets MUST NOT BE IN THE INJECTED ROUTE TABLE.
