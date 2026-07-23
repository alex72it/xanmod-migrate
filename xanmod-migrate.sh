#!/usr/bin/env bash
#
# xanmod-migrate.sh — установка кастомного ядра XanMod (с BBRv3) + сетевой тюнинг
# для VPN/proxy-ноды (Remnawave / Xray). Запускать на сервере ОТ ROOT.
#
#   bash xanmod-migrate.sh          # сделать всё и спросить про перезагрузку
#   bash xanmod-migrate.sh -y       # сделать всё и сразу перезагрузиться
#   bash xanmod-migrate.sh --tune-only   # только sysctl-тюнинг, без смены ядра
#
# Безопасность: ставит XanMod, но в загрузчике дефолтом ОСТАЁТСЯ старое ядро.
# В новое ядро грузимся РАЗОВО (grub-reboot). Если оно успешно загрузилось —
# systemd-сервис сам делает его постоянным. Если не загрузилось — следующая
# (аппаратная) перезагрузка вернёт на старое рабочее ядро. Откат «из коробки».
#
set -euo pipefail

AUTO_REBOOT=0; TUNE_ONLY=0
for a in "$@"; do
  case "$a" in
    -y|--yes) AUTO_REBOOT=1;;
    --tune-only) TUNE_ONLY=1;;
    -h|--help) grep '^#' "$0" | sed 's/^# \?//'; exit 0;;
  esac
done

c(){ printf '\033[1;36m%s\033[0m\n' "$*"; }      # info
ok(){ printf '\033[1;32m%s\033[0m\n' "$*"; }     # success
warn(){ printf '\033[1;33m%s\033[0m\n' "$*"; }   # warn
err(){ printf '\033[1;31m%s\033[0m\n' "$*" >&2; } # error
die(){ err "ОШИБКА: $*"; exit 1; }
have_cmd(){ command -v "$1" >/dev/null 2>&1; }

[ "$(id -u)" = "0" ] || die "запускать нужно от root (sudo -i, затем bash $0)"

# ---------- определяем ОС ----------
. /etc/os-release 2>/dev/null || die "не удалось прочитать /etc/os-release"
CN="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
[ -n "$CN" ] || die "не определён codename дистрибутива"
case "${ID:-} ${ID_LIKE:-}" in
  *debian*|*ubuntu*) ;;
  *) die "поддерживаются только Debian/Ubuntu (у вас: $PRETTY_NAME)";;
esac
RUN="$(uname -r)"
c "Система: $PRETTY_NAME ($CN), текущее ядро: $RUN"

# ====================================================================
# 1. СЕТЕВОЙ ТЮНИНГ (sysctl) — применяем всегда, без простоя
# ====================================================================
apply_tuning(){
  c ">>> Применяю сетевой тюнинг (sysctl)…"
  RAM=$(awk '/^MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
  { [ -n "${RAM:-}" ] && [ "$RAM" -gt 0 ] 2>/dev/null; } || RAM=2048
  if   [ "$RAM" -le 2500 ]; then CTMAX=262144
  elif [ "$RAM" -le 5000 ]; then CTMAX=524288
  else CTMAX=1048576; fi
  if [ "$RAM" -ge 8000 ]; then BUF=67108864; else BUF=16777216; fi
  SOMAX=16384; BACKLOG=16384
  # nf_conntrack может быть модулем и ещё не быть загружен на минимальном образе.
  # Не пишем в отсутствующий /proc/sys: bash печатает ошибку редиректа даже при
  # `2>/dev/null`, а sysctl.d затем шумит при каждой загрузке.
  have_cmd modprobe && modprobe nf_conntrack >/dev/null 2>&1 || true
  CT_AVAILABLE=0
  if [ -r /proc/sys/net/netfilter/nf_conntrack_max ]; then
    CT_AVAILABLE=1
    cur=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 0)
    [ "${cur:-0}" -gt "$CTMAX" ] && CTMAX=$cur
  fi
  # не понижаем уже бОльшие значения
  cur=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0);     [ "${cur:-0}" -gt "$BUF" ] && BUF=$cur
  cur=$(sysctl -n net.core.somaxconn 2>/dev/null || echo 0);    [ "${cur:-0}" -gt "$SOMAX" ] && SOMAX=$cur
  cur=$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo 0); [ "${cur:-0}" -gt "$BACKLOG" ] && BACKLOG=$cur
  HASH=$((CTMAX/4))

  printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/99-bbr.conf
  cat > /etc/sysctl.d/99-vpn-tuning.conf <<EOF
