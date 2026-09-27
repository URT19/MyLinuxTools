# Paqet Auto Optimizer

اسکریپتی برای پیدا کردن بهترین تنظیمات `Paqet` (KCP mode) بین دو سرور.

## کاری که می‌کند

1. باینری Paqet را دانلود و با SHA256 به سرور دوم منتقل می‌کند.
2. یک baseline مستقیم با `iperf3` بین دو سرور می‌گیرد.
3. به‌صورت greedy این پارامترها را مرحله‌به‌مرحله تست می‌کند و بهترین مقدار هرکدام را انتخاب می‌کند:
   - `mode` (fast, fast2, fast3, normal, manual)
   - `mtu` (1500 تا 1150)
   - `conn` (2, 4, 8)
   - `block` (aes, xor, none)
4. در پایان، بهترین ترکیب و سرعتش را گزارش می‌دهد.

## پیش‌نیاز

- دو سرور Ubuntu 22 یا 24 با دسترسی root.
- دسترسی SSH از سرور اول به سرور دوم.
- `sshpass` روی سرور اول (اسکریپت خودش نصب می‌کند).

## اجرا

```bash
sudo IRAN_IP=<iran-ip> IRAN_PASS=<password> ./paqet-optimizer.sh


متغیرهای محیطی
اتصال
متغیر	پیش‌فرض	توضیح
IRAN_IP	—	IP سرور دوم (اجباری)
IRAN_USER	root	یوزر SSH
IRAN_PASS	—	پسورد SSH (اجباری)
IRAN_PORT	22	پورت SSH
حالت اجرا
متغیر	پیش‌فرض	توضیح
DEBUG	0	اگر 1 باشد، بعد از هر مرحله pause می‌کند و وضعیت را نشان می‌دهد
Override کردن پارامترها (skip کردن sweep)
هر کدام که ست شود، مرحله‌ی مربوطه skip می‌شود.

متغیر	مقادیر مجاز	مثال
MODE	fast, fast2, fast3, normal, manual	MODE=fast3
MTU	عدد	MTU=1400
CONN	عدد	CONN=8
BLOCK	aes, xor, none	BLOCK=xor
مثال‌ها
فقط mode قفل:

bash
sudo MODE=fast3 IRAN_IP=<iran-ip> IRAN_PASS=<password> ./paqet-optimizer.sh
همه چیز دستی (فقط یک تست):

bash
sudo MODE=fast3 MTU=1400 CONN=8 BLOCK=xor \
  IRAN_IP=<iran-ip> IRAN_PASS=<password> \
  ./paqet-optimizer.sh
با debug:

bash
sudo DEBUG=1 MODE=fast3 IRAN_IP=<iran-ip> IRAN_PASS=<password> ./paqet-optimizer.sh
خروجی
در انتها بهترین ترکیب (mode, mtu, conn, block) و سرعتش گزارش می‌شود.

نکته‌ها
در طول تست، همه‌ی پروسه‌های paqet و iperf3 روی هر دو سرور با pkill پاک می‌شوند.

فایل‌های config در /run/paqet-optimizer/configs/ ساخته می‌شوند و به‌صورت خودکار interface و MAC روتر هر سرور در آن‌ها قرار می‌گیرد.

key هر بار به‌صورت تصادفی ساخته می‌شود و بین سرور و کلاینت یکسان است.