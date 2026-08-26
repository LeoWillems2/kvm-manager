#!/usr/bin/env bash
#
# beveilig.sh - zet de beveiligingsmaatregelen op een Ubuntu-server.
#
# Bedoeld voor twee situaties:
#   1. makevm.sh draait dit script in een nieuwe VM (via de qemu-guest-agent),
#      voordat er een base-image van wordt gemaakt;
#   2. u draait het zelf op een bestaande host: kopieer het erheen en start
#      het met sudo. Elke stap is idempotent, dus opnieuw draaien mag altijd.
#
# Wat het doet (blok A uit het beveiligingsvoorstel):
#   pakketten  apt update + dist-upgrade, daarna de benodigde pakketten
#   updates    unattended-upgrades voor security-updates, needrestart automatisch
#   sysctl     kernel- en netwerkhardening, IPv4 en IPv6
#   ssh        alleen sleutels, strakke limieten, moderne algoritmes
#   ufw        alles dicht behalve ssh (rate-limited), IPv4 en IPv6, logging
#   fail2ban   sshd-jail en recidive-jail
#   tmp        /tmp, /dev/shm en /var/tmp zonder exec/suid/dev
#   sudo       use_pty en een sudo-logboek; de uitvoerende gebruiker krijgt
#              wachtwoordloze sudo; root-account op slot
#   apparmor   geinstalleerd, ingeschakeld en in enforce
#   auditd     basisregels: identiteit, sudo, ssh-config, modules, root-exec
#
# Wat het bewust NIET doet: uitgaand verkeer filteren, aparte partities,
# CIS/USG, wachtwoordbeleid (blok B), en niets op host- of netwerkniveau
# (blok C). De tijdsynchronisatie wordt met rust gelaten.
#
# Gebruik:  sudo ./beveilig.sh [--ssh-from "any|CIDR ..."] [--skip STAP,...] [-y]
#           sudo ./beveilig.sh --dry-run          # alleen laten zien
#
set -Eeuo pipefail

########################################################################
# 1. INSTELLINGEN
########################################################################

# Vanaf welke adressen mag ssh? "any" of een lijst, bijv. "192.168.100.0/24"
SSH_ALLOW_FROM="any"

# Netwerken die fail2ban nooit mag blokkeren (naast localhost). Leeg = het
# script leidt het netwerk van de eerste interface zelf af.
TRUSTED_NETS=""

# Automatisch herstarten na een unattended security-update: leeg = nooit,
# anders een tijdstip als "03:30".
AUTO_REBOOT_TIME=""

# NOPASSWD-regels in sudo weghalen? Standaard nee: cloud-init zet die er zelf
# neer en het weghalen breekt beheer op afstand dat op sudo -n leunt.
DROP_NOPASSWD="no"

# Wie moet er na afloop nog met sudo naar binnen kunnen? Leeg = de gebruiker
# achter sudo (SUDO_USER), anders wat --admin-user meegeeft. Deze gebruiker
# krijgt een eigen regel in ${USERS_DROPIN}; dat is de weg terug zodra het
# root-account op slot gaat.
ADMIN_USER=""

STEPS_ALL="pakketten updates sysctl ssh ufw fail2ban tmp sudo apparmor auditd"
SKIP_STEPS=""                     # --skip
ONLY_STEPS=""                     # --only
DRY_RUN="no"
ASSUME_YES="no"
FORCE="no"                        # ssh dichtzetten zonder sleutelcontrole
UFW_RESET="no"                    # alle bestaande ufw-regels wissen?

LOG_DIR="/var/log"
LOG_FILE=""                       # leeg => ${LOG_DIR}/beveilig-{tijd}.log
STATUS_FILE=""                    # leeg => ${LOG_DIR}/beveilig.status

# Alle bestanden die dit script beheert, staan onder deze namen. Ze worden
# elke keer overschreven; met de hand aangepaste kopieen gaan dus verloren.
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-beveilig.conf"
SYSCTL_DROPIN="/etc/sysctl.d/99-beveilig.conf"
SUDO_DROPIN="/etc/sudoers.d/99-beveilig"
USERS_DROPIN="/etc/sudoers.d/99-users"
AUDIT_RULES="/etc/audit/rules.d/99-beveilig.rules"
F2B_JAIL="/etc/fail2ban/jail.d/99-beveilig.conf"
UU_CONF="/etc/apt/apt.conf.d/52-beveilig-unattended"
NR_CONF="/etc/needrestart/conf.d/99-beveilig.conf"

########################################################################
# 2. MELDINGEN
########################################################################
#
# Zelfde vorm als makevm.sh, zodat een mens en een bewakende agent hetzelfde
# lezen:
#
#   2026-08-20T21:30:02+02:00 [beveilig] run=... host=demo step=ssh \
#       status=OK duur=3s msg="sshd accepteert alleen nog publieke sleutels"
#
# status: PLAN START INFO OK SKIP CHECK WARN FAIL RESULT
# Een run is goed afgelopen als de laatste regel status=RESULT result=ok bevat.
# Exitcodes: 0 = klaar, 1 = fout, 3 = klaar maar met waarschuwingen.

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
CURRENT_STEP="start"
STEP_STARTED_AT="$(date +%s)"
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || echo onbekend)"
FAILED_STEP=""
REBOOT_NEEDED="nee"
declare -i N_OK=0 N_SKIP=0 N_WARN=0 N_FAIL=0

_ts()  { date +%Y-%m-%dT%H:%M:%S%:z; }
_now() { date +%s; }

status_write() {
    [[ -n "${STATUS_FILE:-}" ]] || return 0
    local tmp="${STATUS_FILE}.${BASHPID}.tmp"
    {
        cat >"$tmp" <<EOF
run=${RUN_ID}
pid=$$
host=${HOSTNAME_SHORT}
bijgewerkt=$(_ts)
step=${1}
status=${2}
msg=${3}
gedaan=${N_OK}
overgeslagen=${N_SKIP}
waarschuwingen=${N_WARN}
mislukt=${N_FAIL}
herstart_nodig=${REBOOT_NEEDED}
log=${LOG_FILE:-geen}
EOF
        mv "$tmp" "$STATUS_FILE"
        chmod 0644 "$STATUS_FILE"
    } 2>/dev/null || true
    return 0
}

