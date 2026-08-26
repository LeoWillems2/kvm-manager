#!/usr/bin/env bash
#
# makevm.sh - maakt een KVM/QEMU VM aan via libvirt (virsh/virt-install).
#
# Twee routes:
#   1. Bestaat er nog geen base-image ({naam}-base.qcow2 in de pool), dan wordt
#      de VM volledig onbeheerd geinstalleerd vanaf de install-ISO (Ubuntu
#      autoinstall via een cloud-init NoCloud seed). Zodra de VM bereikbaar is
#      wordt hij netjes gestopt en wordt de qcow2 gekopieerd naar
#      {naam}-base.qcow2; daarna start de VM weer.
#   2. Bestaat het base-image al, dan wordt de nieuwe VM daaruit gekloond en
#      krijgt hij via cloud-init zijn eigen naam, IP, MAC, ssh-hostkeys en
#      machine-id. Dat scheelt een complete installatie.
#
# Software in de VM: ssh (alleen keys, geen wachtwoord), fail2ban, ufw.
#
# Elke VM krijgt de qemu-guest-agent mee: het virtio-kanaal
# org.qemu.guest_agent.0 in de domeindefinitie (virtinstall_common) en het
# pakket qemu-guest-agent in de gast (EXTRA_PACKAGES, en een kloon erft het uit
# het base-image). Na de ssh-controle wordt gecontroleerd of die agent ook
# echt antwoordt en kan bevriezen. Zonder agent is een snapshot hooguit
# crash-consistent: bruikbaar, maar bij het terugzetten doet het filesystem
# journal-replay en kan een database in de gast inconsistent zijn. Met een
# werkende agent slaagt --quiesce en wordt het filesystem tijdens het
# snapshotten bevroren - dat duurt milliseconden.
#
# Daarna draait beveilig.sh in de gast
# (via de qemu-guest-agent): apt update + dist-upgrade, automatische
# security-updates, sysctl-hardening, strakke sshd, ufw met IPv6, fail2ban,
# beperkte tmp-mounts, sudo-logging, apparmor en auditd. Dat gebeurt voordat
# het base-image wordt gemaakt, dus elke kloon erft het. Zie beveilig.sh -h;
# dat script is ook los te draaien op een bestaande host.
#
# Sleutels komen uit deze map (SSH_KEY_DIR): alle publieke sleutels uit
# authorized_keys plus de publieke helft van id_ed25519.
#
# De install-ISO wordt niet gekopieerd; die moet in ISO_DIR staan.
#
# Elke stap meldt zich met een vaste, machineleesbare regel (zie deel 2) op
# het scherm en in een logbestand, zodat te volgen is waar een run staat en
# waarom hij eventueel niet is afgemaakt.
#
# Gebruik:  sudo ./makevm.sh -n naam -i ip [-d GB] [-b base] [--iso x] [-y]
#           sudo ./makevm.sh -r NAAM            # VM en boekhouding opruimen
#           sudo ./makevm.sh -m OUD NIEUW       # VM en boekhouding hernoemen
#
set -Eeuo pipefail

########################################################################
# 1. DEFINITIE - pas hier aan
########################################################################

# Naam en adres komen altijd van de opdrachtregel (-n en -i); deze twee
# waarden zijn alleen een voorbeeld van de vorm die verwacht wordt.
Hostname="demo"
IPaddress="192.168.100.77"
ISO="ubuntu-26.04-live-server-amd64.iso"

# --- netwerk (libvirt-netwerk "tthomlw": 192.168.100.0/24) ---
LIBVIRT_NET="tthomlw"
NETMASK_PREFIX="24"
GATEWAY="192.168.100.1"
DNS_SERVERS="192.168.100.1,1.1.1.1"
SEARCH_DOMAIN="tthomlw"

# Hoe krijgt de VM zijn adres?
#   static      = vast IP in de guest, libvirt weet van niets
#   reservation = guest doet DHCP, libvirt/dnsmasq geeft MAC -> IP vast uit
#   both        = vast IP in de guest EN een reservering in libvirt (voor DNS)
IP_MODE="static"

# --- hardware van de VM ---
VCPUS="2"
RAM_MB="4096"
DISK_GB="10"                      # standaard; overschrijf met -d/--disk-size GB
MACHINE="q35"
CPU_MODEL="host-passthrough,check=none,migratable=on"
OS_VARIANT="ubuntu25.10"          # nieuwste variant in de lokale osinfo-db
GRAPHICS="spice,listen=127.0.0.1"
VIDEO="virtio"

# --- opslag / paden ---
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
POOL_DIR="/t/kvm"                 # libvirt-pool "kvm"
ISO_DIR="${POOL_DIR}/iso"         # hier staan de install-ISO's
BASE_NAME=""                      # leeg => {Hostname}-base.qcow2; of -b NAAM|PAD

# Schijfindeling bij een volledige installatie:
#   lvm    = ext4 op LVM (Ubuntu-standaard), direct = een enkele ext4 root
# LVM_SIZING: all = root-LV vult de hele VG, scaled = subiquity-standaard
STORAGE_LAYOUT="lvm"
LVM_SIZING="all"

# --- account en ssh-sleutels op de nieuwe VM ---
ADMIN_USER="leo"
ADMIN_PWHASH=""                   # leeg => script vraagt erom bij een full build
SSH_KEY_DIR="${SCRIPT_DIR}"
SSH_AUTH_KEYS_FILE="${SSH_KEY_DIR}/authorized_keys"
SSH_PRIVKEY_FILE="${SSH_KEY_DIR}/id_ed25519"

# --- beveiliging ---
# Los script met alle maatregelen (blok A). makevm.sh zet het in de gast neer
# en draait het daar; zo staat alles op een plek en kunt u het ook los op een
# bestaande host draaien.
HARDEN_SCRIPT="${SCRIPT_DIR}/beveilig.sh"
HARDEN="yes"                      # met --no-harden overslaan

# --- firewall ---
# "any" of een spatiegescheiden lijst, bijv. "192.168.100.0/24 10.8.0.5"
SSH_ALLOW_FROM="any"

# --- installatiekeuzes ---
TIMEZONE="Europe/Amsterdam"
LOCALE="en_US.UTF-8"
KEYBOARD_LAYOUT="us"
EXTRA_PACKAGES="qemu-guest-agent"  # naast openssh-server, fail2ban, ufw
AUTOSTART="yes"                    # VM starten bij boot van de host
ASSUME_YES="no"                    # geen vragen stellen (ook: -y)
SSH_WAIT_SECS="900"                # hoe lang wachten tot de VM ssh accepteert

# Oude hostkeys van dit IP/deze naam uit known_hosts halen en de nieuwe
# hostkey toevoegen (van root en van de gebruiker achter sudo).
MANAGE_KNOWN_HOSTS="yes"

# --- logging en bewaking ---
LOG_DIR="${SCRIPT_DIR}/logs"      # hierin komen het log- en het statusbestand
LOG_FILE=""                       # leeg => ${LOG_DIR}/makevm-{naam}-{tijd}.log
                                  # "-"  => niet naar bestand loggen
STATUS_FILE=""                    # leeg => ${LOG_DIR}/makevm-{naam}.status
HEARTBEAT_SECS="60"               # hoe vaak een WAIT-regel tijdens lang wachten

########################################################################
# 2. LOGGING EN CONTROLEMELDINGEN
########################################################################
#
# Elke stap meldt zich met een vaste regel, te lezen door een mens en door
# een bewakende agent:
#
#   2026-08-20T13:22:01+02:00 [makevm] run=... vm=demo step=base-image \
#       status=START duur=12s msg="base-image maken uit /t/kvm/demo.qcow2"
#
# status is er een uit:
#   PLAN   - de stappen die deze run gaat doen (staat bovenaan het log)
#   START  - stap begonnen              OK     - stap geslaagd
#   INFO   - detailregel binnen een stap SKIP  - stap overgeslagen (met reden)
#   WAIT   - hartslag tijdens lang wachten (elke ${HEARTBEAT_SECS}s)
#   CHECK  - controle op een resultaat (bestaat het base-image echt?)
#   WARN   - niet fataal, wel opletten  FAIL   - stap mislukt
#   RESULT - eindregel met exitcode en de checklist van de hele run
#
# Het logbestand krijgt alle regels; het scherm houdt INFO kort. De huidige
# stand staat bovendien in het statusbestand, zodat een bewakende agent met
# een enkele cat ziet waar de run is:
#
#   tail -f ${LOG_DIR}/makevm-{naam}-laatste.log     # meelezen
#   cat     ${LOG_DIR}/makevm-{naam}.status          # huidige stap
#
# Een run is pas goed afgelopen als de laatste regel status=RESULT en
# result=ok bevat. Ontbreekt die regel, dan is het script afgebroken of nog
# bezig: kijk dan naar de laatste START/WAIT-regel om te zien waar.
# Exitcodes: 0 = klaar, 1 = fout, 2 = VM draait maar het base-image ontbreekt.

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
RUN_STARTED="$(date +%Y-%m-%dT%H:%M:%S%:z)"
CURRENT_STEP="start"
STEP_STARTED_AT="$(date +%s)"
HEARTBEAT_PID=""
FAILED_STEP=""
BASE_OK="onbekend"                # ja | nee | n.v.t. | onbekend
BASE_EXPECTED="onbekend"
ACTIVE="nee"
RESIZED="no"                      # is de kloonschijf groter gemaakt dan de base?

_ts()  { date +%Y-%m-%dT%H:%M:%S%:z; }
_now() { date +%s; }

# Huidige stand wegschrijven; tmp+mv zodat een lezer nooit een halve regel ziet
status_write() {
    [[ -n "${STATUS_FILE:-}" ]] || return 0
    # Eigen tmp-naam per proces: de hartslag schrijft hier ook in. De naam moet
    # vooraf in een variabele, want bash vult $BASHPID in een omleiding pas na
    # de fork in - cat en mv zouden dan elk een ander bestand pakken.
    local tmp="${STATUS_FILE}.${BASHPID}.tmp"
    {
        cat >"$tmp" <<EOF
run=${RUN_ID}
pid=$$
vm=${Hostname}
ip=${IPaddress}
gestart=${RUN_STARTED}
bijgewerkt=$(_ts)
step=${1}
status=${2}
msg=${3}
route=${BUILD_MODE:-onbekend}
base_image=${BASE_IMAGE:-onbekend}
base_gemaakt=${BASE_OK}
ssh_bereikbaar=${ACTIVE}
log=${LOG_FILE:-geen}
EOF
        mv "$tmp" "$STATUS_FILE"
        chmod 0644 "$STATUS_FILE"
    } 2>/dev/null || true
    return 0
}

# event STATUS STAP BOODSCHAP [sleutel=waarde ...]
event() {
    local status="$1" step="$2" msg="$3"; shift 3
    local extra="$*" color line screen
    msg="${msg//$'\n'/ }"; msg="${msg//\"/\'}"
    line="$(_ts) [makevm] run=${RUN_ID} vm=${Hostname} step=${step} status=${status}"
    [[ -n "$extra" ]] && line+=" ${extra}"
    line+=" msg=\"${msg}\""
    case "$status" in
        FAIL)       color="1;31" ;;
        WARN)       color="1;33" ;;
        OK|RESULT)  color="1;32" ;;
        WAIT)       color="0;36" ;;
        INFO)       color="1;32" ;;
        *)          color="1;34" ;;
    esac
    # op het scherm blijft een detailregel kort; het log krijgt de hele regel
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
warn() { event WARN "$CURRENT_STEP" "$*"; }
die()  { FAILED_STEP="$CURRENT_STEP"; event FAIL "$CURRENT_STEP" "$*"; exit 1; }

step_start() { CURRENT_STEP="$1"; STEP_STARTED_AT="$(_now)"; event START "$1" "${2:-begonnen}"; }
step_ok()    { event OK   "${1:-$CURRENT_STEP}" "${2:-klaar}" "duur=$(( $(_now) - STEP_STARTED_AT ))s"; }
step_skip()  { event SKIP "$1" "$2"; }
step_fail()  { FAILED_STEP="$1"; event FAIL "$1" "$2" "duur=$(( $(_now) - STEP_STARTED_AT ))s"; }

# Voert een commando uit en schrijft alle uitvoer ook naar het logbestand,
# zodat een bewakende agent ziet wat virt-install of qemu-img zei.
logged() {
    local rc
    [[ -n "${LOG_FILE:-}" ]] || { "$@"; return $?; }
    set +e
    "$@" 2>&1 | tee -a "$LOG_FILE"
    rc=${PIPESTATUS[0]}
    set -e
    return "$rc"
}

# Hartslag tijdens iets dat lang duurt en zelf niets zegt (installatie,
# kopieren). Zonder deze regels is een vastgelopen run niet te onderscheiden
# van een run die gewoon nog bezig is.
heartbeat_start() {
    local step="$1" what="$2" iv="${3:-$HEARTBEAT_SECS}"
    heartbeat_stop
    (
        local waited=0 dom
        while sleep "$iv"; do
            waited=$(( waited + iv ))
            dom="$(virsh domstate "$Hostname" 2>/dev/null | head -1 | tr ' ' '-')"
            event WAIT "$step" "$what" "wacht=${waited}s" "domstate=${dom:-onbekend}"
        done
    ) &
    HEARTBEAT_PID=$!
    return 0
}
heartbeat_stop() {
    [[ -n "$HEARTBEAT_PID" ]] || return 0
    kill "$HEARTBEAT_PID" 2>/dev/null || true
    wait "$HEARTBEAT_PID" 2>/dev/null || true
    HEARTBEAT_PID=""
    return 0
}

# Logbestand en statusbestand klaarzetten; het symlink -laatste.log geeft de
# bewaker een vast pad om te volgen.
init_logging() {
    if [[ "$LOG_FILE" == "-" ]]; then LOG_FILE=""; STATUS_FILE=""; return 0; fi
    if [[ -z "$LOG_FILE" ]]; then
        mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/var/tmp"
        mkdir -p "$LOG_DIR" 2>/dev/null || { warn "Kan ${LOG_DIR} niet maken; alleen schermuitvoer."; LOG_FILE=""; return 0; }
        LOG_FILE="${LOG_DIR}/makevm-${Hostname}-$(date +%Y%m%d-%H%M%S).log"
    else
        LOG_DIR="$(dirname "$LOG_FILE")"
        mkdir -p "$LOG_DIR" 2>/dev/null || true
    fi
    [[ -z "$STATUS_FILE" ]] && STATUS_FILE="${LOG_DIR}/makevm-${Hostname}.status"
    if ! : >"$LOG_FILE" 2>/dev/null; then
        warn "Kan niet naar ${LOG_FILE} schrijven; alleen schermuitvoer."
        LOG_FILE=""; STATUS_FILE=""; return 0
    fi
    chmod 0644 "$LOG_FILE" 2>/dev/null || true
    ln -sfn "$LOG_FILE" "${LOG_DIR}/makevm-${Hostname}-laatste.log" 2>/dev/null || true
    # het script draait als root; de logs blijven van de gebruiker achter sudo
    [[ -n "${SUDO_USER:-}" ]] && chown -h "$SUDO_USER" "$LOG_DIR" "$LOG_FILE" \
        "${LOG_DIR}/makevm-${Hostname}-laatste.log" 2>/dev/null
    return 0
}

