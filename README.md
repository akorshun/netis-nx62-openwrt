# Netis NX62 / Netcore N60 Pro: загрузчик одной командой

Скрипты для роутера **Netis NX62 / Netcore N60 Pro** (MT7986A), на котором уже стоит OpenWrt. Скрипт запускается на самом роутере, записывает новый загрузчик и перезагружает роутер туда, откуда удобно ставить прошивку.

| Версия роутера | Скрипт | Что ставится | Куда перезагружается |
| --- | --- | --- | --- |
| [Стандартная: 128 МБ ROM, 512 / 1024 / 2048 МБ ОЗУ](#стандартная-версия-128-мб-rom) | `flash.sh` | официальный загрузчик OpenWrt 25.12.5 | в initramfs OpenWrt 25.12.5 |
| [С 512 МБ ROM (китайская)](#версия-с-512-мб-rom) | `flash-512m.sh` | кастомный U-Boot 2025.07-WildEdition | в веб-интерфейс U-Boot |

Версию показывает драйвер NAND в журнале ядра:

```sh
dmesg | grep spi-nand
```

`128 MiB` — стандартная версия, `512 MiB` — версия с 512 МБ. У неё встречаются разные микросхемы: Toshiba `TC58CVG2S0HRAIG` (страница 4 КБ, блок 256 КБ) и Winbond `W25N04KV` (страница 2 КБ, блок 128 КБ, как у 128 МБ). Поэтому по размеру блока версию не определить. Скрипты проверяют объём сами: если запустить не тот, он остановится и подскажет нужную команду.

Оба скрипта снимают бэкап `bl2`, `u-boot-env`, `factory` и `fip` и спрашивают подтверждение, прежде чем что-то записать. Запускайте их из интерактивной SSH-сессии: вариант `ssh root@… "wget … | sh"` работает только с `-y` или с `ssh -t`, иначе скрипту неоткуда прочитать ответ.

## Стандартная версия: 128 МБ ROM

`flash.sh`:

1. записывает официальный загрузчик **OpenWrt 25.12.5**: `preloader.bin` в раздел `bl2`, `bl31-uboot.fip` в раздел `fip`;
2. форматирует раздел `ubi` целиком и кладёт официальный **initramfs 25.12.5** в том `fit`, откуда его потом заместит прошивка;
3. перезагружает роутер, и U-Boot сам запускает initramfs из NAND.

После этого остаётся прошить sysupgrade через веб-интерфейс или терминал.

### Быстрый запуск

Зайдите на роутер по SSH и выполните команду. Адрес — LAN роутера: обычно `192.168.1.1`, на [моём образе](#мой-образ-25125) — `192.168.0.1`.

```sh
ssh root@192.168.1.1
wget -qO- https://raw.githubusercontent.com/akorshun/netis-nx62-openwrt/main/flash.sh | sh
```

Без вопросов:

```sh
wget -qO- https://raw.githubusercontent.com/akorshun/netis-nx62-openwrt/main/flash.sh | sh -s -- -y
```

### Что нужно

- роутер на OpenWrt 25.12 с разметкой официальной сборки `netcore_n60-pro`: официальный образ или собранный на его основе;
- интернет на роутере: скачать образы и `kmod-mtd-rw`;
- около 40 МБ свободного места в `/tmp`.

Если на роутере стоковая прошивка или сборка со стоковой разметкой (NMBM, `ubi` на 117248 КБ), скрипт остановится. Поставьте OpenWrt по инструкции [SevenMaxs/netis-nx62-flash-tools](https://github.com/SevenMaxs/netis-nx62-flash-tools).

### Что делает скрипт

1. Проверяет модель (`netcore,n60-pro`) и разметку NAND: 128 МБ, блок 128 КБ, страница 2 КБ, `ubi` до конца флешки. Проверяет, что в `bl2` и `fip` нет bad-блоков, а `sysupgrade` умеет писать UBI-образы.
2. Скачивает preloader, FIP и initramfs 25.12.5 из этого репозитория, запасной источник — [downloads.openwrt.org](https://downloads.openwrt.org/releases/25.12.5/targets/mediatek/filogic/). Сверяет SHA-256.
3. Сохраняет бэкап разделов `bl2`, `u-boot-env`, `factory` и `fip` в `/tmp/nx62-flash/backup`. Пока скрипт ждёт подтверждения, бэкап можно забрать на ПК из другого окна:
   ```sh
   scp -O -r root@192.168.1.1:/tmp/nx62-flash/backup .
   ```
4. Собирает `ubinize` UBI-образ с initramfs в томе `fit`. С ключом `-r` — в отдельном томе `recovery`, см. ниже.
5. Ставит `kmod-mtd-rw`, пишет BL2 и FIP, проверяет их обратным чтением. Если там уже нужные версии, запись пропускается.
6. Запускает `sysupgrade -F -n` с этим UBI-образом: раздел `ubi` форматируется целиком, роутер перезагружается.

`factory` (калибровка Wi-Fi и MAC-адреса) и `u-boot-env` скрипт не трогает. Текущая прошивка и её настройки удаляются.

### После перезагрузки: initramfs

Через 1–2 минуты роутер загрузится в initramfs OpenWrt 25.12.5:

- адрес `192.168.1.1`, DHCP включён: подключите ПК кабелем в любой LAN-порт;
- LuCI `http://192.168.1.1` и SSH `root@192.168.1.1` открываются без пароля, Wi-Fi выключен.

Прошейте sysupgrade без сохранения настроек. Подойдёт [мой образ](#мой-образ-25125) или [официальный](https://downloads.openwrt.org/releases/25.12.5/targets/mediatek/filogic/openwrt-25.12.5-mediatek-filogic-netcore_n60-pro-squashfs-sysupgrade.itb).

**Через веб-интерфейс.** В initramfs LuCI на английском: *System → Backup / Flash Firmware → Flash image…* Выберите файл `*-sysupgrade.itb`, снимите галочку *Keep settings and retain the current configuration*, нажмите *Continue*.

**Через терминал.** Скопируйте образ на роутер и прошейте:

```sh
scp -O openwrt-25.12.5-mediatek-filogic-netcore_n60-pro-argon-ru-squashfs-sysupgrade.itb root@192.168.1.1:/tmp/
ssh root@192.168.1.1 sysupgrade -n /tmp/openwrt-25.12.5-mediatek-filogic-netcore_n60-pro-argon-ru-squashfs-sysupgrade.itb
```

Если WAN роутера подключён к интернету, образ можно скачать прямо на роутере:

```sh
wget -O /tmp/sysupgrade.itb https://raw.githubusercontent.com/akorshun/netis-nx62-openwrt/main/firmware/openwrt-25.12.5-mediatek-filogic-netcore_n60-pro-argon-ru-squashfs-sysupgrade.itb
sysupgrade -n /tmp/sysupgrade.itb
```

> [!WARNING]
> **`mtd erase ubi` в initramfs делать не нужно, и так делать нельзя.** Скрипт уже отформатировал `ubi` целиком: это та же чистая разметка, только без риска.
> - initramfs держит `ubi` подключённым. После стирания «из-под» UBI sysupgrade запишет прошивку в блоки без заголовков, и при следующей загрузке они будут отброшены.
> - Вместе с разделом сотрутся тома окружения U-Boot `ubootenv` и `ubootenv2`, а с ними и сам initramfs. U-Boot при загрузке не сможет пересоздать тома окружения, потому что `rootfs_data` займёт всё место. Тогда он сам отформатирует `ubi` и будет бесконечно ждать прошивку по TFTP — ровно это и происходит на практике.

### Аварийный initramfs в NAND: ключ `-r`

По умолчанию initramfs лежит в томе `fit` и полностью замещается прошивкой, лишнего в NAND не остаётся.

С ключом `-r` скрипт кладёт initramfs в отдельный том `recovery`, и тот остаётся в NAND навсегда:

```sh
wget -qO- https://raw.githubusercontent.com/akorshun/netis-nx62-openwrt/main/flash.sh | sh -s -- -r
```

Тогда U-Boot сам запустит initramfs, если прошивки нет, она не читается или прошлая загрузка закончилась kernel panic. Роутер можно будет перепрошить без ПК и TFTP. Цена — около 9 МБ: на 128 МБ это разница между 89 и 81 МБ свободного места в overlay.

### Как это устроено

Официальный U-Boot OpenWrt для N60 Pro держит окружение в томах `ubootenv` и `ubootenv2`. Прошивку он ищет по порядку: том `fit`, потом том `recovery`, потом initramfs по TFTP. При первой загрузке он создаёт тома окружения, поэтому том с initramfs в UBI-образе получает номер 2: номера 0 и 1 U-Boot займёт сам, как при штатной установке через TFTP. Скрипт получает то же состояние NAND, что и TFTP-восстановление, только без ПК и TFTP-сервера.

## Версия с 512 МБ ROM

`flash-512m.sh`:

1. записывает кастомный загрузчик **U-Boot 2025.07-WildEdition** (BL31 + U-Boot) в раздел `fip` и подходящий к микросхеме BL2 в раздел `bl2`;
2. стирает `u-boot-env`, чтобы U-Boot стартовал с настройками по умолчанию;
3. стирает `ubi` и сразу перезагружает роутер. U-Boot не находит прошивку и сам открывает веб-интерфейс с DHCP-сервером.

BL2 выбирается по микросхеме NAND:

| NAND | BL2 |
| --- | --- |
| Toshiba `TC58CVG2S0HRAIG`, страница 4 КБ | BL2 WildEdition |
| Winbond `W25N04KV` и другие со страницей 2 КБ | официальный BL2 OpenWrt 25.12.5 |

BL2 WildEdition собран только под страницу 4 КБ: BootROM не прочитает его с микросхемы со страницей 2 КБ, и роутер не загрузится. Официальный BL2 грузится на `W25N04KV`, а сам U-Boot WildEdition эту микросхему знает. Связка «официальный BL2 + U-Boot WildEdition» проверена на роутере с `W25N04KV`.

### Быстрый запуск

```sh
ssh root@192.168.1.1
wget -qO- https://raw.githubusercontent.com/akorshun/netis-nx62-openwrt/main/flash-512m.sh | sh
```

Без вопросов:

```sh
wget -qO- https://raw.githubusercontent.com/akorshun/netis-nx62-openwrt/main/flash-512m.sh | sh -s -- -y
```

Нужны OpenWrt на роутере (модель `netcore,n60-pro…`), интернет для `kmod-mtd-rw` и около 16 МБ в `/tmp`.

### Что делает скрипт

1. Проверяет модель и NAND: объём 512 МБ (по журналу ядра, а если он вытеснен — по резерву UBI под bad-блоки), стандартное начало разметки (`bl2`, `u-boot-env`, `factory`, `fip`), нет bad-блоков в `bl2` и `fip`.
2. Скачивает BL2 и U-Boot из этого репозитория (запасные источники — jsDelivr и downloads.openwrt.org) и сверяет SHA-256.
3. Сохраняет бэкап разделов в `/tmp/nx62-flash-512m/backup`. Забрать на ПК, пока скрипт ждёт подтверждения:
   ```sh
   scp -O -r root@192.168.1.1:/tmp/nx62-flash-512m/backup .
   ```
4. Ставит `kmod-mtd-rw`, пишет BL2 и FIP, проверяет их обратным чтением. Если там уже нужные версии, запись пропускается.
5. Стирает `u-boot-env`.
6. Выполняет `mtd -r erase ubi`: стирает `ubi` и перезагружает роутер.

`factory` и раздел `data`, если он есть, скрипт не трогает. Текущая прошивка и её настройки удаляются.

### После перезагрузки: веб-интерфейс U-Boot

Примерно через полминуты:

1. подключите ПК кабелем в LAN, адрес он получит по DHCP (`10.10.10.x`);
2. откройте **`http://10.10.10.1`**.

Интерфейс на китайском. Главная страница «固件更新» — прошивка: выберите раскладку NAND в «选择mtd布局», файл прошивки и нажмите «上传». В меню есть «Initramfs加载» (загрузить initramfs в память), «U-Boot更新» (обновить сам загрузчик) и «备份» (бэкап разделов).

Если страница не открывается, войдите в U-Boot кнопкой: выключите роутер, зажмите reset, включите и держите кнопку 4–5 секунд, пока не загорится индикатор питания.

**Раскладка NAND должна совпадать с разделом `ubi` в DTS прошивки.** Раскладки в этой сборке U-Boot:

| Метка | `ubi` | `data` |
| --- | --- | --- |
| `default`, `default-spi-nand-512MB-ubi-500MB-data-1m` | 500 МБ | 1 МБ |
| `spi-nand-512MB-ubi-400MB-data-100m` | 400 МБ | 100 МБ |
| `spi-nand-512MB-ubi-300MB-data-200m` | 300 МБ | 200 МБ |
| `spi-nand-512MB-MAX-506.5MB` | 506,5 МБ | — |
| `spi-nand-512MB-ubi-490MB` | 490 МБ | — |
| `spi-nand-512MB-ubi-460MB` | 460 МБ | — |
| `spi-nand-512MB-ubi-114.5MB-data-385m` | 117248 КБ | 385 МБ |
| `spi-nand-512MB-ubi-122.5MB-data-377m` | 125540 КБ ⚠️ | 377 МБ |
| `spi-nand-128MB-ubi-114.5MB` | 117248 КБ | — |
| `spi-nand-128MB-ubi-MAX-122.5MB` | 125540 КБ ⚠️ | — |

⚠️ 125540 КБ не кратно блоку 256 КБ. U-Boot делает такой раздел только для чтения, и прошить его из веб-интерфейса не выйдет. К тому же в официальном OpenWrt для N60 Pro `ubi` — 125440 КБ.

## Мой образ 25.12.5

`firmware/openwrt-25.12.5-mediatek-filogic-netcore_n60-pro-argon-ru-squashfs-sysupgrade.itb` — OpenWrt 25.12.5 (r33051-f5dae5ece4) с официальным ядром:

- тема Argon и русский LuCI;
- дополнительно: `luci-app-ttyd` (терминал в браузере), `luci-app-cpu-status`, `luci-app-temp-status`, `luci-app-netstat` (`vnstat`), `htop`, `nano-full`, `curl`;
- программный и аппаратный flow offloading включены, IPv6 выключен;
- **адрес LAN — `192.168.0.1`**, а не 192.168.1.1: после прошивки переподключите кабель, чтобы ПК получил новый адрес по DHCP;
- **Wi-Fi включён сразу и без пароля**: сети `netcore-2.4G` и `netcore-5G`, регион PA;
- **у root нет пароля**.

Сразу после прошивки задайте пароли и новые SSH-ключи. Ключи dropbear зашиты в образ и одинаковы у всех, кто его поставил:

```sh
passwd
rm -f /etc/dropbear/dropbear_*_host_key
reboot
```

Пароль Wi-Fi: *Сеть → Беспроводная сеть → Изменить → Безопасность беспроводной сети*.

## Файлы

| Файл | Что это | SHA-256 |
| --- | --- | --- |
| `openwrt-25.12.5-mediatek-filogic-netcore_n60-pro-preloader.bin` | BL2, официальный | `4215ec48f52b26ce0d93c2f67d4e435d6372c2701b9574b59d2ed51aaef0acf2` |
| `openwrt-25.12.5-mediatek-filogic-netcore_n60-pro-bl31-uboot.fip` | BL31 + U-Boot, официальный | `1d5c3cbac086bf69598a374f8098776a1843384b014dda79f4673d8e4d7d645a` |
| `openwrt-25.12.5-mediatek-filogic-netcore_n60-pro-initramfs-recovery.itb` | initramfs, официальный | `8ceee0b72589da501ee7e9e34628491a385a6b2f2cf87fec005b1af29cd843b3` |
| `openwrt-25.12.5-mediatek-filogic-netcore_n60-pro-argon-ru-squashfs-sysupgrade.itb` | мой sysupgrade | `f98dceeb28b3a8446f1ff58a904794b502c9f21bc9d9a762197b7ceff0113a1f` |
| `512m/netcore_n60-pro-512m-wildedition-bl2.bin` | BL2 WildEdition для NAND 512 МБ (сборка 31.12.2025), образ раздела 1 МБ | `9b958b6ff922f55aa20dcf81afc5052152c020a5b0fc9ca50d7fd246cd560388` |
| `512m/netcore_n60-pro-512m-wildedition-fip.bin` | BL31 + U-Boot 2025.07-WildEdition (09.11.2025), образ раздела 2 МБ | `e4d87f39ebc01f5b5cf8428adc000cb327424f7b223622782bb876d1ebf34aed` |

Официальные файлы побайтно совпадают с [downloads.openwrt.org](https://downloads.openwrt.org/releases/25.12.5/targets/mediatek/filogic/). Суммы лежат в [`firmware/SHA256SUMS`](firmware/SHA256SUMS) и [`firmware/512m/SHA256SUMS`](firmware/512m/SHA256SUMS).

## Если что-то пошло не так

- **Скрипт остановился до записи загрузчика.** На роутере ничего не изменилось.
- **Ошибка при записи `bl2` или `fip`.** Не перезагружайте и не выключайте роутер. Запустите скрипт ещё раз: он повторит запись. Вернуть прежний загрузчик из бэкапа (для `flash-512m.sh` каталог `/tmp/nx62-flash-512m/backup`):
  ```sh
  mtd write /tmp/nx62-flash/backup/bl2.bin bl2 && mtd write /tmp/nx62-flash/backup/fip.bin fip
  ```
- **Стандартная версия не загрузилась в initramfs.** Если в NAND нет ни прошивки, ни recovery, U-Boot OpenWrt ждёт initramfs по TFTP:
  1. на ПК задайте адрес `192.168.1.254/24`, подключите кабель в LAN;
  2. запустите TFTP-сервер (например, Tftpd64) с файлом `openwrt-mediatek-filogic-netcore_n60-pro-initramfs-recovery.itb`. Это `firmware/openwrt-25.12.5-…-initramfs-recovery.itb`, переименованный **без версии**;
  3. U-Boot заберёт файл, запишет его в том `recovery` и загрузится.
- **Версия 512 МБ: не открывается `http://10.10.10.1`.** Проверьте, что ПК получил адрес `10.10.10.x`, или войдите в U-Boot кнопкой reset, как описано [выше](#после-перезагрузки-веб-интерфейс-u-boot).

## Благодарности

- [SevenMaxs/netis-nx62-flash-tools](https://github.com/SevenMaxs/netis-nx62-flash-tools): идея и скрипт обновления прямо на роутере;
- [OpenWrt](https://openwrt.org/toh/netcore/n60_pro): поддержка Netcore N60 Pro.
