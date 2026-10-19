# awg-relay — راهنمای فارسی راه‌اندازی

> نسخه‌ی انگلیسی: [README.en.md](README.en.md)

`awg-relay` یک باینری تکی (Rust) است که روی **هر دو سرور** نصب می‌شود و یک تونل **AmneziaWG v3** بین سرور ایران و سرور خارج می‌سازد. سرور ایران نقش **relay** دارد: کاربر به IP ایران وصل می‌شود و ترافیک او از داخل تونل به Xray روی سرور خارج می‌رسد.

```
کاربر ──▶ ایران 198.51.100.20:443 ──▶ [ تونل AmneziaWG ] ──▶ خارج 10.8.0.1:443 (Xray)
```

روی سیمِ ایران↔خارج فقط یک جریان **UDP مبهم‌سازی‌شده** دیده می‌شود (و در حالت wrap، شبیه **TCP**). دیگر خبری از GRE و امضای protocol 47 نیست.

---

## فهرست

1. [سناریوی فرضی این راهنما](#۱-سناریوی-فرضی-این-راهنما)
2. [پیش‌نیازها](#۲-پیشنیازها)
3. [قرار دادن باینری روی سرورها](#۳-قرار-دادن-باینری-روی-سرورها)
4. [راه‌اندازی پایه (مثال اصلی)](#۴-راهاندازی-پایه-مثال-اصلی)
5. [تنظیم Xray روی سرور خارج](#۵-تنظیم-xray-روی-سرور-خارج)
6. [تغییر کانفیگ کلاینت‌ها](#۶-تغییر-کانفیگ-کلاینتها)
7. [مثال‌های کاربردی دیگر](#۷-مثالهای-کاربردی-دیگر)
8. [حالت udp2raw (پنهان کردن UDP به شکل TCP)](#۸-حالت-udp2raw-پنهان-کردن-udp-به-شکل-tcp)
9. [پروفایل رم](#۹-پروفایل-رم)
10. [مدیریت روزمره](#۱۰-مدیریت-روزمره)
11. [عیب‌یابی](#۱۱-عیبیابی)
12. [حذف و نصب مجدد](#۱۲-حذف-و-نصب-مجدد)
13. [مرجع سریع دستورات](#۱۳-مرجع-سریع-دستورات)

---

## ۱. سناریوی فرضی این راهنما

همه‌ی مثال‌ها با این مقادیر فرضی نوشته شده‌اند. موقع اجرا، IPهای واقعی خودتان را جایگزین کنید.

| مورد | مقدار فرضی |
|---|---|
| IP عمومی سرور **خارج** | `203.0.113.10` |
| IP عمومی سرور **ایران** | `198.51.100.20` |
| پورت Xray روی خارج | `443` (کانفیگ Xray از قبل وجود دارد) |
| پورتی که کاربران به ایران وصل می‌شوند | `443` |
| پورت تونل AmneziaWG (UDP) | `51820` |
| IP داخل تونل — خارج | `10.8.0.1` |
| IP داخل تونل — ایران | `10.8.0.2` |
| سیستم‌عامل هر دو سرور | Ubuntu 24.04 |

مسیر کامل یک بسته:

```
کاربر
  │  vless://...@198.51.100.20:443
  ▼
سرور ایران (198.51.100.20)
  │  iptables DNAT:  :443  ──▶  10.8.0.1:443
  ▼
تونل AmneziaWG  (198.51.100.20 ──UDP:51820──▶ 203.0.113.10)
  ▼
سرور خارج (10.8.0.1 روی اینترفیس awg0)
  │
  ▼
Xray روی پورت 443
```

> نکته: فوروارد در سطح **کرنل** (iptables) انجام می‌شود، نه در یک پروسه‌ی جداگانه؛ برای همین روی سرور ۱ گیگی هم با حدود ۱۰۰ کاربر همزمان مصرف رم ناچیز است.

---

## ۲. پیش‌نیازها

- دو سرور **Ubuntu 24.04** با دسترسی `root` (یا `sudo`).
- سرور ایران باید بتواند به `203.0.113.10` روی **UDP 51820** برسد (در حالت wrap: **TCP 4096**).
- هر دو سرور باید به مخازن Ubuntu و PPA آمنزیا (`ppa:amnezia/ppa`) دسترسی داشته باشند، چون نصب‌کننده AmneziaWG را از آنجا نصب می‌کند.
- روی سرور خارج، Xray روی پورت `443` در حال اجراست.

**فایروال:**

روی سرور **خارج**:

```bash
sudo ufw allow 51820/udp          # پورت تونل
sudo ufw allow in on awg0         # اجازه‌ی ورود ترافیکِ داخل تونل به Xray
```

روی سرور **ایران** (اگر ufw فعال است):

```bash
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
```

---

## ۳. قرار دادن باینری روی سرورها

باینری را روی **هر دو سرور** در مسیر `/usr/local/bin/awg-relay` قرار دهید.

> ⚠️ مهم: سرویس systemd مسیر همان باینری‌ای را ثبت می‌کند که `install` با آن اجرا شده. پس **همیشه** از `/usr/local/bin/awg-relay` اجرا کنید، نه از پوشه‌ی دانلود یا `/tmp`.

### روش الف — کپی باینری آماده

از کامپیوتر خودتان (یا هر جایی که باینری را دارید):

```bash
scp awg-relay root@203.0.113.10:/usr/local/bin/awg-relay
scp awg-relay root@198.51.100.20:/usr/local/bin/awg-relay
```

سپس روی هر سرور:

```bash
sudo chmod +x /usr/local/bin/awg-relay
awg-relay --version
```

### روش ب — ساخت از سورس

روی سروری که Rust دارد:

```bash
tar -xzf awg-relay-src.tar.gz
cd awg-relay
cargo build --release
sudo install -m0755 target/release/awg-relay /usr/local/bin/awg-relay
```

اگر سرور ایران به اینترنت آزاد دسترسی ندارد، باینری را روی خارج بسازید و به ایران کپی کنید:

```bash
# روی سرور خارج
scp /usr/local/bin/awg-relay root@198.51.100.20:/usr/local/bin/awg-relay
```

---

## ۴. راه‌اندازی پایه (مثال اصلی)

راه‌اندازی **سه قدم** دارد و ترتیبش مهم است: **خارج ← ایران ← خارج**.

```
 قدم ۱ (خارج)  ──توکن AWGR1-...──▶  قدم ۲ (ایران)
 قدم ۳ (خارج)  ◀──کلید عمومی ایران──  قدم ۲ (ایران)
```

### قدم ۱ — سرور خارج (`203.0.113.10`)

```bash
sudo awg-relay install --role kharej --endpoint 203.0.113.10
```

این دستور:
- AmneziaWG v3 را نصب می‌کند (ماژول کرنل با DKMS؛ اگر نشد، خودکار نسخه‌ی userspace)،
- کلیدها و پارامترهای مبهم‌سازی را می‌سازد،
- اینترفیس `awg0` را با IP `10.8.0.1` بالا می‌آورد،
- و در آخر یک **توکن** چاپ می‌کند.

خروجی انتهای دستور شبیه این است:

```
================ NEXT STEP ================
On the IRAN node, run install with this peer token:

  awg-relay install --role iran --peer AWGR1-djogMQpwdWJsaWNfa2V5OiBVTVUw...

Then paste the IRAN public key it prints back here:

  awg-relay add-peer <IRAN_PUBLIC_KEY>
===========================================
```

کل رشته‌ی `AWGR1-...` را کپی کنید (حدود ۴۰۰ کاراکتر، یک خط).

> این توکن شامل کلید عمومی خارج، آدرس، و پارامترهای مبهم‌سازی است. پارامترهای `S1–S4` و `H1–H4` باید در دو سر **دقیقاً یکی** باشند، وگرنه handshake هرگز برقرار نمی‌شود؛ توکن این تطابق را خودکار تضمین می‌کند.

### قدم ۲ — سرور ایران (`198.51.100.20`)

```bash
sudo awg-relay install --role iran --peer AWGR1-djogMQpwdWJsaWNfa2V5OiBVTVUw...
```

(به‌جای `AWGR1-...` توکن کامل قدم ۱ را بگذارید.)

این دستور AmneziaWG را نصب می‌کند، تنظیمات را از توکن برمی‌دارد، تونل را بالا می‌آورد و پورت `443` ایران را به `10.8.0.1:443` فوروارد می‌کند. در پایان چاپ می‌کند:

```
================ NEXT STEP ================
On the KHAREJ node, register this iran node:

  awg-relay add-peer kOeESYkGkrzsqvJsGzSRPzV3DB+knIYbjQiHw6cXs0c=

Make sure Xray on kharej listens on 10.8.0.1 at ports [443].
===========================================
```

کلید عمومی ایران (رشته‌ی ۴۴ کاراکتری که با `=` تمام می‌شود) را کپی کنید.

### قدم ۳ — دوباره سرور خارج

```bash
sudo awg-relay add-peer kOeESYkGkrzsqvJsGzSRPzV3DB+knIYbjQiHw6cXs0c=
```

حالا تونل کامل است.

### بررسی

روی سرور **ایران**:

```bash
ping -c3 10.8.0.1
awg-relay status
```

خروجی سالم `status` شبیه این است:

```
role:    iran
profile: auto (low)
iface:   awg0 (mtu 1320)
self ip: 10.8.0.2
peer ip: 10.8.0.1
endpoint:203.0.113.10:51820
relay: tcp+udp ports [443] -> 10.8.0.1
wrap:    none
service: active
handshake: 12s ago
transfer: rx 3 MiB / tx 1 MiB
```

اگر `handshake: none` دیدید، به بخش [عیب‌یابی](#۱۱-عیبیابی) بروید.

---

## ۵. تنظیم Xray روی سرور خارج

ترافیک از تونل با مقصد `10.8.0.1:443` به سرور خارج می‌رسد. پس Xray باید روی این آدرس هم گوش بدهد.

**حالت معمول — نیازی به تغییر نیست:** اگر inbound شما روی `0.0.0.0` یا خالی (همه‌ی آدرس‌ها) گوش می‌دهد، `10.8.0.1` را هم پوشش می‌دهد.

```json
{
  "listen": "0.0.0.0",
  "port": 443,
  "protocol": "vless",
  "...": "..."
}
```

**اگر listen روی IP عمومی ست شده** (مثلاً `"listen": "203.0.113.10"`)، آن را خالی یا `0.0.0.0` کنید. اگر می‌خواهید inbound **فقط** از طریق ایران قابل دسترس باشد:

```json
{
  "listen": "10.8.0.1",
  "port": 443,
  "protocol": "vless",
  "...": "..."
}
```

> در پنل سنایی (3x-ui): فیلد **Listen IP** در تنظیمات inbound را خالی بگذارید یا `10.8.0.1` بنویسید.

**بررسی روی خارج:**

```bash
ss -lntup | grep ':443'
```

باید `0.0.0.0:443` یا `10.8.0.1:443` را ببینید.

> ⚠️ **نکته‌ی محدودیت IP:** چون ایران ترافیک را SNAT می‌کند، Xray روی خارج **همه‌ی کاربرانی که از ایران می‌آیند را با IP `10.8.0.2` می‌بیند**. اگر در 3x-ui برای کلاینت‌ها «IP Limit» گذاشته‌اید، برای این مسیر کار نخواهد کرد (همه یک IP حساب می‌شوند). لاگ‌های Xray هم IP واقعی کاربر را نشان نمی‌دهند.

---

## ۶. تغییر کانفیگ کلاینت‌ها

relay در لایه‌ی ۴ (TCP/UDP) کار می‌کند و TLS را باز نمی‌کند؛ پس در کانفیگ کاربر **فقط آدرس سرور** به IP ایران تغییر می‌کند. UUID، SNI، Public Key ریلیتی، path و بقیه دست‌نخورده می‌مانند.

**قبل (اتصال مستقیم به خارج):**

```
vless://UUID@203.0.113.10:443?security=reality&sni=www.example.com&pbk=PUBKEY&type=tcp#direct
```

**بعد (از طریق relay ایران):**

```
vless://UUID@198.51.100.20:443?security=reality&sni=www.example.com&pbk=PUBKEY&type=tcp#via-iran
```

**اگر inbound با TLS و دامنه کار می‌کند** (مثلاً `sub.example.com`)، دو راه دارید:

- رکورد DNS دامنه را به IP ایران (`198.51.100.20`) تغییر دهید؛ گواهی TLS همچنان روی خارج می‌ماند و درست کار می‌کند.
- یا در کانفیگ کاربر `address` را `198.51.100.20` بگذارید و `sni`/`host` را همان دامنه نگه دارید.

---

## ۷. مثال‌های کاربردی دیگر

در همه‌ی مثال‌ها ترتیب سه‌قدمی بخش ۴ ثابت است؛ فقط پرچم‌ها عوض می‌شوند.

### مثال ۱ — رله‌ی چند پورت

Xray روی خارج روی پورت‌های `443`، `8443` و `2053` inbound دارد و می‌خواهید هر سه از ایران رله شوند.

خارج (بدون تغییر):

```bash
sudo awg-relay install --role kharej --endpoint 203.0.113.10
```

ایران — پورت‌ها را با کاما جدا کنید:

```bash
sudo awg-relay install --role iran --peer AWGR1-... --relay-ports 443,8443,2053
```

خارج:

```bash
sudo awg-relay add-peer <IRAN_PUBLIC_KEY>
```

نتیجه:

```
198.51.100.20:443   ──▶  10.8.0.1:443
198.51.100.20:8443  ──▶  10.8.0.1:8443
198.51.100.20:2053  ──▶  10.8.0.1:2053
```

> پورت‌های رله فقط روی **ایران** تعیین می‌شوند (داخل توکن نیستند). پورت ایران و پورت خارج همیشه یکی است.

### مثال ۲ — فقط TCP (بدون UDP)

اگر inboundهای شما UDP لازم ندارند:

```bash
sudo awg-relay install --role iran --peer AWGR1-... --no-udp
```

و برعکس، فقط UDP:

```bash
sudo awg-relay install --role iran --peer AWGR1-... --no-tcp
```

> هر دو را با هم نمی‌شود خاموش کرد. پیش‌فرض، رله‌ی **هر دو** پروتکل است.

### مثال ۳ — تغییر پورت تونل

اگر پورت `51820/udp` روی مسیر شما مشکل دارد، روی **خارج** پورت دیگری بدهید (مثلاً `40000`):

```bash
sudo awg-relay install --role kharej --endpoint 203.0.113.10 --port 40000
sudo ufw allow 40000/udp
```

روی **ایران** نیازی به `--port` نیست؛ پورت از داخل توکن خوانده می‌شود:

```bash
sudo awg-relay install --role iran --peer AWGR1-...
```

### مثال ۴ — پروفایل رم ثابت

به‌طور پیش‌فرض پروفایل از روی رم سرور خودکار انتخاب می‌شود. برای تعیین دستی هنگام نصب:

```bash
sudo awg-relay install --role kharej --endpoint 203.0.113.10 --profile low
```

جزئیات در [بخش ۹](#۹-پروفایل-رم).

### مثال ۵ — ترکیب کامل

خارج با پورت تونل سفارشی و پروفایل ثابت، ایران با چند پورت و فقط TCP:

```bash
# خارج
sudo awg-relay install --role kharej --endpoint 203.0.113.10 --port 40000 --profile low

# ایران
sudo awg-relay install --role iran --peer AWGR1-... --relay-ports 443,8443 --no-udp

# خارج
sudo awg-relay add-peer <IRAN_PUBLIC_KEY>
```

### مثال ۶ — گرفتن دوباره‌ی توکن یا کلید

اگر خروجی نصب را گم کردید:

```bash
# روی خارج: توکن را دوباره چاپ می‌کند
awg-relay show-peer

# روی ایران: کلید عمومی ایران را دوباره چاپ می‌کند
awg-relay show-peer
```

### مثال ۷ — اضافه کردن پورت بعد از نصب

مثلاً بعداً پورت `2083` را هم می‌خواهید رله کنید. روی **ایران** فایل کانفیگ را باز کنید:

```bash
sudo nano /etc/awg-relay/config.yaml
```

بخش `relay` را این‌طور تغییر دهید:

```yaml
relay:
  ports:
  - 443
  - 8443
  - 2083
  tcp: true
  udp: true
```

و اعمال کنید:

```bash
sudo awg-relay up
```

> بخش‌های `obfs` و `wrap` را در کانفیگ **دستی تغییر ندهید**؛ این مقادیر باید در دو سرور یکسان باشند. برای عوض کردنشان از [نصب مجدد](#۱۲-حذف-و-نصب-مجدد) استفاده کنید.

---

## ۸. حالت udp2raw (پنهان کردن UDP به شکل TCP)

در حالت پیش‌فرض، روی سیم UDP مبهم‌سازی‌شده دیده می‌شود. اگر روزی همین هم محدود شد، می‌توانید تونل را داخل **udp2raw** بپیچید تا روی سیم شبیه یک اتصال **TCP** معمولی دیده شود.

```
ایران:  AWG ──▶ 127.0.0.1:52820 ──▶ udp2raw client ──┐
                                                       │  FakeTCP روی سیم (پورت 4096)
خارج:   AWG ◀── 127.0.0.1:51820 ◀── udp2raw server ◀──┘
```

> توصیه: اول بدون wrap راه بیندازید. فقط اگر لازم شد wrap را روشن کنید.

### مثال ۸ — wrap با FakeTCP (حالت پیشنهادی)

wrap فقط روی **خارج** تعیین می‌شود؛ ایران آن را (همراه کلید مشترک) از توکن می‌گیرد.

خارج:

```bash
sudo awg-relay install --role kharej --endpoint 203.0.113.10 --wrap udp2raw
sudo ufw allow 4096/tcp
```

در خروجی این خط را می‌بینید:

```
wrap: udp2raw enabled (faketcp). Open inbound port 4096 on this server's firewall.
```

ایران (بدون پرچم wrap):

```bash
sudo awg-relay install --role iran --peer AWGR1-...
```

خارج:

```bash
sudo awg-relay add-peer <IRAN_PUBLIC_KEY>
```

بررسی روی ایران:

```bash
awg-relay status
```

```
wrap:    udp2raw (faketcp, raw-port 4096) active
```

### مثال ۹ — wrap روی پورت دیگر

```bash
sudo awg-relay install --role kharej --endpoint 203.0.113.10 --wrap udp2raw --raw-port 8880
sudo ufw allow 8880/tcp
```

### مثال ۱۰ — حالت‌های دیگر udp2raw

```bash
# FakeTCP (پیش‌فرض)
--wrap udp2raw --raw-mode faketcp

# UDP خام
--wrap udp2raw --raw-mode udp

# ICMP (شبیه ping)
--wrap udp2raw --raw-mode icmp
```

### مثال ۱۱ — وقتی ایران به GitHub دسترسی ندارد

نصب‌کننده udp2raw را از GitHub دانلود می‌کند. اگر سرور ایران نتواند، باینری را از خارج کپی کنید.

روی **خارج** (بعد از نصب با wrap، باینری در `/usr/bin/udp2raw` است):

```bash
scp /usr/bin/udp2raw root@198.51.100.20:/root/udp2raw_amd64
```

روی **ایران**:

```bash
sudo awg-relay install --role iran --peer AWGR1-... --udp2raw-bin /root/udp2raw_amd64
```

اگر خارج هم دسترسی ندارد، فایل `udp2raw_binaries.tar.gz` را از صفحه‌ی release پروژه‌ی udp2raw روی سیستم خودتان دانلود کنید، `udp2raw_amd64` را از آن استخراج کنید و با `--udp2raw-bin` روی هر دو سرور بدهید.

### نکات wrap

- MTU تونل در حالت wrap خودکار ۸۰ بایت کم می‌شود (مثلاً `1320` → `1240`).
- udp2raw با سرویس جداگانه‌ی `awg-relay-wrap.service` اجرا می‌شود و قبل از تونل بالا می‌آید.
- پرچم `-a` در udp2raw قانون لازم iptables (drop کردن RST کرنل) را خودش اضافه و حذف می‌کند.

---

## ۹. پروفایل رم

پروفایل، اندازه‌ی جدول conntrack، بافر سوکت‌ها، MTU و شدت junk packetها را تنظیم می‌کند.

| پروفایل | رم سرور | conntrack | بافر سوکت | MTU |
|---|---|---|---|---|
| `low` | تا ۱.۵ گیگ | 65536 | 8 MiB | 1320 |
| `mid` | تا ۳ گیگ | 131072 | 16 MiB | 1360 |
| `high` | بیشتر از ۳ گیگ | 262144 | 32 MiB | 1380 |

برای سرور خارج ۱ گیگی، حالت `auto` خودش `low` را انتخاب می‌کند.

### تغییر پروفایل بعد از نصب

```bash
sudo awg-relay set-profile low
sudo awg-relay set-profile mid
sudo awg-relay set-profile high
sudo awg-relay set-profile auto
```

> ⚠️ پروفایل روی MTU اثر دارد. اگر پروفایل یک سرور را عوض کردید، **روی سرور دیگر هم همان پروفایل** را بزنید تا MTU دو سر یکی بماند.

> برای تغییر پروفایل از `set-profile` استفاده کنید و خط `profile` را در `config.yaml` دستی ویرایش نکنید؛ فرمت ذخیره‌اش (`!fixed low`) برای ویرایش دستی مناسب نیست.

---

## ۱۰. مدیریت روزمره

| کار | دستور |
|---|---|
| وضعیت لحظه‌ای | `awg-relay status` |
| عیب‌یابی خودکار | `awg-relay doctor` |
| بالا آوردن / اعمال دوباره‌ی تنظیمات | `sudo awg-relay up` |
| پایین آوردن | `sudo awg-relay down` |
| لاگ سرویس اصلی | `journalctl -u awg-relay -e` |
| لاگ udp2raw | `journalctl -u awg-relay-wrap -f` |
| وضعیت خام تونل | `sudo awg show awg0` |

بعد از ری‌استارت سرور، سرویس `awg-relay.service` تونل و قوانین iptables را خودکار برمی‌گرداند؛ نیازی به `iptables-persistent` نیست.

**فایل‌های مهم:**

| فایل | توضیح |
|---|---|
| `/etc/awg-relay/config.yaml` | کانفیگ اصلی (شامل کلید خصوصی، دسترسی فقط root) |
| `/etc/amnezia/amneziawg/awg0.conf` | کانفیگ تولیدشده‌ی AmneziaWG (دستی ویرایش نکنید) |
| `/etc/systemd/system/awg-relay.service` | سرویس اصلی |
| `/etc/systemd/system/awg-relay-wrap.service` | سرویس udp2raw (فقط در حالت wrap) |

---

## ۱۱. عیب‌یابی

اولین قدم همیشه:

```bash
awg-relay doctor
```

خروجی سالم روی ایران:

```
awg-relay doctor  (role: iran)
----------------------------------------
[OK  ] awg / awg-quick installed
[OK  ] AmneziaWG backend: kernel
[OK  ] interface awg0 present
[OK  ] obfuscation parameters valid
[OK  ] local + peer keys configured
[OK  ] last handshake 12s ago
[OK  ] transfer rx=3 MiB tx=1 MiB
[OK  ] net.ipv4.ip_forward enabled
[OK  ] relay nat chain present
[OK  ] systemd unit active
----------------------------------------
ping peer tunnel IP to verify path: ping -c3 10.8.0.1
```

### مشکل: `no handshake yet`

تونل برقرار نشده. به ترتیب بررسی کنید:

1. **قدم ۳ را فراموش کرده‌اید؟** روی خارج `awg-relay status` بزنید؛ اگر کلید ایران ثبت نشده، `add-peer` را اجرا کنید.
2. **فایروال خارج:** پورت `51820/udp` (یا پورتی که با `--port` دادید) باز است؟
   ```bash
   sudo ufw status
   ```
3. **توکن ناقص کپی شده؟** روی خارج `awg-relay show-peer` بزنید و دوباره روی ایران `install` را با توکن کامل اجرا کنید.
4. **دسترسی شبکه:** از ایران به `203.0.113.10` می‌رسید؟
   ```bash
   ping -c3 203.0.113.10
   ```

### مشکل: handshake هست ولی کاربر وصل نمی‌شود

تونل سالم است، مشکل از رله یا Xray است.

روی **ایران** — قوانین فوروارد و شمارنده‌ی بسته‌ها:

```bash
sudo iptables -t nat -L AWGR_PRE -n -v
```

باید خطی مثل این ببینید:

```
pkts bytes target  prot  ...  tcp dpt:443 to:10.8.0.1:443
```

اگر `pkts` صفر است، ترافیک کاربر اصلاً به ایران نمی‌رسد (فایروال ایران یا آدرس کانفیگ کاربر را بررسی کنید).

روی **ایران** — دسترسی به Xray از داخل تونل:

```bash
nc -vz 10.8.0.1 443
```

اگر وصل نشد، روی **خارج**:

```bash
ss -lntup | grep ':443'       # Xray روی 0.0.0.0 یا 10.8.0.1 گوش می‌دهد؟
sudo ufw allow in on awg0     # ufw ترافیک تونل را مسدود نکند
```

### مشکل: سرعت پایین یا قطع‌ووصل صفحات سنگین

احتمالاً مشکل MTU است. پروفایل را یک پله پایین بیاورید (روی **هر دو** سرور):

```bash
sudo awg-relay set-profile low
```

### مشکل: wrap فعال است ولی وصل نمی‌شود

```bash
awg-relay doctor
journalctl -u awg-relay-wrap -e
```

- `udp2raw binary present: FAIL` ← باینری نصب نشده؛ [مثال ۱۱](#مثال-۱۱--وقتی-ایران-به-github-دسترسی-ندارد).
- پورت `4096/tcp` روی فایروال خارج باز است؟

### مشکل: نصب AmneziaWG خطا می‌دهد

- بررسی کنید سرور به `ppa.launchpadcontent.net` و مخازن Ubuntu دسترسی دارد.
- اگر ماژول کرنل build نشد، نصب‌کننده خودکار به نسخه‌ی userspace (`amneziawg-go`) می‌رود. در `doctor` خط `AmneziaWG backend` نشان می‌دهد کدام فعال است.

---

## ۱۲. حذف و نصب مجدد

### حذف کامل تنظیمات

روی هر سرور:

```bash
sudo awg-relay uninstall
```

تونل، قوانین iptables، سرویس‌ها و `config.yaml` حذف می‌شوند. **بسته‌های AmneziaWG باقی می‌مانند** تا نصب بعدی سریع‌تر باشد.

### عوض کردن پارامترهای مبهم‌سازی (rotate)

اگر احساس کردید پروفایل مبهم‌سازی شناسایی شده، با نصب مجدد پارامترها و کلیدهای جدید ساخته می‌شوند:

```bash
# خارج
sudo awg-relay uninstall
sudo awg-relay install --role kharej --endpoint 203.0.113.10

# ایران (با توکن جدید)
sudo awg-relay uninstall
sudo awg-relay install --role iran --peer AWGR1-...جدید...

# خارج
sudo awg-relay add-peer <کلید جدید ایران>
```

### روشن کردن wrap روی نصب موجود

همان روند rotate است، فقط روی خارج `--wrap udp2raw` اضافه کنید.

---

## ۱۳. مرجع سریع دستورات

### پرچم‌های `install`

| پرچم | توضیح | پیش‌فرض | کجا |
|---|---|---|---|
| `--role iran\|kharej` | نقش سرور | — (اجباری) | هر دو |
| `--endpoint <IP>` | IP عمومی خارج | — (اجباری روی خارج) | خارج |
| `--peer <توکن>` | توکن خروجی خارج | — (اجباری روی ایران) | ایران |
| `--port <n>` | پورت UDP تونل | `51820` | خارج |
| `--relay-ports a,b,c` | پورت‌های رله | `443` | ایران |
| `--no-tcp` | خاموش کردن رله‌ی TCP | روشن | ایران |
| `--no-udp` | خاموش کردن رله‌ی UDP | روشن | ایران |
| `--profile auto\|low\|mid\|high` | پروفایل رم | `auto` | هر دو |
| `--wrap none\|udp2raw` | لایه‌ی wrap | `none` | خارج |
| `--raw-port <n>` | پورت udp2raw | `4096` | خارج |
| `--raw-mode faketcp\|udp\|icmp` | حالت udp2raw | `faketcp` | خارج |
| `--udp2raw-bin <مسیر>` | باینری udp2raw محلی | دانلود خودکار | هر دو |

### دستورات دیگر

| دستور | کار |
|---|---|
| `awg-relay add-peer <کلید یا توکن>` | ثبت طرف مقابل و بالا آوردن کامل تونل |
| `awg-relay show-peer` | چاپ دوباره‌ی توکن (خارج) / کلید (ایران) |
| `awg-relay status` | وضعیت |
| `awg-relay doctor` | عیب‌یابی |
| `awg-relay up` | اعمال تنظیمات و بالا آوردن |
| `awg-relay down` | پایین آوردن |
| `awg-relay set-profile <p>` | تغییر پروفایل رم |
| `awg-relay uninstall` | حذف تنظیمات و سرویس‌ها |

### خلاصه‌ی کل راه‌اندازی در یک نگاه

```bash
# ── خارج (203.0.113.10) ──
sudo ufw allow 51820/udp && sudo ufw allow in on awg0
sudo awg-relay install --role kharej --endpoint 203.0.113.10
#   → توکن AWGR1-... را کپی کن

# ── ایران (198.51.100.20) ──
sudo awg-relay install --role iran --peer AWGR1-...
#   → کلید عمومی ایران را کپی کن

# ── خارج ──
sudo awg-relay add-peer <IRAN_PUBLIC_KEY>

# ── ایران: بررسی ──
ping -c3 10.8.0.1 && awg-relay status

# ── کلاینت‌ها: فقط آدرس را عوض کن ──
# vless://UUID@198.51.100.20:443?...
```

---

> این ابزار مبهم‌سازی انجام می‌دهد و تضمین دائمی در برابر شناسایی نیست؛ ولی بسیار مقاوم‌تر از GRE خام است. ترتیب پیشنهادی: اول AmneziaWG ساده، در صورت شناسایی rotate، و در صورت نیاز wrap با udp2raw.
