
Find a Debian or Ubuntu box with root on a clean public IP and run:
  
```bash
apt update \
  && apt -y install git \
  && git clone https://github.com/exploitfate/sni.git \
  && cd ~/sni \
  && ./build.sh
```


Reset password
```bash
cd ~/sni/auth
/bin/bash -c '. /root/sni/venv/bin/activate && ./admin-reset.sh'

service sni-admin restart
docker restart sniproxy
```


Create new account
```bash
cd ~/sni/auth
/bin/bash -c '. /root/sni/venv/bin/activate && ./account-creator.sh'

# Please enter a username: user
# Please enter a password: 
# Expiry date? (YYYY-MM-DD): 2039-01-01
# Please specify access group (0=user 1=admin): 0

service sni-admin restart
docker restart sniproxy
```

Rebuild container 

```
./venv/bin/docker-compose up -d --build sniproxy-service
```

Login into container 

```
./venv/bin/docker-compose exec sniproxy-service bash
```