# VPN/proxy node tuning (xanmod-migrate.sh)
net.core.rmem_max = $BUF
net.core.wmem_max = $BUF
net.ipv4.tcp_rmem = 4096 131072 $BUF
net.ipv4.tcp_wmem = 4096 131072 $BUF
net.core.netdev_max_backlog = $BACKLOG
net.core.somaxconn = $SOMAX
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
EOF
  if [ "$CT_AVAILABLE" = "1" ]; then
    echo "net.netfilter.nf_conntrack_max = $CTMAX" >> /etc/sysctl.d/99-vpn-tuning.conf
    echo "options nf_conntrack hashsize=$HASH" > /etc/modprobe.d/nf_conntrack.conf
    install -d /etc/modules-load.d
    echo "nf_conntrack" > /etc/modules-load.d/xanmod-migrate.conf
  else
    warn "nf_conntrack недоступен в текущем ядре — его параметры пропущены"
  fi
  sysctl --system >/dev/null 2>&1 || true
  if [ "$CT_AVAILABLE" = "1" ] && [ -w /proc/sys/net/netfilter/nf_conntrack_max ]; then
    printf '%s\n' "$CTMAX" > /proc/sys/net/netfilter/nf_conntrack_max
    CT_STATUS=$CTMAX
  else
    CT_STATUS="пропущен"
  fi
  ok "Тюнинг применён: buffers=$BUF, somaxconn=$SOMAX, conntrack_max=$CT_STATUS (RAM ${RAM}MB)"
}

apply_tuning

if [ "$TUNE_ONLY" = "1" ]; then
  ok "Режим --tune-only: ядро не трогаю. Готово."
  exit 0
fi

case "$RUN" in *xanmod*) ok "Ядро уже XanMod ($RUN) — установка не нужна, тюнинг применён."; exit 0;; esac

# ====================================================================
# 2. ВЫБОР ПАКЕТА ЯДРА ПО CPU (psABI)
# ====================================================================
F=$(grep -m1 '^flags' /proc/cpuinfo)
has(){ echo "$F" | grep -qw "$1"; }
LVL=1
if has sse4_2 && has popcnt && has sse4_1 && has ssse3 && has cx16; then LVL=2; fi
if [ "$LVL" = "2" ] && has avx && has avx2 && has bmi1 && has bmi2 && has fma && has movbe && has f16c && has xsave; then LVL=3; fi
if [ "$LVL" = "1" ]; then PKG="linux-xanmod-lts-x64v1"; else PKG="linux-xanmod-x64v${LVL}"; fi
c "CPU psABI: v$LVL  ->  пакет $PKG"

# места на диске
AVAIL=$(df -Pm / | awk 'NR==2{print $4}')
[ "$AVAIL" -ge 1500 ] || die "мало места на / ($AVAIL MB, нужно >=1500)"

fetch_url_to_stdout(){
  if have_cmd curl; then curl -fsSL "$1" && return 0; fi
  if have_cmd wget; then wget -qO - "$1" && return 0; fi
  return 1
}
xanmod_suite_available(){
  local suite="$1" tmp
  tmp=$(mktemp) || return 1
  if fetch_url_to_stdout "https://deb.xanmod.org/dists/${suite}/InRelease" >"$tmp" 2>/dev/null \
     && grep -q '^-----BEGIN PGP SIGNED MESSAGE-----' "$tmp" \
     && grep -qE "^(Suite|Codename):[[:space:]]*${suite}$" "$tmp"; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}
