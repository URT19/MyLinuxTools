# GRE Auto Optimizer

**نسخه:** V1.0  
**هدف:** پیدا کردن بهترین تنظیمات تانل **GRE** (با یا بدون IPsec) بین دو سرور به‌صورت خودکار و greedy.

اسکریپت پارامترهای مختلف را مرحله‌به‌مرحله تست می‌کند، بهترین مقدار هر مرحله را قفل می‌کند و در پایان علاوه بر گزارش، **دستورات آماده کپی-پیست** برای هر دو سرور را چاپ می‌کند.

---

## چه کاری انجام می‌دهد؟

1. اتصال SSH به سرور دوم و نصب وابستگی‌ها
2. بارگذاری ماژول‌های کرنل لازم (`ip_gre`, `esp4`, `xfrm_user` و ...)
3. (اختیاری) اندازه‌گیری **baseline** مستقیم با `iperf3`
4. **تنظیم greedy** روی این پارامترها:
   - GRE mode
   - MTU
   - IPsec (on/off)
   - IPsec cipher
   - TTL
   - MASQUERADE
   - MSS clamp
   - Offload (GRO/GSO/TSO)
   - txqueuelen
   - TCP sysctl (default / tuned)
5. اعتبارسنجی هر تست با `ping` بین IPهای تانل
6. گزارش نهایی + **دستورات آماده** برای استقرار روی هر دو سرور

---

## پیش‌نیازها

| مورد | توضیح |
|------|--------|
| سیستم‌عامل | Ubuntu 22.04 یا 24.04 (هر دو سرور) |
| دسترسی | root روی هر دو سرور |
| شبکه | دسترسی SSH از سرور **اجراکننده (معمولاً خارج)** به سرور دوم |
| کرنل | پشتیبانی از `ip_gre` / `esp4` / `xfrm_user` |
| ابزار | `sshpass` (اسکریپت خودش نصب می‌کند) |

> اسکریپت را روی سرور **خارج (Kharej)** اجرا کنید.

---

## نصب و اجرا

### روش سریع

```bash
curl -fsSL -o gre-optimizer.sh \
  "https://raw.githubusercontent.com/URT19/MyLinuxTools/main/GRE%20Optimizer/gre-optimizer.sh"

chmod +x gre-optimizer.sh

sudo IRAN_IP=<آی‌پی-سرور-دوم> IRAN_PASS=<پسورد> ./gre-optimizer.sh
```

### روش کلون کردن مخزن

```bash
git clone https://github.com/URT19/MyLinuxTools.git
cd "MyLinuxTools/GRE Optimizer"
sudo IRAN_IP=<آی‌پی-سرور-دوم> IRAN_PASS=<پسورد> ./gre-optimizer.sh
```

اگر متغیرهای محیطی را ندهید و ترمینال تعاملی باشد، اسکریپت از شما IP، یوزر، پسورد و پورت را می‌پرسد.

---

## متغیرهای محیطی

### اتصال SSH

| متغیر | پیش‌فرض | توضیح |
|-------|---------|--------|
| `IRAN_IP` | — | IP سرور دوم (**اجباری**) |
| `IRAN_USER` | `root` | نام کاربری SSH |
| `IRAN_PASS` | — | پسورد SSH (**اجباری**) |
| `IRAN_PORT` | `22` | پورت SSH |

### حالت اجرا

| متغیر | پیش‌فرض | توضیح |
|-------|---------|--------|
| `DEBUG` | `0` | اگر `1` باشد بین تست‌ها pause می‌کند و وضعیت را نشان می‌دهد |
| `BASELINE` | `1` | اگر `0` باشد تست baseline مستقیم اجرا نمی‌شود |
| `IPSEC_KEY` | تصادفی | کلید hex برای IPsec (۴۰ کاراکتر برای AES-GCM) |

### قفل کردن پارامترها (Skip کردن Sweep)

| متغیر | مقادیر مجاز | مثال |
|-------|-------------|------|
| `GRE_MODE` | `gre` | `GRE_MODE=gre` |
| `MTU` | عدد | `MTU=1400` |
| `IPSEC` | `on`, `off` | `IPSEC=off` |
| `IPSEC_CIPHER` | `aes128gcm`, `aes256gcm`, `chacha20poly1305` | `IPSEC_CIPHER=aes256gcm` |
| `TTL` | عدد | `TTL=64` |
| `MASQ` | `on`, `off` | `MASQ=on` |
| `MSS_CLAMP` | `on`, `off` | `MSS_CLAMP=on` |
| `OFFLOAD` | `on`, `off` | `OFFLOAD=off` |
| `TXQLEN` | عدد | `TXQLEN=5000` |
| `TCP_TUNED` | `default`, `tuned` | `TCP_TUNED=tuned` |

---

## مثال‌های کاربردی

### اجرای کامل

```bash
sudo IRAN_IP=1.2.3.4 IRAN_PASS='your-password' ./gre-optimizer.sh
```

### بدون baseline و فقط GRE ساده (بدون IPsec)

```bash
sudo BASELINE=0 GRE_MODE=gre MTU=1400 IPSEC=off \
  IRAN_IP=1.2.3.4 IRAN_PASS='your-password' \
  ./gre-optimizer.sh
```

### GRE با IPsec و cipher مشخص

