#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════ #
# | ArchUpd: A script for safely updating Arch Linux                           | #
# | Version: v.3.0-2026_ru final                                                    | #
# | Author: LeoIKT                                                             | #
# | License: MIT                                                               | #
# ══════════════════════════════════════════════════════════════════════════════ #
#                                    Note                                        #
# ══════════════════════════════════════════════════════════════════════════════ #
# ! Этот "портативный" скрипт archupd.sh вы можете загрузить или скопировать   ! #
# ! файлом и запускать его из любой директории через ./archupd.sh              ! #
# ! Если вы скопировали код из RAW или загрузили zip-архивом из GitHub,        ! #
# ! выдайте разрешение скрипту: sudo chmod 755 filename.sh                     ! #
# ══════════════════════════════════════════════════════════════════════════════ #
# ! Для удобства используйте ./install.sh                                      ! #
# ! Установщик запишет скрипт в /usr/local/bin и                               ! #
# ! Сделает его доступным для запуска через команду archupd                    ! #
# ══════════════════════════════════════════════════════════════════════════════ #
# go
readonly VER=v.3.0-2026_ru
declare -A C
C=([blue]='\033[0;34m' [green]='\033[0;32m' [red]='\033[0;31m' [yellow]='\033[1;33m' [nc]='\033[0m' [bold]='\033[1m')
echo -e " \033[2m-------------${C[nc]} \033[1;34mArchUpd ${VER}${C[nc]} \033[2m-------------${C[nc]}"

set -euo pipefail

# ============================================
# 1. ПУТИ, ПРАВА И КОНФИГУРАЦИЯ
# ============================================
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
[[ -z "$REAL_HOME" ]] && REAL_HOME="/home/$REAL_USER"

# Дефолты (переопределяются в /etc/archupd.conf)
KERNEL_NAME="linux"
KEEP_CACHE=2
CHECK_NETWORK=true
BACKUP_DIRS=("hypr" "waybar" "kitty")
MIN_FREE_ROOT=2048
MIN_FREE_BOOT=25

[[ -f "/etc/archupd.conf" ]] && source "/etc/archupd.conf"

readonly VMLINUZ="/boot/vmlinuz-${KERNEL_NAME}"
readonly INITRAMFS="/boot/initramfs-${KERNEL_NAME}.img"
readonly BACKUP_ROOT="${REAL_HOME}/Documents/Arch_Backups"
readonly TIMESTAMP=$(date +%Y%m%d_%H%M%S)
readonly CUR_BACKUP_DIR="${BACKUP_ROOT}/backup_${TIMESTAMP}"
readonly LOG_FILE="${REAL_HOME}/.local/log/archupd.log"

# Флаги
CONFIRM_FLAG=""
SKIP_BACKUP=false
DRY_RUN_ONLY=false
for arg in "$@"; do
	case $arg in
	--noconfirm) CONFIRM_FLAG="--noconfirm" ;;
	--no-backup) SKIP_BACKUP=true ;;
	--dry-run) DRY_RUN_ONLY=true ;;
	esac
done

# ============================================
# 2. СЕРВИСНЫЕ ФУНКЦИИ
# ============================================

log() {
	local msg="$1"
	echo -e "${C[blue]}[$(date +%H:%M:%S)]${C[nc]} $msg"
	mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
	echo "[$(date +"%Y-%m-%d %H:%M:%S")] $msg" >>"$LOG_FILE" 2>/dev/null || true
}

log_success() { echo -e "${C[green]}✓${C[nc]} $1"; }
log_warning() { echo -e "${C[yellow]}⚠${C[nc]} $1"; }
log_error() { echo -e "${C[red]}✗${C[nc]} $1"; }

run_as_root() { [[ $EUID -eq 0 ]] && "$@" || sudo "$@"; }
run_as_user() { [[ $EUID -ne 0 ]] && "$@" || { [[ -n "${SUDO_USER:-}" ]] && sudo -u "$SUDO_USER" "$@" || "$@"; }; }

check_disk_space() {
	local free_root=$(df -m / | awk 'NR==2 {print $4}')
	[[ $free_root -lt $MIN_FREE_ROOT ]] && {
		log_error "Мало места на /: ${free_root}MB"
		return 1
	}
	if findmnt /boot &>/dev/null; then
		local free_boot=$(df -m /boot | tail -n1 | awk '{print $4}')
		[[ $free_boot -lt $MIN_FREE_BOOT ]] && {
			log_error "Мало места на /boot: ${free_boot}MB"
			return 1
		}
	fi
	return 0
}

