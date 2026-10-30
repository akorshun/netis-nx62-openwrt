<#
.SYNOPSIS
  Netis NX62 / Netcore N60 Pro (128 МБ ROM): OpenWrt 25.12.5 с ПК под Windows.

.DESCRIPTION
  Находит роутер по SSH (192.168.2.1, 192.168.20.1, 192.168.1.1, 192.168.0.1;
  без пароля или с одним из стандартных), проверяет модель, снимает бэкап
  загрузчика и factory через flash.sh -b и копирует его в backup\<дата>, затем
  запускает flash.sh -y. После перезагрузки в initramfs заливает
  sysupgrade-образ, ждёт загрузки прошивки и проверяет разделы и свободное место.

  Нужен только встроенный в Windows 10/11 клиент OpenSSH. ПК подключается
  кабелем в LAN роутера и получает адрес по DHCP; роутеру нужен интернет (WAN).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File flash-windows.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File flash-windows.ps1 -Ip 192.168.10.1 -Password secret
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File flash-windows.ps1 -Firmware D:\openwrt-...-sysupgrade.itb

.LINK
  https://github.com/akorshun/netis-nx62-openwrt
#>
[CmdletBinding()]
param(
	# Адреса, на которых искать роутер, по порядку
	[string[]]$Ip = @('192.168.2.1', '192.168.20.1', '192.168.1.1', '192.168.0.1'),
	# Пароль root; без него пробуются пустой и стандартные
	[string]$Password,
	# Свой sysupgrade-образ; без него берётся образ из репозитория
	[string]$Firmware,
	# Оставить initramfs в NAND аварийным томом recovery (flash.sh -r)
	[switch]$Recovery,
	# Снять в бэкап и раздел ubi (прежнюю прошивку целиком, около 120 МБ)
	[switch]$FullBackup,
	# Не спрашивать подтверждения
	[switch]$Yes,
	# Куда класть бэкапы; по умолчанию папка backup рядом со скриптом
	[string]$BackupRoot
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Repo = 'https://github.com/akorshun/netis-nx62-openwrt'
$RepoRaw = 'https://raw.githubusercontent.com/akorshun/netis-nx62-openwrt/main'
$FlashUrl = "$RepoRaw/flash.sh"
$FwName = 'openwrt-25.12.5-mediatek-filogic-netcore_n60-pro-argon-ru-squashfs-sysupgrade.itb'
$FwUrl = "$RepoRaw/firmware/$FwName"
$SumsUrl = "$RepoRaw/firmware/SHA256SUMS"
$RouterFw = '/tmp/sysupgrade.itb'
$RouterBackup = '/tmp/nx62-flash/backup'

# Официальный загрузчик 25.12.5, который пишет flash.sh: размер и SHA-256
$Bl2Size = 209931
$Bl2Sha = '4215ec48f52b26ce0d93c2f67d4e435d6372c2701b9574b59d2ed51aaef0acf2'
$FipSize = 1095212
$FipSha = '1d5c3cbac086bf69598a374f8098776a1843384b014dda79f4673d8e4d7d645a'

$Passwords = @('', 'root', 'password', 'passwd', 'toor', 'admin', '12345678',
	'123456789', '1234567890', '1234', '12345', '123456', 'admin123', 'root123',
	'netis', 'netcore', 'openwrt')

# powershell -File передаёт «-Ip a,b» одной строкой
$Ip = @($Ip | ForEach-Object { $_ -split '[,; ]+' } | Where-Object { $_ })
if (-not $BackupRoot) { $BackupRoot = Join-Path $PSScriptRoot 'backup' }

# --- вывод -------------------------------------------------------------------

function Step($m) { Write-Host ''; Write-Host "== $m" -ForegroundColor Cyan }
function Ok($m) { Write-Host "  [ok] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Note($m) { Write-Host "       $m" }
function Fail($m) { throw $m }

# --- SSH ---------------------------------------------------------------------

$Ssh = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
$Scp = Join-Path $env:SystemRoot 'System32\OpenSSH\scp.exe'
if (-not (Test-Path $Ssh)) {
	$cmd = Get-Command ssh.exe -ErrorAction SilentlyContinue
	if ($cmd) {
		$Ssh = $cmd.Source
		$Scp = Join-Path (Split-Path $Ssh) 'scp.exe'
	}
}

# Пароль ssh.exe получает из askpass-файла: по-другому встроенный клиент его
# не принимает. Сам пароль лежит в переменной окружения, не в файле.
$AskPass = Join-Path $env:TEMP "nx62-askpass-$PID.cmd"

# Ключи хоста меняются при каждой перепрошивке, поэтому known_hosts не ведём.
# ssh-rsa и group14-sha1 — для старого dropbear в заводских прошивках.
$SshOpts = @(
	'-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL',
	'-o', 'GlobalKnownHostsFile=NUL', '-o', 'LogLevel=ERROR',
	'-o', 'ConnectTimeout=6', '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=4',
	'-o', 'PubkeyAuthentication=no', '-o', 'NumberOfPasswordPrompts=1',
	'-o', 'HostKeyAlgorithms=+ssh-rsa', '-o', 'KexAlgorithms=+diffie-hellman-group14-sha1'
)

function Set-RouterPassword($p) { $env:NX62_SSH_PASS = $p }

function Join-Args($list) {
	($list | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
}

# Запускает sh-скрипт на роутере (через stdin) и возвращает код и вывод.
# Код 255 — нет соединения или не подошёл пароль.
function Invoke-Router([string]$Address, [string]$Script, [int]$TimeoutSec = 60, [switch]$Quiet) {
	$opts = $SshOpts
	if ($Quiet) { $opts = $opts + @('-o', 'LogLevel=QUIET') }
	$psi = New-Object Diagnostics.ProcessStartInfo
	$psi.FileName = $Ssh
	$psi.Arguments = Join-Args ($opts + @("root@$Address", 'sh -s'))
	$psi.UseShellExecute = $false
	$psi.RedirectStandardInput = $true
	$psi.RedirectStandardOutput = $true
	$psi.RedirectStandardError = $true
	$psi.StandardOutputEncoding = [Text.Encoding]::UTF8
	$psi.StandardErrorEncoding = [Text.Encoding]::UTF8
	$p = [Diagnostics.Process]::Start($psi)
	$out = $p.StandardOutput.ReadToEndAsync()
	$err = $p.StandardError.ReadToEndAsync()
	$bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Script -replace "`r", '') + "`n")
	try {
		$p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
		$p.StandardInput.Close()
	} catch { }
	if (-not $p.WaitForExit($TimeoutSec * 1000)) {
		try { $p.Kill() } catch { }
		return [pscustomobject]@{ Code = 255; Out = ''; Err = 'timeout' }
	}
	[pscustomobject]@{ Code = $p.ExitCode; Out = $out.Result; Err = $err.Result }
}

# Команда на роутере с выводом прямо в консоль; возвращает строки stdout
function Invoke-RouterLive([string]$Address, [string]$Command) {
	$lines = New-Object Collections.Generic.List[string]
	& $Ssh @SshOpts "root@$Address" $Command | ForEach-Object {
		Write-Host "  | $_"
		$lines.Add($_)
	}
	[pscustomobject]@{ Code = $LASTEXITCODE; Lines = $lines }
}

function Test-Port([string]$Address, [int]$Port = 22, [int]$Ms = 1500) {
	$c = New-Object Net.Sockets.TcpClient
	try {
		$t = $c.ConnectAsync($Address, $Port)
		return ($t.Wait($Ms) -and $c.Connected)
	} catch {
		return $false
	} finally {
		$c.Close()
	}
}

# --- состояние роутера ---------------------------------------------------------

# Одна проверка на все случаи: модель, прошивка, корневая ФС, загрузчик,
# разделы, тома UBI, место. Вывод «ключ=значение», ключи могут повторяться.
$ProbeScript = @'
idx() { sed -n "s/^mtd\([0-9][0-9]*\): [0-9a-f]* [0-9a-f]* \"$1\"\$/\1/p" /proc/mtd; }
echo "board=$(cat /tmp/sysinfo/board_name 2>/dev/null)"
echo "model=$(cat /tmp/sysinfo/model 2>/dev/null)"
echo "compat=$(tr '\000' ' ' < /proc/device-tree/compatible 2>/dev/null)"
echo "release=$( (. /etc/openwrt_release; echo "$DISTRIB_DESCRIPTION") 2>/dev/null)"
echo "kernel=$(uname -r)"
echo "root=$(awk '$2 == "/" { t = $3 } END { print t }' /proc/mounts)"
echo "rom=$(awk '$2 == "/rom" { print $1 " " $3 }' /proc/mounts)"
echo "overlay=$(awk '$2 == "/overlay" { print $1 " " $3 }' /proc/mounts)"
echo "lan=$(uci -q get network.lan.ipaddr)"
b=$(idx bl2); f=$(idx fip)
[ -n "$b" ] && echo "bl2sha=$(head -c @BL2SIZE@ /dev/mtd$b | sha256sum | cut -d ' ' -f 1)"
[ -n "$f" ] && echo "fipsha=$(head -c @FIPSIZE@ /dev/mtd$f | sha256sum | cut -d ' ' -f 1)"
sed -n 's/^mtd\([0-9]*\): \([0-9a-f]*\) [0-9a-f]* "\(.*\)"$/\1 \2 \3/p' /proc/mtd | while read -r n size name; do
	echo "mtd=$name $(( 0x$size / 1024 )) $(cat /sys/class/mtd/mtd$n/bad_blocks 2>/dev/null)"
done
for u in /sys/class/ubi/ubi[0-9]; do
	[ -d "$u" ] || continue
	echo "ubi=$(cat $u/mtd_num) $(cat $u/total_eraseblocks) $(cat $u/avail_eraseblocks) $(cat $u/bad_peb_count) $(cat $u/eraseblock_size)"
done
for v in /sys/class/ubi/ubi[0-9]_[0-9]*; do
	[ -f "$v/name" ] || continue
	echo "vol=$(cat $v/name) $(( $(cat $v/reserved_ebs) * $(cat $v/usable_eb_size) / 1024 ))"
done
df -k /overlay 2>/dev/null | awk 'NR == 2 { print "df=" $2 " " $3 " " $4 }'
awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } END { print "mem=" int(t / 1024) " " int(a / 1024) }' /proc/meminfo
dmesg 2>/dev/null | grep -iE 'ubi[0-9]* (error|warning)|ubifs error|squashfs error|bad block|nmbm' | tail -n 10 | sed 's/^/dmesg=/'
'@
$ProbeScript = $ProbeScript.Replace('@BL2SIZE@', "$Bl2Size").Replace('@FIPSIZE@', "$FipSize")