event() {
    local status="$1" step="$2" msg="$3"; shift 3
    local extra="$*" color line screen
    msg="${msg//$'\n'/ }"; msg="${msg//\"/\'}"
    line="$(_ts) [beveilig] run=${RUN_ID} host=${HOSTNAME_SHORT} step=${step} status=${status}"
    [[ -n "$extra" ]] && line+=" ${extra}"
    line+=" msg=\"${msg}\""
    case "$status" in
        FAIL)       color="1;31" ;;
        WARN)       color="1;33" ;;
        OK|RESULT)  color="1;32" ;;
        INFO)       color="1;32" ;;
        *)          color="1;34" ;;
    esac
    if [[ "$status" == "INFO" ]]; then screen="==> ${msg}"; else screen="$line"; fi
    if [[ "$status" == "FAIL" || "$status" == "WARN" ]]; then
        printf '\033[%sm%s\033[0m\n' "$color" "$screen" >&2
    else
        printf '\033[%sm%s\033[0m\n' "$color" "$screen"
    fi
    [[ -n "${LOG_FILE:-}" ]] && { printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true; }
    status_write "$step" "$status" "$msg"
    return 0
}

log()  { event INFO "$CURRENT_STEP" "$*"; }
warn() { N_WARN+=1; event WARN "$CURRENT_STEP" "$*"; }
die()  { FAILED_STEP="$CURRENT_STEP"; N_FAIL+=1; event FAIL "$CURRENT_STEP" "$*"; exit 1; }

step_start() { CURRENT_STEP="$1"; STEP_STARTED_AT="$(_now)"; event START "$1" "${2:-begonnen}"; }
step_ok()    { N_OK+=1;   event OK   "${1:-$CURRENT_STEP}" "${2:-klaar}" "duur=$(( $(_now) - STEP_STARTED_AT ))s"; }
step_skip()  { N_SKIP+=1; event SKIP "$1" "$2"; }
step_fail()  { N_FAIL+=1; FAILED_STEP="$1"; event FAIL "$1" "$2" "duur=$(( $(_now) - STEP_STARTED_AT ))s"; }

# Elke wijziging loopt hierlangs, zodat --dry-run precies laat zien wat er
# zou gebeuren en het logboek achteraf te lezen is als een lijst commando's.
run() {
    if [[ "$DRY_RUN" == "yes" ]]; then
        event INFO "$CURRENT_STEP" "[proef] $*"
        return 0
    fi
    local out rc=0
    out="$("$@" 2>&1)" || rc=$?
    if [[ -n "${LOG_FILE:-}" && -n "$out" ]]; then
        printf '    | %s\n' "$out" >>"$LOG_FILE" 2>/dev/null || true
    fi
    return "$rc"
}

# Een bestand met vaste inhoud neerzetten; meldt of het echt veranderde.
# Gebruik: <iets dat de inhoud maakt> | write_file /pad 0644
write_file() {
    local path="$1" mode="$2" tmp
    tmp="$(mktemp)"
    cat >"$tmp"
    if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"
        log "Ongewijzigd: ${path}"
        return 1
    fi
    if [[ "$DRY_RUN" == "yes" ]]; then
        event INFO "$CURRENT_STEP" "[proef] zou ${path} (${mode}) schrijven, $(wc -l <"$tmp") regels"
        rm -f "$tmp"
        return 0
    fi
    install -D -m "$mode" "$tmp" "$path"
    rm -f "$tmp"
    log "Geschreven: ${path}"
    return 0
}

init_logging() {
    if [[ "$LOG_FILE" == "-" ]]; then LOG_FILE=""; STATUS_FILE=""; return 0; fi
    if [[ -z "$LOG_FILE" ]]; then
        mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/var/tmp"
        LOG_FILE="${LOG_DIR}/beveilig-$(date +%Y%m%d-%H%M%S).log"
    else
        LOG_DIR="$(dirname "$LOG_FILE")"
        mkdir -p "$LOG_DIR" 2>/dev/null || true
    fi
    [[ -z "$STATUS_FILE" ]] && STATUS_FILE="${LOG_DIR}/beveilig.status"
    if ! : >"$LOG_FILE" 2>/dev/null; then
        LOG_FILE=""; STATUS_FILE=""
        return 0
    fi
    chmod 0640 "$LOG_FILE" 2>/dev/null || true
    ln -sfn "$LOG_FILE" "${LOG_DIR}/beveilig-laatste.log" 2>/dev/null || true
    return 0
}

on_exit() {
    local rc=$?
    trap - EXIT ERR
    [[ "$CURRENT_STEP" == "start" && $rc -eq 0 ]] && exit 0
    local result
    case "$rc" in
        0) result="ok"; (( N_WARN > 0 )) && result="ok-met-waarschuwingen" ;;
        3) result="ok-met-waarschuwingen" ;;
        *) result="fout" ;;
    esac
    event RESULT einde "run afgerond" \
        "result=${result}" "exit=${rc}" "mislukte_stap=${FAILED_STEP:-geen}" \
        "gedaan=${N_OK}" "overgeslagen=${N_SKIP}" "waarschuwingen=${N_WARN}" \
        "mislukt=${N_FAIL}" "herstart_nodig=${REBOOT_NEEDED}" \
        "proef=${DRY_RUN}" "log=${LOG_FILE:-geen}"
    exit "$rc"
}

on_err() {
    local rc="$1" line="$2" cmd="$3"
    FAILED_STEP="$CURRENT_STEP"; N_FAIL+=1
    event FAIL "$CURRENT_STEP" "onverwachte fout bij: ${cmd}" "exit=${rc}" "regel=${line}"
    return 0
}

trap 'on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR
trap on_exit EXIT
trap 'FAILED_STEP="$CURRENT_STEP"; event FAIL "$CURRENT_STEP" "afgebroken door ctrl-c"; exit 130' INT
trap 'FAILED_STEP="$CURRENT_STEP"; event FAIL "$CURRENT_STEP" "afgebroken door TERM"; exit 143' TERM

########################################################################
# 3. PARAMETERS
########################################################################

