#!/bin/sh
# shellcheck shell=dash disable=SC2015
#
# Прогоняет flash.sh и flash-512m.sh на поддельном роутере: /proc/mtd,
# /sys/class/mtd и /dev/mtdN — обычные файлы, mtd/wget/apk/insmod/sysupgrade —
# заглушки.
#
#   sh tests/run.sh
#   UBINIZE=real sh tests/run.sh      # настоящий ubinize, образ → tests/out-recovery.ubi
#   SH="busybox sh" BB_PATH=/tmp/bb sh tests/run.sh
#                                     # скрипты под busybox ash, утилиты из busybox

TOP=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
FAILED=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }

# <каталог-корень> <размер ubi в hex> [bad_blocks в fip] [блок] [страница] [чип]
# чип: «512» — строка spi-nand в журнале ядра и резерв UBI, «ubi:512» — только
# резерв UBI, «none» — объём узнать неоткуда. По умолчанию 128 при блоке 128 КБ.
make_router() {
	local root="$1" ubi_size="$2" fip_bad="${3:-0}" erasesize="${4:-131072}" \
		writesize="${5:-2048}" chip="${6:-}" idx name off size mib

	mkdir -p "$root/proc" "$root/dev" "$root/tmp/sysinfo" "$root/etc" \
		"$root/lib/upgrade" "$root/lib/modules/6.12.94"
	printf 'dev:    size   erasesize  name\n' > "$root/proc/mtd"
	idx=0
	for entry in bl2:0:0x100000 u-boot-env:0x100000:0x80000 \
			factory:0x180000:0x200000 fip:0x380000:0x200000 \
			"ubi:0x580000:$ubi_size"; do
		name=${entry%%:*}
		off=${entry#*:}
		size=${off#*:}
		off=${off%%:*}
		printf 'mtd%d: %08x %08x "%s"\n' "$idx" "$size" "$erasesize" "$name" >> "$root/proc/mtd"
		mkdir -p "$root/sys/class/mtd/mtd$idx"
		echo $(( off )) > "$root/sys/class/mtd/mtd$idx/offset"
		echo $(( size )) > "$root/sys/class/mtd/mtd$idx/size"
		echo "$erasesize" > "$root/sys/class/mtd/mtd$idx/erasesize"
		echo "$writesize" > "$root/sys/class/mtd/mtd$idx/writesize"
		echo "$writesize" > "$root/sys/class/mtd/mtd$idx/subpagesize"
		echo 0 > "$root/sys/class/mtd/mtd$idx/bad_blocks"
		# bl2, factory и fip в официальном DTS только для чтения
		case "$name" in
		u-boot-env|ubi) echo 0x400 ;;
		*) echo 0x0 ;;
		esac > "$root/sys/class/mtd/mtd$idx/flags"
		if [ "$name" != ubi ]; then
			# «старая прошивка»: bl2 из букв A, u-boot-env из B, factory из C, fip из D
			head -c $(( size )) /dev/zero | tr '\000' "\\$(( idx + 101 ))" > "$root/dev/mtd$idx"
		fi
		idx=$(( idx + 1 ))
	done
	echo "$fip_bad" > "$root/sys/class/mtd/mtd3/bad_blocks"

	if [ -z "$chip" ]; then
		chip=512
		[ "$erasesize" = 131072 ] && chip=128
	fi
	mib=${chip#ubi:}
	if [ "$chip" = "$mib" ] && [ "$chip" != none ]; then
		printf '[    0.927302] spi-nand spi0.0: %s MiB, block size: %s KiB, page size: %s, OOB size: 128\n' \
			"$mib" $(( erasesize / 1024 )) "$writesize" > "$root/dmesg.txt"
	fi
	if [ "$chip" != none ]; then
		mkdir -p "$root/sys/class/ubi/ubi0"
		echo 4 > "$root/sys/class/ubi/ubi0/mtd_num"
		echo 0 > "$root/sys/class/ubi/ubi0/bad_peb_count"
		echo $(( mib * 20480 / erasesize )) > "$root/sys/class/ubi/ubi0/reserved_for_bad"
	fi

	echo "netcore,n60-pro" > "$root/tmp/sysinfo/board_name"
	cat > "$root/etc/openwrt_release" <<-'EOF'
		DISTRIB_ID='OpenWrt'
		DISTRIB_RELEASE='25.12.5'
		DISTRIB_DESCRIPTION='OpenWrt 25.12.5 r33051-f5dae5ece4'
	EOF
	echo "MemTotal:        2031616 kB" > "$root/proc/meminfo"
	: > "$root/proc/modules"
	printf 'nand_upgrade_ubinized() {\n\t:\n}\n' > "$root/lib/upgrade/nand.sh"
	printf '\tnetcore,n60-pro|\\\n' > "$root/lib/upgrade/platform.sh"
}

make_stubs() {
	local bin="$1"

	mkdir -p "$bin"

	cat > "$bin/id" <<-'EOF'
		#!/bin/sh
		echo 0
	EOF

	cat > "$bin/uci" <<-'EOF'
		#!/bin/sh
		echo "192.168.0.1/24"
	EOF

	cat > "$bin/dmesg" <<-'EOF'
		#!/bin/sh
		cat "$NX62_ROOT/dmesg.txt" 2>/dev/null
		exit 0
	EOF

	cat > "$bin/logread" <<-'EOF'
		#!/bin/sh
		exit 0
	EOF

	# wget: отдаёт файлы из firmware/, репозиторий можно «сломать» FAIL_REPO=1
	cat > "$bin/wget" <<-EOF
		#!/bin/sh
		out="" url=""
		while [ \$# -gt 0 ]; do
			case "\$1" in
			-O) out="\$2"; shift ;;
			-T) shift ;;
			-*) ;;
			*) url="\$1" ;;
			esac
			shift
		done
		echo "\$url" >> "\$NX62_LOG/wget.log"
		case "\$url" in
		https://raw.githubusercontent.com/*) [ "\$FAIL_REPO" = 1 ] && exit 8 ;;
		esac
		for f in "$TOP/firmware/\${url##*/}" "$TOP/firmware/512m/\${url##*/}"; do
			[ -f "\$f" ] && exec cp "\$f" "\$out"
		done
		exit 8
	EOF

	# mtd: erase/write по поддельным /dev/mtdN, как настоящий — только в writable.
	# -r «перезагружает»: убивает запустивший скрипт shell, как reboot.
	cat > "$bin/mtd" <<-'EOF'
		#!/bin/sh
		idx_of() {
			sed -n "s/^mtd\([0-9]*\): [0-9a-f]* [0-9a-f]* \"$1\"\$/\1/p" "$NX62_ROOT/proc/mtd"
		}
		echo "mtd $*" >> "$NX62_LOG/mtd.log"
		reboot=0
		while [ "${1#-}" != "$1" ]; do
			[ "$1" = -r ] && reboot=1
			shift
		done
		case "$1" in
		erase) part="$2" ;;
		write) file="$2"; part="$3" ;;
		*) exit 1 ;;
		esac
		idx=$(idx_of "$part")
		[ -n "$idx" ] || exit 1
		flags=$(cat "$NX62_ROOT/sys/class/mtd/mtd$idx/flags")
		[ $(( flags & 0x400 )) -ne 0 ] || { echo "Could not open mtd device: $part" >&2; exit 1; }
		dev="$NX62_ROOT/dev/mtd$idx"
		size=$(cat "$NX62_ROOT/sys/class/mtd/mtd$idx/size")
		case "$1" in
		erase)
			# содержимое огромного ubi тестам не нужно
			if [ "$part" = ubi ]; then
				: > "$dev.erased"
			else
				head -c "$size" /dev/zero | tr '\000' '\377' > "$dev"
			fi
			;;
		write)
			fsize=$(wc -c < "$file" | tr -d ' ')
			{ cat "$file"; tail -c +$(( fsize + 1 )) "$dev"; } > "$dev.new"
			mv "$dev.new" "$dev"
			;;
		esac
		if [ "$reboot" = 1 ]; then
			echo reboot >> "$NX62_LOG/mtd.log"
			kill -9 "$PPID"
		fi
	EOF

	cat > "$bin/apk" <<-'EOF'
		#!/bin/sh
		echo "apk $*" >> "$NX62_LOG/apk.log"
		[ "$1" = add ] || exit 0
		for p in "$@"; do
			[ "$p" = kmod-mtd-rw ] && : > "$NX62_ROOT/lib/modules/6.12.94/mtd-rw.ko"
		done
		exit 0
	EOF

	cat > "$bin/insmod" <<-'EOF'
		#!/bin/sh
		echo "insmod $*" >> "$NX62_LOG/insmod.log"
		[ "$1" = mtd-rw ] && [ "$2" = i_want_a_brick=1 ] || exit 1
		for f in "$NX62_ROOT"/sys/class/mtd/mtd*/flags; do echo 0x400 > "$f"; done
		echo "mtd_rw 12288 0 - Live 0x0000000000000000" >> "$NX62_ROOT/proc/modules"
	EOF

	cat > "$bin/sysupgrade" <<-'EOF'
		#!/bin/sh
		echo "sysupgrade $*" >> "$NX62_LOG/sysupgrade.log"
		for last; do :; done
		cp "$last" "$NX62_LOG/sysupgrade-image"
	EOF

	if [ "$UBINIZE" != real ]; then
		cat > "$bin/ubinize" <<-'EOF'
			#!/bin/sh
			echo "ubinize $*" >> "$NX62_LOG/ubinize.log"
			while [ $# -gt 1 ]; do
				[ "$1" = -o ] && out="$2"
				shift
			done
			cp "$1" "$NX62_LOG/ubinize.cfg"
			{ printf 'UBI#'; head -c 131068 /dev/zero; } > "$out"
		EOF
	fi

	chmod +x "$bin"/*
}

# <имя сценария> <корень> <аргументы скрипта...>; скрипт — $SCRIPT или flash.sh
run_flash() {
	local name="$1" root="$2"
	shift 2

	export NX62_ROOT="$root" NX62_WORKDIR="$T/$name/work" NX62_LOG="$T/$name/log"
	mkdir -p "$NX62_LOG"
	# shellcheck disable=SC2086 # SH может быть «busybox sh»
	PATH="$T/bin:${BB_PATH:+$BB_PATH:}$PATH" ${SH:-sh} "$TOP/${SCRIPT:-flash.sh}" "$@" \
		> "$T/$name/out" 2>&1 < /dev/null
	echo $? > "$T/$name/rc"
}

rc_of() {
	cat "$T/$1/rc"
}

sha_of_head() { # <файл> <размер>
	head -c "$2" "$1" | sha256sum | cut -d ' ' -f 1
}

check_written() { # <сценарий> <корень>
	local name="$1" root="$2"

	[ "$(sha_of_head "$root/dev/mtd0" 209931)" = 4215ec48f52b26ce0d93c2f67d4e435d6372c2701b9574b59d2ed51aaef0acf2 ] &&
		pass "$name: bl2 содержит preloader" || fail "$name: bl2 не записан"
	[ "$(sha_of_head "$root/dev/mtd3" 1095212)" = 1d5c3cbac086bf69598a374f8098776a1843384b014dda79f4673d8e4d7d645a ] &&
		pass "$name: fip содержит BL31 + U-Boot" || fail "$name: fip не записан"
	[ "$(head -c 4 "$T/$name/log/sysupgrade-image" 2>/dev/null)" = "UBI#" ] &&
		grep -q -- '^sysupgrade -F -n .*/recovery.ubi$' "$T/$name/log/sysupgrade.log" &&
		pass "$name: sysupgrade -F -n с UBI-образом" || fail "$name: sysupgrade не вызван как нужно"
}