function ConvertFrom-Probe([string]$Text) {
	$h = @{}
	foreach ($line in ($Text -split "`n")) {
		$line = $line.TrimEnd("`r")
		$i = $line.IndexOf('=')
		if ($i -lt 1) { continue }
		$k = $line.Substring(0, $i)
		if (-not $h.ContainsKey($k)) { $h[$k] = New-Object Collections.Generic.List[string] }
		$h[$k].Add($line.Substring($i + 1))
	}
	$h
}

function Get-One($probe, $key) {
	if ($probe.ContainsKey($key)) { $probe[$key][0] } else { '' }
}

function Test-Model($probe) {
	$text = (Get-One $probe 'board') + ' ' + (Get-One $probe 'model') + ' ' + (Get-One $probe 'compat')
	$text -match 'netcore,n60-pro|n60[ _-]?pro|nx62'
}

function Test-Initramfs($probe) {
	(Get-One $probe 'root') -in @('rootfs', 'tmpfs', 'ramfs')
}

function Test-Loader($probe) {
	(Get-One $probe 'bl2sha') -eq $Bl2Sha -and (Get-One $probe 'fipsha') -eq $FipSha
}

function Show-Router($address, $probe) {
	Ok "роутер: $address"
	Note "модель:   $(Get-One $probe 'model') ($(Get-One $probe 'board'))"
	Note "прошивка: $(Get-One $probe 'release'), ядро $(Get-One $probe 'kernel')"
}

