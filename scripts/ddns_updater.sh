#!/usr/bin/env bash

# ddns_updater.sh: Checks DDNS sites and updates the IPs if needed.
# author: patrice@brendamour.net

# bomb on any error
set -e

# make sure basic paths are set
export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH

CDW=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
. ${CDW}/functions

SQLITE_DB=${CDW}/../auth/db/auth.db

# obtain the interface with the default gateway
IFACE=$(get_iface 4)

LIST=`sudo $(which sqlite3) ${SQLITE_DB} "SELECT domain,last_ipaddr FROM DDNS"`
for ROW in $LIST; do
        DOMAIN=`echo $ROW | awk '{split($0,a,"|"); print a[1]}'`
        OLDIP=`echo $ROW | awk '{split($0,a,"|"); print a[2]}'`
        NEWIP=`dig +short $DOMAIN`

        if [ "$OLDIP" != "$NEWIP" ]; then
                echo "$(date): Updating $DOMAIN"
                if [ -n "$OLDIP" ]; then
                        /usr/sbin/ipset del -exist sniproxy $OLDIP
                fi
                if [ -n "$NEWIP" ]; then
                        /usr/sbin/ipset add -exist sniproxy $NEWIP
                fi



                #UPDATE database
                sudo $(which sqlite3) ${SQLITE_DB} "UPDATE DDNS SET last_ipaddr = '${NEWIP}' WHERE domain = '${DOMAIN}'"
        fi
done

/usr/sbin/service netfilter-persistent save

exit 0
