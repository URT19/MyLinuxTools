# MyLinuxTools

مجموعه‌ای از ابزارهای کاربردی لینوکس برای بنچمارک سرور و تست پروکسی Xray.

---

## 📂 ساختار پروژه

| پوشه | توضیح |
|------|-------|
| [Linux-Bench](./Linux-Bench) | اسکریپت بنچمارک کامل سیستم (CPU، RAM، دیسک، شبکه) |
| [xRay-Test](./xRay-Test) | راهنمای نصب و تست Xray + Proxychains |

---

## 🚀 Linux-Bench

اسکریپت بنچمارک پیشرفته بر پایه `bench.sh` (Teddysun) که اطلاعات سیستم، سرعت دیسک، سرعت شبکه و موقعیت IP را نمایش می‌دهد.

### اجرای سریع

```bash
curl -H 'Cache-Control: no-cache' "https://raw.githubusercontent.com/URT19/MyLinuxTools/refs/heads/main/Linux-Bench/bench.sh?$RANDOM" -o bench.sh && chmod +x bench.sh
sudo ./bench.sh
```

### قابلیت‌ها
- نمایش اطلاعات سیستم‌عامل، CPU، RAM، Swap و آپتایم
- تست سرعت I/O دیسک
- تست سرعت شبکه (Speedtest) با سرورهای منتخب از جمله **Tehran Irancell**
- تشخیص نوع مجازی‌سازی (KVM، Docker، LXC و ...)
- نمایش اطلاعات ISP و موقعیت جغرافیایی IP

---

## 🔧 xRay-Test

راهنمای نصب و تست Xray همراه با Proxychains برای بررسی عملکرد پروکسی.

### ۱. نصب پیش‌نیازها

```bash
sudo apt install -y curl unzip speedtest-cli
```

### ۲. نصب Xray

```bash
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

sudo mkdir -p /usr/local/share/xray

# دانلود فایل‌های Geo
sudo curl -L -o /usr/local/share/xray/geosite.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
sudo curl -L -o /usr/local/share/xray/geoip.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
```

### ۳. پیکربندی و اجرا

```bash
nano /usr/local/etc/xray/config.json
sudo cp /usr/local/share/xray/*.dat /usr/share/xray/
sudo systemctl restart xray
```

### ۴. تست پروکسی

```bash
# تست IP خروجی
curl --socks5-hostname 127.0.0.1:10808 https://ipinfo.io

# نصب Proxychains
sudo apt install -y proxychains4

# ویرایش تنظیمات
sudo nano /etc/proxychains4.conf
```

در بخش `[ProxyList]` این خط را اضافه کنید:

```
socks5 127.0.0.1 10808
```

سپس تست کنید:

```bash
proxychains4 curl myip.wtf/json
proxychains4 speedtest-cli
```

---

## 📝 نکات

- اسکریپت‌ها عمدتاً برای سیستم‌های Debian/Ubuntu نوشته شده‌اند.
- برای اجرای بنچمارک نیاز به دسترسی `sudo` دارید.
- قبل از تست Xray حتماً فایل `config.json` را مطابق نیاز خود تنظیم کنید.

---

## 👤 نویسنده

**URT19**  
[GitHub Profile](https://github.com/URT19)

---

## 📄 مجوز

این پروژه بر اساس اسکریپت‌های متن‌باز موجود ساخته شده است.  
اسکریپت بنچمارک بر پایه کار [Teddysun](https://github.com/teddysun/across) است.
```