# Пробует войти на адрес: сначала пароль, который уже подошёл, затем список
function Connect-Router([string]$Address, [string[]]$Candidates) {
	foreach ($pw in $Candidates) {
		Set-RouterPassword $pw
		$r = Invoke-Router $Address $ProbeScript -TimeoutSec 40 -Quiet
		if ($r.Code -eq 0) {
			return [pscustomobject]@{ Ip = $Address; Password = $pw; Probe = (ConvertFrom-Probe $r.Out) }
		}
		if (-not (Test-Port $Address)) { break }
	}
	$null
}

# Ждёт роутер N60 Pro на одном из адресов, у которого $Condition истинно
function Wait-Router([string[]]$Addresses, [string[]]$Candidates, [scriptblock]$Condition,
		[int]$TimeoutSec, [string]$What) {
	$deadline = (Get-Date).AddSeconds($TimeoutSec)
	$renewed = $false
	$start = Get-Date
	Write-Host -NoNewline "       жду $What "
	while ((Get-Date) -lt $deadline) {
		foreach ($a in $Addresses) {
			if (-not (Test-Port $a)) { continue }
			$r = Connect-Router $a $Candidates
			if ($r -and (Test-Model $r.Probe) -and (& $Condition $r.Probe)) {
				Write-Host ''
				return $r
			}
		}
		# ПК мог остаться с адресом из старой подсети: обычно Windows сама
		# берёт новый по DHCP, когда роутер перезагружается и линк падает.
		if (-not $renewed -and ((Get-Date) - $start).TotalSeconds -gt 100) {
			$renewed = $true
			ipconfig /renew *> $null
		}
		Write-Host -NoNewline '.'
		Start-Sleep -Seconds 5
	}
	Write-Host ''
	$null
}

