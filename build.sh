#!/usr/bin/env bash

# bomb on any error
set -e

apt -qq -y install nano dnsutils curl sudo
curl -fsSL https://get.docker.com/ | sh || apt -qq -y install docker.io

# globals
CWD=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
[ -e "${CWD}/scripts/globals" ] && . ${CWD}/scripts/globals

# import functions
[ -e "/lib/lsb/init-functions" ] && . /lib/lsb/init-functions
[ -e "${CWD}/scripts/functions" ] && . ${CWD}/scripts/functions

# display usage
usage() {
    echo "Usage: $0 [-b 0|1] [-c <ip>]" 1>&2;\
    printf "\t-b\tgrab docker images from repository (0) or build locally (1) (default: 0)\n";\
    printf "\t-c\tspecify client-ip instead of being taken from ssh_connection\n";\
    exit 1;
}

# fix terminfo
# http://ashberlin.co.uk/blog/2010/08/24/color-in-ubuntu-init-scripts/
if [[ $(infocmp | grep 'hpa=') == "" ]]; then
  (infocmp; printf '\thpa=\\E[%sG,\n' %i%p1%d) > tmp-${$}.tic\
    && tic -s tmp-$$.tic -o /etc/terminfo\
    && rm tmp-$$.tic\
    && exec $0 $*
fi

# process options
printf "$0: $*\n"
while getopts "b:c:" o; do
    case "${o}" in
        b)
            b=${OPTARG}
            ((b == 0|| b == 1)) || usage
            ;;
        c)
            c=${OPTARG}
            ;;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

if [ ${b} ]; then DOCKER_BUILD=${b}; fi
if [ ${c} ]; then CLIENTIP=${c}; fi

log_action_begin_msg "checking OS compatibility"
if [[ $(cat /etc/os-release | grep '^ID=') =~ ubuntu ]]\
  || [[ $(cat /etc/os-release | grep '^ID=') =~ debian ]]; then
    true
    log_action_end_msg $?
else
    false
    log_action_end_msg $?
    exit 1
fi

log_action_begin_msg "checking if cURL is installed"
which curl > /dev/null
log_action_end_msg $?

log_action_begin_msg "checking if Docker is installed"
which docker > /dev/null
log_action_end_msg $?

log_action_begin_msg "checking if sudo is installed"
which sudo > /dev/null
log_action_end_msg $?

log_action_begin_msg "checking if dig is installed"
which dig > /dev/null
log_action_end_msg $?

log_action_begin_msg "testing available ports"
#for port in 80 443 53; do
for port in 80 443; do
    ###! netstat -a -n -p | grep LISTEN | grep -P '\d+\.\d+\.\d+\.\d+::${port}' > /dev/null\
    ###  || (printf "required port ${port} already in use\n" && exit 1)
    ! ss -H -lptn "sport = :$port"|grep $port > /dev/null || (printf "required port ${port} already in use\n" && exit 1)
done
log_action_end_msg $?

log_action_begin_msg "disabling ufw"
if which ufw > /dev/null; then ufw disable &>> ${CWD}/sni.log; fi
log_action_end_msg $?

if [[ $(cat /proc/swaps | wc -l) -le 1 ]]; then
    log_action_begin_msg "setting up swapfile"
    fallocate -l 2G /swapfile && \
      chmod 600 /swapfile && \
      mkswap /swapfile && \
      swapon /swapfile && \
      printf "/swapfile   none    swap    sw    0   0\n" >> /etc/fstab
    log_action_end_msg $?
fi

log_action_begin_msg "installing net-tools"
sudo apt-get -y update &>> ${CWD}/netflix-proxy.log\
  && sudo apt-get -y install net-tools &>> ${CWD}/netflix-proxy.log
log_action_end_msg $?

# obtain the interface with the default gateway
IFACE=$(get_iface 4)

# obtain IP address of the Internet facing interface
IPADDR=$(get_ipaddr)
EXTIP=$(get_ext_ipaddr 4)

