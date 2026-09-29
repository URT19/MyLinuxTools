# GRE Extreme Manager (v3.0)

```
curl -o gre_extreme.sh https://raw.githubusercontent.com/URT19/MyLinuxTools/refs/heads/main/Gre_Manager/gre_extreme.sh

chmod +x gre_extreme.sh

nano gre_extreme.sh
```

ابتدا از سرور ایران، 
مقادیر اولیه رو برای آی پی سرور ایران و خارج و پورت هایی که قراره فوروارد بشه رو ویرایش و بروزرسانی کنید.

بعد اسکریپت رو اجرا کنید

```bash
bash /root/gre_extreme.sh run
```

بعد همین فایل رو به سرور خارج با دستور زیر انتقال بدید

```
apt install sshpass -y
sleep 1
cp gre_extreme.sh gre_extreme_kharej.sh && \
sed -i 's/^RUN_SCRIPT="IRAN"/#RUN_SCRIPT="IRAN"/; s/^#RUN_SCRIPT="KHAREJ"/RUN_SCRIPT="KHAREJ"/' gre_extreme_kharej.sh && \
read -p "KHAREJ host (IP or hostname): " HOST && \
read -p "User (default: root): " USER && USER=${USER:-root} && \
read -sp "Password: " PASS && echo && \
sshpass -p "$PASS" scp -o StrictHostKeyChecking=no gre_extreme_kharej.sh ${USER}@${HOST}:~/gre_extreme.sh

```

بعد وارد سرور خارج میشیم و دستور زیر رو وارد میکنیم

```
chmod +x gre_extreme.sh
bash /root/gre_extreme.sh run
```

--------


اسکریپت مدیریت تونل GRE بین دو سرور (ایران ↔ خارج) با این قابلیت‌ها:

- ساخت و نگهداری خودکار تونل GRE
- تشخیص خودکار MTU و کلَمپ MSS
- پورت‌فوروارد از سرور ایران به سرور خارج از طریق تونل
- بررسی سلامت تونل و بازسازی خودکار (با کرون)
- تیونینگ کرنل برای پایداری
- قفل `flock` برای جلوگیری از اجرای هم‌زمان و لاگ با محدودیت حجم

---

## سناریوی نمونه

| | سرور ایران | سرور خارج |
|---|---|---|
| IP عمومی | `27.30.125.94` | `207.131.135.125` |
| IP تونل | `172.31.255.1/30` | `172.31.255.2/30` |
| مقدار `RUN_SCRIPT` | `IRAN` | `KHAREJ` |

کاربر به IP سرور ایران وصل می‌شود، سرور ایران پورت‌های `80, 443, 2053` را از طریق تونل به سرور خارج (`172.31.255.2`) می‌فرستد.

```
کاربر ──► ایران:443 ══[ GRE 172.31.255.1 ↔ .2 ]══► خارج:443 ──► اینترنت
```

---

## پیش‌نیازها

- دسترسی `root` روی هر دو سرور
- ابزارهای `ip`, `iptables`, `sysctl`, `ping`, `crontab`, `flock` (روی اکثر توزیع‌ها پیش‌فرض نصب هستند)
- **باز بودن پروتکل GRE (IP protocol 47) در فایروال هر دو سرور** (این پروتکل TCP/UDP نیست و پورت ندارد)

اگر روی سرورها فایروال دارید، مثلاً:

```bash
# روی سرور ایران (IP سرور خارج را بگذارید)
iptables -I INPUT -p gre -s 207.131.135.125 -j ACCEPT

# روی سرور خارج (IP سرور ایران را بگذارید)
iptables -I INPUT -p gre -s 27.30.125.94 -j ACCEPT
```

---

## نصب

### ۱) روی سرور خارج

```bash
nano /root/gre_extreme.sh        # محتوای اسکریپت را بچسبانید
chmod +x /root/gre_extreme.sh
```

در بخش تنظیمات فقط این خط را عوض کنید:

```bash
RUN_SCRIPT="KHAREJ"
```

