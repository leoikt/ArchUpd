#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════ #
# | ArchUpd (Arch Update): A script for safely updating Arch Linux             | #
# | Installer: ArchUpd Hardening Installer v.2.5-lite_ru                       | #
# | Version (archupd): v.3.0-2026_ru                                           | #
# | Author: LeoIKT                                                             | #
# | License: MIT                                                               | #
# ══════════════════════════════════════════════════════════════════════════════ #
set -euo pipefail
REAL_USER="${SUDO_USER:-$USER}"
SUDO_FILE="/etc/sudoers.d/archupd"

# --- Оформление ---
C_BLUE='\033[0;34m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_NC='\033[0m'
C_BOLD='\033[1m'

log() { echo -e "${C_BLUE}[INSTALL]${C_NC} $1"; }
log_ok() { echo -e "${C_GREEN}  ✓${C_NC} $1"; }
error_exit() {
	echo -e "${C_RED}[ERROR]${C_NC} $1"
	exit 1
}

# --- Функция удаления ---
uninstall() {
	echo -e "${C_YELLOW}${C_BOLD}Выполнение деинсталляции ArchUpd...${C_NC}"

	# 1. Остановка системных служб
	log "Остановка и отключение таймеров..."
	systemctl disable --now archupd.timer 2>/dev/null || true
	systemctl stop archupd.service 2>/dev/null || true

	# 2. Удаление файлов
	log "Удаление компонентов..."
	for entry in "${MAP[@]}"; do
		IFS=":" read -r src dest <<<"$entry"
		if [[ -f "$dest" ]]; then
			rm -f "$dest"
			log_ok "Удалено: $dest"
		fi
	done

	# 3. Очистка sudoers и системных путей
	rm -f "$SUDO_FILE" && log_ok "Привилегии sudo аннулированы"
	systemctl daemon-reload

	echo -e "\n${C_GREEN}${C_BOLD}ДЕИНСТАЛЛЯЦИЯ ЗАВЕРШЕНА${C_NC}"
	log "Примечание: Группу 'systemd-journal' и установленные пакеты (timeshift и др.) нужно удалять вручную, если они больше не нужны."
	exit 0
}

# --- Проверка флага удаления ---
[[ "${1:-}" == "--uninstall" ]] && uninstall
# --- ЛОГИКА УСТАНОВКИ ---
[[ $EUID -ne 0 ]] && error_exit "Запустите через sudo!"
[[ "$REAL_USER" == "root" ]] && error_exit "Запустите через sudo от обычного пользователя!"

configure_timeshift() {
	log "Настройка Timeshift..."

	if [[ ! -f "/etc/timeshift/timeshift.json" ]]; then
		mkdir -p /etc/timeshift

		# МАГИЯ: Автоматически находим UUID раздела, где лежит корень (/)
		local ROOT_UUID=$(lsblk -no UUID $(findmnt -no SOURCE /))

		log "Определен UUID системы: $ROOT_UUID"

		cat >/etc/timeshift/timeshift.json <<TS_EOF
{
  "backup_device_uuid" : "$ROOT_UUID",
  "parent_device_uuid" : "",
  "do_first_run" : "false",
  "btrfs_mode" : "false",
  "include_btrfs_home" : "false",
  "date_format" : "%Y-%m-%d %H:%M:%S",
  "exclude" : [
    "/home/${REAL_USER}/**",
    "/root/**",
    "/var/cache/pacman/pkg/**"
  ]
}
TS_EOF
		log_ok "Конфигурация Timeshift создана"
	else
		log_ok "Timeshift уже настроен"
	fi
}

echo -e "${C_BLUE}${C_BOLD}
══════════════════════════════════════════════════════════════
                 ArchUpd Installer v.2.5 lite
══════════════════════════════════════════════════════════════${C_NC}"
sed -i 's/^[# ]*ParallelDownloads.*/ParallelDownloads = 8/' /etc/pacman.conf
log "Оптимизация сборки пакетов (makepkg)..."
# Ускоряем компиляцию на все ядра
sed -i "s/#MAKEFLAGS=\"-j2\"/MAKEFLAGS=\"-j$(nproc)\"/g" /etc/makepkg.conf
# Ускоряем сжатие
sed -i "s/COMPRESSZST=(zstd -c -z -q -)/COMPRESSZST=(zstd -c -z -q --threads=0 -)/g" /etc/makepkg.conf
log "1. Проверка зависимостей..."
PKGS=(pacman-contrib timeshift rsync curl libnotify file)
pacman -S --needed --noconfirm "${PKGS[@]}" || error_exit "Ошибка установки зависимостей"

configure_timeshift

# Формат: "Источник:Назначение:Права"
declare -a MAP=(
	"archupd.sh:/usr/local/bin/archupd:755"
	"archupdauto.sh:/usr/local/bin/archupdauto:755"
	"archupd.conf:/etc/archupd.conf:644"
	"archupd.service:/etc/systemd/system/archupd.service:644"
	"archupd.timer:/etc/systemd/system/archupd.timer:644"
	"archupd-notify@.service:/etc/systemd/system/archupd-notify@.service:644"
	"99-hardened.conf:/etc/sysctl.d/99-hardened.conf:644"
)

log "2. Развертывание файлов..."
for entry in "${MAP[@]}"; do
	# Важно: IFS=":" только для команды read
	IFS=":" read -r src dest mode <<<"$entry"

	if [[ -f "$src" ]]; then
		# Бэкап существующего конфига
		[[ "$dest" == "/etc/archupd.conf" && -f "$dest" ]] && cp "$dest" "$dest.bak"

		cp "$src" "$dest"
		chmod "$mode" "$dest"
		log_ok "$dest"
	else
		error_exit "Критическая ошибка: файл $src не найден!"
	fi
done

log "Настройка уведомлений для пользователя $REAL_USER..."

# Путь к установленному сервису
SERVICE_DEST="/etc/systemd/system/archupd.service"
# Если файл скопирован, заменяем заглушку на реальное имя пользователя
if [[ -f "$SERVICE_DEST" ]]; then
	# Используем sed для замены {{USER}} на имя текущего пользователя
	sed -i "s/{{USER}}/$REAL_USER/g" "$SERVICE_DEST"
	log "Настройка уведомлений..."
	sed -i "s/{{USER}}/$REAL_USER/g" /etc/systemd/system/archupd.service

	log_ok "Сервис настроен на пользователя: $REAL_USER"
fi

log "3. Настройка прав и уведомлений..."
# Настройка уведомлений в сервисе
# Мы заменяем заглушку {{USER}} на реальный логин
if [[ -f "/etc/systemd/system/archupd.service" ]]; then
	sed -i "s/{{USER}}/$REAL_USER/g" /etc/systemd/system/archupd.service
	log_ok "Сервис настроен для пользователя $REAL_USER"
fi

# Настройка Sudoers
SUDO_FILE="/etc/sudoers.d/archupd"
cat >"$SUDO_FILE" <<EOF
# Разрешения для работы ArchUpd
$REAL_USER ALL=(ALL) NOPASSWD: /usr/bin/pacman -Sy, /usr/bin/pacman -Syu --noconfirm, /usr/bin/pacman -Syu --dryrun, /usr/bin/timeshift --create *
EOF
chmod 440 "$SUDO_FILE"
log_ok "Права sudoers.d настроены"

log "4. Активация служб..."
usermod -aG systemd-journal "$REAL_USER"
systemctl daemon-reload
systemctl enable --now archupd.timer
log_ok "Авто-обновление по таймеру включено"

log "Применение политик безопасности ядра..."
sysctl --system &>/dev/null || true
sysctl -p /etc/sysctl.d/99-hardened.conf &>/dev/null || true

BDIR=$(getent passwd "$REAL_USER" | cut -d: -f6)/Documents/Arch_Backups
mkdir -p "$BDIR"
chown -R "$REAL_USER:$REAL_USER" "$(dirname "$BDIR")"

echo -e "\n${C_GREEN}${C_BOLD}═════════════════════ УСТАНОВКА ЗАВЕРШЕНА ════════════════════${C_NC}"
echo -e "Используйте ${C_BOLD}archupd --help${C_NC} для начала работы."
