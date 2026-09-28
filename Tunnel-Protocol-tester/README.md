# FRP Protocol Tester

### این اسکریپت فقط از روی سرور خارج نصب و اجرا میشود.

#### اگر در اجرای اول به مشکل برخورد، بار دوم اجرا کنید. باگ روی سرور های ایران هست متاسفانه.
---
اگر روی سرور ایران محدودیت روی پورت ۲۲ برای اتصال SSH وجود دارد، ابتدا با روش دیگری (مثل کنسول ابری یا پورت جایگزین) وارد سرور ایران شوید و سپس اسکریپت زیر را اجرا کنید تا پورت SSH تغییر کند:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/ExtremeDot/Tunnel-Protocol-tester/main/change_ssh_port.sh)
```

---

تستر چندپروتکله برای بررسی وضعیت تانل ریورس **frp** بین سرور ایران و خارج.

### پروتکل‌های پشتیبانی‌شده

| پروتکل       | توضیح                          | لایه   |
|--------------|--------------------------------|--------|
| **TCP**      | پایدار و پیش‌فرض               | TCP    |
| **KCP**      | مناسب شبکه‌های پرتأخیر و پرلگ  | UDP    |
| **QUIC**     | مدرن، مالتی‌پلکسینگ قوی        | UDP    |
| **WebSocket**| مناسب عبور از فایروال و CDN    | TCP    |

---

## ویژگی‌ها

- تشخیص خودکار سرور ایران / خارج
- نصب ایزوله باینری‌های frp (بدون تداخل با نسخه‌های موجود)
- همگام‌سازی نسخه کلاینت و سرور
- باز کردن خودکار پورت‌ها روی UFW
- پشتیبانی از یوزر غیر روت (با `sudo`)
- پورت‌های رندوم و غیرمعمول
- خروجی رنگی و خوانا
- مناسب سرورهای کند ایران (دارای مکث بین مراحل)

---

## پیش‌نیازها

روی **سرور خارج** اجرا شود:

```bash
apt update
apt install -y curl wget tar netcat-openbsd sshpass openssl
```

---

## نصب و اجرا

### روش استاندارد 


```bash
bash <(curl -sSL https://raw.githubusercontent.com/ExtremeDot/Tunnel-Protocol-tester/main/frp_test.sh)
```

### روش سریع


```bash
bash <(curl -sSL https://raw.githubusercontent.com/ExtremeDot/Tunnel-Protocol-tester/main/frp_test.sh) \
  --iran-host IP_OR_DOMAIN \
  --iran-port 22 \
  --iran-user root \
  --iran-pass 'PASSWORD'
```

### روش دستی

```bash
wget -O frp_test.sh https://raw.githubusercontent.com/ExtremeDot/Tunnel-Protocol-tester/main/frp_test.sh
chmod +x frp_test.sh

./frp_test.sh \
  --iran-host 2.144.x.x \
  --iran-port 22 \
  --iran-user cloud-admin \
  --iran-pass 'YourPassword'
```

---

## پارامترها

| پارامتر         | توضیح                        | پیش‌فرض |
|-----------------|------------------------------|---------|
| `--iran-host`   | آی‌پی یا دامنه سرور ایران    | —       |
| `--iran-port`   | پورت SSH                     | `22`    |
| `--iran-user`   | نام کاربری SSH               | `root`  |
| `--iran-pass`   | رمز عبور SSH                 | —       |

---

## نمونه خروجی

```
╔════════════════════════════════════════════╗
║           FINAL TEST RESULTS               ║
╚════════════════════════════════════════════╝

  PROTOCOL       STATUS
  ────────────────────────────
  TCP            ✔  SUCCESS
  KCP            ✔  SUCCESS
  QUIC           ✔  SUCCESS
  WebSocket      ✔  SUCCESS
```

---


## نکات مهم

1. اسکریپت باید از **سرور خارج** اجرا شود.
2. باینری‌های frp در مسیر زیر ذخیره می‌شوند و با نسخه‌های سیستم تداخل ندارند:
   ```
   /opt/frp_tester/bin/
   ```
3. در صورت فعال بودن UFW، پورت‌های مورد نیاز به‌صورت خودکار باز می‌شوند.
4. بین راه‌اندازی سرور ایران و شروع تست‌ها ۸ ثانیه مکث وجود دارد (مناسب سرورهای کند).

---


### FRP

```
bash frp_test.sh --iran-host IP.IP.IP.IP --iran-port 22 --iran-user root --iran-pass 'PASSWORD'
```

##### Example:

ار سرور خارج دستور رو اجرا میکنید

خودش به سرور ایران وصل میشه
فایل های مورد نیاز رو روی دو تا سرور نصب و تونل ها با پروتوکل ها رو راه اندازی و تست میگیره، در انتهای بهتون میگه که کدوم تانل ها اامکان برقراری داره

روی frp از پروتوکل های زیر تست میگیره


```
TCP
KCP
QUIC
WEB SOCKET
```

نمونه دستور اجرای برای سرور ابران با آی پی 2.3.4.5 با یوزر روت و پسورد دسترسی `qI78jNJGBSNB`

```
bash frp_test.sh --iran-host 2.3.4.5.6 --iran-port 22 --iran-user root --iran-pass 'qI78jNJGBSNB'
```

## مجوز

MIT License