remove_stale_xanmod_source(){
  local source_file=/etc/apt/sources.list.d/xanmod-release.list backup_dir backup_file
  if [ -f "$source_file" ] \
     && grep -qE '^[[:space:]]*deb([[:space:]]+\[[^]]+\])?[[:space:]]+https?://deb\.xanmod\.org([[:space:]]|/)' "$source_file"; then
    backup_dir=/var/backups/xanmod-migrate
    backup_file="$backup_dir/xanmod-release.list.$(date +%Y%m%d_%H%M%S)"
    install -d -m 0700 "$backup_dir"
    mv "$source_file" "$backup_file"
    warn "Нерабочий источник XanMod отключён (резервная копия: $backup_file)"
  fi
}
install_xanmod_key(){
  local key_url tmpasc tmpgpg src
  tmpasc=$(mktemp) || return 1
  tmpgpg=$(mktemp) || { rm -f "$tmpasc"; return 1; }
  for key_url in \
    "https://dl.xanmod.org/archive.key" \
    "https://dl.xanmod.org/gpg.key" \
    "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x86F7D09EE734E623"
  do
    if fetch_url_to_stdout "$key_url" >"$tmpasc" 2>/dev/null \
       && grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$tmpasc" 2>/dev/null \
       && gpg --dearmor <"$tmpasc" >"$tmpgpg" 2>/dev/null \
       && [ -s "$tmpgpg" ]; then
      install -m 0644 "$tmpgpg" /etc/apt/keyrings/xanmod-archive-keyring.gpg
      src="${key_url#https://}"
      ok "Ключ XanMod установлен: $src"
      rm -f "$tmpasc" "$tmpgpg"
      return 0
    fi
  done
  rm -f "$tmpasc" "$tmpgpg"
  return 1
}
xanmod_key_error(){
  grep -qiE 'NO_PUBKEY 86F7D09EE734E623|signatures couldn.t be verified|repository .+deb.xanmod.org.+ is not signed' "$APT_LOG" 2>/dev/null
}

# ====================================================================
# 3. РЕПОЗИТОРИЙ XANMOD + УСТАНОВКА
# ====================================================================
c ">>> Подключаю репозиторий XanMod…"
if ! xanmod_suite_available "$CN"; then
  remove_stale_xanmod_source
  err "XanMod не публикует репозиторий для codename '$CN' (проверен официальный InRelease)."
  if [ "${ID:-}" = "ubuntu" ] && [ "$CN" = "jammy" ]; then
    err "Ubuntu 22.04 (jammy) больше не поддерживается репозиторием XanMod."
    err "Обнови ОС до поддерживаемого Ubuntu LTS (сейчас 24.04 noble), затем запусти скрипт снова."
  else
    err "Поддерживаемые системы указаны на https://xanmod.org/ в разделе APT Repository."
  fi
  die "APT не изменён; подключать репозиторий от другой версии ОС небезопасно"
fi
install -d /etc/apt/keyrings
if [ ! -s /etc/apt/keyrings/xanmod-archive-keyring.gpg ]; then
  c "Устанавливаю ключ подписи XanMod…"
  install_xanmod_key || die "не скачался ключ XanMod (проверь доступ к dl.xanmod.org / keyserver.ubuntu.com)"
fi
echo "deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] https://deb.xanmod.org $CN main" \
  > /etc/apt/sources.list.d/xanmod-release.list
c "Обновляю списки пакетов…"
APT_LOG=$(mktemp) || die "не удалось создать временный лог apt"
trap 'rm -f "$APT_LOG"' EXIT
apt-get update -o Acquire::Retries=3 2>"$APT_LOG" >/dev/null || true
if xanmod_key_error; then
  warn "APT отклонил подпись XanMod — переустанавливаю ключ и повторяю update…"
  install_xanmod_key || die "не удалось импортировать ключ XanMod автоматически"
  rm -f /var/lib/apt/lists/deb.xanmod.org_* 2>/dev/null || true
  : >"$APT_LOG"
  apt-get update -o Acquire::Retries=3 -o Acquire::Check-Valid-Until=false 2>"$APT_LOG" >/dev/null || true
fi
CAND=$(LC_ALL=C apt-cache policy "$PKG" 2>/dev/null | awk '/Candidate:/{print $2}')
if [ -z "$CAND" ] || [ "$CAND" = "(none)" ]; then
  warn "Кандидат не найден с первого раза — принудительно перечитываю список XanMod…"
  rm -f /var/lib/apt/lists/deb.xanmod.org_* 2>/dev/null || true
  : >"$APT_LOG"
  apt-get update -o Acquire::Retries=3 -o Acquire::Check-Valid-Until=false 2>"$APT_LOG" >/dev/null || true
  CAND=$(LC_ALL=C apt-cache policy "$PKG" 2>/dev/null | awk '/Candidate:/{print $2}')
fi
if [ -z "$CAND" ] || [ "$CAND" = "(none)" ]; then
  err "Нет кандидата для $PKG (codename=$CN)."
  if xanmod_key_error; then
    err "Похоже, ключ подписи XanMod не удалось получить автоматически."
    err "Проверь доступ к keyserver.ubuntu.com и GitLab-редиректу dl.xanmod.org."
  fi
  if grep -qiE 'xanmod' "$APT_LOG" 2>/dev/null; then
    err "Сервер НЕ смог скачать список пакетов с deb.xanmod.org. Ошибки apt:"
    grep -i xanmod "$APT_LOG" | tail -4 >&2
  fi
  err "Репозиторий доступен, но пакет $PKG в нём не найден."
  err "Проверь актуальные имена пакетов на https://xanmod.org/."
  exit 1
