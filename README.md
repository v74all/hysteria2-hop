# hysteria2-hop

نصب Hysteria 2 با مبهم‌سازی Salamander و پورت‌هاپینگ UDP روی سرور شخصی، با یه دستور.
English version: [below](#english)

آموزش ویدیویی (فارسی): کانال یوتیوب [@V7lthronyx](https://www.youtube.com/@V7lthronyx)، اینترنت آزاد فصل ۲: [قسمت ۳ — وقتی همه‌چیز کُنده، UDP](https://youtu.be/lPaPOH6o8Kk).

## چی کار می‌کنه

- آخرین نسخه‌ی Hysteria 2 رو از گیت‌هاب رسمی `apernet/hysteria` می‌گیره و هش SHA-256 باینری رو با `hashes.txt` رسمی چک می‌کنه. اگه سرورت به گیت‌هاب دسترسی نداره، `hysteria-linux-amd64` (یا `arm64`) و `hashes.txt` رو کنار اسکریپت بذار.
- کلید سبک ECC P-256 و گواهی X.509 می‌سازه و اثر انگشت SHA-256 گواهی (`pinSHA256`) رو توی لینک‌ها می‌ذاره تا هم جلوی شنود بین‌راهی گرفته بشه و هم هسته‌های جدید Xray توی v2rayNG و v2rayN بدون خطای `allowInsecure` وصل بشن. با `--cert` و `--key` می‌تونی گواهی معتبر دامنه خودت رو هم بهش بدی.
- مبهم‌سازی Salamander رو با کلید تصادفی روشن می‌کنه تا هدرهای QUIC روی شبکه قابل تشخیص نباشن، و `masquerade` رو روی پروکسی معکوس تنظیم می‌کنه.
- قبل از جایگزین کردن کانفیگ، فایل جدید رو با خود باینری `hysteria` تست می‌کنه تا کانفیگ خراب سرویس فعال رو نخوابونه.
- سرویس با کاربر جدای `hysteria` اجرا میشه، نه root، داخل واحد محدودشده‌ی systemd (`ProtectSystem=strict`، `NoNewPrivileges` و ...).
- با یک قانون `iptables PREROUTING` روی کارت شبکه‌ی اصلی، ۳۰ هزار پورت UDP (`20000:50000`) رو به پورت اصلی (`443`) هدایت می‌کنه، با `netfilter-persistent` دائمی‌ش می‌کنه و بافر UDP کرنل (`rmem_max` / `wmem_max`) رو برای سرعت‌های بالا تنظیم می‌کنه.
- سرور به آدرس‌های داخلی (مثل `169.254.169.254`) و مقصدهای ایرانی (`geoip:ir`، `geosite:category-ir`، `*.ir`) وصل نمیشه.
- فقط روی UDP پورت ۴۴۳ گوش میده؛ یعنی اگه از قسمت ۱ `xhttp-reality` رو روی TCP پورت ۴۴۳ همون سرور داری، هر دو کنار هم بدون تداخل کار می‌کنن.

## پیش‌نیاز

- سرور خارج از ایران با Ubuntu 22.04 / 24.04 یا Debian 12 (x86_64 یا arm64) و systemd
- دسترسی root یا sudo
- باز بودن UDP روی پورت `443` و بازه‌ی `20000-50000` توی فایروال پنل ارائه‌دهنده‌ی سرور

## نصب

```bash
curl -fsSLO https://github.com/v74all/hysteria2-hop/releases/latest/download/install.sh
curl -fsSLO https://github.com/v74all/hysteria2-hop/releases/latest/download/install.sh.sha256
sha256sum -c install.sh.sha256

sudo bash install.sh --firewall
sudo bash install.sh show
```

اسکریپت رو با `curl | bash` اجرا نکن. دانلود کن، هشش رو چک کن، یه نگاه بهش بنداز، بعد اجرا کن.

خروجی نصب این شکلیه:

```
[1/6] system   ubuntu 24.04, x86_64, systemd
[2/6] binary   v2.13.0, github hysteria-linux-amd64, sha256 ok
[3/6] tls      self-signed P-256 (CN=www.bing.com), sha256 pin 9f4c2a1b8e0d...
[4/6] config   /etc/hysteria/config.yaml, salamander on, geoip/geosite ir + private blocked
[5/6] service  hysteria-server.service active, runs as user hysteria
[6/6] network  udp 20000:50000 -> 443 (eth0), ufw on, rmem_max 16777216
done. your link: sudo bash install.sh show
```

## دستورها

| دستور | کار |
|---|---|
| `sudo bash install.sh` | نصب، یا آپدیت باینری و دیتابیس‌های geo بدون تغییر رمزها و لینک‌ها |
| `sudo bash install.sh show [NAME] [--qr]` | نمایش لینک کلاینت‌ها، با `--qr` کد QR توی ترمینال |
| `sudo bash install.sh show NAME --yaml` | کانفیگ YAML کلاینت رسمی Hysteria (SOCKS5 روی `127.0.0.1:10808`) |
| `sudo bash install.sh show NAME --json` | کانفیگ JSON کلاینت sing-box با `server_ports` و `hop_interval` |
| `sudo bash install.sh hop 25000:45000` | عوض کردن بازه‌ی پورت‌هاپینگ UDP (یا `hop off` برای خاموش کردنش) |
| `sudo bash install.sh status` | وضعیت سرویس، پورت، قانون `iptables`، گواهی و بافر کرنل |
| `sudo bash install.sh add NAME` | ساخت کاربر جدید با رمز جدا |
| `sudo bash install.sh del NAME` | حذف کاربر (لینکش همون لحظه از کار میفته) |
| `sudo bash install.sh users` | لیست کاربرها |
| `sudo bash install.sh uninstall` | حذف کامل سرویس، فایل‌ها، کاربر و قانون پورت‌هاپینگ |

گزینه‌های نصب:

| گزینه | پیش‌فرض | توضیح |
|---|---|---|
| `--sni DOMAIN` | `www.bing.com` | نام ظاهری گواهی و SNI لینک |
| `--masquerade URL` | `https://SNI` | سایتی که پروکسی معکوس Masquerade نشون میده |
| `--port N` | `443` | پورت اصلی UDP سرور |
| `--hop START:END` | `20000:50000` | بازه‌ی پورت‌هاپینگ UDP (یا `off`) |
| `--cert FILE` و `--key FILE` | خاموش | استفاده از گواهی معتبر دامنه به جای گواهی سلف‌سایند |
| `--user NAME` | `main` | اسم کاربر اول |
| `--address HOST` | خودکار | آی‌پی یا دامنه‌ای که توی لینک میاد |
| `--up MBPS` و `--down MBPS` | بدون سقف | محدود کردن پهنای باند سمت سرور بر حسب مگابیت |
| `--hysteria vX.Y.Z` | `latest` | نصب نسخه‌ی مشخص Hysteria 2 |
| `--no-geo` | خاموش | رد شدن از دانلود `geoip.dat` و `geosite.dat` (بستن `*.ir` همچنان فعاله) |
| `--firewall` | خاموش | روشن کردن ufw (پورت‌های SSH، Xray در صورت اجرا، و پورت‌های UDP هیستریا) |
| `--new-keys` | خاموش | موقع نصب دوباره، گواهی و کلید Salamander جدید بساز |

## پورت‌هاپینگ و فایروال پنل ابری

قانون `iptables -t nat -A PREROUTING` داخل کرنل خود لینوکس اجرا میشه؛ یعنی هیستریا فقط روی پورت ۴۴۳ گوش میده ولی کرنل همه‌ی بسته‌های UDP بازه‌ی `20000` تا `50000` رو تحویلش میده.

اگه ارائه‌دهنده‌ی سرورت بیرون از ماشین مجازی فایروال جدایی داره (مثل Security List در اوراکل، Cloud Firewall در هتزنر یا Security Group در AWS)، باید توی پنل اونجا هم پروتکل **UDP** رو برای پورت `443` و بازه‌ی `20000-50000` باز بذاری؛ وگرنه بسته‌ها اصلاً به کرنل سرور نمی‌رسن.

## کلاینت‌ها و تنظیمات مهم

چون کلاینت‌ها پارامتر پرش پورت رو به دو شکل متفاوت می‌خونن، دستور `show` هر دو لینک رو چاپ می‌کنه:

- **v2rayNG / v2rayN / NekoBox:** لینک اول که آخرش `mport=20000-50000` داره.
- **Hiddify / کلاینت رسمی Hysteria:** لینک دوم که بازه رو به شکل `:443,20000-50000` توی آدرس گذاشته.

سه تنظیم کلیدی سمت کلاینت برای اینترنت ایران:

- **زمان پرش پورت (Hop Interval):** بذار روی `30s` تا `60s`.
- **سقف سرعت دانلود و آپلود:** الگوریتم Brutal با نرخی که کلاینت اعلام می‌کنه دیتا می‌فرسته؛ سقف سرعت رو نزدیک سرعت واقعی خط خودت بذار تا بافر مودم یا دکل پر نشه.
- **MTU روی همراه اول و ایرانسل:** توی تنظیمات برنامه یا TUN عدد MTU رو بذار روی `1280` تا بسته‌های درشت UDP تکه‌تکه و دراپ نشن.

توی بخش Routing کلاینت هم سایت‌ها و آی‌پی‌های ایران رو روی Direct بذار؛ سرور خودش مقصدهای ایران رو رد می‌کنه.

## چه فایل‌هایی عوض میشه

| مسیر | محتوا |
|---|---|
| `/usr/local/bin/hysteria` | باینری رسمی Hysteria 2 |
| `/usr/local/share/hysteria/` | `geoip.dat` و `geosite.dat` |
| `/etc/hysteria/config.yaml` | کانفیگ سرور (`root:hysteria`، `640`) |
| `/etc/hysteria/server.crt`، `server.key` | گواهی و کلید خصوصی (`root:hysteria`، `640`) |
| `/etc/hysteria/hysteria2-hop.env` | تنظیمات و کلید Salamander (فقط root، `600`) |
| `/etc/hysteria/users` | نام و رمز کاربرها (فقط root، `600`) |
| `/etc/systemd/system/hysteria-server.service` | واحد سرویس systemd |
| `/etc/sysctl.d/99-hysteria.conf` | تنظیم بافر UDP کرنل |

به‌علاوه‌ی کاربر سیستمی `hysteria` و قانون `PREROUTING` توی `iptables` (ذخیره‌شده با `netfilter-persistent`). دستور `uninstall` همه‌ی این موارد رو پاک می‌کنه جز قانون‌های `ufw`.

## مشکلات رایج

- **اصلاً وصل نمیشه (Timeout):** فایروال پنل دیتاسنتر UDP رو بسته، یا کلاینت و سرور روی کلید `salamander` یکی نیستن. لینک تازه رو از `show` بگیر و پنل ابری رو چک کن.
- **خطای گواهی در v2rayNG / v2rayN جدید:** لینک‌های این اسکریپت `pinSHA256` دارن و مستقیم وصل میشن؛ اگه لینک رو دستی ساختی، یا `pinSHA256` رو از خروجی `status` بذار یا در کلاینت‌هایی مثل Hiddify گزینه‌ی Allow Insecure رو روشن کن.
- **پورت ۴۴۳ وصل میشه ولی پورت‌هاپینگ کار نمی‌کنه:** خروجی `sudo bash install.sh status` رو ببین که قانون `hop` ثبت شده باشه، و مطمئن شو بازه‌ی `20000-50000` روی UDP توی پنل کلود بازه.
- **روی اینترنت موبایل سرعت نوسان داره:** عدد MTU کلاینت رو روی `1280` بذار و سقف آپلود/دانلود کلاینت رو به سرعت واقعی خطت محدود کن.
- **`hysteria-server did not start`:** خروجی `journalctl -u hysteria-server -n 50` رو ببین.

## مجوز

MIT. باینری Hysteria 2 متعلق به پروژه‌ی [apernet/hysteria](https://github.com/apernet/hysteria) با مجوز MIT و فایل‌های قوانین geo متعلق به [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat) با مجوز GPL-3.0 هستن و این اسکریپت فقط اون‌ها رو نصب می‌کنه.

---

## English

One-command install of Hysteria 2 with Salamander obfuscation and kernel-level UDP port hopping on Ubuntu/Debian.

```bash
curl -fsSLO https://github.com/v74all/hysteria2-hop/releases/latest/download/install.sh
curl -fsSLO https://github.com/v74all/hysteria2-hop/releases/latest/download/install.sh.sha256
sha256sum -c install.sh.sha256

sudo bash install.sh --firewall
sudo bash install.sh show
```

What it does:

- downloads the official `hysteria` binary from `apernet/hysteria` and checks its SHA-256 digest against the release `hashes.txt` (or uses local `hysteria-linux-*` + `hashes.txt` next to the script on restricted networks)
- generates a P-256 self-signed certificate and embeds `pinSHA256` in generated links so Xray 26.2+ clients (`v2rayNG` / `v2rayN`) verify the leaf certificate without deprecated `allowInsecure`, or validates a custom `--cert` / `--key` pair
- enables Salamander UDP obfuscation with a random 128-bit key and configures reverse-proxy `masquerade`
- validates every generated config by booting a temporary local instance before replacing `/etc/hysteria/config.yaml`
- runs Hysteria as a dedicated `hysteria` system user inside a hardened systemd unit (`ProtectSystem=strict`, `NoNewPrivileges`, `CAP_NET_BIND_SERVICE`)
- redirects UDP ports `20000:50000` to `443` via `iptables` `PREROUTING` on the default interface, persists rules with `netfilter-persistent`, and tunes kernel UDP buffers (`rmem_max` / `wmem_max`)
- blocks private/link-local/metadata ranges and Iranian destinations (`geoip:ir`, `geosite:category-ir`, `*.ir`) on the server
- binds UDP only on `:443`, so it coexists cleanly on the same VPS with `xhttp-reality` running on TCP `:443`

`show` prints both the `mport=` URI (`v2rayNG`, `v2rayN`, `NekoBox`) and the `:443,20000-50000` URI (`Hiddify`, official `hysteria` client); `--yaml` prints a native Hysteria client config and `--json` prints a `sing-box` client config. `hop START:END` changes the UDP hopping range at any time, `add NAME` / `del NAME` manage per-user credentials, `status` inspects live state, and `uninstall` removes everything except `ufw` rules.

Remember to open **UDP** port `443` and `20000-50000` in your cloud provider's external firewall panel (Oracle Security List, Hetzner Firewall, AWS Security Group).

License: MIT. Hysteria 2 is MIT by [apernet/hysteria](https://github.com/apernet/hysteria).