اجرا:

```bash
bash /root/gre_extreme.sh run
```

### ۲) روی سرور ایران

همان فایل را کپی کنید (مثلاً با `scp`) و مقدار زیر را بگذارید:

```bash
RUN_SCRIPT="IRAN"
```

اجرا:

```bash
bash /root/gre_extreme.sh run
```

> **نکته:** بقیه‌ی متغیرها باید روی هر دو سرور **یکسان** باشند. فقط `RUN_SCRIPT` فرق دارد.

---

## دستورات

| دستور | کار |
|---|---|
| `bash gre_extreme.sh run` | ساخت تونل، تیونینگ، قوانین فایروال و نصب کرون |
| `bash gre_extreme.sh check` | بررسی سلامت و بازسازی در صورت خرابی (کرون خودش صدا می‌زند) |
| `bash gre_extreme.sh status` | نمایش وضعیت تونل، MTU و قوانین NAT |
| `bash gre_extreme.sh stop` | حذف تونل، قوانین پورت‌فوروارد و کرون‌ها |

---

## توضیح متغیرها

### تنظیمات پایه

| متغیر | پیش‌فرض | توضیح |
|---|---|---|
| `RUN_SCRIPT` | `IRAN` | سمت این سرور: `IRAN` یا `KHAREJ` |
| `GRE_LOCAL_IP_IRAN` | `27.30.125.94` | IP عمومی سرور ایران |
| `GRE_LOCAL_IP_KHAREJ` | `207.131.135.125` | IP عمومی سرور خارج |
| `GRE_NAME` | `gre1` | نام اینترفیس تونل |
| `GRE_TUN_IP_IRAN` | `172.31.255.1/30` | IP داخل تونل سمت ایران |
| `GRE_TUN_IP_KHAREJ` | `172.31.255.2/30` | IP داخل تونل سمت خارج |
| `GRE_TTL` | `255` | TTL تونل |

### MTU

| متغیر | پیش‌فرض | توضیح |
|---|---|---|
| `GRE_MTU_AUTO` | `yes` | تشخیص خودکار با پینگ. اگر `no` باشد مستقیم `GRE_MTU_FALLBACK` اعمال می‌شود |
| `GRE_MTU_MAX` | `1400` | سقف MTU تونل |
| `GRE_MTU_MIN` | `1280` | کف MTU در تشخیص خودکار |
| `GRE_MTU_FALLBACK` | `1400` | مقدار جایگزین وقتی تشخیص ممکن نیست (مثلاً ICMP بلاک است) |

### پورت‌فوروارد (فقط روی سرور ایران اثر دارد)

| متغیر | پیش‌فرض | توضیح |
|---|---|---|
| `GRE_PORT_FORWARD_ENABLE` | `yes` | روشن/خاموش کردن پورت‌فوروارد |
| `GRE_PORT_FORWARD_MODE` | `limited` | `limited` = فقط پورت‌های لیست، `all` = همه به‌جز SSH و مستثنی‌ها |
| `GRE_PORT_FORWARD` | `80,443,2053` | لیست پورت‌ها (کاما، رنج با `:` مثل `10000:10100`) |
| `GRE_PORT_FORWARD_PROTO` | `tcp` | `tcp`، `udp` یا `"tcp udp"` |
| `GRE_PORT_FORWARD_EXCLUDE` | خالی | پورت‌های مستثنی در حالت `all` (علاوه بر SSH) |
| `GRE_PORT_FORWARD_MASQ` | `yes` | MASQUERADE روی تونل (توصیه می‌شود) |

### شبکه

| متغیر | پیش‌فرض | توضیح |
|---|---|---|
| `SSH_PORT` | خالی | خالی = خواندن خودکار از `sshd_config` (وگرنه 22) |
| `PUBLIC_IF` | خالی | خالی = تشخیص خودکار اینترفیس عمومی |

### سلامت تونل و کرون