function Wait-Down([string]$Address, [int]$TimeoutSec = 120) {
	$deadline = (Get-Date).AddSeconds($TimeoutSec)
	while ((Get-Date) -lt $deadline) {
		if (-not (Test-Port $Address 22 1000)) { return $true }
		Start-Sleep -Seconds 2
	}
	$false
}

function Confirm-Step([string]$Question) {
	if ($Yes) { return }
	$a = Read-Host "$Question [y/N]"
	if ($a -notmatch '^(y|yes|д|да)$') {
		Write-Host 'Отменено.'
		exit 0
	}
}

# --- шаги ------------------------------------------------------------------

function Find-Router {
	Step 'Поиск роутера'
	$list = $Passwords
	if ($Password) { $list = @($Password) + $Passwords }
	foreach ($a in $Ip) {
		if (-not (Test-Port $a)) {
			Note "$a — SSH не отвечает"
			continue
		}
		$r = Connect-Router $a $list
		if (-not $r) {
			Warn "$a — SSH есть, но ни один пароль не подошёл (укажите -Password)"
			continue
		}
		if (-not (Test-Model $r.Probe)) {
			Warn "$a — это не NX62 / N60 Pro: '$(Get-One $r.Probe 'model')' ($(Get-One $r.Probe 'board'))"
			continue
		}
		Show-Router $a $r.Probe
		if ($r.Password -eq '') { Note 'пароль: пустой' } else { Note 'пароль: подобран' }
		return $r
	}
	Fail "Netis NX62 / Netcore N60 Pro не найден на $($Ip -join ', '). Подключите ПК кабелем в LAN, проверьте адрес и пароль (-Ip, -Password)."
}

