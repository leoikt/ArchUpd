#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════ #
# | ArchUpd: A script for safely updating Arch Linux                           | #
# | This script: v.2.4-2026-srvc_ru (Lite)                                     | #
# | Author: LeoIKT                                                             | #
# | License: MIT                                                               | #
# ══════════════════════════════════════════════════════════════════════════════ #
set -euo pipefail
readonly VER=v.2.4-2026-srvc_ru
readonly LOCK_FILE="/tmp/archupdauto.lock"
readonly MAX_LOCK_AGE=3600 # val in seconds

log() {
	local level="$1"
	local message="$2"
	local timestamp=$(date +"%Y-%m-%d %H:%M:%S")

	echo "[${timestamp}] ${level}: ${message}"
}

log_info() { log "INFO" "$1"; }
log_warn() { log "WARN" "$1"; }
log_error() { log "ERROR" "$1"; }

if [[ ${MAX_DOWNLOAD_SIZE:-0} -gt 0 ]]; then
	# Получаем общий размер в байтах и переводим в МБ
	local total_size=$(pacman -Syu --print-format "%s" | awk '{s+=$1} END {print s/1024/1024}')
	# Округляем до целого для сравнения
	local size_int=${total_size%.*}

	if [[ $size_int -ge $MAX_DOWNLOAD_SIZE ]]; then
		log_warn "Размер обновлений ($size_int МБ) превышает лимит ($MAX_DOWNLOAD_SIZE МБ). Пропуск авто-обновления."
		return 0
	fi
	log_info "Общий размер обновлений: ${size_int} МБ (лимит OK)"
fi

check_disk_space() {
	# Пороги из нашего конфига /etc/archupd.conf (или дефолты)
	local min_root=${MIN_FREE_ROOT:-2048} # 2GB
	local min_boot=${MIN_FREE_BOOT:-25}   # 25MB

	# Проверка корня
	local free_root=$(df -m / | awk 'NR==2 {print $4}')
	if [[ $free_root -lt $min_root ]]; then
		log_error "Критически мало места на /: ${free_root}MB (нужно ${min_root}MB)"
		return 1
	fi

	# Проверка /boot (если смонтирован)
	if findmnt /boot &>/dev/null; then
		local free_boot=$(df -m /boot | tail -n1 | awk '{print $4}')
		if [[ $free_boot -lt $min_boot ]]; then
			log_error "Критически мало места на /boot: ${free_boot}MB (нужно ${min_boot}MB)"
			return 1
		fi
	fi
	return 0
}

check_environment() {
	if [[ -n "${INVOCATION_ID:-}" ]]; then
		log_info "Запущено через systemd (invocation: ${INVOCATION_ID})"
	else
		log_warn "Ручной запуск автоскрипта (не через systemd)"
	fi

	if [[ $EUID -ne 0 ]]; then
		if [[ -t 1 ]]; then
			# Есть терминал - предлагаем sudo
			log_error "Требуются права root"
			echo "Запустите с sudo или настройте systemd service с User=root" >&2
		else
			# Нет терминала - это systemd с ошибкой конфигурации
			log_error "FATAL: Запуск не от root. Проверьте systemd service файл."
			echo "FATAL: Добавьте 'User=root' в /etc/systemd/system/archupdauto.service" >&2
		fi
		exit 1
	fi
	log_info "Проверка прав: OK (uid=$(id -u))"
	if ! check_disk_space; then
		log_error "Обновление отменено из-за нехватки места. Очистите диск!"
		# Если есть notify-send (из нашего инсталлера), можно кинуть пуш
		exit 1
	fi
}

