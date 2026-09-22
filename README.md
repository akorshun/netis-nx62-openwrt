# Netis NX62 / Netcore N60 Pro: загрузчик OpenWrt и initramfs одной командой

Скрипт для роутера **Netis NX62 / Netcore N60 Pro** (MT7986A), на котором уже стоит OpenWrt. Он:

1. записывает официальный загрузчик **OpenWrt 25.12.5**: `preloader.bin` в раздел `bl2`, `bl31-uboot.fip` в раздел `fip`;
2. форматирует раздел `ubi` целиком и кладёт официальный **initramfs 25.12.5** в том `recovery`;
3. перезагружает роутер, и U-Boot сам запускает initramfs из NAND.

После этого остаётся прошить sysupgrade через веб-интерфейс или терминал.

> [!IMPORTANT]
> **Подходит только для стандартной версии: 128 МБ ROM и 512 / 1024 / 2048 МБ ОЗУ.**
> Версия с 512 МБ ROM (китайская) не подходит, скрипт её распознает и остановится.

## Быстрый запуск

Зайдите на роутер по SSH и выполните команду. Адрес — LAN роутера: обычно `192.168.1.1`, на [моём образе](#мой-образ-25125) — `192.168.0.1`.

```sh
ssh root@192.168.1.1
wget -qO- https://raw.githubusercontent.com/akorshun/netis-nx62-openwrt/main/flash.sh | sh
```

Скрипт покажет, что собирается сделать, и спросит подтверждение. Чтобы не спрашивал:

```sh
wget -qO- https://raw.githubusercontent.com/akorshun/netis-nx62-openwrt/main/flash.sh | sh -s -- -y
```

Запускайте из интерактивной SSH-сессии. Вариант `ssh root@192.168.1.1 "wget … | sh"` работает только с `-y` или с `ssh -t`: иначе скрипту неоткуда прочитать ответ.

## Что нужно

- роутер на OpenWrt 25.12 с разметкой официальной сборки `netcore_n60-pro`: официальный образ или собранный на его основе;
- интернет на роутере: скачать образы и `kmod-mtd-rw`;
- около 40 МБ свободного места в `/tmp`.

Если на роутере стоковая прошивка или сборка со стоковой разметкой (NMBM, `ubi` на 117248 КБ), скрипт остановится. Поставьте OpenWrt по инструкции [SevenMaxs/netis-nx62-flash-tools](https://github.com/SevenMaxs/netis-nx62-flash-tools).

## Что делает скрипт

1. Проверяет модель (`netcore,n60-pro`) и разметку NAND: 128 МБ, блок 128 КБ, страница 2 КБ, `ubi` до конца флешки. Проверяет, что в `bl2` и `fip` нет bad-блоков, а `sysupgrade` умеет писать UBI-образы.
2. Скачивает preloader, FIP и initramfs 25.12.5 из этого репозитория, запасной источник — [downloads.openwrt.org](https://downloads.openwrt.org/releases/25.12.5/targets/mediatek/filogic/). Сверяет SHA-256.
3. Сохраняет бэкап разделов `bl2`, `u-boot-env`, `factory` и `fip` в `/tmp/nx62-flash/backup`. Пока скрипт ждёт подтверждения, бэкап можно забрать на ПК из другого окна:
   ```sh
   scp -O -r root@192.168.1.1:/tmp/nx62-flash/backup .
   ```
4. Собирает `ubinize` UBI-образ с initramfs в томе `recovery`.
5. Ставит `kmod-mtd-rw`, пишет BL2 и FIP, проверяет их обратным чтением. Если там уже нужные версии, запись пропускается.
6. Запускает `sysupgrade -F -n` с этим UBI-образом: раздел `ubi` форматируется целиком, роутер перезагружается.

`factory` (калибровка Wi-Fi и MAC-адреса) и `u-boot-env` скрипт не трогает. Текущая прошивка и её настройки удаляются.

## После перезагрузки: initramfs

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
> - Вместе с разделом сотрутся тома `ubootenv`, `ubootenv2` и `recovery`. U-Boot при загрузке не сможет пересоздать тома окружения, потому что `rootfs_data` займёт всё место. Тогда он сам отформатирует `ubi` и будет бесконечно ждать прошивку по TFTP.

Том `recovery` с initramfs остаётся в NAND. Если основной прошивки нет или она не читается, или прошлая загрузка закончилась kernel panic, U-Boot сам запустит recovery.

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

Официальные файлы побайтно совпадают с [downloads.openwrt.org](https://downloads.openwrt.org/releases/25.12.5/targets/mediatek/filogic/). Суммы лежат в [`firmware/SHA256SUMS`](firmware/SHA256SUMS).

## Если что-то пошло не так

- **Скрипт остановился до записи загрузчика.** На роутере ничего не изменилось.
- **Ошибка при записи `bl2` или `fip`.** Не перезагружайте и не выключайте роутер. Запустите скрипт ещё раз: он повторит запись. Вернуть прежний загрузчик из бэкапа:
  ```sh
  mtd write /tmp/nx62-flash/backup/bl2.bin bl2 && mtd write /tmp/nx62-flash/backup/fip.bin fip
  ```
- **Роутер не загрузился в initramfs.** Если в NAND нет ни прошивки, ни recovery, U-Boot OpenWrt ждёт initramfs по TFTP:
  1. на ПК задайте адрес `192.168.1.254/24`, подключите кабель в LAN;
  2. запустите TFTP-сервер (например, Tftpd64) с файлом `openwrt-mediatek-filogic-netcore_n60-pro-initramfs-recovery.itb`. Это `firmware/openwrt-25.12.5-…-initramfs-recovery.itb`, переименованный **без версии**;
  3. U-Boot заберёт файл, запишет его в том `recovery` и загрузится.

## Как это устроено

Официальный U-Boot OpenWrt для N60 Pro держит окружение в томах `ubootenv` и `ubootenv2`. Прошивку он ищет по порядку: том `fit`, потом том `recovery`, потом initramfs по TFTP. При первой загрузке он создаёт тома окружения, поэтому том `recovery` в UBI-образе получает номер 2: номера 0 и 1 U-Boot займёт сам, как при штатной установке через TFTP. Скрипт получает то же состояние NAND, что и TFTP-восстановление, только без ПК и TFTP-сервера.

## Благодарности

- [SevenMaxs/netis-nx62-flash-tools](https://github.com/SevenMaxs/netis-nx62-flash-tools): идея и скрипт обновления прямо на роутере;
- [OpenWrt](https://openwrt.org/toh/netcore/n60_pro): поддержка Netcore N60 Pro.