```bash
sudo GRE_MODE=gre MTU=1400 IPSEC=on IPSEC_CIPHER=aes256gcm \
  IRAN_IP=1.2.3.4 IRAN_PASS='your-password' \
  ./gre-optimizer.sh
```

### با کلید IPsec دستی

```bash
sudo IPSEC=on IPSEC_KEY='0123456789abcdef0123456789abcdef01234567' \
  IRAN_IP=1.2.3.4 IRAN_PASS='your-password' \
  ./gre-optimizer.sh
```

### با حالت Debug

```bash
sudo DEBUG=1 IRAN_IP=1.2.3.4 IRAN_PASS='your-password' ./gre-optimizer.sh
```

---

## مراحل Sweep

| مرحله | پارامتر | مقادیر تست‌شده |
|-------|---------|-----------------|
| 1 | GRE mode | `gre` |
| 2 | MTU | `1500`, `1476`, `1450`, `1420`, `1400`, `1380`, `1350`, `1300`, `1250`, `1200`, `1150` |
| 3 | IPsec | `off`, `on` |
| 4 | IPsec cipher | `aes128gcm`, `aes256gcm`, `chacha20poly1305` *(فقط اگر IPsec=on)* |
| 5 | TTL | `64`, `128`, `255` |
| 6 | MASQUERADE | `off`, `on` |
| 7 | MSS clamp | `off`, `on` |
| 8 | Offload (GRO/GSO/TSO) | `on`, `off` |
| 9 | txqueuelen | `1000`, `5000`, `10000` |
| 10 | TCP sysctl | `default`, `tuned` |

در هر مرحله مقدار برنده قفل می‌شود و مرحله بعدی با همان مقدار ادامه پیدا می‌کند (**greedy**).

---

## خروجی

در پایان اسکریپت موارد زیر را نمایش می‌دهد:

1. **جدول نتایج** هر مرحله + برنده آن
2. **بهترین ترکیب کلی** با سرعت نهایی
3. **دو بلوک دستور آماده** برای کپی-پیست:
   - سمت **خارج (Kharej)**
   - سمت **ایران**
   - شامل: GRE tunnel، MSS clamp، MASQUERADE، sysctl و در صورت نیاز IPsec

### آدرس‌های پیش‌فرض تانل

| سمت | IP تانل |
|-----|---------|
| ایران | `172.31.255.1/30` |
| خارج | `172.31.255.2/30` |
| نام اینترفیس | `gre1` |

---

## نکات مهم

- **IPsec** در حالت **transport mode** روی پروتکل GRE (proto 47) اعمال می‌شود و بدون daemon (با `ip xfrm`) کار می‌کند.
- کلید IPsec یک بار در هر اجرا ساخته می‌شود (یا از `IPSEC_KEY` خوانده می‌شود) و روی هر دو سرور یکسان است.
- هر تست با `ping` بین دو IP تانل اعتبارسنجی می‌شود.
- در طول تست، تنظیمات قبلی پاک می‌شوند تا با تست بعدی تداخل نکنند.
- `net.ipv4.ip_forward=1` روی هر دو سرور فعال می‌شود.
- پس از پایان، اینترفیس‌ها، state/policyهای xfrm، قوانین iptables موقت و پروسه‌های iperf پاک می‌شوند.
- مدت هر تست `iperf3`: ۱۰ ثانیه (+ ۲ ثانیه warm-up).

---

## محدودیت‌ها

| مورد | توضیح |
|------|--------|
| gretap | پشتیبانی نمی‌شود؛ کرنل با `ip tunnel add ... mode gretap` خطا می‌دهد |
| تک‌هسته‌ای بودن GRE | در لینوکس GRE روی یک هسته پردازش می‌شود؛ پهنای باند نهایی معمولاً به محدودیت تک‌هسته‌ای گره می‌خورد |
| هزینه IPsec | اگر IPsec فعال باشد، بسته به cipher و توان CPU سرعت می‌تواند کاهش یابد |

---

## ساختار داخلی (خلاصه)

| بخش | وظیفه |
|-----|--------|
| `cleanup_local` / `cleanup_remote` | پاک‌سازی اینترفیس GRE، xfrm و iperf |
| `ssh_kh` / `ssh_kh_script` | اجرای دستور روی سرور ایران |
| راه‌اندازی GRE | ساخت تانل، تنظیم MTU، TTL، txqueuelen |
| راه‌اندازی IPsec | state و policy با `ip xfrm` (transport mode) |
| MSS / MASQ / Offload / TCP | اعمال تنظیمات اختیاری |
| `measure_gre` | راه‌اندازی کامل + تست سرعت با iperf3 |
| مراحل ۱ تا ۱۰ | Greedy sweep روی پارامترها |
| گزارش نهایی | چاپ نتایج + دستورات آماده استقرار |

---

## مجوز و مسئولیت

این ابزار برای استفاده شخصی و آزمایشی ارائه شده است.  
قبل از استفاده در محیط تولید حتماً تست کنید. نویسنده مسئولیتی در قبال قطعی سرویس یا مشکلات ناشی از استفاده نادرست ندارد.

---

**مخزن اصلی:** [URT19/MyLinuxTools](https://github.com/URT19/MyLinuxTools)  
**مسیر پروژه:** `GRE Optimizer/`