fi
c "Версия для установки: $PKG = $CAND"

# бэкап grub
cp -a /etc/default/grub "/etc/default/grub.pre-xanmod.$(date +%Y%m%d_%H%M%S)"

c ">>> Устанавливаю ядро (может занять пару минут)…"
DEBIAN_FRONTEND=noninteractive apt-get install -y "$PKG" || die "не удалось установить $PKG (см. вывод apt выше)"

# ====================================================================
# 4. GRUB: дефолт = старое ядро, в XanMod грузимся РАЗОВО
# ====================================================================
sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
grep -q '^GRUB_DEFAULT=' /etc/default/grub || echo 'GRUB_DEFAULT=saved' >> /etc/default/grub
if grep -q '^GRUB_TIMEOUT=' /etc/default/grub; then sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub; else echo 'GRUB_TIMEOUT=3' >> /etc/default/grub; fi
update-grub >/dev/null 2>&1 || grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true

CFG=/boot/grub/grub.cfg
SUBID=$(grep "submenu '" "$CFG" 2>/dev/null | grep -oP "menuentry_id_option '\K[^']+" | head -1)
GENID=$(grep "menuentry '" "$CFG" | grep -- "$RUN" | grep -vi recovery | grep -oP "menuentry_id_option '\K[^']+" | head -1)
XANID=$(grep "menuentry '" "$CFG" | grep -i xanmod | grep -vi recovery | grep -oP "menuentry_id_option '\K[^']+" | head -1)
[ -n "$XANID" ] || die "не нашёл пункт XanMod в grub.cfg"
[ -n "$GENID" ] || die "не нашёл текущее ядро ($RUN) в grub.cfg для отката"
if [ -n "$SUBID" ]; then
  grub-set-default "${SUBID}>${GENID}"; grub-reboot "${SUBID}>${XANID}"
else
  grub-set-default "${GENID}"; grub-reboot "${XANID}"
fi
ok "GRUB: дефолт=старое ядро ($RUN), разовая загрузка=XanMod"

# ====================================================================
# 5. САМО-ФИНАЛИЗАЦИЯ: после успешной загрузки XanMod сделать его дефолтом
# ====================================================================
cat > /usr/local/sbin/xanmod-finalize.sh <<'FIN'
#!/usr/bin/env bash
case "$(uname -r)" in *xanmod*) ;; *) exit 0;; esac
CFG=/boot/grub/grub.cfg
SUBID=$(grep "submenu '" "$CFG" 2>/dev/null | grep -oP "menuentry_id_option '\K[^']+" | head -1)
XANID=$(grep "menuentry '" "$CFG" | grep -i xanmod | grep -vi recovery | grep -oP "menuentry_id_option '\K[^']+" | head -1)
[ -n "$XANID" ] && { [ -n "$SUBID" ] && grub-set-default "${SUBID}>${XANID}" || grub-set-default "${XANID}"; }
systemctl disable xanmod-finalize.service >/dev/null 2>&1 || true
FIN
chmod +x /usr/local/sbin/xanmod-finalize.sh
cat > /etc/systemd/system/xanmod-finalize.service <<'UNIT'
[Unit]
Description=Finalize XanMod as default kernel after a successful boot
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/xanmod-finalize.sh
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable xanmod-finalize.service >/dev/null 2>&1 || true
ok "Авто-финализация настроена (сделает XanMod дефолтом после успешной загрузки)"

echo
ok "================= ГОТОВО К ПЕРЕЗАГРУЗКЕ ================="
c "Ядро: $PKG=$CAND  |  Откат: $RUN (останется дефолтом, пока XanMod не загрузится успешно)"
c "После reboot проверь:  uname -r   и   modinfo tcp_bbr | grep version   (должно быть 3)"
echo

if [ "$AUTO_REBOOT" = "1" ]; then
  warn "Перезагружаюсь сейчас (-y)…"; sleep 2; reboot
else
  warn "Перезагрузи сервер вручную, когда будешь готов:   reboot"
  warn "(если XanMod не поднимется — аппаратный power-cycle вернёт на старое ядро автоматически)"
fi