IPV6=0
if cat /proc/net/if_inet6 | grep -v lo | grep -v fe80 > /dev/null\
  && $(which curl) mgmt.unzoner.com --fail --silent -6 > /dev/null; then
    IPV6=1
    IPADDR6=$(get_ipaddr6)
    EXTIP6=$(get_ext_ipaddr 6)
fi

# obtain client (home) ip address and address family
if ! [ ${CLIENTIP} ]; then
    CLIENTIP=$(get_client_ipaddr)
fi

IS_CLIENT_IPV4=0
if ! is_ipv4 ${CLIENTIP}; then IS_CLIENT_IPV4=1; fi

IS_CLIENT_IPV6=1
if [[ "${IPV6}" == '1' ]]; then
    if is_ipv6 ${CLIENTIP}; then
        IS_CLIENT_IPV6=0
    fi
fi

# diagnostics info
debug="$0: build=${DOCKER_BUILD} client=${CLIENTIP} is_client_ipv4=${IS_CLIENT_IPV4} ipaddr=${IPADDR} extip=${EXTIP}"

if [[ "${IPV6}" == '1' ]]; then
    debug_v6="$0: is_client_ipv6=${IS_CLIENT_IPV6} ipaddr6=${IPADDR6} extip6=${EXTIP6}"
fi

sudo touch ${CWD}/sni.log

log_action_begin_msg "log diagnostics info"
printf "build=${DOCKER_BUILD} client=${CLIENTIP} local=${IPADDR} public=${EXTIP}\n"
printf "${debug}\n" &>> ${CWD}/sni.log
log_action_end_msg $?

if [[ ${debug_v6} ]]; then
    log_action_begin_msg "log diagnostics info (IPv6)"
    printf "local6=${IPADDR6} public6=${EXTIP6}\n"
    printf "${debug_v6}\n" &>> ${CWD}/sni.log
    log_action_end_msg $?
fi

# switch to working directory
pushd ${CWD} &>> ${CWD}/sni.log

# configure iptables
#####if [[ -n "${CLIENTIP}" ]]; then
#####    log_action_begin_msg "authorising clientip=${CLIENTIP} on iface=${IFACE}"
#####    if [[ "${IS_CLIENT_IPV4}" == '0' ]]; then
#####        sudo iptables -t nat -A PREROUTING -s ${CLIENTIP}/32 -i ${IFACE} -j ACCEPT
#####    fi
#####    if [[ "${IS_CLIENT_IPV6}" == '0' ]]; then
#####        sudo ip6tables -t nat -A PREROUTING -s ${CLIENTIP}/128 -i ${IFACE} -j ACCEPT
#####    fi
#####    log_action_end_msg $?
#####else
#####    log_action_cont_msg "unable to resolve and authorise client ip"
#####fi

log_action_begin_msg "adding IPv4 iptables rules"
sudo iptables -t nat -A PREROUTING -i ${IFACE} -p tcp --dport 80 -j REDIRECT --to-port 8080\
  && sudo iptables -t nat -A PREROUTING -i ${IFACE} -p tcp --dport 443 -j REDIRECT --to-port 8080\
  && sudo iptables -t nat -A PREROUTING -i ${IFACE} -p udp --dport 53 -j REDIRECT --to-port 5353\
  && sudo iptables -t nat -A POSTROUTING -o ${IFACE} -j MASQUERADE\
  && sudo iptables -A INPUT -p icmp -j ACCEPT\
  && sudo iptables -A INPUT -i lo -j ACCEPT\
  && sudo iptables -A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT\
  && sudo iptables -A INPUT -p tcp -m state --state NEW -m tcp --dport 2012 -j ACCEPT\
  && sudo iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT\
  && sudo iptables -A INPUT -p udp -m udp --dport 53 -j ACCEPT\
  && sudo iptables -A INPUT -p udp -m udp --dport 5353 -j ACCEPT\
  && sudo iptables -A INPUT -p tcp -m tcp --dport 80 -j ACCEPT\
  && sudo iptables -A INPUT -p tcp -m tcp --dport 8080 -j ACCEPT\
  && sudo iptables -A INPUT -p tcp -m tcp --dport 443 -j ACCEPT