usage() {
    cat <<EOF
Gebruik: $(basename "$0") [opties]

Zet de beveiligingsmaatregelen (blok A) op deze host. Idempotent: opnieuw
draaien is altijd veilig.

      --ssh-from LIJST  vanaf welke adressen ssh mag: "any" of bijvoorbeeld
                        "192.168.100.0/24 10.8.0.5" (nu: ${SSH_ALLOW_FROM})
      --trusted LIJST   netwerken die fail2ban nooit blokkeert (naast
                        localhost); leeg = zelf afleiden uit de interface
      --auto-reboot TIJD  herstart automatisch na een security-update, bijv.
                        03:30 (standaard: nooit)
      --drop-nopasswd   NOPASSWD-regels uit sudo halen (standaard: alleen
                        melden; weghalen breekt beheer dat sudo -n gebruikt)
      --admin-user NAAM wie wachtwoordloze sudo krijgt in /etc/sudoers.d/99-users
                        (standaard: de gebruiker achter sudo); "geen" slaat
                        dit over
      --skip STAP,...   stappen overslaan
      --only STAP,...   alleen deze stappen doen
      --dry-run         niets wijzigen, alleen laten zien wat er zou gebeuren
      --force           ssh dichtzetten ook als er geen sleutels gevonden zijn
      --ufw-reset       alle bestaande ufw-regels wissen voor een schone lei
                        (zonder deze vlag blijven regels van andere diensten staan)
      --log BESTAND     logbestand ("-" = alleen scherm)
  -y, --yes             geen bevestiging vragen
  -h, --help            deze hulptekst

Stappen: ${STEPS_ALL// /, }

Let op: na de eerste run is /tmp noexec. Zet het script daarna dus in
/root of /usr/local/sbin, of start het als: bash /tmp/beveilig.sh

Meelezen tijdens een run:
  tail -f ${LOG_DIR}/beveilig-laatste.log
  cat     ${LOG_DIR}/beveilig.status
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssh-from)     SSH_ALLOW_FROM="${2:-}"; shift 2 ;;
        --trusted)      TRUSTED_NETS="${2:-}"; shift 2 ;;
        --auto-reboot)  AUTO_REBOOT_TIME="${2:-}"; shift 2 ;;
        --drop-nopasswd) DROP_NOPASSWD="yes"; shift ;;
        --admin-user)   ADMIN_USER="${2:-}"; shift 2 ;;
        --skip)         SKIP_STEPS="${2:-}"; shift 2 ;;
        --only)         ONLY_STEPS="${2:-}"; shift 2 ;;
        --dry-run)      DRY_RUN="yes"; shift ;;
        --force)        FORCE="yes"; shift ;;
        --ufw-reset)    UFW_RESET="yes"; shift ;;
        --log)          LOG_FILE="${2:-}"; shift 2 ;;
        -y|--yes)       ASSUME_YES="yes"; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              usage >&2; die "Onbekende optie: $1" ;;
    esac
done

confirm() {
    [[ "$ASSUME_YES" == "yes" ]] && return 0
    local answer
    read -rp "$1 [j/N] " answer
    [[ "$answer" =~ ^([jJ]|[yY])$ ]]
}

# Doet deze run stap $1?
doet() {
    local s="$1"
    [[ ",${SKIP_STEPS}," == *",${s},"* ]] && return 1
    [[ -n "$ONLY_STEPS" && ",${ONLY_STEPS}," != *",${s},"* ]] && return 1
    return 0
}

for s in ${SKIP_STEPS//,/ } ${ONLY_STEPS//,/ }; do
    [[ " ${STEPS_ALL} " == *" ${s} "* ]] || { usage >&2; die "Onbekende stap: ${s}"; }
done
[[ -n "$AUTO_REBOOT_TIME" && ! "$AUTO_REBOOT_TIME" =~ ^[0-9]{2}:[0-9]{2}$ ]] && \
    die "--auto-reboot wil een tijd als 03:30 (kreeg: '${AUTO_REBOOT_TIME}')."

########################################################################
# 4. PREFLIGHT
########################################################################

init_logging
event START run "beveilig gestart op '${HOSTNAME_SHORT}'" \
    "pid=$$" "proef=${DRY_RUN}" "log=${LOG_FILE:-geen}" "status=${STATUS_FILE:-geen}"

step_start preflight "host controleren"

[[ ${EUID} -eq 0 ]] || die "Draai dit script als root (sudo $0)."
command -v apt-get >/dev/null || die "Dit script gaat uit van Debian/Ubuntu (apt ontbreekt)."
command -v systemctl >/dev/null || die "Dit script gaat uit van systemd."

OS_NAME="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-onbekend}")"
log "Systeem: ${OS_NAME}, kernel $(uname -r)"

# Het netwerk van de eerste interface met een default route; gebruikt voor de
# ignoreip van fail2ban als er niets is meegegeven.
if [[ -z "$TRUSTED_NETS" ]]; then
    _dev="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
    if [[ -n "${_dev:-}" ]]; then
        TRUSTED_NETS="$(ip -4 -o addr show dev "$_dev" 2>/dev/null \
            | awk '{print $4}' | head -1 \
            | awk -F/ '{split($1,a,"."); print a[1]"."a[2]"."a[3]".0/"$2}')"
    fi
    [[ -n "$TRUSTED_NETS" ]] && log "Vertrouwd netwerk afgeleid: ${TRUSTED_NETS}"
fi

# Wie krijgt straks sudo? De gebruiker achter sudo is de meest waarschijnlijke
# beheerder; draait het script als echte root (bijv. via de guest-agent vanuit
# makevm.sh), dan is er niemand aan te wijzen en blijft sudo zoals het was.
if [[ -z "$ADMIN_USER" ]]; then
    ADMIN_USER="${SUDO_USER:-}"
    [[ -z "$ADMIN_USER" ]] && ADMIN_USER="$(logname 2>/dev/null || true)"
    [[ "$ADMIN_USER" == "root" ]] && ADMIN_USER=""
    if [[ -n "$ADMIN_USER" ]]; then
        log "Beheerder afgeleid uit de sessie: ${ADMIN_USER}"
    else
        log "Geen aanroepende gebruiker gevonden (script draait als echte root); ${USERS_DROPIN} wordt niet geschreven"
    fi
fi
[[ "$ADMIN_USER" == "geen" ]] && ADMIN_USER=""

PLAN=""
for s in $STEPS_ALL; do doet "$s" && PLAN+="${PLAN:+,}${s}"; done
[[ -n "$PLAN" ]] || die "Er blijft geen enkele stap over om te doen."
event PLAN run "stappen van deze run" "proef=${DRY_RUN}" "stappen=preflight,${PLAN},einde"

if [[ "$DRY_RUN" == "no" ]]; then
    confirm "Deze maatregelen nu toepassen op '${HOSTNAME_SHORT}' (${OS_NAME})?" \
        || die "Afgebroken; er is niets gewijzigd."
