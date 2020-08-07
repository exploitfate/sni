
Find a Debian or Ubuntu box with root on a clean public IP and run:
  
```bash
apt update \
  && apt -y install nano dnsutils curl git sudo \
  && curl -fsSL https://get.docker.com/ | sh || apt -y install docker.io \
  && git clone https://github.com/exploitfate/netflix-proxy.git \
  && cd ~/netflix-proxy \
  && ./build.sh
```


Reset password
```bash
cd ~/netflix-proxy/auth
/bin/bash -c '. /root/netflix-proxy/venv/bin/activate && ./admin-reset.sh'

service netflix-proxy-admin restart
docker restart sniproxy
```


Create new account
```bash
cd ~/netflix-proxy/auth
/bin/bash -c '. /root/netflix-proxy/venv/bin/activate && ./account-creator.sh'

# Please enter a username: user
# Please enter a password: 
# Expiry date? (YYYY-MM-DD): 2039-01-01
# Please specify access group (0=user 1=admin): 0

service netflix-proxy-admin restart
docker restart sniproxy
```
