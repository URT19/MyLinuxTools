```
sudo apt install -y curl unzip speedtest-cli

```


```

bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

sudo mkdir -p /usr/local/share/xray

sudo curl -L -o /usr/local/share/xray/geosite.dat https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat


sudo curl -L -o /usr/local/share/xray/geoip.dat https://github.com/v2fly/geoip/releases/latest/download/geoip.dat

sudo curl -L -o /usr/local/share/xray/geosite.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat

sudo curl -L -o /usr/local/share/xray/geoip.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat


```


```
nano /usr/local/etc/xray/config.json
```

```
sudo cp /usr/local/share/xray/*.dat /usr/share/xray/
```

```
xray run -c /usr/local/etc/xray/config.json
```


```
sudo systemctl restart xray
```


```
curl --socks5-hostname 127.0.0.1:10808 https://ipinfo.io
```

```
sudo apt install -y proxychains4 speedtest-cli
```

----

```
sudo nano /etc/proxychains4.conf
```
```
[ProxyList]
# add proxy here ...
# meanwile
# defaults set to "tor"
socks5 127.0.0.1 10808
```


```
proxychains4 curl myip.wtf/json
```

---

```
proxychains4 speedtest-cli
```