#  && sudo iptables -A INPUT -j REJECT --reject-with icmp-host-prohibited
log_action_end_msg $?

log_action_begin_msg "adding IPv6 iptables rules"
sudo ip6tables -t nat -A PREROUTING -i ${IFACE} -p tcp --dport 80 -j REDIRECT --to-port 8080\
  && sudo ip6tables -t nat -A PREROUTING -i ${IFACE} -p tcp --dport 443 -j REDIRECT --to-port 8080\
  && sudo ip6tables -t nat -A PREROUTING -i ${IFACE} -p udp --dport 53 -j REDIRECT --to-port 5353\
  && sudo ip6tables -t nat -A POSTROUTING -o ${IFACE} -j MASQUERADE\
  && sudo ip6tables -A INPUT -p ipv6-icmp -j ACCEPT\
  && sudo ip6tables -A INPUT -i lo -j ACCEPT\
  && sudo ip6tables -A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT\
  && sudo ip6tables -A INPUT -p tcp -m state --state NEW -m tcp --dport 2012 -j ACCEPT\
  && sudo ip6tables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT\
  && sudo ip6tables -A INPUT -p udp -m udp --dport 53 -j ACCEPT\
  && sudo ip6tables -A INPUT -p udp -m udp --dport 5353 -j ACCEPT\
  && sudo ip6tables -A INPUT -p tcp -m tcp --dport 80 -j ACCEPT\
  && sudo ip6tables -A INPUT -p tcp -m tcp --dport 8080 -j ACCEPT\
  && sudo ip6tables -A INPUT -p tcp -m tcp --dport 443 -j ACCEPT
#  && sudo ip6tables -A INPUT -j REJECT --reject-with icmp6-adm-prohibited
log_action_end_msg $?

# check if public IPv6 access is available
log_action_begin_msg "creating Docker and sniproxy configuration templates"
sudo cp ${CWD}/docker-sniproxy/sniproxy.conf.template ${CWD}/docker-sniproxy/sniproxy.conf &>> ${CWD}/sni.log\
  && sudo cp ${CWD}/docker-compose.yml.template ${CWD}/docker-compose.yml &>> ${CWD}/sni.log
log_action_end_msg $?

log_action_begin_msg "disabling Docker iptables control"
cp ${CWD}/daemon.json /etc/docker/
log_action_end_msg $?

if [[ "${IPV6}" == '1' ]]; then
    log_action_begin_msg "enabling sniproxy IPv6 priority"
    printf "\nresolver {\n  nameserver ${RESOLVER_PRI}\n  nameserver ${RESOLVER_SEC}\n  mode ipv6_first\n}\n"\
      | sudo tee -a ${CWD}/docker-sniproxy/sniproxy.conf &>> ${CWD}/sni.log
    log_action_end_msg $?
else
    log_action_begin_msg "configuring sniproxy and Docker"
    printf "\nresolver {\n  nameserver ${RESOLVER_PRI}\n  nameserver ${RESOLVER_SEC}\n  mode ipv4_only\n}\n"\
      | sudo tee -a ${CWD}/docker-sniproxy/sniproxy.conf &>> ${CWD}/sni.log
    log_action_end_msg $?
fi

log_action_begin_msg "installing iptables|netfilter-persistent service"
echo iptables-persistent iptables-persistent/autosave_v4 boolean true\
  | sudo debconf-set-selections &>> ${CWD}/sni.log\
  && echo iptables-persistent iptables-persistent/autosave_v6 boolean true\
  | sudo debconf-set-selections &>> ${CWD}/sni.log\
  && sudo apt-get -y install iptables-persistent &>> ${CWD}/sni.log
log_action_end_msg $?

# Ubuntu and Debian have different service names for iptables-persistent service
if [ -f "/etc/init.d/iptables-persistent" ]; then
    SERVICE=iptables
elif [ -f "/etc/init.d/netfilter-persistent" ]; then
    SERVICE=netfilter
fi