make_stubs "$T/bin"

# --- flash.sh: стандартная версия, 128 МБ ---

# 1. Штатный запуск с -y: всё скачивается, пишется, вызывается sysupgrade
make_router "$T/r1" 0x7a80000
run_flash ok "$T/r1" -y
[ "$(rc_of ok)" = 0 ] && pass "ok: код возврата 0" || fail "ok: код возврата $(rc_of ok)"
check_written ok "$T/r1"
grep -q 'insmod mtd-rw i_want_a_brick=1' "$T/ok/log/insmod.log" 2>/dev/null &&
	pass "ok: mtd-rw загружен" || fail "ok: mtd-rw не загружен"
grep -q 'apk add kmod-mtd-rw' "$T/ok/log/apk.log" 2>/dev/null &&
	pass "ok: kmod-mtd-rw поставлен" || fail "ok: kmod-mtd-rw не ставился"
for f in bl2 u-boot-env factory fip; do
	[ -s "$T/ok/work/backup/$f.bin" ] || fail "ok: нет бэкапа $f"
done
(cd "$T/ok/work/backup" && sha256sum -c SHA256SUMS > /dev/null 2>&1) &&
	pass "ok: бэкап и его SHA256SUMS" || fail "ok: бэкап не сходится"
[ "$(tr -d 'A' < "$T/ok/work/backup/bl2.bin" | wc -c | tr -d ' ')" = 0 ] &&
	pass "ok: в бэкапе старый bl2, а не новый" || fail "ok: бэкап bl2 снят после записи"