# De stappen die deze run gaat zetten, zodat de bewaker weet wat er nog moet
# komen en welke melding dus ontbreekt als het misgaat.
plan_steps() {
    local steps="preflight"
    [[ "$REBUILD_BASE" == "yes" ]] && steps+=",base-opruimen"
    steps+=",ssh-sleutels"
    [[ "$IP_MODE" == "reservation" || "$IP_MODE" == "both" ]] && steps+=",dhcp-reservering"
    if [[ "$BUILD_MODE" == "clone" ]]; then
        steps+=",kloon-seed,kloon-schijf,vm-aanmaken"
    else
        steps+=",install-seed,schijf-aanmaken,installatie,eerste-start"
    fi
    steps+=",ssh-controle,agent-controle"
    [[ "$HARDEN" == "yes" ]] && steps+=",beveiligen,ssh-nacontrole"
    if [[ "$BASE_EXPECTED" == "yes" ]]; then
        steps+=",sjabloon-voorbereiden,base-image,base-controle,herstel-na-base,ssh-hercontrole"
    fi
    steps+=",einde"
    event PLAN run "stappen van deze run" "route=${BUILD_MODE}" "base_verwacht=${BASE_EXPECTED}" "stappen=${steps}"
}

# Onverwachte fout (set -e): melden welke regel en welk commando struikelde,
# in plaats van er stilzwijgend mee te stoppen.
on_err() {
    local rc="$1" line="$2" cmd="$3"
    heartbeat_stop
    FAILED_STEP="$CURRENT_STEP"
    event FAIL "$CURRENT_STEP" "onverwachte fout bij: ${cmd}" "exit=${rc}" "regel=${line}"
    return 0
}

# Eindregel: altijd, ook bij ctrl-c of een harde fout. Hierin staat wat er
# wel en niet is opgeleverd - de bewaker hoeft niets af te leiden.
on_exit() {
    local rc=$?
    trap - EXIT ERR
    heartbeat_stop
    # niets te melden als het script alleen -h/--help heeft gedaan
    [[ "$CURRENT_STEP" == "start" && $rc -eq 0 ]] && exit 0
    [[ -n "${WORKDIR:-}" ]] && rm -rf "$WORKDIR"
    local vm_def="nee" vm_state="-" disk="nee" base="nee" result
    if virsh dominfo "$Hostname" &>/dev/null; then
        vm_def="ja"
        vm_state="$(virsh domstate "$Hostname" 2>/dev/null | head -1 | tr ' ' '-')"
    fi
    [[ -n "${DISK_PATH:-}"  && -e "${DISK_PATH:-}"  ]] && disk="ja"
    [[ -n "${BASE_IMAGE:-}" && -e "${BASE_IMAGE:-}" ]] && base="ja"
    case "$rc" in
        0) result="ok" ;;
        2) result="base-image-ontbreekt" ;;
        *) result="fout" ;;
    esac
    [[ "$base" == "nee" && "${BASE_EXPECTED}" == "yes" && "$result" == "ok" ]] && result="base-image-ontbreekt"
    event RESULT einde "run afgerond" \
        "result=${result}" "exit=${rc}" "mislukte_stap=${FAILED_STEP:-geen}" \
        "vm_gedefinieerd=${vm_def}" "vm_status=${vm_state}" \
        "schijf=${disk}" "ssh_bereikbaar=${ACTIVE}" "agent=${AGENT_OK:-onbekend}" \
        "base_verwacht=${BASE_EXPECTED}" "base_aanwezig=${base}" \
        "base_pad=${BASE_IMAGE:-onbekend}" "log=${LOG_FILE:-geen}"
    exit "$rc"
}

trap 'on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR
trap on_exit EXIT
# ctrl-c, kill of een wegvallende terminal (HUP) niet stilzwijgend laten
# gebeuren; anders eindigt het log midden in een stap zonder RESULT-regel
trap 'FAILED_STEP="$CURRENT_STEP"; event FAIL "$CURRENT_STEP" "afgebroken door signaal INT (ctrl-c)"; exit 130' INT
trap 'FAILED_STEP="$CURRENT_STEP"; event FAIL "$CURRENT_STEP" "afgebroken door signaal TERM"; exit 143' TERM
trap 'FAILED_STEP="$CURRENT_STEP"; event FAIL "$CURRENT_STEP" "afgebroken door signaal HUP (terminal weg?); start lange runs met: setsid nohup ./makevm.sh ..."; exit 129' HUP

########################################################################
# 3. PARAMETERS
########################################################################

confirm() {
    [[ "$ASSUME_YES" == "yes" ]] && return 0
    local answer
    read -rp "$1 [j/N] " answer
    [[ "$answer" =~ ^([jJ]|[yY])$ ]]
}

usage() {
    cat <<EOF
Gebruik: $(basename "$0") -n NAAM -i ADRES [opties]

  -n, --name NAAM      naam/hostname van de VM        (verplicht bij bouwen)
  -i, --ip ADRES       IPv4-adres van de VM           (verplicht bij bouwen)
  -d, --disk-size GB   grootte van de systeemschijf in GiB (standaard: ${DISK_GB})
  -b, --base NAAM|PAD  base-image om uit te klonen (standaard: {naam}-base.qcow2)
      --iso BESTAND    install-ISO in ${ISO_DIR} (standaard: ${ISO})
      --no-base        geen base-image aanmaken/gebruiken, altijd volledig installeren
      --rebuild-base   bestaand base-image weggooien en opnieuw opbouwen uit een
                       volledige installatie (in plaats van eruit klonen)
      --no-harden      beveilig.sh niet in de nieuwe VM draaien (standaard wel,
                       in beide routes; zie beveilig.sh -h voor wat het doet)
      --no-known-hosts known_hosts van root/${SUDO_USER:-de gebruiker} niet aanpassen
      --log BESTAND    logbestand (standaard: ${LOG_DIR}/makevm-{naam}-{tijd}.log,
                       "-" = alleen schermuitvoer)
      --heartbeat SEC  hoe vaak een WAIT-regel tijdens lang wachten (nu: ${HEARTBEAT_SECS})
  -y, --yes            geen bevestiging vragen (bestaande VM wordt opgeruimd)
  -h, --help           deze hulptekst

Beheren in plaats van bouwen (deze twee bouwen niets):
  -r, --remove NAAM    VM opruimen: domein (incl. nvram, managed-save en
                       snapshots), schijf, seed-iso, DHCP-reservering en de
                       known_hosts-regels. Het base-image wordt apart gevraagd.
  -m, --move OUD NIEUW VM hernoemen: qcow2, pad in de XML, domeinnaam en
                       autostart. De gast houdt binnenin zijn eigen hostname
                       en zijn IP-adres; die blijven ongemoeid.
  Let op: met -y worden ook hier alle vragen met ja beantwoord, ook die over
  het weggooien of hernoemen van {naam}-base.qcow2.

Meelezen tijdens een run:
  tail -f ${LOG_DIR}/makevm-{naam}-laatste.log
  cat     ${LOG_DIR}/makevm-{naam}.status

Overige instellingen staan als variabelen bovenaan het script.
EOF
}

USE_BASE="yes"
REBUILD_BASE="no"
REMOVE_MODE="no"                  # -r: opruimen in plaats van bouwen
MOVE_TO=""                        # -m: nieuwe naam; leeg = niet hernoemen
MANAGE_MODE="no"                  # -r of -m: deze run bouwt niets
NAME_GIVEN="no"                   # is -n meegegeven? (verplicht bij bouwen)
IP_GIVEN="no"                     # is -i meegegeven? (verplicht bij bouwen)
DISK_GIVEN="no"                   # is -d meegegeven? (alleen voor de melding)

# Zonder argumenten niets doen. De waarden bovenaan dit script zijn een
# vertrekpunt, geen opdracht: wie hier per ongeluk op enter drukt, zou anders
# een VM '${Hostname}' op ${IPaddress} bouwen en een bestaande van die naam
# aangeboden krijgen om op te ruimen.
if [[ $# -eq 0 ]]; then
    usage >&2
    die "Geef op zijn minst -n NAAM en -i ADRES mee (of -r NAAM / -m OUD NIEUW); zonder argumenten doet dit script niets."
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--disk-size) DISK_GB="${2:-}"; DISK_GIVEN="yes"; shift 2 ;;
        -n|--name)      Hostname="${2:-}"; NAME_GIVEN="yes"; shift 2 ;;
        -i|--ip)        IPaddress="${2:-}"; IP_GIVEN="yes"; shift 2 ;;
        -b|--base)      BASE_NAME="${2:-}"; shift 2 ;;
        --iso)          ISO="${2:-}"; shift 2 ;;
        --no-base)      USE_BASE="no"; shift ;;
        --rebuild-base) REBUILD_BASE="yes"; shift ;;
        -r|--remove)    [[ -n "${2:-}" && "${2:-}" != -* ]] || { usage >&2; die "-r/--remove heeft een naam nodig: -r NAAM."; }
                        REMOVE_MODE="yes"; Hostname="$2"; shift 2 ;;
        -m|--move)      [[ -n "${2:-}" && "${2:-}" != -* && -n "${3:-}" && "${3:-}" != -* ]] \
                            || { usage >&2; die "-m/--move heeft twee namen nodig: -m OUD NIEUW."; }
                        Hostname="$2"; MOVE_TO="$3"; shift 3 ;;
        --no-harden)    HARDEN="no"; shift ;;
        --no-known-hosts) MANAGE_KNOWN_HOSTS="no"; shift ;;
        --log)          LOG_FILE="${2:-}"; shift 2 ;;
        --heartbeat)    HEARTBEAT_SECS="${2:-}"; shift 2 ;;
        -y|--yes)       ASSUME_YES="yes"; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              usage >&2; die "Onbekende optie: $1" ;;
    esac
done

[[ "$USE_BASE" == "no" && "$REBUILD_BASE" == "yes" ]] && \
    die "--no-base en --rebuild-base gaan niet samen: de eerste maakt geen base-image, de tweede juist een nieuwe."

# -r en -m zijn beheermodi: die bouwen niets, dus bouwopties horen er niet bij
if [[ "$REMOVE_MODE" == "yes" || -n "$MOVE_TO" ]]; then
    MANAGE_MODE="yes"
    [[ "$REMOVE_MODE" == "yes" && -n "$MOVE_TO" ]] && \
        die "-r en -m gaan niet samen: kies opruimen of hernoemen."
    [[ "$REBUILD_BASE" == "yes" ]] && \
        die "--rebuild-base hoort bij het bouwen van een VM, niet bij -r/-m."
    [[ "$USE_BASE" == "no" ]] && \
        die "--no-base hoort bij het bouwen van een VM, niet bij -r/-m."
    [[ "$DISK_GIVEN" == "yes" ]] && \
        die "-d hoort bij het bouwen van een VM, niet bij -r/-m."
    [[ "$HARDEN" == "no" ]] && \
        die "--no-harden hoort bij het bouwen van een VM, niet bij -r/-m."
fi
# Bouwen doet het script nooit op eigen houtje: naam en adres moeten van de
# opdrachtregel komen. Anders zou een run zonder -n/-i de VM uit deel 1
# bouwen - en een bestaande VM met die naam aanbieden om op te ruimen.
if [[ "$MANAGE_MODE" == "no" ]]; then
    [[ "$NAME_GIVEN" == "yes" ]] || \
        die "Geef de naam van de VM mee met -n NAAM; er is geen standaardnaam."
    [[ "$IP_GIVEN" == "yes" ]] || \
        die "Geef het adres van de VM mee met -i ADRES; er is geen standaardadres."
fi