# socialise Docker with iptables-persistent
# https://groups.google.com/forum/#!topic/docker-dev/4SfOwCOmw-E
if [ ! -f "/etc/init/docker.conf.bak" ] && [ -f "/etc/init/docker.conf" ]; then
    log_action_begin_msg "socialising Docker with iptables-persistent service"
    sudo $(which sed) -i.bak "s/ and net-device-up IFACE!=lo)/ and net-device-up IFACE!=lo and started ${SERVICE}-persistent)/" /etc/init/docker.conf || true &>> ${CWD}/sni.log
    log_action_end_msg $?
fi

if [[ ${SERVICE} == "iptables" ]]; then
    if [ ! -f "/etc/init.d/iptables-persistent.bak" ] && [ -f "/etc/init.d/iptables-persistent" ]; then
        log_action_begin_msg "updating iptables-persistent init script"
        sudo $(which sed) -i.bak '/load_rules$/{N;s/load_rules\n\t;;/load_rules\n\tinitctl emit -n started JOB=iptables-persistent\n\t;;/}' /etc/init.d/iptables-persistent || true &>> ${CWD}/sni.log\
          && sudo $(which sed) -i'' 's/stop)/stop)\n\tinitctl emit stopping JOB=iptables-persistent/' /etc/init.d/iptables-persistent &>> ${CWD}/sni.log
        log_action_end_msg $?
    fi
fi

log_action_begin_msg "installing ipset-persistent service"
sudo DEBIAN_FRONTEND=noninteractive apt-get -y -qq install ipset-persistent &>> ${CWD}/sni.log
log_action_end_msg $?

log_action_begin_msg "reload ${SERVICE}-persistent service to enable ipset-persistent"
systemctl daemon-reload
log_action_end_msg $?


log_action_begin_msg "create sniproxy ipset"
ipset create -exist sniproxy6 hash:net family inet6 hashsize 1048576 maxelem 1048576
ipset create -exist sniproxy hash:net family inet hashsize 1048576 maxelem 1048576
log_action_end_msg $?

# configure iptables
if [[ -n "${CLIENTIP}" ]]; then
    log_action_begin_msg "authorising clientip=${CLIENTIP} sniproxy ipset"
    if [[ "${IS_CLIENT_IPV4}" == '0' ]]; then
        sudo ipset add -exist sniproxy ${CLIENTIP}
    fi
    if [[ "${IS_CLIENT_IPV6}" == '0' ]]; then
        sudo ipset add -exist sniproxy6 ${CLIENTIP}
    fi
    log_action_end_msg $?
else
    log_action_cont_msg "unable to resolve and authorise client ip"
fi

log_action_begin_msg "Add iptables rule with sniproxy ipset match"
sudo ip6tables -t nat -I PREROUTING -m set --match-set sniproxy6 src -i ${IFACE} -j ACCEPT
sudo iptables -t nat -I PREROUTING -m set --match-set sniproxy src -i ${IFACE} -j ACCEPT
log_action_end_msg $?

log_action_begin_msg "saving iptables rules"
sudo service ${SERVICE}-persistent save &>> ${CWD}/sni.log
log_action_end_msg $?

log_action_begin_msg "creating dnsmasq.conf from template"
sudo cp ${CWD}/dnsmasq.conf.template ${CWD}/dnsmasq.conf &>> ${CWD}/sni.log
log_action_end_msg $?

if [[ "${IPV6}" == '1' ]] && [[ ${EXTIP6} ]]; then
    log_action_begin_msg "updating dnsmasq.conf extip=${EXTIP} extip6=${EXTIP6}"
else
    log_action_begin_msg "updating dnsmasq.conf extip=${EXTIP}"
fi

if [[ -n "${EXTIP}" ]]; then
    for domain in $(cat ${CWD}/proxy-domains.txt); do
        printf "address=/${domain}/${EXTIP}\n"\
          | sudo tee -a ${CWD}/dnsmasq.conf &>> ${CWD}/sni.log
    done
fi

for domain in $(cat ${CWD}/bypass-domains.txt); do
    printf "server=/${domain}/${RESOLVER_PRI}\n"\
      | sudo tee -a ${CWD}/dnsmasq.conf &>> ${CWD}/sni.log
    printf "server=/${domain}/${RESOLVER_SEC}\n"\
      | sudo tee -a ${CWD}/dnsmasq.conf &>> ${CWD}/sni.log
