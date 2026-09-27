# Paqet Auto Optimizer

**نسخه:** V2.1  
**هدف:** پیدا کردن بهترین تنظیمات `Paqet` (حالت KCP) بین دو سرور (خارج / ایران) به‌صورت خودکار و greedy.

اسکریپت یک baseline مستقیم با `iperf3` می‌گیرد، سپس پارامترهای مهم را مرحله‌به‌مرحله تست می‌کند و بهترین ترکیب را گزارش می‌دهد.

---

## چه کاری انجام می‌دهد؟

1. **دانلود باینری Paqet** (نسخه بهینه‌شده v2.2.0) و انتقال امن آن به سرور دوم با تأیید SHA256
2. **اندازه‌گیری baseline** مستقیم (بدون تونل) با `iperf3`
3. **تنظیم greedy چندمرحله‌ای**:
   - **Mode** → `fast`, `fast2`, `fast3`, `normal`, `manual`
   - **MTU** → `1500` تا `1150` (با گام ۵۰)
   - **CONN** → `2`, `4`, `8`
   - **Block** (رمزنگاری) → `aes`, `xor`, `none`
4. گزارش نهایی بهترین ترکیب + سرعت هر مرحله + کلید مشترک

---

## پیش‌نیازها

| مورد | توضیح |
|------|--------|
| سیستم‌عامل | Ubuntu 22.04 یا 24.04 (هر دو سرور) |
| دسترسی | root روی هر دو سرور |
| شبکه | دسترسی SSH از سرور **خارج (Kharej)** به سرور **ایران** |
| ابزار | `sshpass` (اسکریپت خودش نصب می‌کند) |

> اسکریپت را روی سرور **خارج** اجرا کنید. سرور ایران فقط مقصد SSH است.

---

## نصب و اجرا

### روش سریع

```bash

curl -fsSL -o paqet-optimizer.sh \
  "https://raw.githubusercontent.com/URT19/MyLinuxTools/main/Paqet%20Auto%20Optimizer/paqet-optimizer.sh"
```

```
chmod +x paqet-optimizer.sh
```

```
sudo IRAN_IP=<آی‌پی-ایران> IRAN_PASS=<پسورد> ./paqet-optimizer.sh
```

### روش کلون کردن مخزن

```bash
git clone https://github.com/URT19/MyLinuxTools.git
cd "MyLinuxTools/Paqet Auto Optimizer"
sudo IRAN_IP=<آی‌پی-ایران> IRAN_PASS=<پسورد> ./paqet-optimizer.sh
```

اگر متغیرهای محیطی را ندهید و ترمینال تعاملی باشد، اسکریپت از شما IP، یوزر، پسورد و پورت را می‌پرسد.

---

## متغیرهای محیطی

### اتصال SSH

| متغیر | پیش‌فرض | توضیح |
|-------|---------|--------|
| `IRAN_IP` | — | IP سرور ایران (**اجباری**) |
| `IRAN_USER` | `root` | نام کاربری SSH |
| `IRAN_PASS` | — | پسورد SSH (**اجباری**) |
| `IRAN_PORT` | `22` | پورت SSH |

### حالت اجرا

| متغیر | پیش‌فرض | توضیح |
|-------|---------|--------|
| `DEBUG` | `0` | اگر `1` باشد بعد از هر مرحله pause می‌کند و وضعیت (پروسه‌ها، لاگ، کانفیگ) را نشان می‌دهد |

### قفل کردن پارامترها (Skip کردن Sweep)

اگر هر کدام از این متغیرها ست شود، مرحله مربوطه انجام نمی‌شود و مقدار داده شده استفاده می‌گردد:

| متغیر | مقادیر مجاز | مثال |
|-------|-------------|------|
| `MODE` | `fast`, `fast2`, `fast3`, `normal`, `manual` | `MODE=fast3` |
| `MTU` | عدد (مثلاً `1400`) | `MTU=1400` |
| `CONN` | عدد (مثلاً `8`) | `CONN=8` |
| `BLOCK` | `aes`, `xor`, `none` | `BLOCK=xor` |

---

## مثال‌های کاربردی

### اجرای کامل (همه پارامترها تست شوند)

```bash
sudo IRAN_IP=1.2.3.4 IRAN_PASS='your-password' ./paqet-optimizer.sh
```

### فقط Mode را قفل کنید

```bash
sudo MODE=fast3 \
  IRAN_IP=1.2.3.4 IRAN_PASS='your-password' \
  ./paqet-optimizer.sh
```

### همه پارامترها دستی (فقط یک تست سریع)

```bash
sudo MODE=fast3 MTU=1400 CONN=8 BLOCK=xor \
  IRAN_IP=1.2.3.4 IRAN_PASS='your-password' \
  ./paqet-optimizer.sh
```

### با حالت Debug

```bash
sudo DEBUG=1 MODE=fast3 \
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
  fast                 78.40 Mbit/s
  fast2                81.20 Mbit/s
  fast3                84.50 Mbit/s
  ...
  -> winner: fast3

Stage 2 - MTU:
  mtu=1500             82.10 Mbit/s
  mtu=1450             83.70 Mbit/s
  ...
  -> winner: 1400

Stage 3 - CONN:
  ...
  -> winner: 8

Stage 4 - BLOCK:
  ...
  -> winner: xor

Best overall config:
  mode=fast3 mtu=1400 conn=8 block=xor
  shared key=AbCdEf123456...
==========================================================
```

---

## نکات مهم

- در طول تست، همه پروسه‌های `paqet` و `iperf3` روی **هر دو سرور** با `pkill` پاک می‌شوند.
- فایل‌های کانفیگ در مسیر `/run/paqet-optimizer/configs/` ساخته می‌شوند و به‌صورت خودکار **interface** و **MAC روتر** هر سرور در آن‌ها قرار می‌گیرد.
- کلید رمزنگاری (`key`) هر بار به‌صورت تصادفی ساخته می‌شود و بین سرور و کلاینت یکسان است.
- باینری از این آدرس دانلود می‌شود:  
  `https://github.com/behzadea12/Paqet-Tunnel-Manager/releases/download/PaqetOptimized/paqet-linux-amd64-v2.2.0-optimize.tar.gz`
- مسیر نصب محلی و ریموت: `/opt/paqet-optimizer`
- مدت هر تست `iperf3`: ۱۰ ثانیه (+ ۲ ثانیه warm-up)

---

## ساختار داخلی اسکریپت (خلاصه)

| بخش | وظیفه |
|-----|--------|
| `cleanup_*` | پاک‌سازی پروسه‌ها و فایل‌های موقت |
| `remote_exec` / `remote_copy_atomic` | اجرای دستور و کپی امن با تأیید SHA256 |
| `detect_*_network` | تشخیص interface، IP و MAC روتر |
| `generate_*_config` | ساخت فایل YAML سرور/کلاینت |
| `run_baseline_iperf` | اندازه‌گیری سرعت مستقیم |
| `measure_paqet` | راه‌اندازی تونل + تست سرعت برای یک ترکیب پارامتر |
| مراحل ۱ تا ۴ | Greedy sweep روی Mode → MTU → CONN → Block |

---

## مجوز و مسئولیت

این ابزار برای استفاده شخصی و آزمایشی ارائه شده است.  
قبل از استفاده در محیط تولید، حتماً تست کنید. نویسنده مسئولیتی در قبال قطعی سرویس یا مشکلات ناشی از استفاده نادرست ندارد.

---

**مخزن اصلی:** [URT19/MyLinuxTools](https://github.com/URT19/MyLinuxTools)  
**مسیر پروژه:** `Paqet Auto Optimizer/`
