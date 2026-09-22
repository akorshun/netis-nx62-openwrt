#!/bin/sh
# shellcheck shell=dash
#
# Netis NX62 / Netcore N60 Pro, версия с 512 МБ ROM (MT7986A, SPI-NAND
# со страницей 4 КБ и блоком 256 КБ).
#
# Записывает кастомный загрузчик U-Boot 2025.07-WildEdition (BL2 в bl2,
# BL31 + U-Boot в fip), стирает u-boot-env и ubi и перезагружает роутер:
# U-Boot не находит прошивку и сам открывает веб-интерфейс с DHCP.
#
#   wget -qO- https://raw.githubusercontent.com/akorshun/netis-nx62-openwrt/main/flash-512m.sh | sh
#   wget -qO- https://raw.githubusercontent.com/akorshun/netis-nx62-openwrt/main/flash-512m.sh | sh -s -- -y
#
# https://github.com/akorshun/netis-nx62-openwrt

REPO_URL="https://github.com/akorshun/netis-nx62-openwrt"
REPO_RAW="https://raw.githubusercontent.com/akorshun/netis-nx62-openwrt/main/firmware/512m"
REPO_CDN="https://cdn.jsdelivr.net/gh/akorshun/netis-nx62-openwrt@main/firmware/512m"

BL2_FILE="netcore_n60-pro-512m-wildedition-bl2.bin"
BL2_SHA256="9b958b6ff922f55aa20dcf81afc5052152c020a5b0fc9ca50d7fd246cd560388"
FIP_FILE="netcore_n60-pro-512m-wildedition-fip.bin"
FIP_SHA256="e4d87f39ebc01f5b5cf8428adc000cb327424f7b223622782bb876d1ebf34aed"

# Адрес из окружения U-Boot по умолчанию; u-boot-env скрипт стирает
UBOOT_IP="10.10.10.1"

# Начало NAND одинаково во всех раскладках U-Boot: смещение и размер в байтах.
# Раздел ubi у текущей прошивки может быть любым, лишь бы начинался с 5,5 МБ.
LAYOUT="bl2:0:1048576 u-boot-env:1048576:524288 factory:1572864:2097152
fip:3670016:2097152"
UBI_OFFSET=5767168
FLASH_SIZE=536870912

# Только для тестов: корень с подменёнными /proc, /sys, /dev и т. п.
ROOT="${NX62_ROOT:-}"
WORKDIR="${NX62_WORKDIR:-/tmp/nx62-flash-512m}"

AUTO_YES=0
NEED_BL2=1
NEED_FIP=1

C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_OFF=""
if [ -t 1 ]; then
	esc=$(printf '\033')
	C_RED="${esc}[1;31m" C_GREEN="${esc}[1;32m" C_YELLOW="${esc}[1;33m"
	C_BLUE="${esc}[1;36m" C_OFF="${esc}[0m"
fi

say()  { printf '%s%s%s\n' "$1" "$2" "$C_OFF"; }
info() { say "$C_BLUE" "$*"; }
ok()   { say "$C_GREEN" "  ✓ $*"; }
warn() { say "$C_YELLOW" "  ! $*" >&2; }
die()  { say "$C_RED" "ОШИБКА: $*" >&2; exit 1; }

# Номер mtd-устройства по имени раздела
mtd_index() {
	sed -n "s/^mtd\([0-9][0-9]*\): [0-9a-f]* [0-9a-f]* \"$1\"\$/\1/p" "$ROOT/proc/mtd"
}

mtd_attr() { # <номер> <атрибут>
	cat "$ROOT/sys/class/mtd/mtd$1/$2" 2>/dev/null
}

sha256_of() {
	sha256sum "$1" | cut -d ' ' -f 1
}

file_size() {
	wc -c < "$1" | tr -d ' '
}

# Совпадает ли начало раздела с файлом
part_matches() { # <раздел> <файл> <sha256>
	local idx size
	idx=$(mtd_index "$1")
	size=$(file_size "$2")
	[ "$(head -c "$size" "$ROOT/dev/mtd$idx" | sha256sum | cut -d ' ' -f 1)" = "$3" ]
}

