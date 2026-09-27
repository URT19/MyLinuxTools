# Paqet Auto Optimizer (a21)

**نسخه اسکریپت:** V3.0  
**نسخه Paqet هدف:** [`hanselime/paqet v1.0.0-alpha.21`](https://github.com/hanselime/paqet)  
**هدف:** پیدا کردن بهترین تنظیمات KCP بین دو سرور (خارج / ایران) به‌صورت خودکار و greedy.

این نسخه نسبت به نسخه‌های قبلی پارامترهای بیشتری را پوشش می‌دهد (sndwnd، rcvwnd، smuxbuf، streambuf و پارامترهای manual mode) و قوانین `iptables` لازم برای NOTRACK و DROP RST را خودش مدیریت می‌کند.

---

## چه کاری انجام می‌دهد؟

1. **دانلود باینری Paqet** (v1.0.0-alpha.21) و انتقال امن آن به سرور دوم با تأیید SHA256
2. **اندازه‌گیری baseline** مستقیم (بدون تونل) با `iperf3` — قابل غیرفعال‌سازی با `BASELINE=0`
3. **تنظیم greedy چندمرحله‌ای** روی این پارامترها:
   - **Mode** → `normal`, `fast`, `fast2`, `fast3`, `manual`
   - **MTU** → `1500` … `1150` (گام ۵۰)
   - **sndwnd** → `128`, `256`, `512`, `1024`, `2048`, `4096`
   - **rcvwnd** → `512`, `1024`, `2048`, `4096`
   - **conn** → `1`, `2`, `4`, `8`
   - **block** (رمزنگاری) → `aes`, `xor`, `none`
   - **smuxbuf** → `4MB`, `8MB`, `16MB`
   - **streambuf** → `2MB`, `4MB`, `8MB`
4. اگر **mode=manual** برنده شود، به‌صورت خودکار این پارامترها هم sweep می‌شوند:
   - `nodelay` (0 / 1)
   - `interval` (5 / 10 / 20)
   - `resend` (0 / 1 / 2)
   - `nocongestion` (0 / 1)
   - `wdelay` (false / true)
   - `acknodelay` (true / false)
5. قوانین **iptables** لازم (NOTRACK + DROP RST روی پورت KCP) را خودش اضافه و بعد از هر تست پاک می‌کند
6. در پایان بهترین ترکیب + سرعت هر مرحله + کلید مشترک را گزارش می‌دهد

---

## پیش‌نیازها

| مورد | توضیح |
|------|--------|
| سیستم‌عامل | Ubuntu 22.04 یا 24.04 (هر دو سرور) |
| دسترسی | root روی هر دو سرور |
| شبکه | دسترسی SSH از سرور **اجراکننده (معمولاً خارج)** به سرور دوم (ایران) |
| ابزار | `sshpass` (اسکریپت خودش نصب می‌کند) |
| سرور دوم | باید `iptables` و `iproute2` داشته باشد |

> اسکریپت را روی سرور **خارج (Kharej)** اجرا کنید. سرور ایران فقط مقصد SSH است.

---

## فایل‌های موجود در این پوشه

| فایل | توضیح |
|------|--------|
| `paqet-optimizer.sh` | اسکریپت اصلی تیونر |
| `server.yaml.example` | نمونه کانفیگ سرور (مرجع) |
| `client.yaml.example` | نمونه کانفیگ کلاینت (مرجع) |
| `README.md` | همین مستند |

---

## نصب و اجرا

### روش سریع

```bash
# دانلود اسکریپت
curl -fsSL -o paqet-optimizer.sh \
  "https://raw.githubusercontent.com/URT19/MyLinuxTools/main/Paqet%20Auto%20Optimizer/a21/paqet-optimizer.sh"

chmod +x paqet-optimizer.sh

# اجرا
sudo IRAN_IP=<آی‌پی-سرور-دوم> IRAN_PASS=<پسورد> ./paqet-optimizer.sh
```

### روش کلون کردن مخزن

```bash
git clone https://github.com/URT19/MyLinuxTools.git
cd "MyLinuxTools/Paqet Auto Optimizer/a21"
sudo IRAN_IP=<آی‌پی-سرور-دوم> IRAN_PASS=<پسورد> ./paqet-optimizer.sh
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
| `DEBUG` | `0` | اگر `1` باشد بعد از هر تست pause می‌کند و وضعیت (پروسه‌ها، لاگ، کانفیگ) را نشان می‌دهد |
| `BASELINE` | `1` | اگر `0` باشد تست baseline مستقیم اجرا نمی‌شود |

### قفل کردن پارامترها (Skip کردن Sweep)

هر کدام که ست شود، مرحله مربوطه skip می‌شود و همان مقدار استفاده می‌گردد:

| متغیر | مقادیر مجاز / محدوده | مثال |
|-------|----------------------|------|
| `MODE` | `normal`, `fast`, `fast2`, `fast3`, `manual` | `MODE=fast3` |
| `MTU` | عدد (۵۰–۱۵۰۰) | `MTU=1400` |
| `SNDWND` | عدد | `SNDWND=2048` |
| `RCVWND` | عدد | `RCVWND=2048` |
| `CONN` | عدد (۱–۲۵۶) | `CONN=8` |
| `BLOCK` | `aes`, `xor`, `none` | `BLOCK=xor` |
| `SMUXBUF` | عدد (بایت) | `SMUXBUF=8388608` |
| `STREAMBUF` | عدد (بایت) | `STREAMBUF=4194304` |
| `NODELAY` | `0`, `1` | `NODELAY=1` |
| `INTERVAL` | عدد (میلی‌ثانیه) | `INTERVAL=10` |
| `RESEND` | `0`, `1`, `2` | `RESEND=2` |
| `NOCONG` | `0`, `1` | `NOCONG=1` |
| `WDELAY` | `false`, `true` | `WDELAY=false` |
| `ACKNODELAY` | `true`, `false` | `ACKNODELAY=true` |

> پارامترهای `NODELAY`, `INTERVAL`, `RESEND`, `NOCONG`, `WDELAY`, `ACKNODELAY` **فقط** وقتی اعمال می‌شوند که `mode=manual` باشد.

---

## مثال‌های کاربردی

### اجرای کامل (همه پارامترها تست شوند)

```bash
sudo IRAN_IP=1.2.3.4 IRAN_PASS='your-password' ./paqet-optimizer.sh
```

### بدون baseline

```bash
sudo BASELINE=0 \
  IRAN_IP=1.2.3.4 IRAN_PASS='your-password' \
  ./paqet-optimizer.sh
```

### فقط Mode را قفل کنید (بقیه sweep شوند)

```bash
sudo MODE=fast3 \
  IRAN_IP=1.2.3.4 IRAN_PASS='your-password' \
  ./paqet-optimizer.sh
```

### همه پارامترها دستی (فقط یک تست سریع)

```bash
sudo MODE=manual MTU=1400 SNDWND=2048 RCVWND=2048 CONN=4 BLOCK=xor \
     NODELAY=1 INTERVAL=10 RESEND=2 NOCONG=1 WDELAY=false ACKNODELAY=true \
     SMUXBUF=8388608 STREAMBUF=4194304 \
     BASELINE=0 \
     IRAN_IP=1.2.3.4 IRAN_PASS='your-password' \
     ./paqet-optimizer.sh
```

### با حالت Debug

```bash
sudo DEBUG=1 MODE=fast \
  IRAN_IP=1.2.3.4 IRAN_PASS='your-password' \
  ./paqet-optimizer.sh
```

### پورت SSH غیر استاندارد

```bash
sudo IRAN_IP=1.2.3.4 IRAN_PORT=2222 IRAN_PASS='your-password' ./paqet-optimizer.sh
```

---

## خروجی نمونه

در پایان گزارش نهایی شبیه این نمایش داده می‌شود:

```
==========================================================
                 FINAL REPORT
==========================================================
Baseline (no tunnel) : 95.30 Mbit/s

Stage 1 - Mode:
  normal               72.10 Mbit/s
  fast                 81.40 Mbit/s
  fast2                83.20 Mbit/s
  fast3                84.90 Mbit/s
  manual               85.30 Mbit/s
  -> winner: manual

Stage 2 - MTU:
  ...
  -> winner: 1400

Stage 3 - sndwnd:
  ...
  -> winner: 2048

...

Best overall config:
  mode=manual mtu=1400 sndwnd=2048 rcvwnd=2048
  conn=4 block=xor smuxbuf=8388608 streambuf=4194304
  nodelay=1 interval=10 resend=2
  nocongestion=1 wdelay=false acknodelay=true
  shared key=AbCdEf123456...
==========================================================
```

---

## نکات مهم

- در طول تست، همه پروسه‌های `paqet` و `iperf3` روی **هر دو سرور** با `pkill` پاک می‌شوند.
- فایل‌های کانفیگ در مسیر `/run/paqet-optimizer/configs/` ساخته می‌شوند و به‌صورت خودکار **interface** و **MAC روتر** هر سرور تشخیص داده می‌شود.
- قوانین **iptables** روی سرور اول (NOTRACK + DROP RST روی پورت KCP) به‌صورت خودکار اضافه و بعد از هر تست پاک می‌شوند.
- کلید رمزنگاری (`key`) هر بار به‌صورت تصادفی ساخته می‌شود و بین دو سرور یکسان است.
- باینری هر نسخه در مسیر `/opt/paqet-optimizer/bin/<version>/` نگه داشته می‌شود تا نسخه‌های مختلف با هم تداخل نکنند.
- پورت‌های ثابت تست:
  - `50001` → iperf3 سمت سرور
  - `50002` → forward کلاینت
- مدت هر تست `iperf3`: ۱۰ ثانیه (+ ۲ ثانیه warm-up)
- باینری از این آدرس دانلود می‌شود:  
  `https://github.com/hanselime/paqet/releases/download/v1.0.0-alpha.21/paqet-linux-amd64-v1.0.0-alpha.21.tar.gz`

---

## تفاوت با نسخه قبلی (غیر a21)

| مورد | نسخه قبلی | این نسخه (a21 / V3.0) |
|------|-----------|------------------------|
| نسخه Paqet | v2.2.0-optimized (بسته سفارشی) | hanselime/paqet v1.0.0-alpha.21 |
| پارامترهای sweep | mode, mtu, conn, block | + sndwnd, rcvwnd, smuxbuf, streambuf + پارامترهای manual |
| Baseline | همیشه فعال | اختیاری (`BASELINE=0`) |
| مدیریت iptables | ندارد | دارد (NOTRACK + DROP RST) |
| مسیر باینری | `/opt/paqet-optimizer/bin` | `/opt/paqet-optimizer/bin/<version>/` |

---

## ساختار مراحل Sweep

| مرحله | پارامتر | مقادیر تست‌شده |
|-------|---------|-----------------|
| 1 | Mode | normal, fast, fast2, fast3, manual |
| 1b | (اگر manual) nodelay / interval / resend / nocongestion / wdelay / acknodelay | مقادیر لیست‌شده در بالا |
| 2 | MTU | 1500 → 1150 |
| 3 | sndwnd | 128 … 4096 |
| 4 | rcvwnd | 512 … 4096 |
| 5 | conn | 1, 2, 4, 8 |
| 6 | block | aes, xor, none |
| 7 | smuxbuf | 4M, 8M, 16M |
| 8 | streambuf | 2M, 4M, 8M |

---

## مجوز و مسئولیت

این ابزار برای استفاده شخصی و آزمایشی ارائه شده است.  
قبل از استفاده در محیط تولید حتماً تست کنید. نویسنده مسئولیتی در قبال قطعی سرویس یا مشکلات ناشی از استفاده نادرست ندارد.

---

**مخزن اصلی:** [URT19/MyLinuxTools](https://github.com/URT19/MyLinuxTools)  
**مسیر این نسخه:** `Paqet Auto Optimizer/a21/`  
**پروژه Paqet:** [hanselime/paqet](https://github.com/hanselime/paqet)