if [ "$UBINIZE" = real ]; then
	cp "$T/ok/log/sysupgrade-image" "$TOP/tests/out-recovery.ubi" 2>/dev/null
else
	grep -q '^ubinize -o .*/recovery.ubi -p 131072 -m 2048 -s 2048 ' "$T/ok/log/ubinize.log" &&
		pass "ok: параметры ubinize" || fail "ok: параметры ubinize: $(cat "$T/ok/log/ubinize.log")"
	grep -q '^vol_id=2$' "$T/ok/log/ubinize.cfg" && grep -q '^vol_name=recovery$' "$T/ok/log/ubinize.cfg" &&
		grep -q '^vol_type=dynamic$' "$T/ok/log/ubinize.cfg" &&
		pass "ok: конфиг ubinize (recovery, id 2, dynamic)" || fail "ok: конфиг ubinize"
fi

# 2. Повторный запуск: загрузчик уже на месте, пишется только ubi
run_flash again "$T/r1" -y
[ "$(rc_of again)" = 0 ] && ! grep -q '^mtd ' "$T/again/log/mtd.log" 2>/dev/null &&
	grep -q 'уже записан, пропуск' "$T/again/out" && [ -s "$T/again/log/sysupgrade.log" ] &&
	pass "again: bl2/fip не перезаписываются, sysupgrade вызывается" ||
	fail "again: $(tail -n 5 "$T/again/out")"