if [[ -n "$MOVE_TO" ]]; then
    [[ "$MOVE_TO" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || \
        die "Ongeldige nieuwe hostname: '${MOVE_TO}'."
    [[ "$MOVE_TO" != "$Hostname" ]] || \
        die "Oude en nieuwe naam zijn gelijk ('${Hostname}'); niets te hernoemen."
fi

[[ "$DISK_GB" =~ ^[0-9]+$ ]] || die "Disksize moet een geheel getal in GiB zijn (kreeg: '${DISK_GB}')."
(( DISK_GB >= 10 )) || die "Disksize van ${DISK_GB}G is te klein voor Ubuntu Server; gebruik minimaal 10."
[[ "$IPaddress" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Ongeldig IP-adres: '${IPaddress}'."
[[ "$Hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || die "Ongeldige hostname: '${Hostname}'."
[[ "$HEARTBEAT_SECS" =~ ^[0-9]+$ ]] && (( HEARTBEAT_SECS > 0 )) || die "--heartbeat moet een aantal seconden zijn."

########################################################################
# 4. AFGELEIDE WAARDEN
########################################################################

DISK_PATH="${POOL_DIR}/${Hostname}.qcow2"
SEED_ISO="${ISO_DIR}/${Hostname}-seed.iso"
INSTALL_ISO="${ISO_DIR}/${ISO}"

case "$BASE_NAME" in
    "")  BASE_IMAGE="${POOL_DIR}/${Hostname}-base.qcow2" ;;
    */*) BASE_IMAGE="$BASE_NAME" ;;
    *)   BASE_IMAGE="${POOL_DIR}/${BASE_NAME%-base.qcow2}-base.qcow2" ;;
esac

ip2int() { local IFS=.; read -r a b c d <<<"$1"; echo $(( (a<<24)|(b<<16)|(c<<8)|d )); }
int2ip() { local i=$1; echo "$(( (i>>24)&255 )).$(( (i>>16)&255 )).$(( (i>>8)&255 )).$(( i&255 ))"; }

# MAC deterministisch afgeleid van het IP-adres (52:54:00:<o2>:<o3>:<o4>)
IFS='.' read -r _o1 _o2 _o3 _o4 <<<"${IPaddress}"
MAC="$(printf '52:54:00:%02x:%02x:%02x' "$_o2" "$_o3" "$_o4")"

# Netwerkadres, voor de ufw- en fail2ban-regels
_mask=$(( 0xFFFFFFFF ^ ((1 << (32 - NETMASK_PREFIX)) - 1) ))
NETWORK_CIDR="$(int2ip $(( $(ip2int "$IPaddress") & _mask )))/${NETMASK_PREFIX}"

# known_hosts-bestanden die het script bijwerkt, als "gebruiker:pad"
KNOWN_HOSTS_ENTRIES=("root:/root/.ssh/known_hosts")
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    _sudo_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    [[ -n "$_sudo_home" ]] && KNOWN_HOSTS_ENTRIES+=("${SUDO_USER}:${_sudo_home}/.ssh/known_hosts")
fi

########################################################################
# 4B. BEHEERMODI (-r en -m) EN DE FUNCTIES DIE ZE MET DE BOUW DELEN
########################################################################
#
# -r en -m bouwen niets. Ze raken alleen de boekhouding van libvirt en de
# bestanden die daarbij horen: de domeindefinitie, de qcow2, de seed-iso, de
# DHCP-reservering en de known_hosts-regels van de host. Wat er binnen in de
# gast staat (hostname, IP-adres) blijft ongemoeid.
#
# Deel 5 roept deze twee aan zodra de host- en netwerkcontroles gedaan zijn,
# dus staan ze hier: bash kent een functie pas nadat de definitie is gelezen.
# De known_hosts-functies en wait_for_shutoff staan om dezelfde reden hier en
# niet meer in deel 6; de bouwroutes verderop gebruiken ze ook.

# --- known_hosts ------------------------------------------------------
#
# Een nieuwe of opnieuw gebouwde VM krijgt verse ssh-hostkeys op een adres
# dat vaak al eerder in gebruik was. StrictHostKeyChecking=no helpt daar
# niet tegen: ssh weigert een *gewijzigde* hostkey altijd. Daarom negeert
# het script zelf alle known_hosts-bestanden, en ruimt het de oude regels
# op in de bestanden van root en van de gebruiker achter sudo.

# Namen waaronder deze VM in known_hosts kan staan. Bij -r is het adres soms
# niet te achterhalen; een lege naam wordt overgeslagen, want ssh-keygen -R ""
# zou dan zomaar de verkeerde regel te pakken kunnen krijgen.
known_hosts_names() {
    local n
    for n in "$IPaddress" "$Hostname" "${Hostname}.${SEARCH_DOMAIN}"; do
        [[ -n "$n" ]] && printf '%s\n' "$n"
    done
    return 0
}

# Oude regels weggooien (werkt ook bij gehashte known_hosts)
known_hosts_forget() {
    [[ "$MANAGE_KNOWN_HOSTS" == "yes" ]] || return 0
    local entry f name found
    for entry in "${KNOWN_HOSTS_ENTRIES[@]}"; do
        f="${entry#*:}"
        [[ -f "$f" ]] || continue
        found=""
        while read -r name; do
            if ssh-keygen -F "$name" -f "$f" >/dev/null 2>&1; then
                ssh-keygen -R "$name" -f "$f" >/dev/null 2>&1 || true
                found+="${name} "
            fi
        done < <(known_hosts_names)
        rm -f "${f}.old"
        [[ -n "$found" ]] && log "Oude hostkeys verwijderd uit ${f}: ${found}"
    done
    return 0
}

# Nieuwe hostkey ophalen en toevoegen, zodat inloggen meteen werkt
known_hosts_learn() {
    [[ "$MANAGE_KNOWN_HOSTS" == "yes" ]] || return 0
    local keys entry user f name targets=("$IPaddress")
    # ook op naam, als die naar dit adres resolvet
    for name in "$Hostname" "${Hostname}.${SEARCH_DOMAIN}"; do
        [[ "$(getent hosts "$name" 2>/dev/null | awk '{print $1}' | head -1)" == "$IPaddress" ]] \
            && targets+=("$name")
    done
    keys="$(ssh-keyscan -H -T 10 -t ed25519,rsa "${targets[@]}" 2>/dev/null || true)"
    [[ -n "$keys" ]] || { warn "Kon geen hostkey ophalen van ${IPaddress}; known_hosts niet bijgewerkt."; return 0; }
    for entry in "${KNOWN_HOSTS_ENTRIES[@]}"; do
        user="${entry%%:*}"; f="${entry#*:}"
        install -d -m 0700 -o "$user" -g "$(id -gn "$user")" "$(dirname "$f")"
        printf '%s\n' "$keys" >>"$f"
        chown "${user}:$(id -gn "$user")" "$f"
        chmod 0600 "$f"
        log "Hostkey van ${IPaddress} toegevoegd aan ${f}"
    done
    return 0
}

# Wacht tot het domein uit staat, forceer daarna
wait_for_shutoff() {
    local secs="${1:-180}" waited=0 next="$HEARTBEAT_SECS"
    while (( waited < secs )); do
        if [[ "$(virsh domstate "$Hostname" 2>/dev/null)" == "shut off" ]]; then
            event CHECK "$CURRENT_STEP" "VM '${Hostname}' staat uit" "wacht=${waited}s"
            return 0
        fi
        sleep 5; waited=$(( waited + 5 ))
        if (( waited >= next )); then
            next=$(( next + HEARTBEAT_SECS ))
            event WAIT "$CURRENT_STEP" "wachten tot '${Hostname}' uit staat" \
                "wacht=${waited}s" "resterend=$(( secs - waited ))s"
        fi
    done
    warn "VM stopte niet binnen $((secs))s; hard afsluiten."
    virsh destroy "$Hostname" >/dev/null 2>&1 || true
    sleep 3
    [[ "$(virsh domstate "$Hostname" 2>/dev/null)" == "shut off" ]] \
        && event CHECK "$CURRENT_STEP" "VM '${Hostname}' hard afgesloten" \
        || event WARN  "$CURRENT_STEP" "VM '${Hostname}' staat nog steeds niet uit"
    return 0
}

# Virtuele grootte van een schijfbestand, in bytes. Bewust niet uit de
# JSON-uitvoer van qemu-img: daarin staat eerst de grootte van het bestand
# zelf (onder "children") en pas daarna die van het image, dus las het
# script 197632 bytes waar 45G bedoeld was. De gewone uitvoer zet het
# aantal bytes tussen haakjes achter de leesbare maat.
image_virtual_bytes() {
    qemu-img info "$1" 2>/dev/null \
        | sed -n 's/^virtual size: .*(\([0-9]\+\) bytes).*/\1/p' | head -1
}

# --- kleine helpers voor -r en -m -------------------------------------

# Bestanden die als schijf in de definitie van een domein staan (geen cdrom).
domain_disk_files() {
    virsh domblklist "$1" --details 2>/dev/null | awk '$1=="file" && $2=="disk" && $4!="-" {print $4}'
}

# Bestanden die als cdrom in de definitie staan (seed-iso, install-iso).
domain_cdrom_files() {
    virsh domblklist "$1" --details 2>/dev/null | awk '$1=="file" && $2=="cdrom" && $4!="-" {print $4}'
}

# De MAC uit de definitie. Die is betrouwbaarder dan de MAC die deel 4 uit
# het IP-adres afleidt, want bij -r/-m is dat adres niet meegegeven.
domain_mac() {
    virsh domiflist "$1" 2>/dev/null | awk 'NF>=5 && $5 ~ /^([0-9a-fA-F]{2}:){5}/ {print $5; exit}'
}

# Het omgekeerde van de MAC-regel uit deel 4: 52:54:00:<o2>:<o3>:<o4> hoort
# bij <eerste octet van de gateway>.<o2>.<o3>.<o4>. Zo weet -r welk adres uit
# known_hosts moet, ook bij een vast IP (geen lease, geen reservering).
ip_from_mac() {
    local mac="$1" ip mask
    [[ "$mac" =~ ^52:54:00:([0-9a-fA-F]{2}):([0-9a-fA-F]{2}):([0-9a-fA-F]{2})$ ]] || return 1
    ip="${GATEWAY%%.*}.$(( 16#${BASH_REMATCH[1]} )).$(( 16#${BASH_REMATCH[2]} )).$(( 16#${BASH_REMATCH[3]} ))"
    # alleen bruikbaar als het adres in dit netwerk valt
    mask=$(( 0xFFFFFFFF ^ ((1 << (32 - NETMASK_PREFIX)) - 1) ))
    (( ($(ip2int "$ip") & mask) == ($(ip2int "$GATEWAY") & mask) )) || return 1
    printf '%s\n' "$ip"
}

# De DHCP-reservering van deze VM in het libvirt-netwerk, als die er is;
# uitvoer is de complete <host .../>-regel uit de netwerkdefinitie.
dhcp_host_entry() {
    local mac="$1" name="$2"
    virsh net-dumpxml "$LIBVIRT_NET" 2>/dev/null \
        | grep -oE "<host [^>]*/>" \
        | grep -E "mac='${mac:-geen}'|name='${name}'" | head -1
}

# Hernoemingen terugdraaien na een halve mislukking; argumenten zijn paren
# "nieuw|oud", zoals ze in move_vm worden opgebouwd.
undo_moves() {
    local p
    for p in "$@"; do
        [[ -e "${p%%|*}" ]] || continue
        mv -n "${p%%|*}" "${p##*|}" 2>/dev/null || true
    done
    [[ $# -gt 0 ]] && warn "De hernoemde bestanden zijn teruggezet naar hun oude naam."
    return 0
}

# --- -r: VM en boekhouding opruimen -----------------------------------
#
# Verwijdert het domein inclusief nvram, managed-save en snapshots, de
# schijven die in de definitie staan, de seed-iso, de DHCP-reservering en de
# known_hosts-regels. Het base-image hoort niet bij het domein en gaat alleen
# weg als daar apart ja op wordt gezegd.
remove_vm() {
    local defined="nee" state="afwezig" mac="" entry="" f rc=0
    local -a targets=()
    local -A gezien=()

    if virsh dominfo "$Hostname" &>/dev/null; then
        defined="ja"
        state="$(virsh domstate "$Hostname" 2>/dev/null | head -1)"
        mac="$(domain_mac "$Hostname")"
    fi

    event PLAN run "stappen van deze run" "route=opruimen" \
        "stappen=preflight,vm-opruimen,dhcp-reservering,known_hosts,base-opruimen,einde"
    step_start vm-opruimen "opruimen van '${Hostname}' (gedefinieerd: ${defined}, status: ${state})"

    # Welk adres hoorde bij deze VM? Zonder -i uit de MAC afleiden; anders
    # zouden de known_hosts-regels van een willekeurig ander adres sneuvelen.
    if [[ "$IP_GIVEN" == "no" ]]; then
        if IPaddress="$(ip_from_mac "$mac")"; then
            log "Adres afgeleid uit MAC ${mac}: ${IPaddress}"
        else
            IPaddress=""
            warn "Kan het IP-adres van '${Hostname}' niet afleiden; known_hosts wordt alleen op naam opgeruimd (geef anders -i ADRES mee)."
        fi
    fi

    # Wat moet er weg? De definitie is leidend, niet de aanname dat de schijf
    # {naam}.qcow2 heet. Een base-image blijft er hoe dan ook buiten.
    while read -r f; do
        [[ -n "$f" ]] || continue
        if [[ "$f" == "$BASE_IMAGE" || "$f" == *-base.qcow2 ]]; then
            log "Blijft staan (base-image): ${f}"
            continue
        fi
        [[ -n "${gezien[$f]:-}" ]] && continue
        gezien[$f]=1
        targets+=("$f")
    done < <(
        if [[ "$defined" == "ja" ]]; then
            domain_disk_files "$Hostname"
            domain_cdrom_files "$Hostname" | grep -E -- '-seed\.iso$' || true
        fi
        [[ -e "$DISK_PATH" ]] && printf '%s\n' "$DISK_PATH"
        [[ -e "$SEED_ISO"  ]] && printf '%s\n' "$SEED_ISO"
        true
    )

    entry="$(dhcp_host_entry "$mac" "$Hostname")"

    if [[ "$defined" == "nee" && ${#targets[@]} -eq 0 ]]; then
        step_skip vm-opruimen "er is geen VM '${Hostname}' en geen ${DISK_PATH}; niets op te ruimen"
    else
        warn "Dit verwijdert definitief:"
        [[ "$defined" == "ja" ]] && \
            log "  domein '${Hostname}' (${state}) uit libvirt, inclusief nvram, managed-save en snapshots"
        for f in "${targets[@]}"; do
            log "  bestand ${f} ($(du -h "$f" 2>/dev/null | cut -f1))"
        done
        [[ -n "$entry" ]] && log "  DHCP-reservering ${entry} uit netwerk ${LIBVIRT_NET}"
        confirm "Dit alles verwijderen?" || die "Afgebroken; er is niets verwijderd."

        if [[ "$defined" == "ja" ]]; then
            if [[ "$state" != "shut off" ]]; then
                log "VM '${Hostname}' stoppen"
                virsh destroy "$Hostname" >/dev/null 2>&1 || true
            fi
            virsh managedsave-remove "$Hostname" >/dev/null 2>&1 || true
            log "Domein '${Hostname}' verwijderen uit libvirt"
            virsh undefine "$Hostname" --nvram --managed-save --snapshots-metadata >/dev/null 2>&1 \
                || virsh undefine "$Hostname" >/dev/null 2>&1 \
                || { step_fail vm-opruimen "domein '${Hostname}' kon niet worden verwijderd"; return 1; }
        fi
        for f in "${targets[@]}"; do
            log "Verwijderen: ${f}"
            rm -f "$f"
            if [[ -e "$f" ]]; then
                step_fail vm-opruimen "${f} kon niet worden verwijderd"
                return 1
            fi
        done
        if virsh dominfo "$Hostname" &>/dev/null; then
            step_fail vm-opruimen "domein '${Hostname}' bestaat nog na het verwijderen"
            return 1
        fi
        event CHECK vm-opruimen "domein weg uit libvirt" "bestanden_verwijderd=${#targets[@]}"
        step_ok vm-opruimen "VM '${Hostname}' en de bijbehorende bestanden zijn opgeruimd"
    fi

    # --- DHCP-reservering ---
    step_start dhcp-reservering "reservering van '${Hostname}' in netwerk ${LIBVIRT_NET}"
    if [[ -z "$entry" ]]; then
        step_skip dhcp-reservering "geen reservering voor '${Hostname}' in ${LIBVIRT_NET}"
    else
        local sel="<host name='${Hostname}'/>"
        [[ -n "$mac" ]] && sel="<host mac='${mac}'/>"
        if virsh net-update "$LIBVIRT_NET" delete ip-dhcp-host "$sel" --live --config >/dev/null 2>&1; then
            step_ok dhcp-reservering "reservering ${entry} verwijderd uit ${LIBVIRT_NET}"
        else
            step_fail dhcp-reservering "kon de reservering niet verwijderen; met de hand: virsh net-update ${LIBVIRT_NET} delete ip-dhcp-host \"${entry}\" --live --config"
            rc=1
        fi
    fi

    # --- known_hosts ---
    step_start known_hosts "hostkeys van '${Hostname}'${IPaddress:+ / ${IPaddress}} uit known_hosts halen"
    if [[ "$MANAGE_KNOWN_HOSTS" != "yes" ]]; then
        step_skip known_hosts "uitgezet met --no-known-hosts"
    else
        known_hosts_forget
        step_ok known_hosts "known_hosts van $(printf '%s ' "${KNOWN_HOSTS_ENTRIES[@]%%:*}")nagelopen"
    fi

    # --- base-image: hoort niet bij het domein, dus apart vragen ---
    step_start base-opruimen "base-image ${BASE_IMAGE}"
    local base_slot="was er niet"
    if [[ ! -e "$BASE_IMAGE" ]]; then
        step_skip base-opruimen "er is geen ${BASE_IMAGE}"
    else
        base_slot="${BASE_IMAGE} (blijft staan)"
        warn "Het base-image ${BASE_IMAGE} ($(du -h "$BASE_IMAGE" 2>/dev/null | cut -f1)) staat los van de VM en blijft staan tenzij u het nu weggooit."
        if confirm "Ook ${BASE_IMAGE} verwijderen?"; then
            rm -f "$BASE_IMAGE"
            if [[ -e "$BASE_IMAGE" ]]; then
                step_fail base-opruimen "kon ${BASE_IMAGE} niet verwijderen"
                rc=1
            else
                base_slot="verwijderd"
                step_ok base-opruimen "${BASE_IMAGE} verwijderd"
            fi
        else
            step_skip base-opruimen "${BASE_IMAGE} blijft staan; een volgende bouw van '${Hostname}' kloont hieruit"
        fi
    fi

    local dom_slot="was er niet"
    [[ "$defined" == "ja" ]] && dom_slot="weg uit libvirt"
    virsh dominfo "$Hostname" &>/dev/null && dom_slot="BESTAAT NOG"
    cat <<EOF

$(log "Opgeruimd.")
  Naam       : ${Hostname}
  Domein     : ${dom_slot}
  Bestanden  : ${#targets[@]} verwijderd${targets:+ (${targets[*]})}
  Reservering: $([[ -n "$entry" ]] && echo "verwijderd uit ${LIBVIRT_NET}" || echo "was er niet")
  Base-image : ${base_slot}
  known_hosts: $([[ "$MANAGE_KNOWN_HOSTS" == "yes" ]] && echo "bijgewerkt" || echo "niet aangeraakt")
  Log        : ${LOG_FILE:-(alleen scherm)}
EOF
    return "$rc"
}

# --- -m: VM en boekhouding hernoemen ----------------------------------
#
# Hernoemt de qcow2 en de seed-iso, past het pad in de definitie aan, geeft
# het domein de nieuwe naam (virsh domrename, alleen mogelijk als de VM uit
# staat) en zet autostart terug. De gast zelf blijft zichzelf bij de oude
# naam noemen en houdt zijn IP-adres; dat is host-boekhouding, geen migratie.
move_vm() {
    local old="$Hostname" new="$MOVE_TO"
    local new_disk="${POOL_DIR}/${new}.qcow2"
    local new_seed="${ISO_DIR}/${new}-seed.iso"
    local new_base="${POOL_DIR}/${new}-base.qcow2"
    local defined="nee" state="afwezig" autostart="disable" was_running="nee"
    local mac="" entry="" xml="" src_now="" pair src dst rc=0
    local -a moved=()

    event PLAN run "stappen van deze run" "route=hernoemen" \
        "stappen=preflight,vm-hernoemen,dhcp-reservering,base-hernoemen,einde"
    step_start vm-hernoemen "'${old}' hernoemen naar '${new}'"

    virsh dominfo "$new" &>/dev/null && die "Er bestaat al een VM '${new}'; kies een andere naam."
    [[ -e "$new_disk" ]] && die "${new_disk} bestaat al; kies een andere naam."
    [[ -e "$new_seed" ]] && die "${new_seed} bestaat al; kies een andere naam."

    if virsh dominfo "$old" &>/dev/null; then
        defined="ja"
        state="$(virsh domstate "$old" 2>/dev/null | head -1)"
        autostart="$(virsh dominfo "$old" 2>/dev/null | awk -F': *' '/^Autostart/{print $2}')"
        mac="$(domain_mac "$old")"
    elif [[ ! -e "$DISK_PATH" ]]; then
        die "Er is geen VM '${old}' en geen ${DISK_PATH}; niets te hernoemen."
    fi
    entry="$(dhcp_host_entry "$mac" "$old")"

    warn "Dit hernoemt:"
    [[ "$defined" == "ja" ]] && log "  domein '${old}' -> '${new}' (status ${state}, autostart ${autostart})"
    [[ -e "$DISK_PATH" ]] && log "  schijf ${DISK_PATH} -> ${new_disk}"
    [[ -e "$SEED_ISO"  ]] && log "  seed-iso ${SEED_ISO} -> ${new_seed}"
    [[ "$defined" == "ja" && "$state" != "shut off" ]] && \
        log "  de VM wordt hiervoor afgesloten en daarna weer gestart"
    log "  de gast houdt binnenin hostname '${old}' en zijn eigen IP-adres"
    confirm "Doorgaan?" || die "Afgebroken; er is niets gewijzigd."

    # virsh domrename werkt alleen op een domein dat uit staat
    if [[ "$defined" == "ja" && "$state" != "shut off" ]]; then
        was_running="ja"
        log "VM '${old}' netjes afsluiten"
        virsh shutdown "$old" >/dev/null 2>&1 || true
        wait_for_shutoff 180
    fi

    for pair in "${DISK_PATH}|${new_disk}" "${SEED_ISO}|${new_seed}"; do
        src="${pair%%|*}"; dst="${pair##*|}"
        [[ -e "$src" ]] || continue
        log "Hernoemen: ${src} -> ${dst}"
        if ! mv -n "$src" "$dst"; then
            undo_moves "${moved[@]}"
            step_fail vm-hernoemen "kon ${src} niet hernoemen naar ${dst}"
            return 1
        fi
        moved+=("${dst}|${src}")
    done

    if [[ "$defined" == "ja" ]]; then
        if ! virsh domrename "$old" "$new" >/dev/null 2>&1; then
            undo_moves "${moved[@]}"
            step_fail vm-hernoemen "virsh domrename ${old} ${new} mislukte; staat de VM wel uit? (virsh domstate ${old})"
            return 1
        fi
        log "Domein heet nu '${new}'"

        # De paden in de definitie wijzen nu nergens meer naar: die moeten mee.
        xml="$(mktemp /var/tmp/makevm-hernoem-XXXXXX.xml)"
        virsh dumpxml --inactive "$new" >"$xml"
        sed -i "s|file='${DISK_PATH}'|file='${new_disk}'|g; s|file='${SEED_ISO}'|file='${new_seed}'|g" "$xml"
        if ! virsh define "$xml" >/dev/null 2>&1; then
            rm -f "$xml"
            step_fail vm-hernoemen "de definitie van '${new}' kon niet worden bijgewerkt; kijk met: virsh dumpxml ${new}"
            return 1
        fi
        rm -f "$xml"
        [[ "$autostart" == "enable" ]] && { virsh autostart "$new" >/dev/null 2>&1 || warn "autostart kon niet worden gezet voor '${new}'."; }

        src_now="$(domain_disk_files "$new" | head -1)"
        event CHECK vm-hernoemen "definitie van '${new}' wijst naar ${src_now:-onbekend}" \
            "autostart=${autostart}" "was_actief=${was_running}"
        [[ "$src_now" == "$new_disk" ]] || \
            warn "De definitie van '${new}' wijst niet naar ${new_disk}; kijk met: virsh domblklist ${new}"
        if virsh dumpxml --inactive "$new" 2>/dev/null | grep -q "${old}"; then
            warn "In de definitie van '${new}' komt '${old}' nog voor: $(virsh dumpxml --inactive "$new" | grep -oE "[^ '\"<>]*${old}[^ '\"<>]*" | sort -u | tr '\n' ' ')"
        fi
    else
        log "Er was geen domein '${old}'; alleen de bestanden zijn hernoemd."
    fi
    step_ok vm-hernoemen "'${old}' heet nu '${new}'"

    # --- DHCP-reservering: de naam daarin is ook host-boekhouding ---
    step_start dhcp-reservering "reservering van '${old}' in netwerk ${LIBVIRT_NET}"
    if [[ -z "$entry" ]]; then
        step_skip dhcp-reservering "geen reservering voor '${old}' in ${LIBVIRT_NET}"
    elif [[ "$entry" != *"name='${old}'"* ]]; then
        step_skip dhcp-reservering "reservering ${entry} draagt de naam '${old}' niet; ongemoeid gelaten"
    elif [[ -z "$mac" ]]; then
        step_skip dhcp-reservering "reservering ${entry} zonder MAC om op te matchen; met de hand: virsh net-update ${LIBVIRT_NET} modify ip-dhcp-host \"$(sed "s|name='${old}'|name='${new}'|" <<<"$entry")\" --live --config"
    else
        local nieuw
        nieuw="$(sed "s|name='${old}'|name='${new}'|" <<<"$entry")"
        if virsh net-update "$LIBVIRT_NET" modify ip-dhcp-host "$nieuw" --live --config >/dev/null 2>&1; then
            step_ok dhcp-reservering "reservering heet nu ${nieuw}"
        else
            step_fail dhcp-reservering "kon de reservering niet bijwerken; met de hand: virsh net-update ${LIBVIRT_NET} modify ip-dhcp-host \"${nieuw}\" --live --config"
            rc=1
        fi
    fi

    # --- base-image: staat los van de VM, dus apart vragen ---
    step_start base-hernoemen "base-image ${BASE_IMAGE}"
    if [[ ! -e "$BASE_IMAGE" ]]; then
        step_skip base-hernoemen "er is geen ${BASE_IMAGE}"
    elif [[ -e "$new_base" ]]; then
        step_skip base-hernoemen "${new_base} bestaat al; ${BASE_IMAGE} blijft zo heten"
    else
        if confirm "Ook het base-image ${BASE_IMAGE} hernoemen naar ${new_base}?"; then
            if mv -n "$BASE_IMAGE" "$new_base"; then
                BASE_IMAGE="$new_base"
                step_ok base-hernoemen "base-image heet nu ${new_base}"
            else
                step_fail base-hernoemen "kon ${BASE_IMAGE} niet hernoemen naar ${new_base}"
                rc=1
            fi
        else
            step_skip base-hernoemen "${BASE_IMAGE} blijft zo heten; een bouw van '${new}' installeert dus volledig"
        fi
    fi

    if [[ "$was_running" == "ja" ]]; then
        log "VM '${new}' weer starten"
        if ! virsh start "$new" >/dev/null 2>&1; then
            warn "VM '${new}' kon niet worden gestart; probeer: virsh start ${new}"
            rc=1
        fi
    fi

    # vanaf hier gaat de rest van het script (en de RESULT-regel) over de
    # nieuwe naam
    Hostname="$new"
    DISK_PATH="$new_disk"
    SEED_ISO="$new_seed"

    cat <<EOF

$(log "Hernoemd.")
  Oude naam  : ${old}
  Nieuwe naam: ${new}
  Domein     : $(virsh dominfo "$new" &>/dev/null && virsh domstate "$new" 2>/dev/null | head -1 || echo "niet gedefinieerd")
  Schijf     : ${new_disk}
  Seed-iso   : $([[ -e "$new_seed" ]] && echo "$new_seed" || echo "(geen)")
  Base-image : $([[ -e "$BASE_IMAGE" ]] && echo "$BASE_IMAGE" || echo "(geen)")
  In de gast : hostname '${old}' en het IP-adres zijn niet aangepast
  Log        : ${LOG_FILE:-(alleen scherm)}
EOF
    return "$rc"
}

########################################################################
# 5. PREFLIGHT
########################################################################

init_logging
event START run "makevm gestart voor '${Hostname}' (${IPaddress}), schijf ${DISK_GB}G" \
    "pid=$$" "gebruiker=${SUDO_USER:-${USER:-root}}" \
    "log=${LOG_FILE:-geen}" "status=${STATUS_FILE:-geen}"
if [[ -n "${LOG_FILE:-}" ]]; then
    printf '    meelezen : tail -f %s\n    stand    : cat %s\n\n' \
        "${LOG_DIR}/makevm-${Hostname}-laatste.log" "${STATUS_FILE}"
fi

step_start preflight "omgeving en instellingen controleren"

[[ ${EUID} -eq 0 ]] || die "Draai dit script als root (sudo $0)."

for cmd in virsh virt-install qemu-img xorriso openssl ssh ssh-keygen ssh-keyscan; do
    command -v "$cmd" >/dev/null || die "Commando '$cmd' ontbreekt."
done

case "$IP_MODE"        in static|reservation|both) ;; *) die "IP_MODE moet static, reservation of both zijn." ;; esac
case "$STORAGE_LAYOUT" in lvm|direct)              ;; *) die "STORAGE_LAYOUT moet lvm of direct zijn." ;; esac
case "$LVM_SIZING"     in all|scaled)              ;; *) die "LVM_SIZING moet all of scaled zijn." ;; esac

[[ -d "$POOL_DIR" ]] || die "Pool-map $POOL_DIR bestaat niet."
[[ -d "$ISO_DIR"  ]] || die "ISO-map $ISO_DIR bestaat niet."

virsh net-info "$LIBVIRT_NET" &>/dev/null || die "Libvirt-netwerk '$LIBVIRT_NET' bestaat niet."
[[ "$(virsh net-info "$LIBVIRT_NET" | awk '/^Active/{print $2}')" == "yes" ]] || \
    die "Libvirt-netwerk '$LIBVIRT_NET' is niet actief."

# --- beheermodi: hier houdt het bouwen op ---
# -r en -m hebben genoeg aan de controles hierboven; alles wat hierna komt
# (opruimen van een gelijknamige VM, vrije ruimte, sleutels, seed) hoort bij
# het bouwen van een nieuwe VM.
if [[ "$MANAGE_MODE" == "yes" ]]; then
    BASE_EXPECTED="no"
    BASE_OK="n.v.t."
    ACTIVE="n.v.t."
    if [[ "$REMOVE_MODE" == "yes" ]]; then BUILD_MODE="opruimen"; else BUILD_MODE="hernoemen"; fi
    step_ok preflight "host en netwerk ${LIBVIRT_NET} zijn in orde (modus: ${BUILD_MODE})"
    if [[ "$REMOVE_MODE" == "yes" ]]; then
        remove_vm || exit 1
    else
        move_vm || exit 1
    fi
    exit 0
fi

# Klonen of volledig installeren? Met --rebuild-base telt een bestaand
# base-image niet mee: dat wordt hieronder opgeruimd en opnieuw opgebouwd.
if [[ "$USE_BASE" == "yes" && "$REBUILD_BASE" == "no" && -r "$BASE_IMAGE" ]]; then
    BUILD_MODE="clone"
    BASE_EXPECTED="no"          # het base-image bestaat al en wordt gebruikt
    BASE_OK="ja"

    # Een kloon is een kopie van het base-image; de schijf mag daarbij nooit
    # kleiner worden dan het origineel. qemu-img zou de qcow2 gewoon afkappen
    # en het bestandssysteem dat erin staat onherstelbaar beschadigen. Deze
    # controle staat bewust voor het opruimen van een oude VM, zodat een te
    # kleine -d niets kapotmaakt.
    base_bytes="$(image_virtual_bytes "$BASE_IMAGE")"
    [[ "$base_bytes" =~ ^[0-9]+$ ]] || \
        die "Kan de virtuele grootte van ${BASE_IMAGE} niet lezen; controleer het bestand met: qemu-img info ${BASE_IMAGE}"
    base_gb=$(( (base_bytes + 1024**3 - 1) / 1024**3 ))     # naar boven afgerond
    want_bytes=$(( DISK_GB * 1024**3 ))
    if (( want_bytes < base_bytes )); then
        die "Schijf van ${DISK_GB}G is kleiner dan het base-image ${BASE_IMAGE} (${base_gb}G); een kloon mag nooit krimpen. Geef -d ${base_gb} of meer, of maak met --rebuild-base een nieuw base-image van ${DISK_GB}G."
    elif (( want_bytes > base_bytes )); then
        RESIZED="yes"
        log "Kloon wordt vergroot van ${base_gb}G naar ${DISK_GB}G"
    else
        log "Kloon houdt de maat van het base-image: ${base_gb}G"
    fi
else
    BUILD_MODE="install"
    [[ -r "$INSTALL_ISO" ]] || \
        die "Install-ISO niet gevonden: ${INSTALL_ISO} (zet de ISO in ${ISO_DIR})."
    # Alleen dan hoort deze run aan het eind een {naam}-base.qcow2 op te leveren
    if [[ "$USE_BASE" == "yes" ]]; then BASE_EXPECTED="yes"; BASE_OK="nee"
    else                                BASE_EXPECTED="no";  BASE_OK="n.v.t."; fi
fi
plan_steps

# --- bestaande VM met dezelfde naam? ---
if virsh dominfo "$Hostname" &>/dev/null; then
    state="$(virsh domstate "$Hostname" 2>/dev/null || echo onbekend)"
    step_start opruimen "bestaande VM '${Hostname}' aangetroffen (status: ${state})"
    warn "Er bestaat al een VM '${Hostname}' (status: ${state})."
    confirm "Deze VM stoppen en opruimen (schijf ${DISK_PATH} wordt verwijderd, ${BASE_IMAGE} $([[ "$REBUILD_BASE" == "yes" ]] && echo "wordt zo apart nagevraagd" || echo "blijft staan"))?" \
        || die "Afgebroken; kies een andere naam met -n."

    if [[ "$state" != "shut off" ]]; then
        log "VM '${Hostname}' stoppen"
        virsh destroy "$Hostname" >/dev/null
    fi
    log "Domein '${Hostname}' verwijderen"
    virsh undefine "$Hostname" --nvram --managed-save --snapshots-metadata >/dev/null 2>&1 || \
        virsh undefine "$Hostname" >/dev/null
    for f in "$DISK_PATH" "$SEED_ISO"; do
        [[ -e "$f" ]] && { log "Verwijderen: $f"; rm -f "$f"; }
    done
    step_ok opruimen "oude VM '${Hostname}' en bijbehorende schijf verwijderd"
    CURRENT_STEP="preflight"
elif [[ -e "$DISK_PATH" ]]; then
    step_start opruimen "losse schijf zonder VM aangetroffen: ${DISK_PATH}"
    warn "Er is geen VM '${Hostname}', maar ${DISK_PATH} bestaat wel."
    confirm "Deze schijf verwijderen?" || die "Afgebroken; kies een andere naam met -n."
    rm -f "$DISK_PATH"
    step_ok opruimen "${DISK_PATH} verwijderd"
    CURRENT_STEP="preflight"
fi

# --- base-image opnieuw opbouwen? ---
# Alleen hier wordt {naam}-base.qcow2 ooit verwijderd, en nooit zonder dat
# erom gevraagd is (of -y meegegeven).
if [[ "$REBUILD_BASE" == "yes" ]]; then
    if [[ -e "$BASE_IMAGE" ]]; then
        step_start base-opruimen "bestaand base-image aangetroffen: ${BASE_IMAGE}"
        warn "Het bestaande ${BASE_IMAGE} ($(du -h "$BASE_IMAGE" 2>/dev/null | cut -f1)) wordt weggegooid."
        confirm "Dit base-image verwijderen en na de installatie opnieuw opbouwen?" \
            || die "Afgebroken; laat --rebuild-base weg om uit ${BASE_IMAGE} te klonen."
        rm -f "$BASE_IMAGE"
        [[ -e "$BASE_IMAGE" ]] && die "Kon ${BASE_IMAGE} niet verwijderen."
        step_ok base-opruimen "${BASE_IMAGE} verwijderd; deze run installeert volledig en maakt een nieuw base-image"
    else
        step_skip base-opruimen "er was nog geen ${BASE_IMAGE}; deze run maakt er een"
    fi
    CURRENT_STEP="preflight"
fi

# IP mag niet al in gebruik zijn
if ping -c1 -W1 "$IPaddress" &>/dev/null; then
    die "$IPaddress reageert al op ping - kies een ander adres."
fi
if virsh net-dhcp-leases "$LIBVIRT_NET" 2>/dev/null | grep -q "${IPaddress}/"; then
    die "$IPaddress staat al als DHCP-lease in netwerk $LIBVIRT_NET."
fi

# Genoeg vrije ruimte in de pool?
avail_gb=$(df -BG --output=avail "$POOL_DIR" | tail -1 | tr -dc '0-9')
needed_gb=$(( DISK_GB + 5 ))
(( avail_gb > needed_gb )) || \
    die "Te weinig vrije ruimte in $POOL_DIR (${avail_gb}G vrij, ~${needed_gb}G nodig)."
log "Vrije ruimte in ${POOL_DIR}: ${avail_gb}G (nodig: ~${needed_gb}G)"
# Het base-image is straks een tweede kopie van dezelfde schijf. Dat hier al
# melden, want anders blijkt het pas na een complete installatie.
if [[ "$BASE_EXPECTED" == "yes" ]] && (( avail_gb < DISK_GB * 2 )); then
    warn "Voor de VM en het base-image samen is tot $(( DISK_GB * 2 ))G nodig en er is ${avail_gb}G vrij; het base-image kan straks niet passen."
fi

step_ok preflight "host, netwerk ${LIBVIRT_NET} en opslag ${POOL_DIR} zijn in orde (route: ${BUILD_MODE})"

# --- ssh-sleutels verzamelen uit deze map ---
step_start ssh-sleutels "publieke sleutels verzamelen uit ${SSH_KEY_DIR}"
SSH_PUBKEYS=()

if [[ -r "$SSH_AUTH_KEYS_FILE" ]]; then
    while read -r key; do
        [[ -n "$key" ]] && SSH_PUBKEYS+=("$key")
    done < <(grep -E '^(ssh-|ecdsa-)' "$SSH_AUTH_KEYS_FILE" || true)
    log "Sleutels uit $(basename "$SSH_AUTH_KEYS_FILE"): ${#SSH_PUBKEYS[@]}"
else
    warn "Geen ${SSH_AUTH_KEYS_FILE} gevonden."
fi

# Publieke helft van de private key erbij, zodat inloggen met -i id_ed25519 werkt
if [[ -r "$SSH_PRIVKEY_FILE" ]]; then
    if privpub="$(ssh-keygen -y -P '' -f "$SSH_PRIVKEY_FILE" 2>/dev/null)"; then
        [[ "$(wc -w <<<"$privpub")" -lt 3 ]] && privpub+=" $(basename "$SSH_PRIVKEY_FILE")"
        SSH_PUBKEYS+=("$privpub")
        log "Publieke sleutel afgeleid uit $(basename "$SSH_PRIVKEY_FILE")"
    else
        warn "Kan geen publieke sleutel afleiden uit ${SSH_PRIVKEY_FILE} (passphrase?); overgeslagen."
    fi
else
    die "Zonder ${SSH_PRIVKEY_FILE} kan het script de VM niet controleren; zet de sleutel terug of pas SSH_PRIVKEY_FILE aan."
fi

# Ontdubbelen op het sleutelmateriaal zelf (veld 2), commentaar mag verschillen
declare -A _seen=()
SSH_KEYS_YAML=""        # inspringing 6 spaties (autoinstall)
SSH_KEYS_YAML4=""       # inspringing 6 spaties onder users: (cloud-config)
SSH_KEYS_PLAIN=""       # kale authorized_keys-inhoud
for key in "${SSH_PUBKEYS[@]}"; do
    material="$(awk '{print $2}' <<<"$key")"
    [[ -n "${_seen[$material]:-}" ]] && continue
    _seen[$material]=1
    SSH_KEYS_YAML+="      - \"${key}\""$'\n'
    SSH_KEYS_YAML4+="      - \"${key}\""$'\n'
    SSH_KEYS_PLAIN+="${key}"$'\n'
done
SSH_KEYS_YAML="${SSH_KEYS_YAML%$'\n'}"
SSH_KEYS_YAML4="${SSH_KEYS_YAML4%$'\n'}"

[[ -n "$SSH_KEYS_YAML" ]] || \
    die "Geen bruikbare publieke sleutels gevonden in ${SSH_KEY_DIR} (authorized_keys / id_ed25519)."
step_ok ssh-sleutels "$(grep -c . <<<"$SSH_KEYS_PLAIN") unieke publieke sleutel(s) voor ${ADMIN_USER}"

# Wachtwoordhash voor het beheeraccount (alleen nodig bij een volledige install;
# een kloon erft het account uit het base-image)
if [[ "$BUILD_MODE" == "install" && -z "$ADMIN_PWHASH" ]]; then
    read -rsp "Wachtwoord voor gebruiker '${ADMIN_USER}' op de console van ${Hostname}: " _pw1; echo
    read -rsp "Nogmaals: " _pw2; echo
    [[ "$_pw1" == "$_pw2" ]] || die "Wachtwoorden komen niet overeen."
    [[ -n "$_pw1" ]]         || die "Leeg wachtwoord is niet toegestaan."
    ADMIN_PWHASH="$(openssl passwd -6 "$_pw1")"
    unset _pw1 _pw2
fi

########################################################################
# 6. GEDEELDE BOUWSTENEN
########################################################################

# opgeruimd door on_exit
WORKDIR="$(mktemp -d /var/tmp/makevm-XXXXXX)"

# ufw-regels voor ssh, als losse commando's
ufw_ssh_rules() {
    local prefix="$1"           # tekst voor elke regel, bijv. "    - curtin in-target -- "
    if [[ "$SSH_ALLOW_FROM" == "any" ]]; then
        printf '%sufw allow OpenSSH\n' "$prefix"
    else
        local src
        for src in $SSH_ALLOW_FROM; do
            printf '%sufw allow from %s to any port 22 proto tcp\n' "$prefix" "$src"
        done
    fi
}

# sshd: alleen publieke sleutels, geen wachtwoorden
sshd_hardening() {
    cat <<'EOF'
# Beheerd door makevm.sh - alleen publieke sleutels, geen wachtwoorden
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitRootLogin no
UsePAM yes
EOF
}

fail2ban_jail() {
    cat <<EOF
[DEFAULT]
backend  = systemd
bantime  = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1 ${NETWORK_CIDR}

[sshd]
enabled = true
mode    = aggressive
EOF
}

# Schrijft een bestand in het te installeren systeem weg als late-commands.
# De inhoud gaat als base64 mee, zodat noch YAML- noch shell-quoting stuk kan.
# Gebruik: <iets dat de inhoud produceert> | target_write_cmds /pad 0644
target_write_cmds() {
    local path="$1" mode="$2" b64
    b64="$(base64 -w0)"
    printf '    - mkdir -p /target%s\n' "$(dirname "$path")"
    printf '    - echo %s | base64 -d > /target%s\n' "$b64" "$path"
    printf '    - chmod %s /target%s\n' "$mode" "$path"
}

# --- commando's in de draaiende gast uitvoeren -------------------------
# Via de qemu-guest-agent (draait als root), omdat er op deze host geen
# libguestfs staat en sudo in de gast een wachtwoord vraagt.
guest_agent_ready() {
    local i
    for i in $(seq "${1:-30}"); do
        virsh qemu-agent-command "$Hostname" '{"execute":"guest-ping"}' >/dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}

# guest_exec SCRIPT [AANTAL_POLLS]
# Wacht standaard 60 x 2s; een lange klus (apt-upgrade) geeft meer mee.
# Na afloop staan de exitcode en de uitvoer in GUEST_EXITCODE/GUEST_OUTPUT,
# zodat de aanroeper onderscheid kan maken tussen "mislukt" en "klaar met
# waarschuwingen", en de uitvoer in het logboek van deze run kan zetten.
GUEST_EXITCODE=""
GUEST_OUTPUT=""
guest_exec() {
    local script="$1" polls="${2:-60}" b64 pid res i out
    GUEST_EXITCODE=""; GUEST_OUTPUT=""
    b64="$(printf '%s' "$script" | base64 -w0)"
    pid="$(virsh qemu-agent-command "$Hostname" \
        "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"/bin/sh\",\"arg\":[\"-c\",\"echo ${b64} | base64 -d | sh\"],\"capture-output\":true}}" \
        2>/dev/null | sed -n 's/.*"pid":\([0-9]\{1,\}\).*/\1/p')"
    [[ -n "$pid" ]] || return 1
    res=""
    for (( i = 0; i < polls; i++ )); do
        res="$(virsh qemu-agent-command "$Hostname" \
            "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":${pid}}}" 2>/dev/null)"
        [[ "$res" == *'"exited":true'* ]] && break
        sleep 2
    done
    [[ "$res" == *'"exited":true'* ]] || return 124      # nog bezig: opgegeven
    GUEST_EXITCODE="$(sed -n 's/.*"exitcode":\([0-9]\{1,\}\).*/\1/p' <<<"$res" | head -1)"
    out="$(sed -n 's/.*"out-data":"\([^"]*\)".*/\1/p' <<<"$res" | head -1)"
    [[ -n "$out" ]] && GUEST_OUTPUT="$(base64 -d <<<"$out" 2>/dev/null || true)"
    [[ "${GUEST_EXITCODE:-1}" == "0" ]]
}

# Zet een bestand van deze host in de gast neer, in stukken: de hele inhoud
# in een keer zou een erg lang guest-exec-commando opleveren.
guest_put_file() {
    local src="$1" dst="$2" mode="${3:-0700}" b64 chunk n=0
    [[ -r "$src" ]] || return 1
    b64="$(base64 -w0 "$src")"
    guest_exec ": > ${dst}.b64" || return 1
    while [[ -n "$b64" ]]; do
        chunk="${b64:0:6000}"; b64="${b64:6000}"
        # base64 bevat geen aanhalingstekens, dus dit quoten is veilig
        guest_exec "printf '%s' '${chunk}' >> ${dst}.b64" || return 1
        n=$(( n + 1 ))
    done
    guest_exec "base64 -d ${dst}.b64 > ${dst} && rm -f ${dst}.b64 && chmod ${mode} ${dst}" || return 1
    log "$(basename "$src") in de gast gezet als ${dst} (${n} stukken)"
    return 0
}

# Kan er straks een consistent snapshot van deze VM gemaakt worden? Daarvoor
# moeten drie dingen kloppen: het kanaal org.qemu.guest_agent.0 in de
# definitie, een agent die antwoordt, en een agent die bevriezen aankan.
# Zonder dat is een snapshot hooguit crash-consistent: bruikbaar, maar bij het
# terugzetten doet het filesystem journal-replay en kan een database in de gast
# inconsistent zijn. Met de agent bevriest libvirt het filesystem in de gast
# tijdens het snapshotten (--quiesce); dat duurt milliseconden.
#
# Dit is een controle, geen reparatie: kanaal en pakket krijgt elke VM van dit
# script al mee. Klopt er hier iets niet, dan is er aan de bouw iets misgegaan
# en zou beveilig.sh - dat via diezelfde agent naar binnen gaat - even later
# toch stranden. Dan is het beter dat het hier met naam en toenaam gemeld wordt.
#
# Bevriezen wordt niet echt geprobeerd: guest-fsfreeze-status vraagt of de
# agent het aankan zonder de gast stil te zetten. Wilt u het bewijs, dan kan
# dat los met: virsh domfsfreeze NAAM && virsh domfsthaw NAAM
AGENT_OK="onbekend"               # ja | nee
agent_check() {
    local vriesstand fs
    step_start agent-controle "controleren of de qemu-guest-agent in '${Hostname}' werkt"

    if ! virsh dumpxml "$Hostname" 2>/dev/null | grep -q "name='org.qemu.guest_agent.0'"; then
        AGENT_OK="nee"
        step_fail agent-controle "het kanaal org.qemu.guest_agent.0 ontbreekt in de definitie van ${Hostname}; snapshots blijven crash-consistent"
        return 1
    fi
    if ! guest_agent_ready 45; then
        AGENT_OK="nee"
        step_fail agent-controle "de agent antwoordt niet; kijk in de gast met: systemctl status qemu-guest-agent"
        return 1
    fi

    # Precies de filesystems die bij --quiesce bevroren worden
    fs="$(virsh domfsinfo "$Hostname" 2>/dev/null | awk 'NR>2 && NF {printf "%s ", $1}')"
    [[ -n "$fs" ]] && event CHECK agent-controle "filesystems via de agent: ${fs% }"

    vriesstand="$(virsh qemu-agent-command "$Hostname" '{"execute":"guest-fsfreeze-status"}' 2>/dev/null \
                  | sed -n 's/.*"return":"\([a-z]*\)".*/\1/p')"
    case "$vriesstand" in
        thawed) AGENT_OK="ja"
                step_ok agent-controle "de agent antwoordt en kan bevriezen; snapshots met --quiesce zijn mogelijk" ;;
        frozen) AGENT_OK="nee"
                step_fail agent-controle "het filesystem in de gast staat bevroren; ontdooien met: virsh domfsthaw ${Hostname}"
                return 1 ;;
        *)      AGENT_OK="nee"
                step_fail agent-controle "de agent kent guest-fsfreeze-status niet; --quiesce werkt niet op ${Hostname}"
                return 1 ;;
    esac
    return 0
}

# Draait beveilig.sh in de gast: apt update/upgrade, ssh, ufw (incl. IPv6),
# fail2ban, sysctl, tmp-mounts, sudo-logging, apparmor en auditd. Gebeurt in
# beide routes, en bij een volledige installatie voor het base-image, zodat
# elke kloon de maatregelen erft.
harden_guest() {
    local rc=0 samenvatting=""
    step_start beveiligen "beveiligingsmaatregelen toepassen in '${Hostname}'"

    if [[ ! -r "$HARDEN_SCRIPT" ]]; then
        step_fail beveiligen "${HARDEN_SCRIPT} niet gevonden; VM blijft ongehard (of gebruik --no-harden)"
        return 1
    fi
    if ! guest_agent_ready 30; then
        step_fail beveiligen "qemu-guest-agent antwoordt niet; maatregelen niet toegepast"
        return 1
    fi
    if ! guest_put_file "$HARDEN_SCRIPT" /root/beveilig.sh 0700; then
        step_fail beveiligen "kon ${HARDEN_SCRIPT} niet in de gast zetten"
        return 1
    fi

    log "beveilig.sh draait nu in de gast; dit duurt een paar minuten (apt-upgrade)"
    heartbeat_start beveiligen "beveiligen in de gast loopt nog"
    # --admin-user meegeven: het script gaat via de guest-agent naar binnen en
    # draait daar als echte root, zonder SUDO_USER of login-sessie. Zonder deze
    # vlag wijst beveilig.sh niemand aan en blijft /etc/sudoers.d/99-users leeg,
    # zodat de beheerder geen wachtwoordloze sudo heeft.
    guest_exec "/root/beveilig.sh -y --ufw-reset --admin-user '${ADMIN_USER}' --ssh-from '${SSH_ALLOW_FROM}' --trusted '${NETWORK_CIDR}' --log /var/log/beveilig.log >/var/log/beveilig-uitvoer.log 2>&1" 900 || rc=$?
    heartbeat_stop
    # meteen vasthouden: elke volgende guest_exec overschrijft GUEST_EXITCODE
    local guest_rc="${GUEST_EXITCODE:-onbekend}"

    # De RESULT-regel van beveilig.sh terughalen, zodat die ook in dit log staat
    if guest_exec "grep -h 'status=RESULT' /var/log/beveilig.log 2>/dev/null | tail -1"; then
        samenvatting="${GUEST_OUTPUT//$'\n'/ }"
        [[ -n "$samenvatting" ]] && event CHECK beveiligen "melding uit de gast: ${samenvatting}"
    fi

    case "$rc" in
        0)  step_ok beveiligen "alle maatregelen toegepast; log in de gast: /var/log/beveilig.log" ;;
        124) step_fail beveiligen "beveilig.sh was na 30 minuten nog niet klaar; kijk in de gast in /var/log/beveilig.log"
             return 1 ;;
        *)  if [[ "$guest_rc" == "3" ]]; then
                warn "beveilig.sh meldde waarschuwingen (exitcode 3); zie /var/log/beveilig.log in de gast."
                step_ok beveiligen "maatregelen toegepast, met waarschuwingen"
            else
                step_fail beveiligen "beveilig.sh stopte met exitcode ${guest_rc}; kijk in de gast in /var/log/beveilig.log"
                return 1
            fi ;;
    esac
    return 0
}

