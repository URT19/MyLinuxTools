# GRE Auto Optimizer

اسکریپت تیونر خودکار برای تانل GRE (با/بدون IPsec) بین دو سرور.
پارامترهای مختلف را مرحله‌به‌مرحله sweep می‌کند و بهترین ترکیب را پیدا می‌کند.

## پیش‌نیاز

- دو سرور Ubuntu 22/24 با دسترسی root.
- دسترسی SSH از سرور اجراکننده به سرور دوم.
- `sshpass` روی سرور اجراکننده (اسکریپت نصب می‌کند).
- کرنل با پشتیبانی `ip_gre` / `esp4` / `xfrm_user`.

## اجرا

```bash
sudo IRAN_IP=<remote-ip> IRAN_PASS=<password> ./gre-optimizer.sh


متغیرهای محیطی
اتصال
متغیر	پیش‌فرض	توضیح
IRAN_IP	—	IP سرور دوم (اجباری)
IRAN_USER	root	یوزر SSH
IRAN_PASS	—	پسورد SSH (اجباری)
IRAN_PORT	22	پورت SSH
حالت اجرا
متغیر	پیش‌فرض	توضیح
DEBUG	0	pause بین تست‌ها و نمایش وضعیت
BASELINE	1	اگر 0 باشد، تست baseline مستقیم اجرا نمی‌شود
IPSEC_KEY	تصادفی	کلید hex برای IPsec (۴۰ کاراکتر برای AES-GCM)
Override پارامترها (skip کردن sweep)
متغیر	مقادیر
GRE_MODE	gre
MTU	عدد
IPSEC	on, off
IPSEC_CIPHER	aes128gcm, aes256gcm, chacha20poly1305
TTL	عدد
MASQ	on, off
MSS_CLAMP	on, off
OFFLOAD	on, off
TXQLEN	عدد
TCP_TUNED	default, tuned
مثال‌ها
بدون baseline و فقط GRE ساده:

bash
sudo BASELINE=0 GRE_MODE=gre MTU=1400 IPSEC=off \
  IRAN_IP=<remote-ip> IRAN_PASS=<password> \
  ./gre-optimizer.sh
GRE با IPsec و cipher مشخص:

bash
sudo GRE_MODE=gre MTU=1400 IPSEC=on IPSEC_CIPHER=aes256gcm \
  IRAN_IP=<remote-ip> IRAN_PASS=<password> \
  ./gre-optimizer.sh
با debug:

bash
sudo DEBUG=1 IRAN_IP=<remote-ip> IRAN_PASS=<password> ./gre-optimizer.sh
مراحل sweep
Stage	پارامتر	مقادیر
1	GRE mode	gre
2	MTU	1500 .. 1150
3	IPsec	off, on
4	IPsec cipher	aes128gcm, aes256gcm, chacha20poly1305
5	TTL	64, 128, 255
6	MASQUERADE	off, on
7	MSS clamp	off, on
8	offload (GRO/GSO/TSO)	on, off
9	txqueuelen	1000, 5000, 10000
10	TCP sysctl	default, tuned
در هر مرحله، مقدار برنده قفل می‌شود و مرحله‌ی بعدی با آن ادامه می‌دهد (greedy).

خروجی
در پایان:

جدول نتایج هر مرحله و برنده‌ی آن.

بهترین ترکیب کلی با سرعت نهایی.

دو بلوک دستور آماده برای کپی-پیست روی هر سرور (شامل GRE، MSS clamp، MASQUERADE، sysctl و IPsec اگر فعال باشد).

نکته‌ها
IPsec در حالت transport mode روی پروتکل GRE (proto 47) اعمال می‌شود، بدون daemon (با ip xfrm).

کلید IPsec یک بار در هر تست ساخته می‌شود و روی دو سرور یکسان است.

هر تست با ping بین دو IP تانل اعتبارسنجی می‌شود.

در طول تست، تنظیمات قبلی پاک می‌شوند تا با تست بعدی تداخل نکنند.

net.ipv4.ip_forward=1 روی هر دو سرور فعال می‌شود.

آدرس تانل به‌صورت پیش‌فرض 172.31.255.1/30 (ایران) و 172.31.255.2/30 (خارج) است.

پس از پایان، interfaceها، state/policy های xfrm، قوانین iptables موقت و پروسه‌های iperf پاک می‌شوند.

محدودیت‌ها
gretap پشتیبانی نمی‌شود چون کرنل با ip tunnel add ... mode gretap خطا می‌دهد.

GRE در Linux روی یک هسته پردازش می‌شود؛ پهنای باند نهایی معمولاً به محدودیت تک‌هسته‌ای گره می‌خورد.

اگر IPsec فعال باشد، بسته به cipher و توان CPU، سرعت می‌تواند کاهش پیدا کند.