# 3. Репозиторий недоступен — образы берутся с downloads.openwrt.org
make_router "$T/r3" 0x7a80000
FAIL_REPO=1 run_flash mirror "$T/r3" -y
[ "$(rc_of mirror)" = 0 ] && grep -q '^https://downloads.openwrt.org/' "$T/mirror/log/wget.log" &&
	pass "mirror: запасной источник" || fail "mirror: $(tail -n 5 "$T/mirror/out")"

# 4. Без -y и без терминала: вопрос задать нельзя, ничего не пишется
make_router "$T/r4" 0x7a80000
run_flash notty "$T/r4"
[ "$(rc_of notty)" = 1 ] && grep -q 'добавьте -y' "$T/notty/out" &&
	[ ! -e "$T/notty/log/mtd.log" ] && [ ! -e "$T/notty/log/sysupgrade.log" ] &&
	pass "notty: остановка до записи с подсказкой про -y" || fail "notty: rc=$(rc_of notty): $(tail -n 2 "$T/notty/out")"

# 5. Разметка стоковая / NMBM (ubi 0x7280000) — отказ
make_router "$T/r5" 0x7280000
run_flash nmbm "$T/r5" -y
[ "$(rc_of nmbm)" = 1 ] && [ ! -e "$T/nmbm/log/mtd.log" ] && grep -q 'раздел ubi' "$T/nmbm/out" &&
	pass "nmbm: чужая разметка отклонена" || fail "nmbm: $(tail -n 3 "$T/nmbm/out")"