done

if [[ "${IPV6}" == '1' ]] && [[ -n "${EXTIP6}" ]]; then
    for domain in $(cat ${CWD}/proxy-domains.txt); do
        printf "address=/${domain}/${EXTIP6}\n"\
          | sudo tee -a ${CWD}/dnsmasq.conf &>> ${CWD}/sni.log
    done
fi
log_action_end_msg $?

log_action_begin_msg "installing Python3 and requirements"
sudo apt-get -y update &>> ${CWD}/sni.log\
  && sudo apt-get -y install git python3.6 python3-venv python3-pip sqlite3 &>> ${CWD}/sni.log\
  && python3 -m venv venv &>> ${CWD}/sni.log\
  && source venv/bin/activate &>> ${CWD}/sni.log\
  && pip3 install pip --upgrade &>> ${CWD}/netflix-proxy.log\
  && pip3 install -r requirements.txt &>> ${CWD}/sni.log\
  && pip3 install -r ${CWD}/auth/requirements.txt &>> ${CWD}/sni.log
log_action_end_msg $?

log_action_begin_msg "configuring admin backend"
PLAINTEXT=$(${CWD}/auth/pbkdf2_sha256_hash.py | awk '{print $1}')\
  && HASH=$(${CWD}/auth/pbkdf2_sha256_hash.py ${PLAINTEXT} | awk '{print $2}')\
  && sudo cp ${CWD}/auth/db/auth.default.db ${CWD}/auth/db/auth.db &>> ${CWD}/sni.log\
  && sudo $(which sqlite3) ${CWD}/auth/db/auth.db "UPDATE users SET created='2016-02-06 17:21:09', privilege=1, expires='2039-01-01', username='admin', password = '\$pbkdf2-sha256\$200000\$hHBOSUkJASAkJGQMISQEYA\$T54BKGa9BWNSq4ahqoKoy85dsLuno6dJVL6q2mDPpdk' WHERE ID = 1;" &>> ${CWD}/sni.log \
  && sudo $(which sqlite3) ${CWD}/auth/db/auth.db "INSERT INTO USERS VALUES(2,'2020-07-29 14:07:00',0,'2039-01-01','user','\$pbkdf2-sha256\$200000\$nPP.H0OIUWotRSgFYIxx7g\$aiENhgxKmE5yIckL6ALUL9z7xSaB3DWl.m4kk83L9j0');" &>> ${CWD}/sni.log
log_action_end_msg $?

log_action_begin_msg "configuring admin frontend"
sudo cp ${CWD}/Caddyfile.template ${CWD}/Caddyfile &>> ${CWD}/sni.log\
  && printf "proxy / localhost:${SDNS_ADMIN_PORT} {\n    except /static\n    header_upstream Host {host}\n    header_upstream X-Forwarded-For {remote}\n    header_upstream X-Real-IP {remote}\n    header_upstream X-Forwarded-Proto {scheme}\n}\n"\
  | sudo tee -a ${CWD}/Caddyfile &>> ${CWD}/sni.log
log_action_end_msg $?

log_action_begin_msg "creating cron scripts"
sudo cp ${CWD}/crond.template /etc/cron.d/sni &>> ${CWD}/sni.log\
  && sudo $(which sed) -i'' "s#{{CWD}}#${CWD}#g" /etc/cron.d/sni &>> ${CWD}/sni.log\
  && sudo service cron restart &>> ${CWD}/sni.log
log_action_end_msg $?

if [[ "${DOCKER_BUILD}" == '1' ]]; then
    log_action_begin_msg "pulling and building docker containers from source"
    sudo $(which docker-compose) build &>> ${CWD}/sni.log
    sudo $(which docker-compose) pull caddy-service &>> ${CWD}/sni.log
    log_action_end_msg $?
else
    log_action_begin_msg "pulling Docker containers"
    sudo $(which docker-compose) pull &>> ${CWD}/sni.log
    log_action_end_msg $?