| متغیر | پیش‌فرض | توضیح |
|---|---|---|
| `HEALTH_PING_TRIES` | `5` | تعداد تلاش پینگ؛ فقط اگر همه شکست بخورند تونل بازسازی می‌شود |
| `HEALTH_PING_TIMEOUT` | `2` | timeout هر پینگ (ثانیه) |
| `HEALTH_RECREATE_SLEEP` | `2` | مکث بین حذف و ساخت مجدد |
| `CHECK_INTERVAL_IRAN` | `12` | فاصله‌ی چک در سرور ایران (دقیقه) |
| `CHECK_INTERVAL_KHAREJ` | `10` | فاصله‌ی چک در سرور خارج (دقیقه) |

### تیونینگ کرنل

با `APPLY_TUNING="no"` کل تیونینگ غیرفعال می‌شود. بقیه‌ی مقادیر (`TUNING_*`) برابر مقادیر sysctl هستند؛ مثلاً `TUNING_TCP_RETRIES2="15"` (پیش‌فرض لینوکس).

---

## مثال‌های کامل پورت‌فوروارد

### مثال ۱: فقط چند پورت TCP (پیش‌فرض)

```bash
GRE_PORT_FORWARD_ENABLE="yes"
GRE_PORT_FORWARD_MODE="limited"
GRE_PORT_FORWARD="80,443,2053"
GRE_PORT_FORWARD_PROTO="tcp"
```

### مثال ۲: پورت‌های TCP و UDP با هم

```bash
GRE_PORT_FORWARD_MODE="limited"
GRE_PORT_FORWARD="443,8443"
GRE_PORT_FORWARD_PROTO="tcp udp"
```

### مثال ۳: یک رنج پورت به‌علاوه‌ی چند پورت تک

```bash
GRE_PORT_FORWARD_MODE="limited"
GRE_PORT_FORWARD="80,443,10000:10100"
GRE_PORT_FORWARD_PROTO="tcp"
```

> در `multiport` هر رنج دو پورت حساب می‌شود و حداکثر ۱۵ پورت مجاز است.

### مثال ۴: فوروارد همه‌ی پورت‌ها به‌جز SSH و چند پورت دلخواه

```bash
GRE_PORT_FORWARD_MODE="all"
GRE_PORT_FORWARD_PROTO="tcp udp"
GRE_PORT_FORWARD_EXCLUDE="8080,9090"   # این پورت‌ها روی خود سرور ایران می‌مانند
```

پورت SSH به‌طور خودکار مستثنی می‌شود تا دسترسی‌تان قطع نشود.

### مثال ۵: خاموش کردن پورت‌فوروارد (فقط تونل)

```bash
GRE_PORT_FORWARD_ENABLE="no"
```

---

## بررسی صحت کار

### ۱) وضعیت اسکریپت

```bash
bash /root/gre_extreme.sh status
```

خروجی سالم (نمونه‌ی سمت ایران):

```
Side        : IRAN
Local/Remote: 27.30.125.94 -> 207.131.135.125
Tunnel      : gre1  172.31.255.1/30  (peer 172.31.255.2)
gre1  UNKNOWN  172.31.255.1/30
MTU         : 1400
[OK] Tunnel healthy
```

### ۲) تست پینگ داخل تونل

```bash
# از ایران
ping -c 3 172.31.255.2

# از خارج
ping -c 3 172.31.255.1
```

### ۳) مشاهده‌ی تونل و MTU

```bash
ip -d tunnel show gre1
ip -br addr show gre1
cat /sys/class/net/gre1/mtu
```

### ۴) مشاهده‌ی قوانین پورت‌فوروارد (ایران)

```bash
iptables -t nat -nL GRE_PF
iptables -t nat -nL POSTROUTING | grep gre1
```

### ۵) تست اتصال از بیرون

از یک دستگاه دیگر به IP سرور ایران:

```bash
curl -v http://27.30.125.94:80
nc -vz 27.30.125.94 443
```