# 6. Bad-блок в fip — отказ
make_router "$T/r6" 0x7a80000 1
run_flash badblock "$T/r6" -y
[ "$(rc_of badblock)" = 1 ] && [ ! -e "$T/badblock/log/mtd.log" ] &&
	pass "badblock: отказ при bad-блоке в fip" || fail "badblock: rc=$(rc_of badblock)"

# 7. Другая модель — отказ
make_router "$T/r7" 0x7a80000
echo "netcore,n60" > "$T/r7/tmp/sysinfo/board_name"
run_flash board "$T/r7" -y
[ "$(rc_of board)" = 1 ] && grep -q "модель 'netcore,n60'" "$T/board/out" &&
	pass "board: чужая модель отклонена" || fail "board: $(tail -n 3 "$T/board/out")"

# 8. Версия 512 МБ (блок 256 КБ, страница 4 КБ) — отказ с подсказкой про flash-512m.sh
make_router "$T/r8" 0x1f400000 0 262144 4096
run_flash is512 "$T/r8" -y
[ "$(rc_of is512)" = 1 ] && [ ! -e "$T/is512/log/mtd.log" ] && grep -q 'flash-512m.sh' "$T/is512/out" &&
	pass "is512: flash.sh отправляет на flash-512m.sh" || fail "is512: $(tail -n 3 "$T/is512/out")"

# 8a. Winbond W25N04KV: 512 МБ при блоке 128 КБ и странице 2 КБ — тоже на flash-512m.sh
make_router "$T/r8a" 0x7a80000 0 131072 2048 512
run_flash winbond "$T/r8a" -y
[ "$(rc_of winbond)" = 1 ] && [ ! -e "$T/winbond/log/mtd.log" ] && grep -q 'flash-512m.sh' "$T/winbond/out" &&
	pass "winbond: flash.sh отправляет 512 МБ со страницей 2 КБ на flash-512m.sh" ||
	fail "winbond: $(tail -n 3 "$T/winbond/out")"

# 8b. Объём не узнать (журнал вытеснен, UBI нет) — считается стандартной версией
make_router "$T/r8b" 0x7a80000 0 131072 2048 none
run_flash nosize "$T/r8b" -y
[ "$(rc_of nosize)" = 0 ] && grep -q 'не удалось узнать объём NAND' "$T/nosize/out" &&
	pass "nosize: без объёма flash.sh идёт как для 128 МБ с предупреждением" ||
	fail "nosize: rc=$(rc_of nosize) $(tail -n 3 "$T/nosize/out")"

# --- flash-512m.sh: версия с 512 МБ ROM ---

BL2_512=9b958b6ff922f55aa20dcf81afc5052152c020a5b0fc9ca50d7fd246cd560388
FIP_512=e4d87f39ebc01f5b5cf8428adc000cb327424f7b223622782bb876d1ebf34aed

OWRT_BL2=4215ec48f52b26ce0d93c2f67d4e435d6372c2701b9574b59d2ed51aaef0acf2