function Save-Backup($r) {
	Step 'Бэкап (flash.sh -b)'
	Set-RouterPassword $r.Password
	$res = Invoke-RouterLive $r.Ip "wget -qO- $FlashUrl | sh -s -- -b"
	if (-not ($res.Lines -match 'Бэкап готов')) {
		Fail 'flash.sh не снял бэкап (ошибка выше). На роутере ничего не записано.'
	}

	$dir = Join-Path $BackupRoot (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')
	New-Item -ItemType Directory -Force $dir | Out-Null
	& $Scp -O @SshOpts "root@$($r.Ip):$RouterBackup/*" "$dir\" | Out-Host
	if ($LASTEXITCODE -ne 0) { Fail "не удалось скопировать бэкап с роутера в $dir" }

	# Сверка с SHA256SUMS, который посчитал сам роутер
	$sums = Join-Path $dir 'SHA256SUMS'
	if (-not (Test-Path $sums)) { Fail "в бэкапе нет SHA256SUMS: $dir" }
	foreach ($line in Get-Content $sums) {
		if ($line -notmatch '^([0-9a-f]{64})\s+\*?(.+)$') { continue }
		$file = Join-Path $dir $Matches[2]
		if (-not (Test-Path $file) -or (Get-FileHash $file -Algorithm SHA256).Hash.ToLower() -ne $Matches[1]) {
			Fail "бэкап повреждён при копировании: $($Matches[2])"
		}
	}
	Ok "bl2, u-boot-env, factory, fip → $dir (SHA-256 сходится)"

	$info = Invoke-Router $r.Ip 'cat /proc/mtd; echo; cat /etc/openwrt_release; echo; uci -q show network; echo; dmesg' -TimeoutSec 30
	if ($info.Code -eq 0) {
		[IO.File]::WriteAllText((Join-Path $dir 'router-info.txt'), $info.Out, [Text.UTF8Encoding]::new($false))
	}

	if ($FullBackup) { Save-FullBackup $r $dir }
	$dir
}

# Каждый раздел целиком потоком по SSH: на роутере место не нужно
function Save-FullBackup($r, $dir) {
	Note 'полный бэкап всех разделов, включая ubi (несколько минут)'
	$list = Invoke-Router $r.Ip 'sed -n "s/^mtd\([0-9]*\): \([0-9a-f]*\) [0-9a-f]* \"\(.*\)\"$/\1 \2 \3/p" /proc/mtd'
	foreach ($line in ($list.Out -split "`n")) {
		if ($line.Trim() -notmatch '^(\d+) ([0-9a-f]+) (\S+)$') { continue }
		$n = $Matches[1]; $size = [Convert]::ToInt64($Matches[2], 16); $name = $Matches[3]
		$file = Join-Path $dir "full-mtd$n-$name.bin"
		$psi = New-Object Diagnostics.ProcessStartInfo
		$psi.FileName = $Ssh
		$psi.Arguments = Join-Args ($SshOpts + @("root@$($r.Ip)", "cat /dev/mtd$n"))
		$psi.UseShellExecute = $false
		$psi.RedirectStandardOutput = $true
		$psi.RedirectStandardInput = $true
		$p = [Diagnostics.Process]::Start($psi)
		$p.StandardInput.Close()
		$fs = [IO.File]::Create($file)
		try { $p.StandardOutput.BaseStream.CopyTo($fs) } finally { $fs.Close() }
		$p.WaitForExit()
		$got = (Get-Item $file).Length
		if ($got -ne $size) { Warn "$name`: получено $got байт из $size" } else { Ok "$name ($([int]($size / 1MB)) МБ)" }
	}
}

function Install-Loader($r) {
	Step 'Загрузчик OpenWrt 25.12.5 + initramfs (flash.sh -y)'
	Warn 'не выключайте питание роутера'
	Set-RouterPassword $r.Password
	$arg = '-y'
	if ($Recovery) { $arg = '-y -r' }
	$res = Invoke-RouterLive $r.Ip "wget -qO- $FlashUrl | sh -s -- $arg"
	if (-not ($res.Lines -match 'Загрузчик OpenWrt 25.12.5 на месте')) {
		Fail 'flash.sh остановился с ошибкой (выше). НЕ выключайте роутер, если он писал bl2/fip, — запустите скрипт ещё раз.'
	}
	Ok 'загрузчик записан, роутер перезагружается в initramfs'
}

# Образ: -Firmware, файл рядом со скриптом или в firmware\, иначе скачивание
function Find-LocalFirmware {
	if ($Firmware) {
		if (-not (Test-Path $Firmware)) { Fail "нет файла $Firmware" }
		return (Resolve-Path $Firmware).Path
	}
	foreach ($p in @((Join-Path $PSScriptRoot $FwName), (Join-Path $PSScriptRoot "firmware\$FwName"))) {
		if (Test-Path $p) { return $p }
	}
	$null
}

function Get-ExpectedSha {
	try {
		[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
		$t = (Invoke-WebRequest -UseBasicParsing -Uri $SumsUrl -TimeoutSec 30).Content
		if ($t -is [byte[]]) { $t = [Text.Encoding]::ASCII.GetString($t) }
		foreach ($line in ($t -split "`n")) {
			if ($line -match "^([0-9a-f]{64})\s+\*?$([regex]::Escape($FwName))\s*$") { return $Matches[1] }
		}
	} catch { }
	$null
}

function Get-RouterSha($r) {
	$res = Invoke-Router $r.Ip "sha256sum $RouterFw 2>/dev/null | cut -d ' ' -f 1"
	$res.Out.Trim()
}

function Send-Firmware($r) {
	Step 'Образ прошивки'
	Set-RouterPassword $r.Password
	$local = Find-LocalFirmware
	$expected = Get-ExpectedSha

	if (-not $local) {
		# Сначала роутер качает сам, как wget -O /tmp/sysupgrade.itb …
		Note "скачиваю на роутере: $FwUrl"
		$res = Invoke-Router $r.Ip "rm -f $RouterFw; wget -q -T 60 -O $RouterFw $FwUrl || wget -q -T 60 --no-check-certificate -O $RouterFw $FwUrl" -TimeoutSec 600
		$sha = Get-RouterSha $r
		if ($res.Code -eq 0 -and $sha -and (-not $expected -or $sha -eq $expected)) {
			Ok "образ скачан роутером$(if ($expected) { ', SHA-256 сходится' })"
			return
		}
		Warn 'роутер не скачал образ (нет интернета на WAN?), качаю на ПК'
		$local = Join-Path $PSScriptRoot $FwName
		try {
			[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
			Invoke-WebRequest -UseBasicParsing -Uri $FwUrl -OutFile $local -TimeoutSec 600
		} catch {
			Fail "не удалось скачать $FwUrl. Положите файл $FwName рядом со скриптом."
		}
	}

	$localSha = (Get-FileHash $local -Algorithm SHA256).Hash.ToLower()
	if ($expected -and (Split-Path $local -Leaf) -eq $FwName -and $localSha -ne $expected) {
		Fail "SHA-256 файла $local не совпадает с репозиторием"
	}
	Note "копирую $local"
	& $Scp -O @SshOpts $local "root@$($r.Ip):$RouterFw" | Out-Host
	if ($LASTEXITCODE -ne 0) { Fail 'scp не скопировал образ на роутер' }
	if ((Get-RouterSha $r) -ne $localSha) { Fail 'образ на роутере не совпадает с файлом на ПК' }
	Ok 'образ на роутере, SHA-256 сходится'
}

function Install-Firmware($r) {
	$t = Invoke-Router $r.Ip "sysupgrade -T $RouterFw 2>&1"
	if ($t.Code -ne 0) {
		Write-Host $t.Out
		Fail 'sysupgrade -T отверг образ, прошивка не начата'
	}
	Ok 'sysupgrade -T: образ подходит'
	Step 'sysupgrade -n'
	Invoke-RouterLive $r.Ip "sysupgrade -n $RouterFw" | Out-Null
	if (-not (Wait-Down $r.Ip 90)) {
		Fail 'роутер не ушёл в перезагрузку после sysupgrade (вывод выше)'
	}
	Ok 'образ записывается, роутер перезагрузится сам'
}

function Test-Result($r, $dir) {
	Step 'Проверка'
	$p = $r.Probe
	$state = @{ Bad = 0 }
	$check = {
		param($cond, $good, $badText)
		if ($cond) { Ok $good } else { Warn $badText; $state.Bad++ }
	}

	Show-Router $r.Ip $p
	& $check (-not (Test-Initramfs $p)) "корень: $(Get-One $p 'root') (не initramfs)" 'роутер загрузился в initramfs, а не в прошивку'
	& $check ((Get-One $p 'rom') -match 'squashfs') "/rom: $(Get-One $p 'rom')" "/rom не squashfs: '$(Get-One $p 'rom')'"
	& $check ((Get-One $p 'overlay') -match 'ubifs') "/overlay: $(Get-One $p 'overlay')" "overlay не на UBI: '$(Get-One $p 'overlay')' — настройки не сохранятся"
	& $check (Test-Loader $p) 'bl2 и fip: официальный загрузчик 25.12.5' 'bl2/fip не совпадают с официальным загрузчиком 25.12.5'

	Write-Host ''
	Note 'разделы NAND (КБ, bad-блоки):'
	foreach ($m in $p['mtd']) {
		$f = $m -split ' '
		Note ("  {0,-12} {1,8}  bad {2}" -f $f[0], $f[1], $f[2])
		if ($f[2] -and $f[2] -ne '0') { Warn "в разделе $($f[0]) $($f[2]) bad-блок(ов)" }
	}
	foreach ($u in $p['ubi']) {
		$f = $u -split ' '
		Note "UBI на mtd$($f[0]): $($f[1]) блоков, свободно $($f[2]), bad $($f[3])"
	}
	$vols = @($p['vol'] | ForEach-Object { ($_ -split ' ')[0] })
	foreach ($v in $p['vol']) {
		$f = $v -split ' '
		Note ("  том {0,-12} {1,8} КБ" -f $f[0], $f[1])
	}
	foreach ($need in @('ubootenv', 'ubootenv2', 'fit', 'rootfs_data')) {
		& $check ($vols -contains $need) "том UBI $need на месте" "нет тома UBI $need"
	}
	foreach ($d in $p['dmesg']) { Warn "dmesg: $d" }

	$df = (Get-One $p 'df') -split ' '
	$mem = (Get-One $p 'mem') -split ' '
	Write-Host ''
	if ($df.Count -eq 3) {
		Write-Host ("  Свободно в overlay: {0:N1} МБ из {1:N1} МБ (занято {2:N1} МБ)" -f ($df[2] / 1024), ($df[0] / 1024), ($df[1] / 1024)) -ForegroundColor Green
	}
	if ($mem.Count -eq 2) { Note "ОЗУ: $($mem[0]) МБ, доступно $($mem[1]) МБ" }

	if ($dir) {
		$res = Invoke-Router $r.Ip $ProbeScript
		[IO.File]::WriteAllText((Join-Path $dir 'after-flash.txt'), $res.Out, [Text.UTF8Encoding]::new($false))
	}

	Write-Host ''
	if ($state.Bad -eq 0) {
		Write-Host "ГОТОВО: OpenWrt прошита и проверена. http://$($r.Ip)  (ssh root@$($r.Ip))" -ForegroundColor Green
	} else {
		Write-Host "Прошивка загрузилась, но проверок с замечаниями: $($state.Bad) (выше)." -ForegroundColor Yellow
	}
}

# --- main ----------------------------------------------------------------------

$oldEnc = [Console]::OutputEncoding
$oldInEnc = [Console]::InputEncoding
try {
	[Console]::OutputEncoding = [Text.Encoding]::UTF8
	# По нему .NET пишет stdin для ssh: UTF-8 с BOM ломает первую строку скрипта
	[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
	$OutputEncoding = [Text.UTF8Encoding]::new($false)

	if (-not (Test-Path $Ssh)) {
		Fail 'нет клиента OpenSSH: Параметры → Приложения → Дополнительные компоненты → Клиент OpenSSH'
	}
	Set-Content -Path $AskPass -Encoding Ascii -Value "@echo off`r`nsetlocal EnableDelayedExpansion`r`necho(!NX62_SSH_PASS!"
	$env:SSH_ASKPASS = $AskPass
	$env:SSH_ASKPASS_REQUIRE = 'force'
	if (-not $env:DISPLAY) { $env:DISPLAY = 'localhost:0' }

	Write-Host 'Netis NX62 / Netcore N60 Pro (128 МБ): OpenWrt 25.12.5' -ForegroundColor Cyan
	Write-Host $Repo

	$r = Find-Router
	$backupDir = Save-Backup $r

	# Уже в initramfs 25.12.5 с нашим загрузчиком (например, повторный запуск
	# после обрыва): загрузчик и ubi не трогаем, сразу заливаем прошивку.
	$inInitramfs = (Test-Initramfs $r.Probe) -and (Test-Loader $r.Probe)
	$fwText = $FwName
	if ($Firmware) { $fwText = $Firmware }

	Step 'План'
	if ($inInitramfs) {
		Note 'роутер уже в initramfs 25.12.5 с официальным загрузчиком'
	} else {
		Note '1. flash.sh -y: загрузчик OpenWrt 25.12.5, ubi с initramfs, перезагрузка'
	}
	Note "2. в initramfs (192.168.1.1): sysupgrade -n $fwText"
	Note '3. проверка прошивки, разделов и свободного места'
	Warn 'текущая прошивка и все её настройки будут удалены'
	Note "бэкап: $backupDir"
	Confirm-Step 'Прошить?'

	$pwList = @('', $r.Password) | Select-Object -Unique
	if (-not $inInitramfs) {
		Install-Loader $r
		Wait-Down $r.Ip 120 | Out-Null
		Step 'Ожидание initramfs'
		$r = Wait-Router @('192.168.1.1') $pwList { param($p) (Test-Initramfs $p) -and (Test-Loader $p) } 360 'initramfs на 192.168.1.1'
		if (-not $r) {
			Fail 'initramfs не появился на 192.168.1.1 за 6 минут. Проверьте, что ПК получил адрес 192.168.1.x (кабель в LAN), и запустите скрипт ещё раз — он продолжит с этого места.'
		}
		Show-Router $r.Ip $r.Probe
	}

	Send-Firmware $r
	Install-Firmware $r

	Step 'Ожидание прошивки'
	$r = Wait-Router @('192.168.0.1', '192.168.1.1') $pwList { param($p) -not (Test-Initramfs $p) } 480 'прошивку на 192.168.0.1 / 192.168.1.1'
	if (-not $r) {
		Fail 'прошивка не ответила по SSH за 8 минут. Первая загрузка с форматированием может идти дольше — проверьте http://192.168.0.1 и http://192.168.1.1 вручную.'
	}
	Test-Result $r $backupDir
} catch {
	Write-Host ''
	Write-Host "ОШИБКА: $($_.Exception.Message)" -ForegroundColor Red
	exit 1
} finally {
	Remove-Item $AskPass -ErrorAction SilentlyContinue
	Remove-Item Env:NX62_SSH_PASS -ErrorAction SilentlyContinue
	[Console]::OutputEncoding = $oldEnc
	[Console]::InputEncoding = $oldInEnc
}
