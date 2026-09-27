# Paqet Auto Optimizer

اسکریپت تیونر خودکار برای `Paqet` (نسخه `hanselime/paqet v1.0.0-alpha.21`).
بین دو سرور اجرا می‌شود، تنظیمات KCP را مرحله‌به‌مرحله تست می‌کند و بهترین ترکیب را پیدا می‌کند.

## کاری که می‌کند

1. باینری Paqet را دانلود و با SHA256 به سرور دوم منتقل می‌کند.
2. (اختیاری) یک baseline مستقیم با `iperf3` بین دو سرور می‌گیرد.
3. به‌صورت greedy این پارامترها را یکی‌یکی sweep می‌کند و بهترین مقدار هر کدام را نگه می‌دارد:
   - `mode`
   - `mtu`
   - `sndwnd`
   - `rcvwnd`
   - `conn`
   - `block`
   - `smuxbuf`
   - `streambuf`
4. اگر `mode=manual` انتخاب شود، به‌صورت خودکار این پارامترها هم sweep می‌شوند:
   - `nodelay`
   - `interval`
   - `resend`
   - `nocongestion`
   - `wdelay`
   - `acknodelay`
5. قوانین `iptables` لازم برای NOTRACK و DROP RST روی پورت KCP را خودش ست و پاک می‌کند.
6. در پایان، بهترین ترکیب را گزارش می‌دهد.

## پیش‌نیاز

- دو سرور Ubuntu 22/24 با دسترسی root.
- دسترسی SSH از سرور اجراکننده به سرور دوم.
- `sshpass` روی سرور اجراکننده (اسکریپت نصبش می‌کند).
- سرور دوم باید `iptables` و `iproute2` داشته باشد.

## اجرا

```bash
sudo IRAN_IP=<remote-ip> IRAN_PASS=<password> ./paqet-optimizer.sh

متغیرهای محیطی
اتصال
متغیر	پیش‌فرض	توضیح
IRAN_IP	—	IP سرور دوم (اجباری)
IRAN_USER	root	یوزر SSH
IRAN_PASS	—	پسورد SSH (اجباری)
IRAN_PORT	22	پورت SSH
حالت اجرا
متغیر	پیش‌فرض	توضیح
DEBUG	0	اگر 1 باشد، بعد از هر تست pause می‌کند و وضعیت را نشان می‌دهد
BASELINE	1	اگر 0 باشد، تست baseline مستقیم اجرا نمی‌شود
Override کردن پارامترها (skip کردن sweep)
هر کدام که ست شود، مرحله‌ی مربوطه skip می‌شود و همان مقدار استفاده می‌شود.

متغیر	مقادیر مجاز	مثال
MODE	normal, fast, fast2, fast3, manual	MODE=fast3
MTU	عدد (50-1500)	MTU=1400
SNDWND	عدد	SNDWND=2048
RCVWND	عدد	RCVWND=2048
CONN	عدد (1-256)	CONN=8
BLOCK	aes, xor, none	BLOCK=xor
NODELAY	0, 1	NODELAY=1
INTERVAL	عدد	INTERVAL=10
RESEND	0, 1, 2	RESEND=2
NOCONG	0, 1	NOCONG=1
WDELAY	false, true	WDELAY=false
ACKNODELAY	true, false	ACKNODELAY=true
SMUXBUF	عدد (بایت)	SMUXBUF=8388608
STREAMBUF	عدد (بایت)	STREAMBUF=4194304
NODELAY, INTERVAL, RESEND, NOCONG, WDELAY, ACKNODELAY فقط وقتی اعمال می‌شوند که mode=manual باشد.

مثال‌ها
بدون baseline:

bash
sudo BASELINE=0 IRAN_IP=<remote-ip> IRAN_PASS=<password> ./paqet-optimizer.sh
فقط mode قفل، بقیه sweep:

bash
sudo MODE=fast3 IRAN_IP=<remote-ip> IRAN_PASS=<password> ./paqet-optimizer.sh
همه چیز دستی (فقط یک تست):

bash
sudo MODE=manual MTU=1400 SNDWND=2048 RCVWND=2048 CONN=4 BLOCK=xor \
     NODELAY=1 INTERVAL=10 RESEND=2 NOCONG=1 WDELAY=false ACKNODELAY=true \
     SMUXBUF=8388608 STREAMBUF=4194304 \
     BASELINE=0 \
     IRAN_IP=<remote-ip> IRAN_PASS=<password> \
     ./paqet-optimizer.sh
با debug:

bash
sudo DEBUG=1 MODE=fast IRAN_IP=<remote-ip> IRAN_PASS=<password> ./paqet-optimizer.sh
خروجی
در انتها جدول هر مرحله، برنده‌ی هر مرحله، و بهترین ترکیب کلی گزارش می‌شود.

نکته‌ها
در طول تست، همه‌ی پروسه‌های paqet و iperf3 روی هر دو سرور با pkill پاک می‌شوند.

config تولیدی در /run/paqet-optimizer/configs/ ساخته می‌شود و interface و MAC روتر هر سرور به‌صورت خودکار تشخیص داده می‌شود.

قوانین iptables روی سرور اول برای NOTRACK و DROP RST روی پورت KCP به‌صورت خودکار اضافه و بعد از هر تست پاک می‌شوند.

key هر بار به‌صورت تصادفی ساخته می‌شود و بین دو سرور یکسان است.

باینری هر نسخه در پوشه‌ی /opt/paqet-optimizer/bin/<version>/ نگه داشته می‌شود تا نسخه‌های مختلف با هم تداخل نکنند.

پورت 50001 برای iperf3 سمت سرور و پورت 50002 برای forward کلاینت استفاده می‌شود.