# <сценарий> <корень> [wild|owrt]: загрузчик записан, env стёрт, последним шёл
# mtd -r erase ubi. BL2 — WildEdition (страница 4 КБ) или официальный (2 КБ).
check_512() {
	local name="$1" root="$2" bl2="${3:-wild}"

	[ "$(rc_of "$name")" = 137 ] && [ "$(tail -n 1 "$T/$name/log/mtd.log")" = reboot ] &&
		[ "$(tail -n 2 "$T/$name/log/mtd.log" | head -n 1)" = "mtd -r erase ubi" ] &&
		pass "$name: последним mtd -r erase ubi и перезагрузка" ||
		fail "$name: rc=$(rc_of "$name"), $(tail -n 3 "$T/$name/out")"
	if [ "$bl2" = wild ]; then
		[ "$(sha256sum < "$root/dev/mtd0" | cut -d ' ' -f 1)" = "$BL2_512" ] &&
			pass "$name: bl2 = WildEdition" || fail "$name: bl2 не WildEdition"
	else
		[ "$(sha_of_head "$root/dev/mtd0" 209931)" = "$OWRT_BL2" ] &&
			pass "$name: bl2 = официальный OpenWrt" || fail "$name: bl2 не официальный"
	fi
	[ "$(sha256sum < "$root/dev/mtd3" | cut -d ' ' -f 1)" = "$FIP_512" ] &&
		pass "$name: fip = WildEdition" || fail "$name: fip не записан"
	[ "$(tr -d '\377' < "$root/dev/mtd1" | wc -c | tr -d ' ')" = 0 ] &&
		pass "$name: u-boot-env стёрт" || fail "$name: u-boot-env не стёрт"
	[ "$(tr -d 'C' < "$root/dev/mtd2" | wc -c | tr -d ' ')" = 0 ] &&
		pass "$name: factory не тронут" || fail "$name: factory изменён"
}

# 9. Штатный запуск на 512 МБ с официальным DTS (ubi 122,5 МБ)
make_router "$T/s1" 0x7a80000 0 262144 4096
SCRIPT=flash-512m.sh run_flash ok512 "$T/s1" -y
check_512 ok512 "$T/s1"
[ "$(tr -d 'A' < "$T/ok512/work/backup/bl2.bin" | wc -c | tr -d ' ')" = 0 ] &&
	(cd "$T/ok512/work/backup" && sha256sum -c SHA256SUMS > /dev/null 2>&1) &&
	pass "ok512: бэкап снят до записи" || fail "ok512: бэкап"

# 10. Повторный запуск: загрузчик не перезаписывается, но env/ubi стираются
SCRIPT=flash-512m.sh run_flash again512 "$T/s1" -y
! grep -q '^mtd write' "$T/again512/log/mtd.log" && grep -q 'уже записан, пропуск' "$T/again512/out" &&
	pass "again512: bl2/fip не перезаписываются" || fail "again512: $(tail -n 5 "$T/again512/out")"
check_512 again512 "$T/s1"

# 11. Прошивка с ubi на 500 МБ и именем платы от другой сборки, репозиторий недоступен
make_router "$T/s3" 0x1f400000 0 262144 4096 none
echo "netcore,n60-pro-512m" > "$T/s3/tmp/sysinfo/board_name"
FAIL_REPO=1 SCRIPT=flash-512m.sh run_flash cdn512 "$T/s3" -y
check_512 cdn512 "$T/s3"
grep -q '^https://cdn.jsdelivr.net/' "$T/cdn512/log/wget.log" &&
	pass "cdn512: запасной источник jsDelivr" || fail "cdn512: jsDelivr не использовался"

# 12. Стандартная версия 128 МБ — отказ с подсказкой про flash.sh
make_router "$T/s4" 0x7a80000
SCRIPT=flash-512m.sh run_flash is128 "$T/s4" -y
[ "$(rc_of is128)" = 1 ] && [ ! -e "$T/is128/log/mtd.log" ] && grep -q 'main/flash.sh' "$T/is128/out" &&
	pass "is128: flash-512m.sh отправляет на flash.sh" || fail "is128: $(tail -n 3 "$T/is128/out")"

