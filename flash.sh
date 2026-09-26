#!/bin/sh
# shellcheck shell=dash
#
# Netis NX62 / Netcore N60 Pro (MT7986A, 128 МБ SPI-NAND).
#
# Записывает официальный загрузчик OpenWrt 25.12.5 (preloader в bl2, BL31 +
# U-Boot в fip), форматирует раздел ubi целиком с initramfs 25.12.5 в томе fit
# и перезагружает роутер: U-Boot сам запускает initramfs из NAND. Прошивка,
# которую вы зальёте из initramfs, заместит initramfs в томе fit.
#
# С -r initramfs кладётся в отдельный том recovery и остаётся в NAND: U-Boot
# запустит его, если прошивки нет или ядро упало. Это стоит около 9 МБ.
#
#   wget -qO- https://raw.githubusercontent.com/akorshun/netis-nx62-openwrt/main/flash.sh | sh
#   wget -qO- https://raw.githubusercontent.com/akorshun/netis-nx62-openwrt/main/flash.sh | sh -s -- -y -r
#
# https://github.com/akorshun/netis-nx62-openwrt

REPO_URL="https://github.com/akorshun/netis-nx62-openwrt"
REPO_RAW="https://raw.githubusercontent.com/akorshun/netis-nx62-openwrt/main/firmware"
OWRT_URL="https://downloads.openwrt.org/releases/25.12.5/targets/mediatek/filogic"
BOARD="netcore,n60-pro"

BL2_FILE="openwrt-25.12.5-mediatek-filogic-netcore_n60-pro-preloader.bin"
BL2_SHA256="4215ec48f52b26ce0d93c2f67d4e435d6372c2701b9574b59d2ed51aaef0acf2"
FIP_FILE="openwrt-25.12.5-mediatek-filogic-netcore_n60-pro-bl31-uboot.fip"
FIP_SHA256="1d5c3cbac086bf69598a374f8098776a1843384b014dda79f4673d8e4d7d645a"
RECOVERY_FILE="openwrt-25.12.5-mediatek-filogic-netcore_n60-pro-initramfs-recovery.itb"
RECOVERY_SHA256="8ceee0b72589da501ee7e9e34628491a385a6b2f2cf87fec005b1af29cd843b3"

# Разметка официального DTS 25.12.5: смещение и размер в байтах.
# ubi занимает всё до конца 128 МБ флешки, без NMBM.
LAYOUT="bl2:0:1048576 u-boot-env:1048576:524288 factory:1572864:2097152
fip:3670016:2097152 ubi:5767168:128450560"

# Только для тестов: корень с подменёнными /proc, /sys, /dev и т. п.
ROOT="${NX62_ROOT:-}"
WORKDIR="${NX62_WORKDIR:-/tmp/nx62-flash}"
UBI_IMAGE="$WORKDIR/initramfs.ubi"

AUTO_YES=0
KEEP_RECOVERY=0
NEED_UBI_UTILS=0
NEED_BL2=1
NEED_FIP=1
BOOT_VOL=fit

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

# Объём всей микросхемы NAND в МиБ. Разделы его не показывают, а блок 128 КБ и
# страница 2 КБ бывают и у 128 МБ, и у 512 МБ (Winbond W25N04KV). Берём строку
# драйвера «spi-nand spi0.0: 512 MiB, block size: …» из журнала ядра, а если
# она вытеснена — резерв UBI под bad-блоки, который ядро считает по всему
# чипу: 20 блоков на каждые 1024.
flash_size_mib() {
	local size ubi resv bad es

	size=$({ dmesg; logread; } 2>/dev/null |
		sed -n 's/.*spi-nand.*: \([0-9][0-9]*\) MiB, block size.*/\1/p' | tail -n 1)
	if [ -n "$size" ]; then
		echo "$size"
		return 0
	fi

	for ubi in "$ROOT"/sys/class/ubi/ubi[0-9]*; do
		[ "$(cat "$ubi/mtd_num" 2>/dev/null)" = "$(mtd_index ubi)" ] || continue
		resv=$(cat "$ubi/reserved_for_bad" 2>/dev/null)
		bad=$(cat "$ubi/bad_peb_count" 2>/dev/null)
		es=$(mtd_attr "$(mtd_index ubi)" erasesize)
		if [ -z "$resv" ] || [ -z "$bad" ] || [ -z "$es" ]; then
			continue
		fi
		echo $(( (resv + bad) * es / 20480 ))
		return 0
	done
	return 1
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
	[ "$board" = "$BOARD" ] ||
		die "модель '$board', а нужна '$BOARD' (Netis NX62 / Netcore N60 Pro)"
	ok "модель: $board"

	release=$(sed -n "s/^DISTRIB_DESCRIPTION='\(.*\)'\$/\1/p" "$ROOT/etc/openwrt_release")
	ok "прошивка: ${release:-неизвестно}"

	mem=$(awk '/^MemTotal:/ { printf "%d", $2 / 1024 }' "$ROOT/proc/meminfo")
	ok "ОЗУ: ${mem:-?} МБ"
}