fi
step_ok preflight "host is bruikbaar; ${PLAN//,/, }"

########################################################################
# 5. STAP: PAKKETTEN - eerst bijwerken, dan pas installeren
########################################################################

PKGS_BASE="openssh-server ufw fail2ban unattended-upgrades apt-listchanges needrestart apparmor apparmor-utils auditd audispd-plugins"

stap_pakketten() {
    step_start pakketten "pakketlijsten bijwerken, systeem bijwerken en pakketten installeren"
    export DEBIAN_FRONTEND=noninteractive

    if ! run apt-get update; then
        step_fail pakketten "apt-get update mislukte; zonder verse pakketlijsten stopt het hier"
        return 1
    fi
    log "Pakketlijsten bijgewerkt"

    # Eerst het systeem bij, dan pas nieuwe software erbij: anders installeert
    # apt versies waarvoor al een security-update klaarstaat.
    local nu_te_upgraden
    nu_te_upgraden="$(apt-get -s dist-upgrade 2>/dev/null | grep -c '^Inst ' || true)"
    log "Te upgraden pakketten: ${nu_te_upgraden}"
    if ! run apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade; then
        step_fail pakketten "apt-get dist-upgrade mislukte"
        return 1
    fi

    local ontbreekt="" p
    for p in $PKGS_BASE; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" || ontbreekt+="${p} "
    done
    if [[ -z "$ontbreekt" ]]; then
        log "Alle benodigde pakketten stonden er al"
    else
        log "Installeren: ${ontbreekt}"
        if ! run apt-get -y install $ontbreekt; then
            step_fail pakketten "installeren van ${ontbreekt}mislukte"
            return 1
        fi
    fi

    run apt-get -y autoremove --purge || warn "apt-get autoremove gaf een fout; niet fataal."
    [[ -f /var/run/reboot-required ]] && { REBOOT_NEEDED="ja"; log "Er staat een herstart open (nieuwe kernel of libc)"; }
    step_ok pakketten "systeem bijgewerkt (${nu_te_upgraden} pakketten) en pakketten aanwezig"
    return 0
}

########################################################################
# 6. STAP: UPDATES - unattended-upgrades en needrestart
########################################################################

stap_updates() {
    step_start updates "automatische security-updates instellen"

    write_file /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'EOF' || true
// Beheerd door beveilig.sh
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

    {
        cat <<'EOF'
// Beheerd door beveilig.sh - alleen security-updates, automatisch
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Mail "";
EOF
        if [[ -n "$AUTO_REBOOT_TIME" ]]; then
            printf 'Unattended-Upgrade::Automatic-Reboot "true";\n'
            printf 'Unattended-Upgrade::Automatic-Reboot-WithUsers "false";\n'
            printf 'Unattended-Upgrade::Automatic-Reboot-Time "%s";\n' "$AUTO_REBOOT_TIME"
        else
            printf 'Unattended-Upgrade::Automatic-Reboot "false";\n'
        fi
    } | write_file "$UU_CONF" 0644 || true

    # needrestart: diensten na een update zelf herstarten in plaats van een
    # vraag stellen die niemand beantwoordt op een onbemande server.
    write_file "$NR_CONF" 0644 <<'EOF' || true
# Beheerd door beveilig.sh
$nrconf{restart} = 'a';
$nrconf{kernelhints} = 0;
EOF

    run systemctl enable --now unattended-upgrades.service \
        || warn "unattended-upgrades.service kon niet worden ingeschakeld."
    if [[ "$DRY_RUN" == "no" ]] && ! unattended-upgrade --dry-run >/dev/null 2>&1; then
        warn "unattended-upgrade --dry-run gaf een fout; controleer ${UU_CONF}."
    fi
    event CHECK updates "automatische herstart: ${AUTO_REBOOT_TIME:-nooit}"
    step_ok updates "security-updates worden automatisch geinstalleerd"
    return 0
}

########################################################################
# 7. STAP: SYSCTL - kernel- en netwerkhardening
########################################################################

stap_sysctl() {
    step_start sysctl "kernel- en netwerkinstellingen vastzetten"

    # IPv6 blijft aan (het gaat mee in ufw), maar redirects en source routing
    # gaan ook daar dicht. accept_ra wordt bewust niet aangeraakt: op een net
    # met SLAAC zou de host anders zijn adres kwijtraken.
    write_file "$SYSCTL_DROPIN" 0644 <<'EOF' || true
# Beheerd door beveilig.sh
# --- kernel ---
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 1
kernel.sysrq = 0
kernel.core_uses_pid = 1
fs.suid_dumpable = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
# --- IPv4 ---
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
# --- IPv6 ---
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
EOF

    if [[ "$DRY_RUN" == "no" ]]; then
        run sysctl -q --load="$SYSCTL_DROPIN" \
            || warn "Niet elke sysctl-sleutel kon worden gezet (zie het log); de rest staat wel."
        event CHECK sysctl "actief: ptrace_scope=$(sysctl -n kernel.yama.ptrace_scope 2>/dev/null || echo '?'), rp_filter=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo '?'), syncookies=$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null || echo '?')"
    fi
    step_ok sysctl "instellingen staan in ${SYSCTL_DROPIN} en zijn actief"
    return 0
}

########################################################################
# 8. STAP: SSH - alleen sleutels, strak, moderne algoritmes
########################################################################

# Houdt uit een lijst alleen over wat deze openssh kent; zo werkt hetzelfde
# script op een oudere host zonder dat sshd weigert te starten.
filter_alg() {
    local query="$1"; shift
    local bekend have out=""
    bekend="$(ssh -Q "$query" 2>/dev/null || true)"
    for have in "$@"; do
        grep -qxF "$have" <<<"$bekend" && out+="${out:+,}${have}"
    done
    printf '%s' "$out"
}