check_power() {
	if ! grep -q "1" /sys/class/power_supply/*/online 2>/dev/null; then
		log_warning "Питание от батареи!"
		if [[ -z "$CONFIRM_FLAG" ]]; then
			echo -ne "Продолжить на свой страх и риск? [y/N]: "
			read -r cp
			if [[ ! $cp =~ ^[Yy]$ ]]; then
				log_error "Прервано пользователем"
				exit 1
			fi
		fi
	fi
}

cleanup() {
	sync
	if findmnt -no OPTIONS /boot 2>/dev/null | grep -q "rw"; then
		log_warning "Возврат /boot в RO..."
		run_as_root mount -o remount,ro /boot 2>/dev/null || true
	fi
}

# ============================================
# 3. МОДУЛИ РАНТАЙМА
# ============================================

show_update_status() {
	log "Проверка наличия обновлений..."
	local p_upd=$(pacman -Qu 2>/dev/null | wc -l || echo 0)
	echo -e "  📦 Pacman: ${C[blue]}$p_upd${C[nc]} пакетов"
	if command -v yay &>/dev/null; then
		local a_upd=$(timeout 10s run_as_user yay -Qua 2>/dev/null | wc -l || echo 0)
		echo -e "  🧬 AUR:    ${C[blue]}$a_upd${C[nc]} пакетов"
	fi
}

run_dry_run() {
	log "--- [ РЕПЕТИЦИЯ ОБНОВЛЕНИЯ ] ---"
	run_as_root pacman -Sy >/dev/null
	log "Системные обновления:"
	pacman -Qu || echo "Нет обновлений"
	local size=$(run_as_root pacman -Syu --print-format "%s" | awk '{s+=$1} END {print s/1024/1024 " MB"}')
	echo -e "${C[bold]}Объем загрузки:${C[nc]} ${C[blue]}$size${C[nc]}"
	if command -v yay &>/dev/null; then
		log "AUR обновления:"
		run_as_user yay -Qu --color always || echo "AUR актуален"
	fi
}

do_backup() {
	log "--- [1/5] Резервное копирование ---"
	run_as_root mkdir -p "${CUR_BACKUP_DIR}"
	if ! $SKIP_BACKUP; then
		for dir in "${BACKUP_DIRS[@]}"; do
			local src="${REAL_HOME}/.config/${dir}"
			[[ -d "$src" ]] && run_as_root rsync -a "$src/" "${CUR_BACKUP_DIR}/$dir/" 2>/dev/null && log "  → $dir скопирован"
		done
	fi
	run_as_root bash -c "pacman -Qqe > '${CUR_BACKUP_DIR}/pkglist.txt'"
	run_as_root chown -R "${REAL_USER}:${REAL_USER}" "$(dirname "${CUR_BACKUP_DIR}")"
}

verify_kernel() {
	log "--- [4/5] Верификация ядра ---"
	local status=0
	run_as_root test -s "${VMLINUZ}" || status=1
	if [[ $status -eq 0 ]] && command -v file &>/dev/null; then
		local k_info=$(run_as_root file -b "${VMLINUZ}")
		[[ ! "$k_info" =~ "kernel" && ! "$k_info" =~ "executable" ]] && status=2
	fi
	if [[ $status -gt 0 ]]; then
		log_error "Сбой ядра! Ремонт..."
		run_as_root pacman -S $CONFIRM_FLAG "${KERNEL_NAME}" --needed
	else
		log_success "Ядро в порядке"
	fi
}

run_full_cycle() {
	local start_time=$SECONDS
	check_disk_space || exit 1
	check_power
	do_backup

	log "--- [2/5] Подготовка ФС ---"
	if ! findmnt /boot &>/dev/null; then run_as_root mount /boot; fi
	run_as_root mount -o remount,rw /boot && log_success "/boot -> RW"

	log "--- [3/5] Обновление пакетов ---"
	run_as_root pacman -Syu $CONFIRM_FLAG
	local helper=$(command -v yay || command -v paru || echo "")
	[[ -n "$helper" ]] && {
		log "--- AUR Обновление ---"
		run_as_user $helper -Sua $CONFIRM_FLAG
	}

	verify_kernel
	run_as_root paccache -rk "$KEEP_CACHE" -q 2>/dev/null || true

	local duration=$((SECONDS - start_time))
	echo -e "\n${C[green]}${C[bold]}══════════════════ ОБНОВЛЕНИЕ ЗАВЕРШЕНО ЗА ${duration}с ══════════════════${C[nc]}"

	if [[ -z "$CONFIRM_FLAG" && -t 0 ]]; then
		echo -ne "\n${C[bold]}Перезагрузить систему сейчас? [y/N]: ${C[nc]}"
		read -n 1 -r
		echo
		if [[ $REPLY =~ ^[Yy]$ ]]; then
			log "Выполняется перезагрузка..."
			run_as_root reboot
		fi
	fi
}

# ============================================
# 4. ТОЧКА ВХОДА
# ============================================
case "${1:-}" in
"--auto")
	log "Вызов фоновой службы обновления (Lite)..."
	if command -v archupdauto &>/dev/null; then
		run_as_root archupdauto
	elif [[ -f "/usr/local/bin/archupdauto" ]]; then
		run_as_root /usr/local/bin/archupdauto
	else
		log_error "Скрипт archupdauto не найден в системе."
		exit 1
	fi
	exit 0
	;;
"--help" | "-h")
	echo -e "Безопасное обновление системы"
	echo -e "\n${C[bold]}ИСПОЛЬЗОВАНИЕ:${C[nc]}"
	echo -e "  archupd ${C[blue]}[опции]${C[nc]}"
	echo -e "\n${C[bold]}ОСНОВНЫЕ КОМАНДЫ:${C[nc]}"
	echo -e "  ${C[green]}(без флагов)${C[nc]}      Полный цикл: Снимок ➜ Бэкап ➜ boot RW ➜ Pacman ➜ AUR ➜ Ядро"
	echo -e "  ${C[blue]}-c, --check${C[nc]}        Быстрая проверка обновлений и питания (без sudo)"
	echo -e "  ${C[blue]}--verify${C[nc]}           Принудительная проверка и ремонт ядра"
	echo -e "  ${C[blue]}--dry-run${C[nc]}          Репетиция: расчет объема и список изменений"
	echo -e "  ${C[blue]}--auto${C[nc]}             Запуск фоновой Lite-версии (archupdauto) вручную"
	echo -e "  ${C[blue]}-l, --logs${C[nc]}         Просмотр журналов фоновой службы автообновления"
	echo -e "\n${C[bold]}МОДИФИКАТОРЫ:${C[nc]}"
	echo -e "  ${C[yellow]}--noconfirm${C[nc]}      Автоматический режим (пропуск всех вопросов)"
	echo -e "  ${C[yellow]}--no-backup${C[nc]}      Обновление без rsync (сохранится только pkglist)"
	echo -e "\n${C[bold]}ПРИМЕРЫ:${C[nc]}"
	echo -e "  archupd --no-backup              ${C[blue]}# Быстрое обновление без бэкапа конфигов${C[nc]}"
	echo -e "  archupd -c --noconfirm           ${C[blue]}# Только чек без интерактивных предложений${C[nc]}"
	echo -e "\n${C[blue]}Конфигурация:${C[nc]} /etc/archupd.conf"
	exit 0
	;;
"--check" | "-c")
	show_update_status
	if [[ -z "$CONFIRM_FLAG" ]] && ! $DRY_RUN_ONLY; then
		echo -ne "\n${C[bold]}Детальный расчет (--dry-run)? [y/N]: ${C[nc]}"
		read -n 1 -r && echo
		[[ $REPLY =~ ^[Yy]$ ]] && run_dry_run
	elif $DRY_RUN_ONLY; then
		run_dry_run
	fi
	exit 0
	;;
"--logs" | "-l")
	groups | grep -q "systemd-journal" && journalctl -u archupdauto.service -n 50 -o cat || sudo journalctl -u archupdauto.service -n 50 -o cat
	exit 0
	;;
"--verify")
	trap cleanup EXIT INT TERM
	if ! findmnt /boot &>/dev/null; then run_as_root mount /boot; fi
	run_as_root mount -o remount,rw /boot &>/dev/null || true
	verify_kernel
	exit 0
	;;
*)
	trap cleanup EXIT INT TERM
	if $DRY_RUN_ONLY; then
		run_dry_run
	else
		run_full_cycle
	fi
	exit 0
	;;
esac