fi

log_action_begin_msg "creating and starting Docker containers"
  EXTIP=${EXTIP} EXTIP6=${EXTIP6}\
  $(which docker-compose) up -d &>> ${CWD}/sni.log
log_action_end_msg $?

# configure appropriate init system
log_action_begin_msg "configuring init system"
if [[ `/sbin/init --version` =~ upstart ]]; then
    sudo cp ${CWD}/init/*.conf /etc/init/ &>> ${CWD}/sni.log\
      && sudo $(which sed) -i'' "s#{{CWD}}#${CWD}#g" /etc/init/sni-admin.conf &>> ${CWD}/sni.log\
      && sudo service sni-admin restart &>> ${CWD}/sni.log
fi

if [[ `systemctl` =~ -\.mount ]]; then
      sudo cp ${CWD}/init/*.service /lib/systemd/system/ &>> ${CWD}/sni.log\
        && sudo $(which sed) -i'' "s#{{CWD}}#${CWD}#g" /lib/systemd/system/sni-admin.service &>> ${CWD}/sni.log\
        && sudo systemctl daemon-reload &>> ${CWD}/sni.log\
        && sudo systemctl enable sni-admin &>> ${CWD}/sni.log\
        && sudo systemctl enable systemd-networkd &>> ${CWD}/sni.log\
        && sudo systemctl enable systemd-networkd-wait-online &>> ${CWD}/sni.log\
        && sudo systemctl restart sni-admin &>> ${CWD}/sni.log
fi
log_action_end_msg $?

log_action_begin_msg "reloading ipables rules"
sudo service ${SERVICE}-persistent reload &>> ${CWD}/sni.log
log_action_end_msg $?

printf "\nsni-admin site=http://${EXTIP}:8080/ credentials=\e[1madmin:7kV6H9vP4u\033[0m\n"
log_action_begin_msg "testing sni admin site"
(with_backoff $(which curl) --silent -4\
  --fail http://${EXTIP}:8080/ &>> ${CWD}/sni.log\
  || with_backoff $(which curl) --silent -4\
  --fail http://${IPADDR}:8080/) &>> ${CWD}/sni.log\
  && with_backoff $(which curl) --silent -4\
  --fail http://localhost:${SDNS_ADMIN_PORT}/ &>> ${CWD}/sni.log
log_action_end_msg $?

if [[ -n "${EXTIP6}" ]] && [[ -n "${IPADDR6}" ]]; then
    printf "\nsni-admin site=http://${EXTIP6}:8080/ credentials=\e[1madmin:7kV6H9vP4u\033[0m\n"
    log_action_begin_msg "testing sni admin site ipv6"
    with_backoff $(which curl) --silent -6\
      --fail http://ip6-localhost:8080/ &>> ${CWD}/sni.log
    log_action_end_msg $?
fi

# change back to original directory
popd &>> ${CWD}/sni.log

if [[ "${IPV6}" == '1' ]]; then
    printf "IPv6=\e[32mEnabled\033[0m\n"
else
    printf "\e[1mWARNING:\033[0m IPv6=\e[31mDisabled\033[0m\n"
fi

# sudo $(which sqlite3) ${CWD}/auth/db/auth.db 'INSERT INTO USERS (privilege, expires, username, password) VALUES (1, "2039-12-31", "user", "$pbkdf2-sha256$200000$yxmjFMKY05pTinEupRQC4A$1ZP2BKR.BRnEdBw7G1Nku.BXCFcY3NpEqFn3srJZSXY");' &>> ${CWD}/sni.log

printf "\nsni-admin site=http://${EXTIP6}:8080/ API credentials=\e[1muser:smile\033[0m\n"

# DO NOT change the text between these lines
printf "Change your DNS to ${EXTIP} and start watching Netflix out of region.\n"
# DO NOT change the text between these lines

printf "\e[33mNote\033[0m: get \e[1mhttp://unzoner.com\033[0m if your app/service no longer works with DNS based solutions.\n"
printf "\e[32mDone.\033[0m\n"