# Koppelt de seed-cdrom los, zowel live als in de opgeslagen configuratie.
eject_seed() {
    local dev
    dev="$(virsh domblklist "$Hostname" 2>/dev/null | awk -v s="$SEED_ISO" '$2==s{print $1}')"
    [[ -n "$dev" ]] || return 0
    log "Seed-cdrom loskoppelen (${dev})"
    if virsh domstate "$Hostname" 2>/dev/null | grep -q running; then
        virsh change-media "$Hostname" "$dev" --eject --live --config >/dev/null 2>&1 || true
    else
        virsh change-media "$Hostname" "$dev" --eject --config >/dev/null 2>&1 || true
    fi
}

# Legt de seed-cdrom er weer in. De VM staat hierbij uit, dus --config is
# genoeg: bij de volgende start zit de schijf in de lade.
insert_seed() {
    local dev
    dev="$(virsh domblklist "$Hostname" --details 2>/dev/null | awk '$2=="cdrom"{print $3; exit}')"
    if [[ -n "$dev" ]]; then
        log "Seed-cdrom terugleggen in ${dev}"
        virsh change-media "$Hostname" "$dev" "$SEED_ISO" --insert --config >/dev/null 2>&1 && return 0
        virsh change-media "$Hostname" "$dev" "$SEED_ISO" --update --config >/dev/null 2>&1 && return 0
        return 1
    fi
    log "Geen cdrom-station meer in de definitie; er een toevoegen (sdb)"
    virsh attach-disk "$Hostname" "$SEED_ISO" sdb --type cdrom --mode readonly --config >/dev/null 2>&1
}