check_layout() {
	local entry name off size idx real_off real_size mib

	idx=$(mtd_index fip)
	[ -n "$idx" ] || die "в /proc/mtd нет раздела 'fip'"
	mib=$(flash_size_mib)
	case "$(mtd_attr "$idx" erasesize)/$(mtd_attr "$idx" writesize)/${mib:-?}" in
	131072/2048/128)
		;;
	131072/2048/\?)
		warn "не удалось узнать объём NAND, считаю версию стандартной (128 МБ)"
		;;
	*/512)
		die "это версия с 512 МБ ROM. Для неё: wget -qO- https://raw.githubusercontent.com/akorshun/netis-nx62-openwrt/main/flash-512m.sh | sh"
		;;
	262144/4096/*)
		die "это версия с 512 МБ ROM (блок 256 КБ, страница 4 КБ). Для неё: wget -qO- https://raw.githubusercontent.com/akorshun/netis-nx62-openwrt/main/flash-512m.sh | sh"
		;;
	*)
		die "NAND: блок $(mtd_attr "$idx" erasesize), страница $(mtd_attr "$idx" writesize) байт, объём ${mib:-?} МиБ — это не стандартная версия (128 МБ)"
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
			die "раздел $name: смещение $real_off, размер $real_size, ожидалось $off и $size. Скрипт только для стандартной версии на 128 МБ с разметкой официальной OpenWrt"
		fi
	done

	for name in bl2 fip; do
		[ "$(mtd_attr "$(mtd_index "$name")" bad_blocks)" = 0 ] ||
			die "в разделе $name есть bad-блоки или ядро не сообщает их число — прошивать загрузчик так нельзя"
	done
	ok "разметка NAND: 128 МБ, bl2/fip без bad-блоков"
}

check_tools() {
	local tool

	for tool in mtd sysupgrade sha256sum wget head; do
		command -v "$tool" >/dev/null 2>&1 || die "нет утилиты $tool"
	done
	command -v ubinize >/dev/null 2>&1 || NEED_UBI_UTILS=1

	grep -q '^nand_upgrade_ubinized()' "$ROOT/lib/upgrade/nand.sh" 2>/dev/null ||
		die "sysupgrade этой прошивки не умеет записывать UBI-образы"
	grep -q "$BOARD" "$ROOT/lib/upgrade/platform.sh" 2>/dev/null ||
		die "sysupgrade этой прошивки не знает $BOARD"
	ok "sysupgrade поддерживает UBI-образы"
}

prepare_workdir() {
	local free_kb

	mkdir -p "$WORKDIR" || die "не удалось создать $WORKDIR"
	free_kb=$(df -Pk "$WORKDIR" | awk 'NR == 2 { print $4 }')
	[ "${free_kb:-0}" -ge 40960 ] ||
		die "в $WORKDIR свободно $(( ${free_kb:-0} / 1024 )) МБ, нужно 40 МБ"
}

fetch() { # <файл> <sha256>
	local file="$1" sum="$2" dst="$WORKDIR/$1" url

	if [ -f "$dst" ] && [ "$(sha256_of "$dst")" = "$sum" ]; then
		ok "$file (уже скачан)"
		return 0
	fi

	for url in "$REPO_RAW/$file" "$OWRT_URL/$file"; do
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
		echo "  • bl2 ← preloader OpenWrt 25.12.5"
	else
		echo "  • bl2: preloader 25.12.5 уже записан, пропуск"
	fi
	if [ "$NEED_FIP" = 1 ]; then
		echo "  • fip ← BL31 + U-Boot OpenWrt 25.12.5"
	else
		echo "  • fip: BL31 + U-Boot 25.12.5 уже записан, пропуск"
	fi
	if [ "$KEEP_RECOVERY" = 1 ]; then
		echo "  • ubi ← форматирование целиком, initramfs 25.12.5 в томе recovery:"
		echo "    он останется в NAND как аварийный (около 9 МБ)"
	else
		echo "  • ubi ← форматирование целиком, initramfs 25.12.5 в томе fit:"
		echo "    прошивка заместит его, лишнего в NAND не останется"
	fi
	echo "  • перезагрузка в initramfs (192.168.1.1)"
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

build_ubi_image() {
	local idx peb page subpage

	if [ "$NEED_UBI_UTILS" = 1 ]; then
		pkg_install ubi-utils || die "не удалось установить ubi-utils"
		command -v ubinize >/dev/null 2>&1 || die "после установки ubi-utils нет ubinize"
	fi

	idx=$(mtd_index ubi)
	peb=$(mtd_attr "$idx" erasesize)
	page=$(mtd_attr "$idx" writesize)
	subpage=$(mtd_attr "$idx" subpagesize)

	# vol_id 2: тома ubootenv и ubootenv2 U-Boot при первом запуске создаст
	# сам под номерами 0 и 1, как при штатной установке через TFTP.
	cat > "$WORKDIR/ubinize.cfg" <<-EOF
		[$BOOT_VOL]
		mode=ubi
		vol_id=2
		vol_type=dynamic
		vol_name=$BOOT_VOL
		image=$WORKDIR/$RECOVERY_FILE
	EOF

	rm -f "$UBI_IMAGE"
	if ! ubinize -o "$UBI_IMAGE" -p "$peb" -m "$page" -s "${subpage:-$page}" \
			"$WORKDIR/ubinize.cfg" > "$WORKDIR/ubinize.log" 2>&1; then
		cat "$WORKDIR/ubinize.log" >&2
		die "ubinize завершился с ошибкой"
	fi
	[ "$(head -c 4 "$UBI_IMAGE")" = "UBI#" ] || die "ubinize собрал некорректный образ"
	ok "UBI-образ: initramfs в томе $BOOT_VOL, $(( $(file_size "$UBI_IMAGE") / 1024 )) КБ"
}

enable_mtd_write() {
	part_writable bl2 && part_writable fip && return 0

	if ! grep -q '^mtd_rw ' "$ROOT/proc/modules" 2>/dev/null; then
		if [ -z "$(find "$ROOT/lib/modules/" -name mtd-rw.ko 2>/dev/null)" ]; then
			pkg_install kmod-mtd-rw ||
				die "не удалось установить kmod-mtd-rw (нужен интернет на роутере)"
		fi
		insmod mtd-rw i_want_a_brick=1 > /dev/null 2>&1 ||
			die "не удалось загрузить модуль mtd-rw"
	fi

	if ! part_writable bl2 || ! part_writable fip; then
		die "разделы bl2 и fip по-прежнему только для чтения"
	fi
	ok "запись в bl2 и fip разрешена (kmod-mtd-rw)"
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
	ok "Загрузчик OpenWrt 25.12.5 на месте."
	echo "  Сейчас sysupgrade отформатирует ubi, положит initramfs в том"
	echo "  recovery и перезагрузит роутер. Сообщения «Image check failed» и"
	echo "  «metadata not present» ожидаемы: это UBI-образ, он пишется с -F."
	echo
	echo "  Через 1–2 минуты:"
	echo "   1. ПК кабелем в LAN (адрес по DHCP), http://192.168.1.1"
	echo "      или ssh root@192.168.1.1 — пароля нет."
	echo "   2. Прошейте sysupgrade без сохранения настроек:"
	echo "      LuCI: System → Backup / Flash Firmware → Flash image…"
	echo "      терминал: sysupgrade -n /tmp/<файл>-sysupgrade.itb"
	echo "   mtd erase ubi делать не нужно."
	if [ "$KEEP_RECOVERY" = 1 ]; then
		echo "   initramfs останется в NAND в томе recovery (около 9 МБ)."
	fi
	echo
	echo "  Инструкция: $REPO_URL"
	echo "=================================================================="
	echo
}

usage() {
	cat <<-EOF
		Использование: flash.sh [-y] [-r]
		  -y, --yes        не задавать вопросов
		  -r, --recovery   оставить initramfs в NAND отдельным томом recovery
		                   как аварийный (около 9 МБ)
		Подробно: $REPO_URL
	EOF
}

main() {
	while [ $# -gt 0 ]; do
		case "$1" in
		-y|--yes)
			AUTO_YES=1
			;;
		-r|--recovery)
			KEEP_RECOVERY=1
			BOOT_VOL=recovery
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

	info "Netis NX62 / Netcore N60 Pro: загрузчик OpenWrt 25.12.5 + initramfs"
	echo
	check_system
	check_layout
	check_tools
	prepare_workdir

	info "Загрузка образов OpenWrt 25.12.5"
	fetch "$BL2_FILE" "$BL2_SHA256"
	fetch "$FIP_FILE" "$FIP_SHA256"
	fetch "$RECOVERY_FILE" "$RECOVERY_SHA256"

	info "Бэкап разделов"
	backup_parts
	part_matches bl2 "$WORKDIR/$BL2_FILE" "$BL2_SHA256" && NEED_BL2=0
	part_matches fip "$WORKDIR/$FIP_FILE" "$FIP_SHA256" && NEED_FIP=0

	summary
	confirm "Продолжить?"

	info "Подготовка UBI-образа"
	build_ubi_image

	if [ "$NEED_BL2" = 1 ] || [ "$NEED_FIP" = 1 ]; then
		info "Запись загрузчика"
		warn "не выключайте питание"
		enable_mtd_write
		[ "$NEED_BL2" = 1 ] && write_part bl2 "$WORKDIR/$BL2_FILE" "$BL2_SHA256"
		[ "$NEED_FIP" = 1 ] && write_part fip "$WORKDIR/$FIP_FILE" "$FIP_SHA256"
	fi

	next_steps
	sysupgrade -F -n "$UBI_IMAGE"
}

main "$@"