# 13. Без -y и без терминала — остановка до записи
make_router "$T/s5" 0x7a80000 0 262144 4096
SCRIPT=flash-512m.sh run_flash notty512 "$T/s5"
[ "$(rc_of notty512)" = 1 ] && [ ! -e "$T/notty512/log/mtd.log" ] && grep -q 'добавьте -y' "$T/notty512/out" &&
	pass "notty512: остановка до записи" || fail "notty512: rc=$(rc_of notty512)"

# 14. Bad-блок в fip — отказ
make_router "$T/s6" 0x7a80000 1 262144 4096
SCRIPT=flash-512m.sh run_flash badblock512 "$T/s6" -y
[ "$(rc_of badblock512)" = 1 ] && [ ! -e "$T/badblock512/log/mtd.log" ] &&
	pass "badblock512: отказ при bad-блоке в fip" || fail "badblock512: rc=$(rc_of badblock512)"

# 15. Winbond 512 МБ (страница 2 КБ), объём из журнала ядра: официальный BL2 + FIP WildEdition
make_router "$T/w1" 0x7a80000 0 131072 2048 512
SCRIPT=flash-512m.sh run_flash winbond512 "$T/w1" -y
check_512 winbond512 "$T/w1" owrt
grep -q 'Winbond W25N04KV' "$T/winbond512/out" && grep -q '^https://raw.githubusercontent.com/.*/firmware/openwrt-25.12.5-mediatek-filogic-netcore_n60-pro-preloader.bin$' "$T/winbond512/log/wget.log" &&
	pass "winbond512: определён Winbond, взят официальный BL2" || fail "winbond512: $(grep -E 'NAND|bl2' "$T/winbond512/out")"

# 16. То же, но журнал вытеснен: объём по резерву UBI под bad-блоки
make_router "$T/w2" 0x7a80000 0 131072 2048 ubi:512
SCRIPT=flash-512m.sh run_flash winbondubi "$T/w2" -y
check_512 winbondubi "$T/w2" owrt

# 17. Как на реальном роутере: официальные BL2 и FIP уже стоят — пишется только FIP
make_router "$T/w3" 0x7a80000 0 131072 2048 512
for f in "0 openwrt-25.12.5-mediatek-filogic-netcore_n60-pro-preloader.bin" 		"3 openwrt-25.12.5-mediatek-filogic-netcore_n60-pro-bl31-uboot.fip"; do
	idx=${f%% *}
	{ cat "$TOP/firmware/${f#* }"; head -c 2097152 /dev/zero | tr ' ' 'ÿ'; } |
		head -c "$(cat "$T/w3/sys/class/mtd/mtd$idx/size")" > "$T/w3/dev/mtd$idx"
done
SCRIPT=flash-512m.sh run_flash winbondfip "$T/w3" -y
! grep -q 'bl2$' "$T/winbondfip/log/mtd.log" && grep -q '^mtd write .* fip$' "$T/winbondfip/log/mtd.log" &&
	pass "winbondfip: официальный BL2 не перезаписан, записан только FIP" ||
	fail "winbondfip: $(cat "$T/winbondfip/log/mtd.log")"
check_512 winbondfip "$T/w3" owrt

# 18. Страница 2 КБ и объём не узнать — отказ до записи
make_router "$T/w4" 0x7a80000 0 131072 2048 none
SCRIPT=flash-512m.sh run_flash nosize512 "$T/w4" -y
[ "$(rc_of nosize512)" = 1 ] && [ ! -e "$T/nosize512/log/mtd.log" ] && grep -q 'не удалось узнать объём NAND' "$T/nosize512/out" &&
	pass "nosize512: без объёма отказ" || fail "nosize512: rc=$(rc_of nosize512) $(tail -n 2 "$T/nosize512/out")"

if [ "$FAILED" = 0 ]; then
	echo "Все сценарии прошли."
else
	echo "Есть ошибки. Вывод первого сценария каждого скрипта:"
	cat "$T/ok/out" "$T/ok512/out"
fi
exit "$FAILED"