# Bouwt een CIDATA-ISO uit de bestanden in $WORKDIR
build_seed_iso() {
    log "Seed-ISO bouwen: ${SEED_ISO}"
    local files=("${WORKDIR}/user-data" "${WORKDIR}/meta-data")
    [[ -f "${WORKDIR}/network-config" ]] && files+=("${WORKDIR}/network-config")
    xorriso -as mkisofs -quiet -output "$SEED_ISO" \
        -volid CIDATA -joliet -rock "${files[@]}"
    chmod 0644 "$SEED_ISO"
    [[ -s "$SEED_ISO" ]] || die "Seed-ISO ${SEED_ISO} is leeg of niet aangemaakt."
    event CHECK "$CURRENT_STEP" "seed-ISO staat klaar: ${SEED_ISO}" \
        "grootte=$(stat -c%s "$SEED_ISO")B" "bestanden=${#files[@]}"
}

# Schrijft de cloud-init-seed waarmee een VM zijn eigen naam, adres, account
# en sleutels krijgt. Twee plekken gebruiken dit:
#   - route 2, voor de eerste boot van een verse kloon;
#   - route 1, om de VM na het strippen voor het base-image weer persoonlijk
#     te maken (zonder deze seed komt hij terug op een DHCP-adres met een
#     dichtgezet account, omdat cloud-init dan geen databron vindt).
write_personalization_seed() {
    # --- netwerkconfiguratie voor cloud-init (NoCloud network-config) ---
    if [[ "$IP_MODE" == "reservation" ]]; then
        cat >"${WORKDIR}/network-config" <<EOF
version: 2
ethernets:
  primary:
    match:
      macaddress: "${MAC}"
    dhcp4: true
    dhcp6: false
EOF
    else
        cat >"${WORKDIR}/network-config" <<EOF
version: 2
ethernets:
  primary:
    match:
      macaddress: "${MAC}"
    dhcp4: false
    dhcp6: false
    addresses:
      - ${IPaddress}/${NETMASK_PREFIX}
    routes:
      - to: default
        via: ${GATEWAY}
    nameservers:
      search: [${SEARCH_DOMAIN}]
      addresses: [${DNS_SERVERS//,/, }]
EOF
    fi

    # Nieuw instance-id => cloud-init draait al zijn per-instance modules opnieuw
    cat >"${WORKDIR}/meta-data" <<EOF
instance-id: ${Hostname}-$(date +%s)
local-hostname: ${Hostname}
EOF

    cat >"${WORKDIR}/user-data" <<EOF
#cloud-config
hostname: ${Hostname}
fqdn: ${Hostname}.${SEARCH_DOMAIN}
manage_etc_hosts: true
timezone: ${TIMEZONE}
locale: ${LOCALE}

# Geen wachtwoord-logins via ssh; het console-wachtwoord staat al in het image
ssh_pwauth: false
disable_root: true

# Verse hostkeys voor deze VM
ssh_deletekeys: true
ssh_genkeytypes: [ed25519, rsa]

users:
  - name: ${ADMIN_USER}
    groups: [adm, sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL:ALL) ALL"
    lock_passwd: false
    ssh_authorized_keys:
${SSH_KEYS_YAML4}

write_files:
  - path: /etc/ssh/sshd_config.d/99-makevm-hardening.conf
    permissions: "0644"
    content: |
$(sshd_hardening | sed 's/^/      /')

  - path: /etc/fail2ban/jail.local
    permissions: "0644"
    content: |
$(fail2ban_jail | sed 's/^/      /')

bootcmd:
  # netplan-bestand van de oorspronkelijke installatie hoort bij een andere MAC
  - rm -f /etc/netplan/00-installer-config.yaml

runcmd:
  # cloud-init zet de default_user op slot als het ooit zonder databron
  # opstartte; dit maakt inloggen op de console weer mogelijk
  - [ sh, -c, "usermod -U ${ADMIN_USER} 2>/dev/null || true" ]
  # firewall opnieuw zetten voor dit adres
  - ufw --force reset
  - ufw default deny incoming
  - ufw default allow outgoing
$(ufw_ssh_rules "  - ")
  - ufw --force enable
  - systemctl enable --now ufw fail2ban ssh
  - systemctl restart ssh fail2ban
  # eigen machine-id bij de volgende boot
  - [ sh, -c, ": > /etc/machine-id; rm -f /var/lib/dbus/machine-id" ]
$(if [[ "$RESIZED" == "yes" ]]; then cat <<'GROW'
  # schijf is groter gemaakt dan het base-image
  - [ sh, -c, "growpart /dev/vda 3 || true" ]
  - [ sh, -c, "pvresize /dev/vda3 2>/dev/null || true" ]
  - [ sh, -c, "root=$(findmnt -no SOURCE /); lvextend -r -l +100%FREE $root 2>/dev/null || resize2fs $root || true" ]
GROW
fi)
EOF

    build_seed_iso
}

# Wacht tot de VM ssh accepteert met de private key uit deze map.
# -F /dev/null en de lege known_hosts-bestanden maken deze controle
# onafhankelijk van ssh-configuratie en oude hostkeys.
wait_for_ssh() {
    local secs="${1:-$SSH_WAIT_SECS}" waited=0 next="$HEARTBEAT_SECS" dom
    log "Wachten tot ${IPaddress} ssh accepteert (max $((secs/60)) minuten)"
    while (( waited < secs )); do
        if ssh -F /dev/null \
               -i "$SSH_PRIVKEY_FILE" \
               -o IdentitiesOnly=yes \
               -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null \
               -o GlobalKnownHostsFile=/dev/null \
               -o CheckHostIP=no \
               -o PreferredAuthentications=publickey \
               -o LogLevel=ERROR \
               -o BatchMode=yes -o ConnectTimeout=5 \
               "${ADMIN_USER}@${IPaddress}" true 2>/dev/null; then
            event CHECK "$CURRENT_STEP" "ssh met $(basename "$SSH_PRIVKEY_FILE") werkt op ${IPaddress}" "wacht=${waited}s"
            return 0
        fi
        sleep 10; waited=$(( waited + 10 ))
        # hartslag: laat zien dat er nog gewacht wordt en hoe lang nog
        if (( waited >= next )); then
            next=$(( next + HEARTBEAT_SECS ))
            dom="$(virsh domstate "$Hostname" 2>/dev/null | head -1 | tr ' ' '-')"
            event WAIT "$CURRENT_STEP" "nog geen ssh op ${IPaddress}" \
                "wacht=${waited}s" "resterend=$(( secs - waited ))s" "domstate=${dom:-onbekend}"
        fi
    done
    event WARN "$CURRENT_STEP" "ssh op ${IPaddress} kwam niet beschikbaar binnen ${secs}s"
    return 1
}

# De vaste hardwaredefinitie van elke VM die dit script maakt
virtinstall_common() {
    printf '%s\n' \
        --connect qemu:///system \
        --name "$Hostname" \
        --machine "$MACHINE" \
        --cpu "$CPU_MODEL" \
        --vcpus "$VCPUS" \
        --memory "$RAM_MB" \
        --osinfo "$OS_VARIANT" \
        --features acpi=on,apic=on,vmport.state=off \
        --clock offset=utc,rtc_tickpolicy=catchup,pit_tickpolicy=delay,hpet_present=no \
        --pm suspend_to_mem.enabled=off,suspend_to_disk.enabled=off \
        --network "network=${LIBVIRT_NET},model=virtio,mac=${MAC}" \
        --graphics "$GRAPHICS" \
        --video "$VIDEO" \
        --controller type=usb,model=qemu-xhci \
        --input tablet,bus=usb \
        --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
        --rng /dev/urandom,model=virtio \
        --watchdog itco,action=reset \
        --memballoon virtio \
        --console pty,target_type=serial
}

########################################################################
# 7. DHCP-reservering in libvirt (indien gevraagd)
########################################################################

if [[ "$IP_MODE" == "reservation" || "$IP_MODE" == "both" ]]; then
    step_start dhcp-reservering "MAC ${MAC} -> ${IPaddress} in netwerk ${LIBVIRT_NET}"
    if virsh net-dumpxml "$LIBVIRT_NET" | grep -q "ip='${IPaddress}'"; then
        step_skip dhcp-reservering "reservering voor ${IPaddress} bestaat al in ${LIBVIRT_NET}"
    else
        virsh net-update "$LIBVIRT_NET" add ip-dhcp-host \
            "<host mac='${MAC}' name='${Hostname}' ip='${IPaddress}'/>" \
            --live --config
        step_ok dhcp-reservering "reservering toegevoegd aan ${LIBVIRT_NET}"
    fi
fi

########################################################################
# 8A. ROUTE 1 - VOLLEDIGE INSTALLATIE VANAF ISO
########################################################################

full_install() {
    step_start install-seed "autoinstall-seed maken (geen base-image ${BASE_IMAGE})"

    # --- netplan-blok ---
    local net_yaml
    if [[ "$IP_MODE" == "reservation" ]]; then
        net_yaml="        dhcp4: true
        dhcp6: false"
    else
        net_yaml="        dhcp4: false
        dhcp6: false
        addresses:
          - ${IPaddress}/${NETMASK_PREFIX}
        routes:
          - to: default
            via: ${GATEWAY}
        nameservers:
          search: [${SEARCH_DOMAIN}]
          addresses: [${DNS_SERVERS//,/, }]"
    fi

    # --- storage-blok ---
    local storage_yaml
    if [[ "$STORAGE_LAYOUT" == "lvm" ]]; then
        storage_yaml="    layout:
      name: lvm
      sizing-policy: ${LVM_SIZING}"
    else
        storage_yaml="    layout:
      name: direct"
    fi

    cat >"${WORKDIR}/meta-data" <<EOF
instance-id: ${Hostname}-install-$(date +%s)
local-hostname: ${Hostname}
EOF

    cat >"${WORKDIR}/user-data" <<EOF
#cloud-config
autoinstall:
  version: 1
  locale: ${LOCALE}
  keyboard:
    layout: ${KEYBOARD_LAYOUT}
  timezone: ${TIMEZONE}

  # Gematcht op MAC, zodat deze regel in een kloon (andere MAC) vanzelf
  # niet meer van toepassing is.
  network:
    version: 2
    ethernets:
      primary:
        match:
          macaddress: "${MAC}"
${net_yaml}

  storage:
${storage_yaml}

  identity:
    hostname: ${Hostname}
    username: ${ADMIN_USER}
    password: "${ADMIN_PWHASH}"

  ssh:
    install-server: true
    allow-pw: false
    authorized-keys:
${SSH_KEYS_YAML}

  packages:
    - openssh-server
    - fail2ban
    - ufw
    - cloud-init
$(for p in ${EXTRA_PACKAGES}; do echo "    - ${p}"; done)

  # Tijdens de installatie alle beschikbare updates meenemen. package_update
  # en package_upgrade horen hier niet: dat zijn cloud-init-sleutels, die
  # gelden alleen onder user-data (verderop) en werden hier genegeerd.
  updates: all

  # Na de installatie uitzetten in plaats van rebooten. Het script koppelt
  # daarna pas de seed-cdrom los en start de VM. Zou die seed bij de eerste
  # boot nog in de lade zitten, dan neemt cloud-init in de gast deze CIDATA
  # als databron - en die bevat alleen autoinstall-configuratie, geen
  # sleutels. Dat leverde eerder een VM op zonder authorized_keys.
  shutdown: poweroff

  # Alles onder user-data is cloud-config voor het GEINSTALLEERDE systeem.
  # Let op: write_files hoort hier en niet bovenaan onder autoinstall:,
  # daar is het geen geldige sleutel en wordt het zonder melding genegeerd.
  user-data:
    disable_root: true
    ssh_pwauth: false
    # bij de eerste start nog een keer bijwerken; beveilig.sh doet daarna
    # zelf ook een apt update + dist-upgrade voor het installeert
    package_update: true
    package_upgrade: true
    write_files:
      - path: /etc/ssh/sshd_config.d/99-makevm-hardening.conf
        permissions: "0644"
        content: |
$(sshd_hardening | sed 's/^/          /')
      - path: /etc/fail2ban/jail.local
        permissions: "0644"
        content: |
$(fail2ban_jail | sed 's/^/          /')

  late-commands:
    # ssh-sleutels rechtstreeks in het doelsysteem zetten. Dit staat los van
    # cloud-init, zodat inloggen ook lukt als daar iets misgaat.
$(printf '%s' "$SSH_KEYS_PLAIN" | target_write_cmds "/home/${ADMIN_USER}/.ssh/authorized_keys" 0600)
    - chmod 0700 /target/home/${ADMIN_USER}/.ssh
    - curtin in-target -- chown -R ${ADMIN_USER}:${ADMIN_USER} /home/${ADMIN_USER}/.ssh
    # sshd-hardening en fail2ban-jail, om dezelfde reden ook hier
$(sshd_hardening | target_write_cmds /etc/ssh/sshd_config.d/99-makevm-hardening.conf 0644)
$(fail2ban_jail | target_write_cmds /etc/fail2ban/jail.local 0644)
    # ufw: alles dicht behalve ssh
    - curtin in-target -- ufw --force reset
    - curtin in-target -- ufw default deny incoming
    - curtin in-target -- ufw default allow outgoing
$(ufw_ssh_rules "    - curtin in-target -- ")
    - curtin in-target -- ufw --force enable
    - curtin in-target -- systemctl enable ssh ufw fail2ban
EOF

    build_seed_iso
    step_ok install-seed "seed voor autoinstall van ${Hostname} klaar"

    step_start schijf-aanmaken "lege systeemschijf ${DISK_PATH} (${DISK_GB}G)"
    qemu-img create -f qcow2 "$DISK_PATH" "${DISK_GB}G" >/dev/null
    chown libvirt-qemu:kvm "$DISK_PATH"
    chmod 0640 "$DISK_PATH"
    [[ -s "$DISK_PATH" ]] || die "Schijf ${DISK_PATH} is niet aangemaakt."
    step_ok schijf-aanmaken "${DISK_PATH} aangemaakt"

    local opts=()
    mapfile -t opts < <(virtinstall_common)
    opts+=(
        --disk "path=${DISK_PATH},format=qcow2,bus=virtio,discard=unmap"
        --disk "path=${SEED_ISO},device=cdrom,readonly=on"
        --location "${INSTALL_ISO},kernel=casper/vmlinuz,initrd=casper/initrd"
        --extra-args "autoinstall ds=nocloud console=tty0 console=ttyS0,115200n8 ---"
        --noautoconsole
        --noreboot
        --wait -1
    )

    step_start installatie "onbeheerde installatie vanaf ${ISO} (${VCPUS} vCPU, ${RAM_MB} MiB, ${DISK_GB}G, ${IPaddress})"
    log "Dit duurt meestal 10-25 minuten; meekijken kan met: virsh console ${Hostname}"
    # virt-install zegt zelf niets meer tot het klaar is; de hartslag laat
    # zien dat er nog iets gebeurt en in welke toestand de VM staat.
    heartbeat_start installatie "installatie loopt nog"
    local rc=0
    logged virt-install "${opts[@]}" || rc=$?
    heartbeat_stop
    (( rc == 0 )) || { step_fail installatie "virt-install stopte met exitcode ${rc}"; return "$rc"; }

    # Door "shutdown: poweroff" en --noreboot staat de VM nu uit.
    virsh domstate "$Hostname" 2>/dev/null | grep -q "shut off" || wait_for_shutoff
    step_ok installatie "installatie afgerond; VM staat uit"

    step_start eerste-start "seed loskoppelen en ${Hostname} voor het eerst starten"
    # Seed loskoppelen VOOR de eerste boot van het nieuwe systeem.
    eject_seed
    rm -f "$SEED_ISO"

    virsh start "$Hostname" >/dev/null
    step_ok eerste-start "VM '${Hostname}' gestart" "domstate=$(virsh domstate "$Hostname" 2>/dev/null | tr ' ' '-')"
}

# Maakt van de draaiende, geverifieerde VM een base-image
# Maakt de geinstalleerde VM geschikt als sjabloon: cloud-init moet in een
# kloon opnieuw kunnen draaien, met de CIDATA-seed van die kloon als bron.
# Dit gebeurt hier in de draaiende gast en niet als late-command tijdens de
# installatie: subiquity zet de sleutels en de sshd-instellingen pas bij de
# eerste boot neer via /etc/cloud/cloud.cfg.d/99-installer.cfg. Wie dat
# bestand tijdens de installatie weghaalt, houdt een VM zonder sleutels over.
prepare_for_clone() {
    step_start sjabloon-voorbereiden "cloud-init in de gast resetten (via qemu-guest-agent)"
    guest_agent_ready 30 || { step_fail sjabloon-voorbereiden "qemu-guest-agent antwoordt niet; sjabloon niet voorbereid"; return 1; }
    guest_exec '
set -e
# installer-configuratie weg: die pint de databron op None en blokkeert de
# netwerkconfiguratie van een kloon
rm -f /etc/cloud/cloud-init.disabled
rm -f /etc/cloud/cloud.cfg.d/99-installer.cfg
rm -f /etc/cloud/cloud.cfg.d/*subiquity-disable-cloudinit-networking.cfg
cat >/etc/cloud/cloud.cfg.d/99-makevm-nocloud.cfg <<CFG
datasource_list: [ NoCloud, None ]
system_info:
  default_user:
    name: '"${ADMIN_USER}"'
    groups: [adm, sudo]
    shell: /bin/bash
    sudo: ALL=(ALL:ALL) ALL
    # zonder dit zet cloud-init het wachtwoord van dit account op slot
    # (usermod -L) zodra het de default_user opnieuw aanmaakt; inloggen op
    # de console lukt dan niet meer
    lock_passwd: false
CFG
chmod 0644 /etc/cloud/cloud.cfg.d/99-makevm-nocloud.cfg
# cloud-init-status wissen, zodat een kloon alle per-instance modules opnieuw
# draait; --machine-id is de sjabloonstand van cloud-init zelf
cloud-init clean --logs --seed --machine-id >/dev/null 2>&1 || {
    rm -rf /var/lib/cloud/instance /var/lib/cloud/instances /var/lib/cloud/data /var/lib/cloud/sem /var/lib/cloud/seed
    : > /etc/machine-id
}
rm -f /var/lib/dbus/machine-id
rm -f /etc/netplan/50-cloud-init.yaml
' || { step_fail sjabloon-voorbereiden "commando's in de gast mislukten"; return 1; }
    step_ok sjabloon-voorbereiden "gast is gereset; een kloon kan cloud-init opnieuw draaien"
    return 0
}

# Elke uitkomst hiervan wordt gemeld: geslaagd, overgeslagen of mislukt. Zo
# is achteraf altijd te zien waarom {naam}-base.qcow2 er wel of niet staat.
make_base_image() {
    step_start base-image "kopie maken: ${DISK_PATH} -> ${BASE_IMAGE}"

    if [[ -e "$BASE_IMAGE" ]]; then
        BASE_OK="ja"
        step_skip base-image "base-image bestaat al: ${BASE_IMAGE} (niet overschreven)"
        return 0
    fi

    # Ruimte vooraf controleren: de kopie is net zo groot als wat de schijf nu
    # in gebruik heeft. Zonder deze controle strandt het pas halverwege de cp.
    local need_mb avail_mb
    need_mb="$(du -BM --summarize "$DISK_PATH" 2>/dev/null | cut -f1 | tr -dc '0-9')"
    avail_mb="$(df -BM --output=avail "$(dirname "$BASE_IMAGE")" 2>/dev/null | tail -1 | tr -dc '0-9')"
    if [[ -n "$need_mb" && -n "$avail_mb" ]]; then
        event CHECK base-image "ruimtecontrole voor de kopie" "nodig=${need_mb}M" "vrij=${avail_mb}M"
        if (( avail_mb < need_mb + 1024 )); then
            BASE_OK="nee"
            step_fail base-image "te weinig ruimte voor ${BASE_IMAGE}: ${need_mb}M nodig, ${avail_mb}M vrij"
            return 1
        fi
    fi

    prepare_for_clone || warn "Het base-image is niet als sjabloon voorbereid; klonen kan mislukken."

    CURRENT_STEP="base-image"
    log "VM '${Hostname}' stoppen voor een consistente kopie"
    virsh shutdown "$Hostname" >/dev/null 2>&1 || true
    wait_for_shutoff

    log "Kopieren naar ${BASE_IMAGE} (${need_mb:-?}M); dit kan enkele minuten duren"
    heartbeat_start base-image "kopie naar ${BASE_IMAGE} loopt nog"
    local rc=0
    cp --reflink=auto "$DISK_PATH" "${BASE_IMAGE}.tmp" || rc=$?
    heartbeat_stop

    if (( rc != 0 )); then
        rm -f "${BASE_IMAGE}.tmp"
        BASE_OK="nee"
        step_fail base-image "kopieren mislukte (cp exitcode ${rc}); ${BASE_IMAGE} is niet gemaakt"
        log "VM '${Hostname}' toch weer starten"
        virsh start "$Hostname" >/dev/null 2>&1 || warn "VM '${Hostname}' kon niet worden gestart."
        return 1
    fi

    mv "${BASE_IMAGE}.tmp" "$BASE_IMAGE"
    chown libvirt-qemu:kvm "$BASE_IMAGE"
    chmod 0640 "$BASE_IMAGE"

    # Nacontrole: staat het bestand er echt en is het een bruikbaar qcow2?
    if [[ ! -s "$BASE_IMAGE" ]]; then
        BASE_OK="nee"
        step_fail base-controle "${BASE_IMAGE} bestaat niet of is leeg na het kopieren"
    elif ! qemu-img info --output=json "$BASE_IMAGE" >/dev/null 2>&1; then
        BASE_OK="nee"
        step_fail base-controle "${BASE_IMAGE} is geen leesbaar qcow2-bestand"
    else
        BASE_OK="ja"
        event CHECK base-controle "base-image gecontroleerd: ${BASE_IMAGE}" \
            "grootte=$(du -BM --summarize "$BASE_IMAGE" | cut -f1 | tr -dc '0-9')M" \
            "virtueel=$(( $(image_virtual_bytes "$BASE_IMAGE") / 1024**3 ))G"
    fi

    CURRENT_STEP="base-image"
    if [[ "$BASE_OK" != "ja" ]]; then
        log "VM '${Hostname}' toch weer starten"
        virsh start "$Hostname" >/dev/null 2>&1 || warn "VM '${Hostname}' kon niet worden gestart."
        return 1
    fi

    # Bewust niet starten: de schijf is nu een sjabloon zonder netplan en
    # zonder cloud-init-status. restore_after_base() legt eerst de seed terug.
    step_ok base-image "base-image staat klaar: ${BASE_IMAGE}"
    return 0
}

# Na make_base_image is de schijf van de VM gestript voor gebruik als sjabloon.
# Zou hij zo opstarten, dan vindt cloud-init geen databron, valt hij terug op
# DHCP (dus een ander adres dan ${IPaddress}) en zet hij het wachtwoord van
# ${ADMIN_USER} op slot. Daarom krijgt hij dezelfde seed als een kloon en maakt
# cloud-init hem bij deze boot weer persoonlijk.
restore_after_base() {
    step_start herstel-na-base "VM na het strippen weer persoonlijk maken met een cloud-init-seed"
    write_personalization_seed
    if ! insert_seed; then
        step_fail herstel-na-base "seed-cdrom kon niet worden teruggelegd"
        virsh start "$Hostname" >/dev/null 2>&1 || warn "VM '${Hostname}' kon niet worden gestart."
        return 1
    fi
    if ! virsh start "$Hostname" >/dev/null 2>&1; then
        step_fail herstel-na-base "VM '${Hostname}' kon niet worden gestart"
        return 1
    fi
    step_ok herstel-na-base "seed teruggelegd; cloud-init zet naam, ${IPaddress}, ${ADMIN_USER} en de sleutels terug"
    return 0
}

########################################################################
# 8B. ROUTE 2 - KLONEN UIT HET BASE-IMAGE
########################################################################

clone_from_base() {
    step_start kloon-seed "cloud-init-seed maken voor kloon uit ${BASE_IMAGE}"

    write_personalization_seed
    step_ok kloon-seed "seed met naam ${Hostname} en adres ${IPaddress} klaar"

    step_start kloon-schijf "schijf kopieren uit base-image: ${BASE_IMAGE} -> ${DISK_PATH}"
    heartbeat_start kloon-schijf "kopie uit het base-image loopt nog"
    local rc=0
    cp --reflink=auto "$BASE_IMAGE" "${DISK_PATH}.tmp" || rc=$?
    heartbeat_stop
    (( rc == 0 )) || { rm -f "${DISK_PATH}.tmp"; step_fail kloon-schijf "kopieren uit ${BASE_IMAGE} mislukte (exitcode ${rc})"; return "$rc"; }
    mv "${DISK_PATH}.tmp" "$DISK_PATH"
    chown libvirt-qemu:kvm "$DISK_PATH"
    chmod 0640 "$DISK_PATH"
    [[ -s "$DISK_PATH" ]] || { step_fail kloon-schijf "${DISK_PATH} is leeg na het kopieren"; return 1; }

    if [[ "$RESIZED" == "yes" ]]; then
        log "Schijf vergroten naar ${DISK_GB}G"
        qemu-img resize "$DISK_PATH" "${DISK_GB}G" >/dev/null
    fi
    event CHECK kloon-schijf "schijf klaar: ${DISK_PATH}" \
        "grootte=$(du -BM --summarize "$DISK_PATH" | cut -f1 | tr -dc '0-9')M" "vergroot=${RESIZED}"
    step_ok kloon-schijf "kloonschijf aangemaakt"

    local opts=()
    mapfile -t opts < <(virtinstall_common)
    opts+=(
        --disk "path=${DISK_PATH},format=qcow2,bus=virtio,discard=unmap"
        --disk "path=${SEED_ISO},device=cdrom,readonly=on"
        --import
        --boot hd
        --noautoconsole
    )

    step_start vm-aanmaken "VM definieren en starten (${VCPUS} vCPU, ${RAM_MB} MiB, ${DISK_GB}G, ${IPaddress})"
    rc=0
    logged virt-install "${opts[@]}" || rc=$?
    (( rc == 0 )) || { step_fail vm-aanmaken "virt-install stopte met exitcode ${rc}"; return "$rc"; }
    step_ok vm-aanmaken "VM '${Hostname}' aangemaakt" "domstate=$(virsh domstate "$Hostname" 2>/dev/null | tr ' ' '-')"
}

########################################################################
# 9. UITVOEREN
########################################################################

# Oude hostkeys van dit adres/deze naam opruimen; de nieuwe VM krijgt verse
# hostkeys en zonder dit faalt elke latere ssh met "IDENTIFICATION HAS CHANGED".
known_hosts_forget

CURRENT_STEP="bouwen"
if [[ "$BUILD_MODE" == "clone" ]]; then
    # De maatvergelijking met het base-image is in deel 5 gedaan; RESIZED zegt
    # of de kopie nog groter gemaakt moet worden.
    # de mislukte stap heeft zichzelf al gemeld; on_exit schrijft de RESULT-regel
    clone_from_base || exit 1
else
    full_install || exit 1
fi

if [[ "$AUTOSTART" == "yes" ]]; then
    virsh autostart "$Hostname" >/dev/null
    log "VM '${Hostname}' start voortaan mee met de host"
fi

########################################################################
# 10. CONTROLEREN EN AFRONDEN
########################################################################

step_start ssh-controle "controleren of ${Hostname} op ${IPaddress} bereikbaar is"
if wait_for_ssh; then
    ACTIVE="ja"
    known_hosts_learn
    step_ok ssh-controle "VM '${Hostname}' draait en accepteert ssh"
else
    ACTIVE="nee"
    step_fail ssh-controle "geen ssh-verbinding met ${IPaddress}; kijk mee met: virsh console ${Hostname}"
fi

# --- werkt de qemu-guest-agent? ---
# Voor het beveiligen, want beveilig.sh wordt via de agent in de gast gezet en
# daar gedraaid, en voor het base-image, zodat een kloon geen kapotte agent erft.
if [[ "$(virsh domstate "$Hostname" 2>/dev/null | head -1)" == "running" ]]; then
    agent_check || true         # al gemeld; het beveiligen hieronder strandt er zelf op
else
    AGENT_OK="nee"
    step_skip agent-controle "overgeslagen: ${Hostname} draait niet"
fi

# --- beveiligingsmaatregelen in de gast ---
# Dit gebeurt voor het base-image, zodat elke kloon de maatregelen erft, en
# ook op een kloon zelf: het base-image kan ouder zijn dan beveilig.sh.
if [[ "$HARDEN" != "yes" ]]; then
    step_skip beveiligen "overgeslagen met --no-harden"
    step_skip ssh-nacontrole "overgeslagen met --no-harden"
elif [[ "$ACTIVE" != "ja" ]]; then
    step_skip beveiligen "overgeslagen: de VM was niet bereikbaar via ssh"
    step_skip ssh-nacontrole "overgeslagen: de VM was niet bereikbaar via ssh"
else
    harden_guest || true        # al gemeld; de controle hieronder telt
    # beveilig.sh heeft sshd opnieuw ingesteld en ufw aangezet: eerst kijken
    # of we er nog in komen voordat hier een base-image van wordt gemaakt.
    step_start ssh-nacontrole "controleren of ssh na het beveiligen nog werkt"
    if wait_for_ssh 180; then
        step_ok ssh-nacontrole "ssh werkt nog na het beveiligen"
    else
        ACTIVE="nee"
        step_fail ssh-nacontrole "na het beveiligen geen ssh meer op ${IPaddress}; er wordt geen base-image gemaakt. Kijk mee met: virsh console ${Hostname} en in de gast in /var/log/beveilig.log"
    fi
fi

# Base-image maken van een geslaagde, volledige installatie. Elke tak meldt
# expliciet wat er gebeurt, zodat een ontbrekend {naam}-base.qcow2 nooit een
# stilte in het log is.
if [[ "$BASE_EXPECTED" == "yes" ]]; then
    if [[ "$ACTIVE" == "ja" ]]; then
        make_base_image || true     # de fout is al gemeld; de VM zelf is bruikbaar
        if [[ "$BASE_OK" == "ja" ]]; then
            restore_after_base || true      # al gemeld; de controle hieronder wijst het uit
            # cloud-init draait opnieuw en maakt verse hostkeys aan
            step_start ssh-hercontrole "controleren of ${Hostname} na het base-image terugkomt op ${IPaddress}"
            if wait_for_ssh 300; then
                eject_seed
                rm -f "$SEED_ISO"
                known_hosts_forget
                known_hosts_learn
                step_ok ssh-hercontrole "VM '${Hostname}' is weer bereikbaar"
            else
                step_fail ssh-hercontrole "VM kwam na het maken van het base-image niet terug op ssh; kijk mee met: virsh console ${Hostname}"
            fi
        else
            step_skip herstel-na-base "overgeslagen omdat het base-image niet gemaakt is"
            step_skip ssh-hercontrole "overgeslagen omdat het base-image niet gemaakt is"
        fi
    else
        BASE_OK="nee"
        step_skip base-image "geen base-image gemaakt: de VM was niet bereikbaar via ssh"
    fi
elif [[ "$BUILD_MODE" == "clone" ]]; then
    step_skip base-image "VM is uit het bestaande ${BASE_IMAGE} gekloond; niets te kopieren"
else
    step_skip base-image "base-image uitgeschakeld met --no-base"
fi

cat <<EOF

$(log "Klaar.")
  Naam      : ${Hostname}
  Route     : $([[ "$BUILD_MODE" == "clone" ]] && echo "kloon uit ${BASE_IMAGE}" || echo "volledige installatie vanaf ${ISO}")
  IP        : ${IPaddress}/${NETMASK_PREFIX}  (gw ${GATEWAY}, net ${LIBVIRT_NET}, modus ${IP_MODE})
  MAC       : ${MAC}
  Schijf    : ${DISK_PATH}  (${DISK_GB}G)
  Base      : $([[ -e "$BASE_IMAGE" ]] && echo "$BASE_IMAGE" || echo "(geen - ${BASE_OK})")
  Log       : ${LOG_FILE:-(alleen scherm)}${STATUS_FILE:+
  Status    : ${STATUS_FILE}}
  Bereikbaar: ${ACTIVE}
  Console   : virsh console ${Hostname}
  Inloggen  : ssh -i ${SSH_PRIVKEY_FILE} ${ADMIN_USER}@${IPaddress}
  known_hosts: $([[ "$MANAGE_KNOWN_HOSTS" == "yes" ]] && echo "bijgewerkt voor $(printf '%s ' "${KNOWN_HOSTS_ENTRIES[@]%%:*}")" || echo "niet aangeraakt")
  Actief    : ssh (alleen keys), fail2ban (sshd- en recidive-jail), ufw (deny incoming, IPv4+IPv6, ssh vanaf ${SSH_ALLOW_FROM})
  Guest-agent: ${AGENT_OK} - met "ja" kan: virsh snapshot-create-as ${Hostname} naam --disk-only --atomic --quiesce
  Beveiligd : $([[ "$HARDEN" == "yes" ]] && echo "met $(basename "$HARDEN_SCRIPT") - log in de gast: /var/log/beveilig.log" || echo "nee (--no-harden)")
EOF

# Exitcode: 0 = klaar, 1 = fout, 2 = VM draait maar het base-image ontbreekt.
# on_exit schrijft hierna de RESULT-regel met de complete checklist.
if [[ "$ACTIVE" != "ja" ]]; then
    exit 1
elif [[ "$BASE_EXPECTED" == "yes" && "$BASE_OK" != "ja" ]]; then
    exit 2
fi
exit 0