# Is er iemand die na het uitzetten van wachtwoorden nog binnenkomt?
sleutels_aanwezig() {
    local d f c n=0
    for d in /root /home/*; do
        f="${d}/.ssh/authorized_keys"
        [[ -r "$f" ]] || continue
        # grep -c geeft 0 en exitcode 1 als er niets in staat; dat is geen fout
        c="$(grep -cE '^(ssh-|ecdsa-|sk-)' "$f" 2>/dev/null)" || c=0
        n=$(( n + c ))
    done
    printf '%s' "$n"
}

stap_ssh() {
    step_start ssh "sshd dichtzetten: alleen publieke sleutels"

    local n_keys bestanden
    n_keys="$(sleutels_aanwezig)"
    bestanden="$(ls -1 /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys 2>/dev/null | tr '\n' ' ')"
    log "Publieke sleutels gevonden: ${n_keys} in ${bestanden:-(nergens)}"
    if (( n_keys == 0 )) && [[ "$FORCE" != "yes" ]]; then
        step_fail ssh "geen enkele authorized_keys gevonden; wachtwoorden uitzetten zou u buitensluiten (gebruik --force als u het zeker weet)"
        return 1
    fi

    # De ed25519-hostkey moet bestaan voordat we de rest niet meer aanbieden.
    if [[ ! -s /etc/ssh/ssh_host_ed25519_key ]]; then
        log "ed25519-hostkey ontbreekt; aanmaken"
        run ssh-keygen -A || { step_fail ssh "kon geen hostkeys aanmaken"; return 1; }
    fi

    local kex ciphers macs hka pka
    kex="$(filter_alg kex \
        sntrup761x25519-sha512@openssh.com sntrup761x25519-sha512 \
        mlkem768x25519-sha256 curve25519-sha256 curve25519-sha256@libssh.org \
        diffie-hellman-group16-sha512 diffie-hellman-group18-sha512)"
    ciphers="$(filter_alg cipher \
        chacha20-poly1305@openssh.com aes256-gcm@openssh.com aes128-gcm@openssh.com \
        aes256-ctr aes192-ctr aes128-ctr)"
    macs="$(filter_alg mac \
        hmac-sha2-256-etm@openssh.com hmac-sha2-512-etm@openssh.com \
        umac-128-etm@openssh.com)"
    hka="$(filter_alg HostKeyAlgorithms ssh-ed25519 ssh-ed25519-cert-v01@openssh.com)"
    pka="$(filter_alg PubkeyAcceptedAlgorithms \
        ssh-ed25519 ssh-ed25519-cert-v01@openssh.com \
        sk-ssh-ed25519@openssh.com rsa-sha2-512 rsa-sha2-256)"

    {
        cat <<'EOF'
# Beheerd door beveilig.sh - niet met de hand aanpassen
# --- authenticatie ---
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitRootLogin no
UsePAM yes
MaxAuthTries 3
MaxSessions 10
LoginGraceTime 20
# --- doorsturen: tunnels blijven mogelijk (ssh -L/-D), de rest niet ---
AllowTcpForwarding yes
GatewayPorts no
PermitTunnel no
X11Forwarding no
AllowAgentForwarding no
PermitUserEnvironment no
# --- sessies en logging ---
ClientAliveInterval 300
ClientAliveCountMax 2
TCPKeepAlive no
LogLevel VERBOSE
PrintLastLog yes
EOF
        printf '# --- alleen een ed25519-hostkey aanbieden ---\nHostKey /etc/ssh/ssh_host_ed25519_key\n'
        [[ -n "$kex"     ]] && printf 'KexAlgorithms %s\n' "$kex"
        [[ -n "$ciphers" ]] && printf 'Ciphers %s\n' "$ciphers"
        [[ -n "$macs"    ]] && printf 'MACs %s\n' "$macs"
        [[ -n "$hka"     ]] && printf 'HostKeyAlgorithms %s\n' "$hka"
        [[ -n "$pka"     ]] && printf 'PubkeyAcceptedAlgorithms %s\n' "$pka"
    } | write_file "$SSHD_DROPIN" 0644 || true

    if [[ "$DRY_RUN" == "no" ]]; then
        # Eerst laten nakijken; een sshd die niet start is het ergste dat dit
        # script kan aanrichten.
        if ! sshd -t 2>>"${LOG_FILE:-/dev/null}"; then
            log "sshd keurde de configuratie af; ${SSHD_DROPIN} wordt teruggedraaid"
            rm -f "$SSHD_DROPIN"
            step_fail ssh "sshd -t keurde ${SSHD_DROPIN} af; niets gewijzigd"
            return 1
        fi
        run systemctl reload ssh || run systemctl restart ssh \
            || { step_fail ssh "ssh kon niet worden herstart"; return 1; }
        local aangeboden
        aangeboden="$(sshd -T 2>/dev/null | awk '/^passwordauthentication|^permitrootlogin|^pubkeyauthentication/{print $1"="$2}' | tr '\n' ' ')"
        event CHECK ssh "sshd draait met: ${aangeboden}"
        [[ "$aangeboden" == *"passwordauthentication=no"* ]] \
            || warn "sshd meldt nog steeds passwordauthentication=yes; staat er een andere drop-in in /etc/ssh/sshd_config.d/?"
    fi
    step_ok ssh "alleen publieke sleutels; tunnels toegestaan, agent-forwarding en X11 uit"
    return 0
}

########################################################################
# 9. STAP: UFW - alles dicht behalve ssh, ook IPv6
########################################################################

stap_ufw() {
    step_start ufw "firewall instellen (IPv4 en IPv6)"

    # IPv6 meenemen. Zonder deze regel filtert ufw alleen IPv4 en staat een
    # v6-adres van de host open zonder dat de firewall er iets van laat zien.
    if [[ -f /etc/default/ufw ]]; then
        if grep -qE '^IPV6=yes' /etc/default/ufw; then
            log "IPv6 stond al aan in /etc/default/ufw"
        else
            run sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
            log "IPv6 aangezet in /etc/default/ufw"
        fi
    fi

    # Een reset wist ook regels van andere diensten. Op een bestaande host
    # doen we dat alleen op verzoek; makevm.sh geeft --ufw-reset mee, want
    # daar is de firewall nog leeg.
    if [[ "$UFW_RESET" == "yes" ]]; then
        run ufw --force reset || warn "ufw reset gaf een fout."
        log "Alle bestaande ufw-regels zijn gewist (--ufw-reset)"
    else
        # oude ssh-regels van dit script of van makevm.sh weghalen, anders
        # blijft er een ruimere 'allow' naast onze 'limit' staan
        run ufw delete allow OpenSSH || true
        run ufw delete allow 22/tcp  || true
        log "Bestaande regels van andere diensten blijven staan (geef --ufw-reset voor een schone lei)"
    fi
    run ufw default deny incoming
    run ufw default allow outgoing
    run ufw default deny routed
    run ufw logging medium

    # ssh eerst toestaan, dan pas aanzetten: anders sluit de firewall de
    # sessie af waarin dit script draait. 'limit' knijpt herhaalde pogingen
    # af nog voordat fail2ban eraan te pas komt.
    if [[ "$SSH_ALLOW_FROM" == "any" ]]; then
        run ufw limit OpenSSH
        log "ssh toegestaan vanaf elk adres (rate-limited)"
    else
        local src
        for src in $SSH_ALLOW_FROM; do
            run ufw limit from "$src" to any port 22 proto tcp
            log "ssh toegestaan vanaf ${src} (rate-limited)"
        done
    fi

    run ufw --force enable || { step_fail ufw "ufw kon niet worden aangezet"; return 1; }
    run systemctl enable ufw || warn "ufw start niet automatisch mee met de host."

    if [[ "$DRY_RUN" == "no" ]]; then
        local status v6
        status="$(ufw status verbose 2>/dev/null | head -4 | tr '\n' ' ')"
        v6="$(grep -E '^IPV6=' /etc/default/ufw 2>/dev/null | cut -d= -f2)"
        event CHECK ufw "ufw: ${status}" "ipv6=${v6:-onbekend}"
        ufw status 2>/dev/null | grep -q "Status: active" \
            || { step_fail ufw "ufw meldt zichzelf niet als actief"; return 1; }
    fi
    step_ok ufw "binnenkomend dicht, ssh rate-limited, IPv6 meegenomen"
    return 0
}

########################################################################
# 10. STAP: FAIL2BAN
########################################################################

stap_fail2ban() {
    step_start fail2ban "jails instellen voor sshd en herhaalde overtreders"

    local ignore="127.0.0.1/8 ::1"
    [[ -n "$TRUSTED_NETS" ]] && ignore+=" ${TRUSTED_NETS}"

    cat <<EOF | write_file "$F2B_JAIL" 0644 || true
# Beheerd door beveilig.sh
[DEFAULT]
backend  = systemd
bantime  = 1h
findtime = 10m
maxretry = 5
ignoreip = ${ignore}

[sshd]
enabled = true
mode    = aggressive

# Wie na een ban terugkomt, gaat er een week uit.
[recidive]
enabled  = true
bantime  = 1w
findtime = 1d
maxretry = 3
EOF

    # Een oudere jail.local van makevm.sh zou dezelfde jails dubbel zetten.
    if [[ -f /etc/fail2ban/jail.local ]] && grep -q "makevm" /etc/fail2ban/jail.local 2>/dev/null; then
        log "Oude /etc/fail2ban/jail.local van makevm.sh wordt vervangen door ${F2B_JAIL}"
        run mv /etc/fail2ban/jail.local /etc/fail2ban/jail.local.beveilig-oud
    fi

    run systemctl enable fail2ban || warn "fail2ban start niet automatisch mee."
    if [[ "$DRY_RUN" == "no" ]]; then
        if ! run systemctl restart fail2ban; then
            step_fail fail2ban "fail2ban kon niet worden gestart; kijk met: journalctl -u fail2ban"
            return 1
        fi
        sleep 2
        local jails
        jails="$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:\s*//p')"
        event CHECK fail2ban "actieve jails: ${jails:-onbekend}"
        [[ -n "$jails" ]] || warn "fail2ban meldt geen enkele actieve jail."
    fi
    step_ok fail2ban "sshd- en recidive-jail actief; ignoreip: ${ignore}"
    return 0
}

