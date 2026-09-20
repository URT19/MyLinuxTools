# Linux-Bench

اسکریپت بنچمارک کامل و پیشرفته برای سرورهای لینوکس.  
بر پایه نسخه معروف **bench.sh** از [Teddysun](https://github.com/teddysun/across) با بهینه‌سازی و سرورهای تست اختصاصی (از جمله سرورهای ایران).

---

## 📋 فهرست مطالب

- [قابلیت‌ها](#-قابلیت‌ها)
- [اجرای سریع](#-اجرای-سریع)
- [نصب و اجرای دستی](#-نصب-و-اجرای-دستی)
- [خروجی نمونه](#-خروجی-نمونه)
- [سرورهای تست شبکه](#-سرورهای-تست-شبکه)
- [نکات مهم](#-نکات-مهم)
- [عیب‌یابی](#-عیب‌یابی)

---

## ✨ قابلیت‌ها

اسکریپت موارد زیر را به صورت خودکار بررسی و نمایش می‌دهد:

| بخش | جزئیات |
|-----|--------|
| **اطلاعات سیستم** | سیستم‌عامل، معماری، کرنل، آپتایم |
| **پردازنده (CPU)** | مدل، تعداد هسته، فرکانس، کش، پشتیبانی AES و Virtualization |
| **حافظه** | RAM کل و استفاده‌شده + Swap |
| **دیسک** | ظرفیت کل و استفاده‌شده |
| **مجازی‌سازی** | تشخیص KVM، Docker، LXC، OpenVZ، VMware، Hyper-V و ... |
| **موقعیت IP** | ISP، شهر، کشور و منطقه از طریق ipinfo.io |
| **تست I/O** | سرعت خواندن/نوشتن دیسک با `dd` |
| **تست شبکه** | سرعت آپلود، دانلود و Latency با Speedtest رسمی Ookla |

---

## 🚀 اجرای سریع

یک دستور برای دانلود و اجرا:

```bash
curl -H 'Cache-Control: no-cache' \
  "https://raw.githubusercontent.com/URT19/MyLinuxTools/refs/heads/main/Linux-Bench/bench.sh?$RANDOM" \
  -o bench.sh && chmod +x bench.sh && sudo ./bench.sh
```

> پارامتر `$RANDOM` برای جلوگیری از کش شدن فایل استفاده شده است.

---

## 📥 نصب و اجرای دستی

اگر می‌خواهید فایل را جداگانه دانلود کنید:

```bash
# دانلود
curl -H 'Cache-Control: no-cache' \
  "https://raw.githubusercontent.com/URT19/MyLinuxTools/refs/heads/main/Linux-Bench/bench.sh?$RANDOM" \
  -o bench.sh

# دادن مجوز اجرا
chmod +x bench.sh

# اجرا با دسترسی root
sudo ./bench.sh
```

---

## 📊 خروجی نمونه

پس از اجرا، خروجی تقریباً به این شکل خواهد بود:

```
-------------------- A Bench.sh Script By Teddysun -------------------
 Version            : v2026-01-31
 Usage              : wget -qO- bench.sh | bash

 CPU Model          : ...
 CPU Cores          : ...
 CPU Frequency      : ...
 CPU Cache          : ...
 AES-NI             : Enabled / Disabled
 VM-x/AMD-V         : Enabled / Disabled
 Total Disk         : ...
 Total Mem          : ...
 Total Swap         : ...
 System uptime      : ...
 Load Average       : ...
 OS                 : ...
 Arch               : ...
 Kernel             : ...
 TCP CC             : ...
 Virtualization     : KVM / Docker / Dedicated / ...
 Organization       : ...
 Location           : ...
 Region             : ...

 I/O Speed (1st run): ...
 I/O Speed (2nd run): ...
 I/O Speed (3rd run): ...
 Average I/O Speed  : ...

 Node Name          Upload Speed      Download Speed     Latency
 Speedtest.net      xx Mbps           xx Mbps            xx ms
 Tehran Irancell IR xx Mbps           xx Mbps            xx ms
 Paris, FR          xx Mbps           xx Mbps            xx ms
 Amsterdam, NL      xx Mbps           xx Mbps            xx ms
```

---

## 🌐 سرورهای تست شبکه

اسکریپت به صورت پیش‌فرض از سرورهای زیر استفاده می‌کند:

| سرور | شناسه (Server ID) | توضیح |
|------|-------------------|-------|
| Speedtest.net | پیش‌فرض | نزدیک‌ترین سرور |
| **Tehran Irancell IR** | `4317` | سرور ایران (ایرانسل) |
| Paris, FR | `61933` | پاریس، فرانسه |
| Amsterdam, NL | `41423` | آمستردام، هلند |

می‌توانید سرورهای بیشتری را با ویرایش تابع `speed()` در اسکریپت فعال کنید (چند سرور به صورت کامنت وجود دارد).

---

## 📝 نکات مهم

- **دسترسی Root لازم است**: برای تست دقیق I/O و اطلاعات سخت‌افزاری باید با `sudo` اجرا شود.
- **اتصال اینترنت**: برای دانلود `speedtest-cli` و تست شبکه نیاز به اینترنت دارید.
- **فضای دیسک**: اسکریپت فایل‌های موقتی می‌سازد و بعد از اتمام پاک می‌کند.
- **معماری‌های پشتیبانی‌شده**:
  - `x86_64` / `amd64`
  - `i386`
  - `aarch64` / `arm64`
  - `armhf` / `armel`
- **سیستم‌عامل**: عمدتاً برای Debian، Ubuntu، CentOS و توزیع‌های مشابه تست شده است.

---

## 🛠 عیب‌یابی

**خطای "No write permission":**
```bash
# در مسیری با دسترسی نوشتن اجرا کنید (مثلاً /tmp)
cd /tmp
# سپس اسکریپت را دوباره دانلود و اجرا کنید
```

**سرعت‌تست شکست می‌خورد:**
- مطمئن شوید فایروال پورت‌های لازم را مسدود نکرده باشد.
- اتصال اینترنت را بررسی کنید.
- می‌توانید سرورهای تست را در تابع `speed()` تغییر دهید.

**اسکریپت متوقف شد:**
اسکریپت با `Ctrl+C` به صورت تمیز خارج می‌شود و فایل‌های موقتی را پاک می‌کند.

---

## 📌 منابع

- اسکریپت اصلی: [Teddysun bench.sh](https://github.com/teddysun/across)
- Speedtest CLI: [Ookla](https://www.speedtest.net/apps/cli)
- اطلاعات IP: [ipinfo.io](https://ipinfo.io)

---

**ساخته‌شده و سفارشی‌سازی‌شده توسط [URT19](https://github.com/URT19)**
```
