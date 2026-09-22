#!/bin/sh
# shellcheck shell=dash disable=SC2015
#
# Прогоняет flash.sh на поддельном роутере: /proc/mtd, /sys/class/mtd и
# /dev/mtdN — обычные файлы, mtd/wget/apk/insmod/sysupgrade — заглушки.
#
#   sh tests/run.sh
#   UBINIZE=real sh tests/run.sh      # настоящий ubinize, образ → tests/out-recovery.ubi
#   SH="busybox sh" BB_PATH=/tmp/bb sh tests/run.sh
#                                     # flash.sh под busybox ash, утилиты из busybox

TOP=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
FAILED=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }

# <каталог-корень> <размер ubi в hex> <bad_blocks в fip>
make_router() {
	local root="$1" ubi_size="$2" fip_bad="${3:-0}" idx name off size

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
		printf 'mtd%d: %08x 00020000 "%s"\n' "$idx" "$size" "$name" >> "$root/proc/mtd"
		mkdir -p "$root/sys/class/mtd/mtd$idx"
		echo $(( off )) > "$root/sys/class/mtd/mtd$idx/offset"
		echo $(( size )) > "$root/sys/class/mtd/mtd$idx/size"
		echo 131072 > "$root/sys/class/mtd/mtd$idx/erasesize"
		echo 2048 > "$root/sys/class/mtd/mtd$idx/writesize"
		echo 2048 > "$root/sys/class/mtd/mtd$idx/subpagesize"
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
		cp "$TOP/firmware/\${url##*/}" "\$out"
	EOF

	# mtd: erase/write по поддельным /dev/mtdN, как настоящий — только в writable
	cat > "$bin/mtd" <<-'EOF'
		#!/bin/sh
		idx_of() {
			sed -n "s/^mtd\([0-9]*\): [0-9a-f]* [0-9a-f]* \"$1\"\$/\1/p" "$NX62_ROOT/proc/mtd"
		}
		echo "mtd $*" >> "$NX62_LOG/mtd.log"
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
			head -c "$size" /dev/zero | tr '\000' '\377' > "$dev"
			;;
		write)
			fsize=$(wc -c < "$file" | tr -d ' ')
			{ cat "$file"; tail -c +$(( fsize + 1 )) "$dev"; } > "$dev.new"
			mv "$dev.new" "$dev"
			;;
		esac
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

# <имя сценария> <корень> <аргументы flash.sh...>
run_flash() {
	local name="$1" root="$2"
	shift 2

	export NX62_ROOT="$root" NX62_WORKDIR="$T/$name/work" NX62_LOG="$T/$name/log"
	mkdir -p "$NX62_LOG"
	# shellcheck disable=SC2086 # SH может быть «busybox sh»
	PATH="$T/bin:${BB_PATH:+$BB_PATH:}$PATH" ${SH:-sh} "$TOP/flash.sh" "$@" \
		> "$T/$name/out" 2>&1 < /dev/null
	echo $? > "$T/$name/rc"
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

# 1. Штатный запуск с -y: всё скачивается, пишется, вызывается sysupgrade
make_router "$T/r1" 0x7a80000
run_flash ok "$T/r1" -y
if [ "$(cat "$T/ok/rc")" = 0 ]; then pass "ok: код возврата 0"; else fail "ok: код возврата $(cat "$T/ok/rc")"; fi
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
[ "$(cat "$T/again/rc")" = 0 ] && ! grep -q '^mtd ' "$T/again/log/mtd.log" 2>/dev/null &&
	grep -q 'уже записан, пропуск' "$T/again/out" && [ -s "$T/again/log/sysupgrade.log" ] &&
	pass "again: bl2/fip не перезаписываются, sysupgrade вызывается" ||
	fail "again: $(tail -n 5 "$T/again/out")"

# 3. Репозиторий недоступен — образы берутся с downloads.openwrt.org
make_router "$T/r3" 0x7a80000
FAIL_REPO=1 run_flash mirror "$T/r3" -y
[ "$(cat "$T/mirror/rc")" = 0 ] && grep -q '^https://downloads.openwrt.org/' "$T/mirror/log/wget.log" &&
	pass "mirror: запасной источник" || fail "mirror: $(tail -n 5 "$T/mirror/out")"

# 4. Без -y и без терминала: вопрос задать нельзя, ничего не пишется
make_router "$T/r4" 0x7a80000
run_flash notty "$T/r4"
[ "$(cat "$T/notty/rc")" = 1 ] && grep -q 'добавьте -y' "$T/notty/out" &&
	[ ! -e "$T/notty/log/mtd.log" ] && [ ! -e "$T/notty/log/sysupgrade.log" ] &&
	pass "notty: остановка до записи с подсказкой про -y" || fail "notty: rc=$(cat "$T/notty/rc"): $(tail -n 2 "$T/notty/out")"

# 5. Разметка стоковая / NMBM (ubi 0x7280000) — отказ
make_router "$T/r5" 0x7280000
run_flash nmbm "$T/r5" -y
[ "$(cat "$T/nmbm/rc")" = 1 ] && [ ! -e "$T/nmbm/log/mtd.log" ] && grep -q 'раздел ubi' "$T/nmbm/out" &&
	pass "nmbm: чужая разметка отклонена" || fail "nmbm: $(tail -n 3 "$T/nmbm/out")"

# 6. Bad-блок в fip — отказ
make_router "$T/r6" 0x7a80000 1
run_flash badblock "$T/r6" -y
[ "$(cat "$T/badblock/rc")" = 1 ] && [ ! -e "$T/badblock/log/mtd.log" ] &&
	pass "badblock: отказ при bad-блоке в fip" || fail "badblock: rc=$(cat "$T/badblock/rc")"

# 7. Другая модель — отказ
make_router "$T/r7" 0x7a80000
echo "netcore,n60" > "$T/r7/tmp/sysinfo/board_name"
run_flash board "$T/r7" -y
[ "$(cat "$T/board/rc")" = 1 ] && grep -q "модель 'netcore,n60'" "$T/board/out" &&
	pass "board: чужая модель отклонена" || fail "board: $(tail -n 3 "$T/board/out")"

if [ "$FAILED" = 0 ]; then
	echo "Все сценарии прошли."
else
	echo "Есть ошибки. Вывод первого сценария:"
	cat "$T/ok/out"
fi
exit "$FAILED"