########################################################################
# 11. STAP: TMP - /tmp, /dev/shm en /var/tmp zonder exec/suid/dev
########################################################################

stap_tmp() {
    step_start tmp "/tmp, /dev/shm en /var/tmp beperken (nodev, nosuid, noexec)"

    # /tmp als tmpfs via systemd. De unit staat in /usr/share en telt daar
    # niet mee; een eigen kopie in /etc/systemd/system doet dat wel.
    if [[ -f /usr/share/systemd/tmp.mount || -f /etc/systemd/system/tmp.mount ]]; then
        {
            if [[ -f /etc/systemd/system/tmp.mount ]]; then
                cat /etc/systemd/system/tmp.mount
            else
                cat /usr/share/systemd/tmp.mount
            fi
        } | sed 's|^Options=.*|Options=mode=1777,strictatime,nosuid,nodev,noexec|' \
          | write_file /etc/systemd/system/tmp.mount 0644 \
          && REBOOT_NEEDED="ja"
        run systemctl daemon-reload
        run systemctl enable tmp.mount || warn "tmp.mount kon niet worden ingeschakeld."
        log "/tmp wordt bij de volgende start een tmpfs met nosuid,nodev,noexec"
    else
        warn "Geen tmp.mount gevonden; /tmp niet aangepast."
    fi

    # /dev/shm kan wel meteen.
    if ! grep -qE '^\S+\s+/dev/shm\s' /etc/fstab 2>/dev/null; then
        if [[ "$DRY_RUN" == "no" ]]; then
            printf 'tmpfs /dev/shm tmpfs defaults,nodev,nosuid,noexec 0 0\n' >>/etc/fstab
            log "Regel voor /dev/shm toegevoegd aan /etc/fstab"
        else
            log "[proef] zou /dev/shm aan /etc/fstab toevoegen"
        fi
    fi
    run mount -o remount,nodev,nosuid,noexec /dev/shm || warn "/dev/shm kon niet worden geremount."

    # /var/tmp koppelen aan /tmp, zodat het dezelfde beperkingen erft.
    if ! grep -qE '^\S+\s+/var/tmp\s' /etc/fstab 2>/dev/null; then
        if [[ "$DRY_RUN" == "no" ]]; then
            printf '/tmp /var/tmp none rw,noexec,nosuid,nodev,bind 0 0\n' >>/etc/fstab
            log "/var/tmp gekoppeld aan /tmp in /etc/fstab (actief na herstart)"
            REBOOT_NEEDED="ja"
        else
            log "[proef] zou /var/tmp aan /tmp koppelen in /etc/fstab"
        fi
    fi

    [[ "$DRY_RUN" == "no" ]] && event CHECK tmp "nu gemount: $(findmnt -no TARGET,OPTIONS /dev/shm 2>/dev/null | tr -s ' ' | head -1)"
    step_ok tmp "beperkingen staan klaar; /tmp en /var/tmp gelden na de eerstvolgende herstart"
    return 0
}