part_writable() { # <раздел>
	local flags
	flags=$(mtd_attr "$(mtd_index "$1")" flags)
	[ -n "$flags" ] && [ $(( flags & 0x400 )) -ne 0 ]
}

check_system() {
	local board release mem

	info "Проверка роутера"
	[ "$(id -u)" = 0 ] || die "нужны права root"
	[ -f "$ROOT/etc/openwrt_release" ] ||
		die "скрипт запускается на роутере с OpenWrt"

	board=$(cat "$ROOT/tmp/sysinfo/board_name" 2>/dev/null)
	case "$board" in
	netcore,n60-pro*|netis,nx62*)
		ok "модель: $board"
		;;
	*)
		die "модель '$board', а нужна Netis NX62 / Netcore N60 Pro"
		;;
	esac

	release=$(sed -n "s/^DISTRIB_DESCRIPTION='\(.*\)'\$/\1/p" "$ROOT/etc/openwrt_release")
	ok "прошивка: ${release:-неизвестно}"

	mem=$(awk '/^MemTotal:/ { printf "%d", $2 / 1024 }' "$ROOT/proc/meminfo")
	ok "ОЗУ: ${mem:-?} МБ"
}

check_layout() {
	local entry name off size idx real_off real_size

	idx=$(mtd_index fip)
	[ -n "$idx" ] || die "в /proc/mtd нет раздела 'fip'"
	case "$(mtd_attr "$idx" erasesize)/$(mtd_attr "$idx" writesize)" in
	262144/4096)
		;;
	131072/2048)
		die "это стандартная версия на 128 МБ (блок 128 КБ, страница 2 КБ). Для неё: wget -qO- https://raw.githubusercontent.com/akorshun/netis-nx62-openwrt/main/flash.sh | sh"
		;;
	*)
		die "NAND с блоком $(mtd_attr "$idx" erasesize) и страницей $(mtd_attr "$idx" writesize) байт: это не версия на 512 МБ (256 КБ / 4 КБ)"
		;;
	esac

	for entry in $LAYOUT; do
		name=${entry%%:*}
		off=${entry#*:}
		size=${off#*:}
		off=${off%%:*}

		idx=$(mtd_index "$name")
		[ -n "$idx" ] || die "в /proc/mtd нет раздела '$name'"
		real_off=$(mtd_attr "$idx" offset)
		real_size=$(mtd_attr "$idx" size)
		if [ "$real_off" != "$off" ] || [ "$real_size" != "$size" ]; then
			die "раздел $name: смещение $real_off, размер $real_size, ожидалось $off и $size"
		fi
	done

	idx=$(mtd_index ubi)
	[ -n "$idx" ] || die "в /proc/mtd нет раздела 'ubi'"
	real_off=$(mtd_attr "$idx" offset)
	real_size=$(mtd_attr "$idx" size)
	if [ "$real_off" != "$UBI_OFFSET" ] ||
	   [ $(( real_off + real_size )) -gt "$FLASH_SIZE" ]; then
		die "раздел ubi: смещение $real_off, размер $real_size — не похоже на NAND 512 МБ"
	fi

	for name in bl2 fip; do
		[ "$(mtd_attr "$(mtd_index "$name")" bad_blocks)" = 0 ] ||
			die "в разделе $name есть bad-блоки или ядро не сообщает их число — прошивать загрузчик так нельзя"
	done
	ok "NAND 512 МБ (блок 256 КБ, страница 4 КБ), bl2/fip без bad-блоков"
}

check_tools() {
	local tool

	for tool in mtd sha256sum wget head; do
		command -v "$tool" >/dev/null 2>&1 || die "нет утилиты $tool"
	done
}

prepare_workdir() {
	local free_kb

	mkdir -p "$WORKDIR" || die "не удалось создать $WORKDIR"
	free_kb=$(df -Pk "$WORKDIR" | awk 'NR == 2 { print $4 }')
	[ "${free_kb:-0}" -ge 16384 ] ||
		die "в $WORKDIR свободно $(( ${free_kb:-0} / 1024 )) МБ, нужно 16 МБ"
}

fetch() { # <файл> <sha256>
	local file="$1" sum="$2" dst="$WORKDIR/$1" url

	if [ -f "$dst" ] && [ "$(sha256_of "$dst")" = "$sum" ]; then
		ok "$file (уже скачан)"
		return 0
	fi

	for url in "$REPO_RAW/$file" "$REPO_CDN/$file"; do
		rm -f "$dst"
		if wget -q -T 30 --no-check-certificate -O "$dst" "$url" 2>/dev/null &&
		   [ -f "$dst" ] && [ "$(sha256_of "$dst")" = "$sum" ]; then
			ok "$file"
			return 0
		fi
		warn "не скачался или не совпала SHA-256: $url"
	done

	rm -f "$dst"
	die "не удалось скачать $file"
}

backup_parts() {
	local name idx

	mkdir -p "$WORKDIR/backup" || die "не удалось создать $WORKDIR/backup"
	for name in bl2 u-boot-env factory fip; do
		idx=$(mtd_index "$name")
		cat "$ROOT/dev/mtd$idx" > "$WORKDIR/backup/$name.bin" ||
			die "не удалось прочитать раздел $name"
	done
	(cd "$WORKDIR/backup" &&
		sha256sum bl2.bin u-boot-env.bin factory.bin fip.bin > SHA256SUMS) ||
		die "не удалось посчитать SHA-256 бэкапа"
	ok "bl2, u-boot-env, factory, fip → $WORKDIR/backup"
}

router_ip() {
	local ip

	ip=$(uci -q get network.lan.ipaddr 2>/dev/null)
	ip=${ip%% *}
	ip=${ip%%/*}
	echo "${ip:-<IP роутера>}"
}

summary() {
	echo
	info "Что будет сделано"
	if [ "$NEED_BL2" = 1 ]; then
		echo "  • bl2 ← BL2 WildEdition для NAND 512 МБ"
	else
		echo "  • bl2: BL2 WildEdition уже записан, пропуск"
	fi
	if [ "$NEED_FIP" = 1 ]; then
		echo "  • fip ← BL31 + U-Boot 2025.07-WildEdition"
	else
		echo "  • fip: U-Boot WildEdition уже записан, пропуск"
	fi
	echo "  • u-boot-env ← стирание: U-Boot запустится с настройками по умолчанию"
	echo "  • ubi ← стирание, затем перезагрузка в веб-интерфейс U-Boot"
	echo "    http://$UBOOT_IP (адрес ПК по DHCP)"
	echo
	warn "текущая прошивка и все её настройки будут удалены"
	echo "  Бэкап лежит в $WORKDIR/backup, пока роутер не перезагружен."
	echo "  Забрать на ПК из другого окна: scp -O -r root@$(router_ip):$WORKDIR/backup ."
	echo
}

confirm() {
	local answer

	[ "$AUTO_YES" = 1 ] && return 0
	# В subshell: ошибка перенаправления у «:» в ash/dash завершает весь shell
	if ! (: < /dev/tty) 2>/dev/null; then
		die "не могу задать вопрос: запустите скрипт в интерактивной SSH-сессии или добавьте -y (… | sh -s -- -y)"
	fi

	printf '%s [y/N]: ' "$1"
	read -r answer < /dev/tty || answer=""
	case "$answer" in
	y|Y|yes|Yes|YES|д|Д|да|Да|ДА)
		return 0
		;;
	esac

	info "Отменено, на роутере ничего не изменилось."
	exit 0
}

pkg_install() {
	local log="$WORKDIR/pkg.log"

	if command -v apk >/dev/null 2>&1; then
		apk update > "$log" 2>&1
		apk add "$@" >> "$log" 2>&1 && return 0
	elif command -v opkg >/dev/null 2>&1; then
		opkg update > "$log" 2>&1
		opkg install "$@" >> "$log" 2>&1 && return 0
	fi

	cat "$log" >&2 2>/dev/null
	return 1
}

all_writable() {
	part_writable bl2 && part_writable fip && part_writable u-boot-env && part_writable ubi
}

enable_mtd_write() {
	all_writable && return 0

	if ! grep -q '^mtd_rw ' "$ROOT/proc/modules" 2>/dev/null; then
		if [ -z "$(find "$ROOT/lib/modules/" -name mtd-rw.ko 2>/dev/null)" ]; then
			pkg_install kmod-mtd-rw ||
				die "не удалось установить kmod-mtd-rw (нужен интернет на роутере)"
		fi
		insmod mtd-rw i_want_a_brick=1 > /dev/null 2>&1 ||
			die "не удалось загрузить модуль mtd-rw"
	fi

	if ! all_writable; then
		die "разделы bl2, fip, u-boot-env или ubi по-прежнему только для чтения"
	fi
	ok "запись в разделы разрешена (kmod-mtd-rw)"
}

write_part() { # <раздел> <файл> <sha256>
	local try

	for try in 1 2 3; do
		mtd erase "$1" > /dev/null 2>&1
		if mtd write "$2" "$1" > /dev/null 2>&1 && part_matches "$1" "$2" "$3"; then
			ok "$1 записан и проверен"
			return 0
		fi
		warn "$1: попытка $try не удалась"
	done

	say "$C_RED" "ОШИБКА: не удалось записать раздел $1." >&2
	say "$C_RED" "НЕ ПЕРЕЗАГРУЖАЙТЕ И НЕ ВЫКЛЮЧАЙТЕ роутер. Запустите скрипт ещё раз —" >&2
	say "$C_RED" "он повторит запись. Вернуть прежний загрузчик из бэкапа:" >&2
	say "$C_RED" "  mtd write $WORKDIR/backup/bl2.bin bl2 && mtd write $WORKDIR/backup/fip.bin fip" >&2
	exit 1
}

next_steps() {
	echo
	echo "=================================================================="
	ok "Загрузчик U-Boot WildEdition на месте."
	echo "  Сейчас роутер сотрёт раздел ubi и перезагрузится. U-Boot не найдёт"
	echo "  прошивку и сам откроет веб-интерфейс."
	echo
	echo "  Через полминуты:"
	echo "   1. ПК кабелем в LAN, адрес по DHCP (10.10.10.x)."
	echo "   2. Откройте http://$UBOOT_IP"
	echo "   3. Выберите раскладку NAND и загрузите прошивку."
	echo
	echo "  Если страница не открывается: выключите роутер, зажмите reset,"
	echo "  включите и держите кнопку 4–5 секунд, пока не загорится индикатор."
	echo
	echo "  Инструкция: $REPO_URL"
	echo "=================================================================="
	echo
}

usage() {
	cat <<-EOF
		Использование: flash-512m.sh [-y]
		  -y, --yes   не задавать вопросов
		Подробно: $REPO_URL
	EOF
}

main() {
	while [ $# -gt 0 ]; do
		case "$1" in
		-y|--yes)
			AUTO_YES=1
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			usage >&2
			die "неизвестный параметр: $1"
			;;
		esac
		shift
	done

	info "Netis NX62 / Netcore N60 Pro 512 МБ ROM: загрузчик U-Boot WildEdition"
	echo
	check_system
	check_layout
	check_tools
	prepare_workdir

	info "Загрузка BL2 и U-Boot"
	fetch "$BL2_FILE" "$BL2_SHA256"
	fetch "$FIP_FILE" "$FIP_SHA256"

	info "Бэкап разделов"
	backup_parts
	part_matches bl2 "$WORKDIR/$BL2_FILE" "$BL2_SHA256" && NEED_BL2=0
	part_matches fip "$WORKDIR/$FIP_FILE" "$FIP_SHA256" && NEED_FIP=0

	summary
	confirm "Продолжить?"

	info "Запись загрузчика"
	warn "не выключайте питание"
	enable_mtd_write
	[ "$NEED_BL2" = 1 ] && write_part bl2 "$WORKDIR/$BL2_FILE" "$BL2_SHA256"
	[ "$NEED_FIP" = 1 ] && write_part fip "$WORKDIR/$FIP_FILE" "$FIP_SHA256"

	mtd erase u-boot-env > /dev/null 2>&1 || die "не удалось стереть u-boot-env"
	ok "u-boot-env стёрт"

	next_steps
	info "Стирание ubi и перезагрузка"
	sync
	mtd -r erase ubi
	die "не удалось стереть ubi. Загрузчик уже записан: перезагрузитесь с зажатой кнопкой reset, чтобы попасть в U-Boot"
}

main "$@"
