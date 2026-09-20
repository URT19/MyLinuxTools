# xRay-Test

راهنمای کامل نصب، پیکربندی و تست **Xray** همراه با **Proxychains** برای بررسی عملکرد پروکسی روی لینوکس (Debian/Ubuntu).

---

## 📋 فهرست مطالب

- [پیش‌نیازها](#-پیش‌نیازها)
- [نصب Xray](#-نصب-xray)
- [دانلود فایل‌های Geo](#-دانلود-فایل‌های-geo)
- [پیکربندی Xray](#-پیکربندی-xray)
- [اجرا و راه‌اندازی سرویس](#-اجرا-و-راه‌اندازی-سرویس)
- [تست اتصال پروکسی](#-تست-اتصال-پروکسی)
- [نصب و تنظیم Proxychains](#-نصب-و-تنظیم-proxychains)
- [تست سرعت از طریق پروکسی](#-تست-سرعت-از-طریق-پروکسی)
- [نکات مهم](#-نکات-مهم)

---

## 📦 پیش‌نیازها

ابتدا پکیج‌های مورد نیاز را نصب کنید:

```bash
sudo apt update
sudo apt install -y curl unzip speedtest-cli
```

---

## 🚀 نصب Xray

برای نصب آخرین نسخه Xray از اسکریپت رسمی استفاده کنید:

```bash
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
```

پس از نصب موفق، سرویس Xray به صورت خودکار راه‌اندازی می‌شود.

---

## 🌍 دانلود فایل‌های Geo

فایل‌های `geosite.dat` و `geoip.dat` برای مسیریابی هوشمند دامنه و IP ضروری هستند.

### روش پیشنهادی (Loyalsoldier - به‌روزتر و کامل‌تر)

```bash
sudo mkdir -p /usr/local/share/xray

sudo curl -L -o /usr/local/share/xray/geosite.dat \
  https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat

sudo curl -L -o /usr/local/share/xray/geoip.dat \
  https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
```

### روش جایگزین (v2fly)

```bash
sudo curl -L -o /usr/local/share/xray/geosite.dat \
  https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat

sudo curl -L -o /usr/local/share/xray/geoip.dat \
  https://github.com/v2fly/geoip/releases/latest/download/geoip.dat
```

سپس فایل‌ها را در مسیر استاندارد کپی کنید:

```bash
sudo cp /usr/local/share/xray/*.dat /usr/share/xray/
```

---

## ⚙️ پیکربندی Xray

فایل کانفیگ را ویرایش کنید:

```bash
sudo nano /usr/local/etc/xray/config.json
```

> **توجه:** کانفیگ را مطابق نیاز خود (VLESS، VMess، Trojan و ...) تنظیم کنید.  
> پورت پیش‌فرض در تست‌های این راهنما `10808` (SOCKS5) در نظر گرفته شده است.

---

## 🔄 اجرا و راه‌اندازی سرویس

### اجرای دستی (برای تست)

```bash
xray run -c /usr/local/etc/xray/config.json
```

### راه‌اندازی به عنوان سرویس (پیشنهادی)

```bash
sudo systemctl restart xray
sudo systemctl enable xray
sudo systemctl status xray
```

---

## 🔍 تست اتصال پروکسی

برای بررسی اینکه ترافیک از طریق Xray عبور می‌کند:

```bash
curl --socks5-hostname 127.0.0.1:10808 https://ipinfo.io
```

یا:

```bash
curl --socks5-hostname 127.0.0.1:10808 https://myip.wtf/json
```

اگر IP خروجی سرور پروکسی شما نمایش داده شد، اتصال صحیح است.

---

## 🔗 نصب و تنظیم Proxychains

Proxychains به شما امکان می‌دهد هر دستوری را از طریق پروکسی اجرا کنید.

### نصب

```bash
sudo apt install -y proxychains4
```

### پیکربندی

فایل تنظیمات را باز کنید:

```bash
sudo nano /etc/proxychains4.conf
```

در انتهای فایل، بخش `[ProxyList]` را به شکل زیر تنظیم کنید:

```ini
[ProxyList]
# add proxy here ...
# meanwile
# defaults set to "tor"
socks5 127.0.0.1 10808
```

> خطوط مربوط به tor را کامنت کنید یا حذف نمایید.

### تست با Proxychains

```bash
proxychains4 curl myip.wtf/json
```

---

## 📶 تست سرعت از طریق پروکسی

برای اندازه‌گیری سرعت اینترنت از طریق تونل Xray:

```bash
proxychains4 speedtest-cli
```

یا با جزئیات بیشتر:

```bash
proxychains4 speedtest-cli --simple
```

---

## 📝 نکات مهم

| نکته | توضیح |
|------|-------|
| پورت | در این راهنما از پورت `10808` برای SOCKS5 استفاده شده. اگر پورت دیگری در کانفیگ دارید، همه جا آن را تغییر دهید. |
| دسترسی root | اکثر دستورات نیاز به `sudo` دارند. |
| سیستم‌عامل | دستورات برای Debian / Ubuntu نوشته شده‌اند. |
| فایل‌های Geo | توصیه می‌شود از نسخه Loyalsoldier استفاده کنید چون قوانین کامل‌تری دارد. |
| سرویس | پس از هر تغییر در `config.json` حتماً سرویس را ری‌استارت کنید: `sudo systemctl restart xray` |

---

## 🛠 عیب‌یابی سریع

**سرویس اجرا نمی‌شود؟**
```bash
sudo journalctl -u xray -n 50 --no-pager
```

**پورت در حال استفاده است؟**
```bash
ss -tulnp | grep 10808
```

**تست ساده اتصال:**
```bash
curl -v --socks5-hostname 127.0.0.1:10808 https://www.google.com
```

---

## 📌 لینک‌های مفید

- [Xray-core](https://github.com/XTLS/Xray-core)
- [Xray-install](https://github.com/XTLS/Xray-install)
- [Loyalsoldier v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat)
- [Proxychains-ng](https://github.com/rofl0r/proxychains-ng)

---

**ساخته‌شده توسط [URT19](https://github.com/URT19)**
```