> برای اینکه تست جواب بدهد، سرویس مورد نظر روی سرور **خارج** باید روی همان پورت‌ها گوش بدهد (روی `0.0.0.0` یا IP تونل `172.31.255.2`).

### ۶) لاگ و کرون

```bash
tail -f /var/log/gre_extreme.log
crontab -l
```

کرون نصب‌شده (سمت ایران):

```
@reboot /root/gre_extreme.sh run >/dev/null 2>&1
*/12 * * * * /root/gre_extreme.sh check >/dev/null 2>&1
```

---

## عیب‌یابی

| مشکل | علت محتمل | راه‌حل |
|---|---|---|
| پینگ `172.31.255.x` جواب نمی‌دهد | پروتکل GRE در فایروال یا دیتاسنتر بلاک است | پروتکل 47 را باز کنید؛ از هر دو طرف `tcpdump -ni any proto gre` بگیرید |
| هشدار «IP محلی روی هیچ اینترفیسی نیست» | سرور پشت NAT است یا IP اشتباه وارد شده | IP را بررسی کنید؛ GRE پشت NAT معمولاً کار نمی‌کند |
| اتصال برقرار می‌شود ولی سایت‌ها نیمه‌باز می‌مانند | مشکل MTU/MSS | `GRE_MTU_AUTO="no"` و `GRE_MTU_FALLBACK="1300"` را امتحان کنید |
| «تشخیص MTU ممکن نشد» | ICMP بلاک است | طبیعی است؛ از fallback استفاده می‌شود |
| پورت‌فوروارد کار نمی‌کند | سرویس روی خارج گوش نمی‌دهد یا `PUBLIC_IF` اشتباه تشخیص داده شده | `status` را ببینید و `PUBLIC_IF` را دستی بگذارید |
| هر چند دقیقه تونل بازسازی می‌شود | لینک ناپایدار یا پینگ فیلتر است | `HEALTH_PING_TRIES` را بیشتر و `HEALTH_PING_TIMEOUT` را بالاتر ببرید |
| خطای `nf_conntrack` هنگام تیونینگ | ماژول لود نشده | اسکریپت خودش `modprobe` می‌زند؛ اگر هنوز خطا بود، پیام warning را بررسی کنید |
| اجرای اسکریپت چیزی نشان نمی‌دهد | نمونه‌ی دیگری در حال اجراست (قفل) | چند ثانیه صبر کنید و دوباره اجرا کنید |

---

## حذف کامل

```bash
bash /root/gre_extreme.sh stop
rm -f /root/gre_extreme.sh /var/log/gre_extreme.log /var/lock/gre_extreme.lock
```

`stop` تونل، قوانین NAT/FORWARD مربوط به تونل و کرون‌ها را پاک می‌کند. تنظیمات `sysctl` که با `-w` اعمال شده‌اند تا ریبوت بعدی باقی می‌مانند. خط `net.ipv4.ip_forward=1` که به `/etc/sysctl.conf` اضافه شده، دستی حذف می‌شود.

---

## نکات امنیتی و محدودیت‌ها

- **GRE رمزگذاری ندارد.** هر کسی در مسیر می‌تواند ترافیک داخل تونل را ببیند. برای حریم خصوصی، روی آن IPsec یا WireGuard بگذارید یا ترافیک را در لایه‌ی بالاتر (مثل TLS) رمز کنید.
- با `MASQ=yes`، سرور خارج IP واقعی کلاینت‌ها را نمی‌بیند و فقط `172.31.255.1` را می‌بیند.
- IPهای واقعی سرورها داخل اسکریپت هستند؛ قبل از اشتراک‌گذاری فایل، آن‌ها را حذف یا جایگزین کنید.
- قبل از استفاده در حالت `all`، مطمئن شوید که پورت SSH درست تشخیص داده شده (`status` را ببینید) تا دسترسی‌تان قطع نشود.
- این اسکریپت با `iptables` کار می‌کند. روی سیستم‌هایی که فقط `nftables` بومی دارند، باید بسته‌ی سازگاری `iptables-nft` نصب باشد.