########################################################################
# 12. STAP: SUDO - auditspoor, geen wachtwoordloze escalatie
########################################################################

stap_sudo() {
    step_start sudo "sudo van een logboek voorzien en root op slot zetten"

    # Welke sudo staat hier? Ubuntu levert sinds 25.10 sudo-rs als standaard
    # (update-alternatives; de klassieke sudo staat er als *.ws naast). sudo-rs
    # kent 'logfile', 'log_year' en 'loglinelen' niet, en visudo keurt een
    # bestand met een enkele onbekende regel in zijn geheel af. Alles in een
    # keer aanbieden kost dan ook de regels die deze sudo wel kent - use_pty
    # voorop. Daarom: elke regel apart voorleggen en houden wat blijft staan.
    local impl tmp regel
    impl="$( { sudo --version 2>/dev/null || true; } | head -1)"
    log "sudo-implementatie: ${impl:-onbekend}"

    local -a gewenst=(
        'Defaults use_pty'
        'Defaults logfile="/var/log/sudo.log"'
        'Defaults log_year, loglinelen=0'
        'Defaults passwd_timeout=1'
        'Defaults timestamp_timeout=5'
    )
    local -a genomen=() geweigerd=()
    tmp="$(mktemp)"
    for regel in "${gewenst[@]}"; do
        printf '%s\n' "$regel" >"$tmp"
        if visudo -cqf "$tmp" >/dev/null 2>&1; then
            genomen+=("$regel")
        else
            geweigerd+=("${regel#Defaults }")
        fi
    done
    rm -f "$tmp"

    # Houdt deze sudo een eigen logboek bij? Zo nee, dan logt hij via PAM naar
    # /var/log/auth.log en heeft een leeg /var/log/sudo.log geen zin.
    SUDO_LOGFILE="nee"
    printf '%s\n' "${genomen[@]:-}" | grep -q '^Defaults logfile=' && SUDO_LOGFILE="ja"

    if (( ${#geweigerd[@]} > 0 )); then
        log "Deze sudo kent niet: ${geweigerd[*]}; die regels zijn overgeslagen"
    fi
    if (( ${#genomen[@]} > 0 )); then
        tmp="$(mktemp)"
        { printf '# Beheerd door beveilig.sh\n'; printf '%s\n' "${genomen[@]}"; } >"$tmp"
        if visudo -cqf "$tmp" 2>/dev/null; then
            cat "$tmp" | write_file "$SUDO_DROPIN" 0440 || true
        else
            warn "visudo keurde de sudo-regels af; ${SUDO_DROPIN} niet geschreven."
        fi
        rm -f "$tmp"
    else
        warn "deze sudo accepteert geen van de gewenste Defaults; ${SUDO_DROPIN} niet geschreven."
    fi

    # De gebruiker die dit script draait, krijgt een eigen drop-in met
    # wachtwoordloze sudo: verderop gaat het root-account op slot, en beheer op
    # afstand (ansible, cron, makevm.sh) leunt op 'sudo -n'. Aparte naam, zodat
    # het los staat van de Defaults hierboven en met de hand te verwijderen is.
    if [[ -n "$ADMIN_USER" ]] && ! [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        warn "Gebruikersnaam '${ADMIN_USER}' ziet er niet uit als een unix-account; ${USERS_DROPIN} niet geschreven."
        ADMIN_USER=""
    fi
    if [[ -n "$ADMIN_USER" ]] && ! id -u "$ADMIN_USER" >/dev/null 2>&1; then
        warn "Gebruiker '${ADMIN_USER}' bestaat niet op deze host; ${USERS_DROPIN} niet geschreven."
        ADMIN_USER=""
    fi
    if [[ -n "$ADMIN_USER" ]]; then
        tmp="$(mktemp)"
        {
            printf '# Beheerd door beveilig.sh\n'
            printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$ADMIN_USER"
        } >"$tmp"
        if visudo -cqf "$tmp" 2>/dev/null; then
            cat "$tmp" | write_file "$USERS_DROPIN" 0440 || true
        else
            warn "visudo keurde de regel voor '${ADMIN_USER}' af; ${USERS_DROPIN} niet geschreven."
            ADMIN_USER=""
        fi
        rm -f "$tmp"
    else
        log "Geen beheerder aangewezen; ${USERS_DROPIN} blijft zoals het was"
    fi

    # NOPASSWD: melden, en alleen weghalen als daar expliciet om gevraagd is.
    # De regel die we net zelf neerzetten telt niet mee: die is de bedoeling.
    local nopass
    nopass="$(grep -rlE 'NOPASSWD' /etc/sudoers /etc/sudoers.d/ 2>/dev/null \
        | grep -vxF "$USERS_DROPIN" | tr '\n' ' ' || true)"
    if [[ -z "$nopass" ]]; then
        log "Geen NOPASSWD-regels gevonden"
    elif [[ "$DROP_NOPASSWD" == "yes" ]]; then
        local f
        for f in $nopass; do
            [[ "$f" == "$SUDO_DROPIN" || "$f" == "$USERS_DROPIN" ]] && continue
            log "NOPASSWD weghalen uit ${f}"
            run sed -i 's/NOPASSWD://g; s/NOPASSWD //g' "$f"
        done
        visudo -c >/dev/null 2>&1 || warn "sudoers is na het aanpassen niet meer geldig; controleer met: visudo -c"
    else
        warn "NOPASSWD staat in: ${nopass}- laat staan (gebruik --drop-nopasswd om het weg te halen; let op: beheer via sudo -n breekt dan)."
    fi

    # root-account: geen wachtwoordlogin
    local rootstate
    rootstate="$(passwd -S root 2>/dev/null | awk '{print $2}')"
    if [[ "$rootstate" == "P" ]]; then
        run passwd -l root
        [[ "$DRY_RUN" == "no" ]] && log "root-account op slot gezet"
    else
        log "root-account stond al op slot (status ${rootstate:-onbekend})"
    fi

    local waar
    if [[ "$SUDO_LOGFILE" == "ja" ]]; then
        [[ "$DRY_RUN" == "no" ]] && { touch /var/log/sudo.log; chmod 0600 /var/log/sudo.log; }
        waar="/var/log/sudo.log"
    else
        # geen leeg /var/log/sudo.log achterlaten: dat suggereert een logboek
        # dat nooit volloopt, en auditd zou een bestand bewaken dat niets doet
        [[ "$DRY_RUN" == "no" && ! -s /var/log/sudo.log ]] && rm -f /var/log/sudo.log
        waar="/var/log/auth.log (via PAM; deze sudo kent geen eigen logbestand)"
    fi
    step_ok sudo "sudo logt naar ${waar}; root kan niet inloggen; wachtwoordloze sudo voor: ${ADMIN_USER:-niemand}"
    return 0
}

########################################################################
# 13. STAP: APPARMOR
########################################################################

stap_apparmor() {
    step_start apparmor "AppArmor controleren"

    run systemctl enable --now apparmor || warn "apparmor.service kon niet worden ingeschakeld."
    if [[ "$DRY_RUN" == "no" ]]; then
        if ! aa-status --enabled 2>/dev/null; then
            warn "AppArmor is niet actief in deze kernel; profielen doen niets."
            step_ok apparmor "apparmor geinstalleerd, maar niet actief"
            return 0
        fi
        local enforce complain
        enforce="$(aa-status 2>/dev/null | sed -n 's/.*\([0-9]\+\) profiles are in enforce mode.*/\1/p' | head -1)"
        complain="$(aa-status 2>/dev/null | sed -n 's/.*\([0-9]\+\) profiles are in complain mode.*/\1/p' | head -1)"
        event CHECK apparmor "profielen: ${enforce:-?} in enforce, ${complain:-?} in complain"
        [[ "${complain:-0}" != "0" ]] && warn "Er staan ${complain} profielen in complain mode; die loggen alleen."
    fi
    step_ok apparmor "AppArmor actief"
    return 0
}

########################################################################
# 14. STAP: AUDITD
########################################################################

stap_auditd() {
    step_start auditd "auditregels neerzetten"

    {
        cat <<'EOF'
## Beheerd door beveilig.sh
-D
-b 8192
-f 1
--backlog_wait_time 60000

## wie is wie
-w /etc/passwd -p wa -k identiteit
-w /etc/shadow -p wa -k identiteit
-w /etc/group -p wa -k identiteit
-w /etc/gshadow -p wa -k identiteit
-w /etc/security/opasswd -p wa -k identiteit

## verhoogde rechten
-w /etc/sudoers -p wa -k sudo
-w /etc/sudoers.d/ -p wa -k sudo
EOF
        # auditd weigert een -w op een pad dat niet bestaat, en waar sudo zijn
        # sporen laat verschilt per implementatie: de klassieke sudo kan een
        # eigen logboek bijhouden (Defaults logfile), sudo-rs laat dat aan PAM
        # over en dat schrijft in /var/log/auth.log. Dus: bewaken wat er is.
        [[ -e /var/log/sudo.log ]] && printf -- '-w /var/log/sudo.log -p wa -k sudo\n'
        [[ -e /var/log/auth.log ]] && printf -- '-w /var/log/auth.log -p wa -k sudo\n'
        cat <<'EOF'

## toegang op afstand
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/ssh/sshd_config.d/ -p wa -k sshd
-w /root/.ssh/ -p wa -k sshd
-w /var/log/faillog -p wa -k aanmelden
-w /var/log/lastlog -p wa -k aanmelden

## kernelmodules
-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k modules
-a always,exit -F arch=b32 -S init_module,finit_module,delete_module -k modules

## commando's die een gewone gebruiker als root uitvoert
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=4294967295 -k rootexec
-a always,exit -F arch=b32 -S execve -F euid=0 -F auid>=1000 -F auid!=4294967295 -k rootexec

## wijzigingen in tijd en netwerkidentiteit
-a always,exit -F arch=b64 -S clock_settime,settimeofday -k tijd
-w /etc/hosts -p wa -k netwerk
-w /etc/netplan/ -p wa -k netwerk
EOF
    } | write_file "$AUDIT_RULES" 0640 || true

    run systemctl enable auditd || warn "auditd start niet automatisch mee."
    if [[ "$DRY_RUN" == "no" ]]; then
        if command -v augenrules >/dev/null; then
            run augenrules --load || warn "augenrules --load gaf een fout."
        fi
        run systemctl restart auditd || warn "auditd kon niet worden herstart (dat mag ook via 'service auditd restart')."
        sleep 1
        local n
        n="$(auditctl -l 2>/dev/null | grep -c . || true)"
        event CHECK auditd "actieve auditregels: ${n:-0}"
        [[ "${n:-0}" == "0" ]] && warn "auditd heeft geen regels geladen; kijk met: auditctl -l"
    fi
    step_ok auditd "regels staan in ${AUDIT_RULES}"
    return 0
}

########################################################################
# 15. UITVOEREN
########################################################################

for stap in $STEPS_ALL; do
    if ! doet "$stap"; then
        step_skip "$stap" "overgeslagen op verzoek (--skip/--only)"
        continue
    fi
    # Een mislukte stap stopt de run niet: de rest is nog steeds winst, en
    # de RESULT-regel vertelt precies welke stap het niet haalde.
    "stap_${stap}" || true
done

CURRENT_STEP="einde"
cat <<EOF

$(log "Klaar.")
  Host          : ${HOSTNAME_SHORT} (${OS_NAME})
  Stappen       : ${N_OK} gedaan, ${N_SKIP} overgeslagen, ${N_WARN} waarschuwing(en), ${N_FAIL} mislukt
  Beheerder     : ${ADMIN_USER:-geen (sudo ongewijzigd)}${ADMIN_USER:+ (NOPASSWD in ${USERS_DROPIN})}
  ssh           : alleen publieke sleutels, vanaf ${SSH_ALLOW_FROM}
  Firewall      : ufw, binnenkomend dicht, IPv4 en IPv6
  Updates       : security-updates automatisch, herstart ${AUTO_REBOOT_TIME:-nooit}
  Herstart nodig: ${REBOOT_NEEDED}
  Log           : ${LOG_FILE:-(alleen scherm)}${STATUS_FILE:+
  Status        : ${STATUS_FILE}}
EOF
[[ "$DRY_RUN" == "yes" ]] && log "Dit was een proefdraai: er is niets gewijzigd."
[[ "$REBOOT_NEEDED" == "ja" ]] && log "Herstart deze host als het uitkomt; /tmp en /var/tmp gelden pas daarna."

(( N_FAIL > 0 )) && exit 1
(( N_WARN > 0 )) && exit 3
exit 0