update_system() {
	log_info "Обновление системы..."

	if findmnt /boot &>/dev/null; then
		# Получаем свободное место в КБ (столбец AVAIL)
		local boot_free=$(df --output=avail /boot | tail -n1)
		# Порог: 25 МБ (25600 КБ). Этого хватит на временные файлы mkinitcpio
		if [[ $boot_free -lt 25600 ]]; then
			log_error "Критически мало места на /boot: $((boot_free / 1024))MB. Обновление отменено!"
			return 1
		fi
		log_info "Место на /boot: $((boot_free / 1024))MB OK"
	fi

	log_info "Синхронизация баз данных..."
	pacman -Sy 2>/dev/null || {
		log_error "Нет доступа к репозиториям"
		return 1
	}

	local updates=$(pacman -Qu 2>/dev/null | wc -l)
	if [[ $updates -eq 0 ]]; then
		log_info "Обновлений не найдено"
		return 0
	fi
	log_info "Найдено обновлений: $updates. Устанавливаю..."
	if pacman -Syu --noconfirm --needed; then
		log_info "Обновление успешно завершено"
	else
		log_warn "Первый проход обновления не удался, пробуем обновить ключи..."
		pacman-key --init
		pacman-key --populate archlinux
		pacman -S archlinux-keyring --noconfirm 2>/dev/null || true

		if pacman -Syu --noconfirm; then
			log_info "Обновление завершено после обновления ключей"
		else
			log_error "Ошибка при обновлении даже после обновления ключей"
			return 1
		fi
	fi

	if findmnt /boot &>/dev/null && [[ -f /boot/vmlinuz-linux ]]; then
		size=$(stat -c%s /boot/vmlinuz-linux 2>/dev/null || echo 0)
		if [[ $size -gt 1000000 ]]; then
			log_info "Ядро OK (${size} байт)"
		else
			log_warn "Ядро повреждено. Слишком малый размер. Запустите archupd --verify для восстановления."
		fi
	fi

	if command -v paccache &>/dev/null; then
		paccache -rk2 2>/dev/null && log_info "Кэш очищен"
	fi
}

main() {
	log_info "=== Начало автообновления ==="

	if [[ -f "${LOCK_FILE}" ]]; then
		local lock_age=$(($(date +%s) - $(stat -c %Y "${LOCK_FILE}" 2>/dev/null || echo 0)))
		if [[ $lock_age -lt $MAX_LOCK_AGE ]]; then
			log_info "Обновление уже выполняется (lock файл: ${lock_age}с)"
			exit 0
		fi
		log_warn "Удаляем устаревший lock файл (${lock_age}с)"
		rm -f "${LOCK_FILE}"
	fi
	touch "${LOCK_FILE}"
	local boot_was_ro=0

	cleanup() {
		sync
		rm -f "${LOCK_FILE}" 2>/dev/null || true
		[[ "${boot_was_ro:-0}" -eq 1 ]] && mount -o remount,ro /boot 2>/dev/null || true
	}
	trap 'cleanup' EXIT INT TERM HUP

	check_environment

	if findmnt /boot &>/dev/null; then
		if findmnt -no OPTIONS /boot | grep -q ",ro"; then
			log_info "/boot в RO, переводим в RW"
			mount -o remount,rw /boot
			boot_was_ro=1
		fi
	else
		log_warn "/boot не смонтирован, проверка ядра невозможна"
	fi

	update_system

	log_info "=== Автообновление завершено ==="
}

case "${1:-}" in
"" | "--auto")
	main
	;;

"--help" | "-h")
	echo -e "\033[1mArchUpd ${VER}\033[0m"
	echo "Это служебный скрипт утилиты archupd, предназначенный для"
	echo "автоматического запуска обновления по таймеру из systemd."
	echo "В отличии от полной версии данный скрипт не обновляет пакеты AUR,"
	echo "логирует процесс в systemd journal, не перезагружает систему по"
	echo "завершению обновлния, не даёт интерактив."
	echo ""
	echo "Использование: archupdauto [опции]"
	echo "  (без аргументов)  - Автообновление без AUR (no reboot)"
	echo "  --auto            - Равнозначно"
	echo ""
	echo "Для полного обновления с AUR и бэкапами используйте: archupd"
	exit 0
	;;

*)
	echo -e "\033[1m[FAIL]\033[0m Неизвестный аргумент: $1" >&2
	echo "Используйте: archupdauto --help"
	exit 1
	;;
esac
