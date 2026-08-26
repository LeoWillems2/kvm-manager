#!/usr/bin/env bash
#
# snapshot.sh - externe snapshots van een KVM/libvirt-gast beheren.
#
# Doel: een vangnet rond een riskante ingreep (upgrade, patchronde) met een
# snelle terugweg, zonder dat er een woud van overlays achterblijft.
#
# Vijf werkwoorden op een keten die nooit dieper is dan een laag:
#
#   maken     extern disk-only snapshot met --quiesce. De bodem-image
#             (/t/kvm/isms.qcow2) bevriest, de overlay in /t/kvm-ss vangt
#             vanaf dat moment alle schrijfacties op.
#   terug     de ingreep is mislukt: de overlay gaat opzij en wordt vervangen
#             door een lege op dezelfde bodem. De gast ziet dan weer precies
#             de stand van het snapshotmoment; het snapshot blijft openstaan.
#   opruimen  de ingreep is geslaagd: overlay samenvoegen in de bodem
#             (virsh snapshot-delete doet blockcommit + pivot + metadata).
#   lijst     wat staat er open, hoe diep is de keten, hoeveel ruimte kost het
#   controle  klopt de administratie nog (voor cron; exit 1 bij een probleem)
#   backup    een opdracht (borg, cp, rsync) draaien met de bodem vergrendeld,
#             zodat er niet samengevoegd wordt terwijl hij gelezen wordt.
#
# --------------------------------------------------------------------------
# De grendel: waarom backup en opruimen elkaar moeten kennen
# --------------------------------------------------------------------------
# Zolang een snapshot openstaat is de bodem-image een stilstaand bestand:
# qemu opent hem alleen-lezen en alle schrijfacties gaan naar de overlay. Dat
# is precies het moment om er met borg overheen te gaan. Maar "opruimen"
# schrijft de overlay er weer in, en dan verandert het bestand onder de
# backup vandaan - het archief hoort dan bij geen enkele toestand.
#
# Daarom twee lagen:
#
#   1. Een flock op ${GRENDEL_DIR}/snapshot-{vm}.grendel. "backup" pakt hem
#      gedeeld (meerdere backups tegelijk mag), "opruimen" exclusief. Geen
#      zelfgemaakt slotbestand met een pid erin: een flock hangt aan een
#      openstaande filedescriptor, dus de kernel laat hem los zodra het
#      proces stopt - hoe het ook stopt. /run/lock is bovendien tmpfs, dus na
#      een herstart is er sowieso geen grendel meer die blijft hangen.
#   2. Een blik op /proc/*/fd voor het geval iemand borg buiten dit script om
#      start. Dat is een vangnet, geen bewijs: het ziet alleen wat deze
#      gebruiker mag zien (als root dus alles).
#
# --------------------------------------------------------------------------
# Waarom "terug" met de hand gaat en niet met virsh snapshot-revert
# --------------------------------------------------------------------------
# Sinds libvirt 9.9 kan snapshot-revert overweg met externe snapshots, maar
# alleen als het snapshot een machinestand heeft. Een disk-only snapshot van
# een draaiende gast krijgt de stand 'disk-snapshot' en daarop weigert
# libvirt (10.0.0, gemeten op deze host):
#
#   error: Invalid target domain state 'disk-snapshot'. Refusing snapshot reversion
#
# Ook met --force. Terugrollen is hier dus: gast uit, de overlay opzij zetten
# en op dezelfde plek een nieuwe, lege overlay op dezelfde bodem-image maken,
# gast aan. De gast ziet dan weer precies de bodem-image, oftewel de stand van
# het snapshotmoment.
#
# Dat gaat bewust niet via de domeindefinitie. virt-xml --edit kan vda wel naar
# de bodem terugwijzen, maar laat dan een verouderd <backingStore> staan dat
# naar datzelfde bestand verwijst; qemu opent het image dan twee keer en de
# gast start niet meer:
#
#   Failed to get "write" lock. Is another process using the image [...]?
#
# Met een verse overlay blijft de definitie ongemoeid, blijft de metadata van
# libvirt kloppen en blijft het snapshot gewoon openstaan als vangnet - u kunt
# de ingreep dus opnieuw proberen. Pas "opruimen" maakt de keten weer plat.
#
# Het alternatief is een snapshot met geheugenstand (--memspec). Daar werkt
# snapshot-revert wel op, en de gast hervat exact waar hij was - geen
# journal-replay, geen InnoDB-recovery. Maar de geheugendump is zo groot als
# het RAM van de gast (isms: 4 GiB) en /t schrijft 88 MB/s, dus dat kost een
# minuut met de gast op pauze, elke keer dat u een snapshot maakt. Voor een
# vangnet rond een geplande ingreep weegt dat niet op tegen 0,5 seconde nu en
# een minuut downtime alleen in het zeldzame geval dat u terug moet.
#
# --------------------------------------------------------------------------
# Waarom "opruimen" wel gewoon virsh doet
# --------------------------------------------------------------------------
# virsh snapshot-delete kan sinds libvirt 9.0 externe snapshots opruimen: het
# doet de blockcommit met pivot op de draaiende gast, gooit het overlaybestand
# weg en werkt de metadata bij. Een eigen blockcommit is niet nodig en laat
# alleen maar administratie achter die niet klopt.
#
# Daarom maakt dit script snapshots MET metadata (geen --no-metadata): dan
# weet libvirt ervan, kan het zelf opruimen, en kan dit script zien of er al
# een snapshot openstaat.
#
# --------------------------------------------------------------------------
# MySQL in de gast
# --------------------------------------------------------------------------
# Voor isms is er geen extra vries-opdracht nodig. --quiesce laat de
# qemu-guest-agent FIFREEZE doen: het filesystem wordt gesynct en stilgezet
# voordat het snapshot valt. Alle tabellen daar zijn InnoDB met
# innodb_flush_log_at_trx_commit=1, sync_binlog=1 en doublewrite aan, en alles
# staat op een filesystem. Elke bevestigde transactie is dus al naar schijf
# gefsynct voordat de bevriezing terugkomt; bij het terugzetten doet InnoDB
# redo-recovery en draait open transacties terug. Dat is de normale,
# ondersteunde manier van herstellen.
#
# Een FLUSH TABLES WITH READ LOCK via /etc/qemu/fsfreeze-hook.d is pas nodig
# als er niet-crashveilige tabellen bijkomen (MyISAM/Aria), als u de
# binlog-positie van het snapshot wilt vastleggen om er een replica mee te
# vullen, of als flush_log_at_trx_commit naar 0 of 2 gaat. Let op: die hook
# draait alleen als qemu-ga met -F start; op Ubuntu is dat niet zo, dus het
# bestand /etc/qemu/fsfreeze-hook in de gast doet daar vandaag niets.
#
# --------------------------------------------------------------------------
# Meldingen
# --------------------------------------------------------------------------
# Elke stap meldt zich met een vaste regel op het scherm en in het log:
#
#   2026-08-22T11:02:04+02:00 [snapshot] run=... vm=isms step=maken \
#       status=OK duur=1s msg="snapshot voor-upgrade staat open"
#
# status: PLAN START INFO CHECK WAIT OK SKIP WARN FAIL RESULT.
# Een run is goed afgelopen als de laatste regel status=RESULT result=ok heeft.
# Exitcodes: 0 = klaar, 1 = fout, 3 = controle vond een probleem.
#
# Zie snapshot.sh -h voor het gebruik.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

########################################################################
# 1. INSTELLINGEN
########################################################################

DOMAIN="isms"                     # voorlopig alleen deze gast; -d om af te wijken
SNAP_DIR="/t/kvm-ss"              # hier komen de overlays
SNAP_PREFIX="snap"                # standaardnaam: snap-JJJJMMDD-UUMM
MIN_FREE_GB="10"                  # zoveel vrije ruimte eisen voor een overlay
SHUTDOWN_WAIT="180"               # hoe lang netjes afsluiten mag duren bij "terug"
FORCE_STOP="no"                   # --hard: niet netjes afsluiten maar meteen destroy
AGENT_WAIT="120"                  # hoe lang wachten tot de agent weer antwoordt
ASSUME_YES="no"                   # -y: niets vragen
DRY_RUN="no"                      # -n: alleen laten zien wat er zou gebeuren
QUIESCE="yes"                     # --geen-quiesce: zonder bevriezing (crash-consistent)
GRENDEL_DIR="/run/lock"           # tmpfs: na een herstart is elke grendel weg
GRENDEL_WACHT="0"                 # --grendel-wacht SEC: zolang op de ander wachten

LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE=""                       # leeg => ${LOG_DIR}/snapshot-{vm}-{tijd}.log, "-" => niet loggen
STATUS_FILE=""

########################################################################
# 2. MELDINGEN
########################################################################

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
RUN_STARTED="$(date +%Y-%m-%dT%H:%M:%S%:z)"
CURRENT_STEP="start"
STEP_STARTED_AT="$(date +%s)"
FAILED_STEP=""
ACTION="geen"
SNAP_NAME=""
RESULT_EXTRA=""

_ts()  { date +%Y-%m-%dT%H:%M:%S%:z; }
_now() { date +%s; }

status_write() {
    [[ -n "${STATUS_FILE:-}" ]] || return 0
    local tmp="${STATUS_FILE}.${BASHPID}.tmp"
    {
        cat >"$tmp" <<EOF
run=${RUN_ID}
pid=$$
vm=${DOMAIN}
actie=${ACTION}
snapshot=${SNAP_NAME:-geen}
gestart=${RUN_STARTED}
bijgewerkt=$(_ts)
step=${1}
status=${2}
msg=${3}
log=${LOG_FILE:-geen}
EOF
        mv -f "$tmp" "$STATUS_FILE" </dev/null
        chmod 0644 "$STATUS_FILE"
    } 2>/dev/null || true
    return 0
}

# event STATUS STAP BOODSCHAP [sleutel=waarde ...]
event() {
    local status="$1" step="$2" msg="$3"; shift 3
    local extra="$*" color line screen
    msg="${msg//$'\n'/ }"; msg="${msg//\"/\'}"
    line="$(_ts) [snapshot] run=${RUN_ID} vm=${DOMAIN} step=${step} status=${status}"
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

log()   { event INFO  "$CURRENT_STEP" "$*"; }
warn()  { event WARN  "$CURRENT_STEP" "$*"; }
check() { event CHECK "$CURRENT_STEP" "$*"; }
die()   { FAILED_STEP="$CURRENT_STEP"; event FAIL "$CURRENT_STEP" "$*"; exit 1; }

step_start() { CURRENT_STEP="$1"; STEP_STARTED_AT="$(_now)"; event START "$1" "${2:-begonnen}"; }
step_ok()    { event OK   "${1:-$CURRENT_STEP}" "${2:-klaar}" "duur=$(( $(_now) - STEP_STARTED_AT ))s"; }
step_skip()  { event SKIP "$1" "$2"; }

logged() {
    local rc
    [[ -n "${LOG_FILE:-}" ]] || { "$@"; return $?; }
    set +e
    "$@" 2>&1 | tee -a "$LOG_FILE"
    rc=${PIPESTATUS[0]}
    set -e
    return "$rc"
}

init_logging() {
    if [[ "$LOG_FILE" == "-" ]]; then LOG_FILE=""; STATUS_FILE=""; return 0; fi
    if [[ -z "$LOG_FILE" ]]; then
        mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/var/tmp"
        mkdir -p "$LOG_DIR" 2>/dev/null || { LOG_FILE=""; return 0; }
        LOG_FILE="${LOG_DIR}/snapshot-${DOMAIN}-$(date +%Y%m%d-%H%M%S).log"
    else
        LOG_DIR="$(dirname "$LOG_FILE")"
        mkdir -p "$LOG_DIR" 2>/dev/null || true
    fi
    [[ -z "$STATUS_FILE" ]] && STATUS_FILE="${LOG_DIR}/snapshot-${DOMAIN}.status"
    if ! : >"$LOG_FILE" 2>/dev/null; then LOG_FILE=""; STATUS_FILE=""; return 0; fi
    chmod 0644 "$LOG_FILE" 2>/dev/null || true
    ln -sfn "$LOG_FILE" "${LOG_DIR}/snapshot-${DOMAIN}-laatste.log" 2>/dev/null || true
    [[ -n "${SUDO_USER:-}" ]] && chown -h "$SUDO_USER" "$LOG_DIR" "$LOG_FILE" \
        "${LOG_DIR}/snapshot-${DOMAIN}-laatste.log" 2>/dev/null
    return 0
}

on_err() {
    local rc="$1" line="$2" cmd="$3"
    FAILED_STEP="$CURRENT_STEP"
    event FAIL "$CURRENT_STEP" "onverwachte fout bij: ${cmd}" "exit=${rc}" "regel=${line}"
    return 0
}

# Eindregel: altijd, ook bij ctrl-c. Hierin staat de stand van de keten, zodat
# een halverwege afgebroken run niet hoeft te worden afgeleid uit losse regels.
on_exit() {
    local rc=$?
    trap - EXIT ERR
    [[ "$CURRENT_STEP" == "start" && $rc -eq 0 ]] && exit 0
    local state="-" bron="-" diep="-" open="-" result
    if virsh dominfo "$DOMAIN" &>/dev/null; then
        state="$(virsh domstate "$DOMAIN" 2>/dev/null | head -1 | tr ' ' '-')"
        bron="$(disk_source 2>/dev/null || echo '-')"
        diep="$(chain_depth "$bron" 2>/dev/null || echo '-')"
        open="$(snapshot_names 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
        [[ -z "$open" ]] && open="geen"
    fi
    case "$rc" in
        0) result="ok" ;;
        3) result="controle-gaf-problemen" ;;
        *) result="fout" ;;
    esac
    event RESULT einde "run afgerond" \
        "result=${result}" "exit=${rc}" "actie=${ACTION}" \
        "mislukte_stap=${FAILED_STEP:-geen}" "vm_status=${state}" \
        "actieve_schijf=${bron}" "keten_diep=${diep}" "open_snapshots=${open}" \
        ${RESULT_EXTRA:+$RESULT_EXTRA} "log=${LOG_FILE:-geen}"
    exit "$rc"
}

trap 'on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR
trap on_exit EXIT
trap 'FAILED_STEP="$CURRENT_STEP"; event FAIL "$CURRENT_STEP" "afgebroken door signaal INT (ctrl-c)"; exit 130' INT
trap 'FAILED_STEP="$CURRENT_STEP"; event FAIL "$CURRENT_STEP" "afgebroken door signaal TERM"; exit 143' TERM
trap 'FAILED_STEP="$CURRENT_STEP"; event FAIL "$CURRENT_STEP" "afgebroken door signaal HUP (terminal weg?)"; exit 129' HUP

confirm() {
    [[ "$ASSUME_YES" == "yes" ]] && return 0
    local answer
    read -rp "$1 [j/N] " answer
    [[ "$answer" =~ ^([jJ]|[yY])$ ]]
}

########################################################################
# 3. DE KETEN UITLEZEN
########################################################################

# Het doelapparaat (vda) en het bestand dat de gast nu gebruikt. Dat bestand
# is de bodem-image als er geen snapshot openstaat, en anders de overlay.
DISK_TARGET=""
disk_target() {
    [[ -n "$DISK_TARGET" ]] && { printf '%s\n' "$DISK_TARGET"; return 0; }
    DISK_TARGET="$(virsh domblklist "$DOMAIN" --details 2>/dev/null \
                   | awk '$1=="file" && $2=="disk" {print $3; exit}')"
    [[ -n "$DISK_TARGET" ]] || return 1
    printf '%s\n' "$DISK_TARGET"
}

disk_source() {
    virsh domblklist "$DOMAIN" --details 2>/dev/null \
        | awk '$1=="file" && $2=="disk" {print $4; exit}'
}

# De onderste laag van de backing chain: het echte image van de gast.
chain_bottom() {
    local f="${1:-}"
    [[ -n "$f" && -e "$f" ]] || return 1
    qemu-img info -U --backing-chain "$f" 2>/dev/null \
        | awk '/^image: /{last=substr($0,8)} END{print last}'
}

# 1 = plat (geen snapshot), 2 = een overlay, 3 of meer = gestapeld
chain_depth() {
    local f="${1:-}"
    [[ -n "$f" && -e "$f" ]] || { echo 0; return 0; }
    qemu-img info -U --backing-chain "$f" 2>/dev/null | grep -c '^image: ' || true
}

snapshot_names() {
    virsh snapshot-list "$DOMAIN" --name 2>/dev/null | sed '/^\s*$/d'
}

snapshot_count() { snapshot_names | wc -l; }

# Het overlaybestand dat bij een snapshotnaam hoort, uit de metadata.
snapshot_file() {
    virsh snapshot-dumpxml "$DOMAIN" "$1" 2>/dev/null \
        | awk -F"'" '/<source file=/{print $2; exit}'
}

snapshot_created() {
    local secs
    secs="$(virsh snapshot-dumpxml "$DOMAIN" "$1" 2>/dev/null \
            | sed -n 's:.*<creationTime>\([0-9]*\)</creationTime>.*:\1:p')"
    [[ -n "$secs" ]] && date -d "@${secs}" '+%Y-%m-%d %H:%M:%S' || echo onbekend
}

dom_running() { [[ "$(virsh domstate "$DOMAIN" 2>/dev/null | head -1)" == "running" ]]; }

# De agent moet antwoorden en het filesystem moet ontdooid zijn, anders is
# --quiesce zinloos of loopt het snapshot vast op een bevroren gast.
agent_ready() {
    local wacht="${1:-15}" eind
    eind=$(( $(_now) + wacht ))
    while (( $(_now) < eind )); do
        virsh qemu-agent-command "$DOMAIN" '{"execute":"guest-ping"}' &>/dev/null && return 0
        sleep 2
    done
    return 1
}

agent_freeze_state() {
    virsh qemu-agent-command "$DOMAIN" '{"execute":"guest-fsfreeze-status"}' 2>/dev/null \
        | sed -n 's/.*"return":"\([a-z]*\)".*/\1/p'
}

human() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}B"; }

# Werkelijk gebruikte ruimte van een overlay: dat is wat u weggooit bij "terug"
# en wat er samengevoegd wordt bij "opruimen".
used_bytes() {
    local f="${1:-}"
    [[ -n "$f" && -e "$f" ]] || { echo 0; return 0; }
    du -B1 "$f" 2>/dev/null | awk '{print $1}' || stat -c %s "$f"
}

free_gb() { df -BG --output=avail "$1" 2>/dev/null | tail -1 | tr -dc '0-9'; }

########################################################################
# 3b. DE GRENDEL
########################################################################

grendel_bestand() { printf '%s\n' "${GRENDEL_DIR}/snapshot-${DOMAIN}.grendel"; }

# Wie hem nu vasthoudt, voor een leesbare weigering.
grendel_houder() {
    local tekst
    tekst="$(cat "$(grendel_bestand)" 2>/dev/null | tr '\n' ' ')"
    printf '%s\n' "${tekst:-onbekend}"
}

# grendel_pakken exclusief|gedeeld [wachttijd]
# Houdt de grendel vast via fd 9, dus tot dit proces stopt. Geeft 1 terug als
# een ander hem heeft; de aanroeper beslist wat dat betekent.
grendel_pakken() {
    local soort="$1" wacht="${2:-0}" pad
    pad="$(grendel_bestand)"
    mkdir -p "$GRENDEL_DIR" 2>/dev/null || true
    # >> en niet >: openen mag de melding van de huidige houder niet wissen
    exec 9>>"$pad" || die "kan grendel ${pad} niet openen"
    local -a vlag
    case "$soort" in
        exclusief) vlag=(-x) ;;   # samenvoegen: niemand anders mag erbij
        gedeeld)   vlag=(-s) ;;   # lezen: meerdere backups tegelijk mag
        *)         die "grendel_pakken: onbekende soort '${soort}'" ;;
    esac
    if (( wacht > 0 )); then vlag+=(-w "$wacht"); else vlag+=(-n); fi
    flock "${vlag[@]}" 9 || return 1
    # nu we hem hebben mag de melding van de vorige houder weg
    : >"$pad" 2>/dev/null || true
    printf 'pid=%s actie=%s vm=%s gestart=%s\n' "$$" "$ACTION" "$DOMAIN" "$(_ts)" \
        >>"$pad" 2>/dev/null || true
    return 0
}

# Tweede laag: wie heeft de bodem-image open, buiten qemu en libvirt om?
# Vangt een borg of cp die zonder "backup" is gestart. Ziet alleen de
# filedescriptors die deze gebruiker mag zien - als root is dat alles.
bodem_lezers() {
    local hit pid naam
    # find doet het readlink-werk in C; /proc/*/fd met de hand aflopen kost
    # op een drukke host tien seconden, dit een fractie daarvan.
    # find geeft 1 terug zodra het ergens in /proc niet mag kijken; dat is hier
    # geen fout, dus wordt het weggevangen (anders slaat pipefail toe).
    { find /proc -maxdepth 3 -path '/proc/[0-9]*/fd/*' -lname "$BASE_DISK" 2>/dev/null || true; } \
    | while IFS= read -r hit; do
        pid="${hit#/proc/}"; pid="${pid%%/fd/*}"
        naam="$(cat "/proc/${pid}/comm" 2>/dev/null || echo onbekend)"
        case "$naam" in
            qemu-system-*|virtqemud|libvirtd|virtlogd) continue ;;
        esac
        printf '%s:%s\n' "$pid" "$naam"
      done | sort -u
    return 0
}

########################################################################
# 4. VOORWAARDEN
########################################################################

# Alles wat voor elk werkwoord moet kloppen. Hier valt het script om als de
# situatie niet is wat het denkt - niet halverwege een blockcommit.
preflight() {
    step_start preflight "situatie van ${DOMAIN} vaststellen"

    command -v virsh    >/dev/null || die "virsh ontbreekt"
    command -v qemu-img >/dev/null || die "qemu-img ontbreekt"
    command -v flock    >/dev/null || die "flock ontbreekt (pakket util-linux)"

    virsh dominfo "$DOMAIN" &>/dev/null || die "domein '${DOMAIN}' bestaat niet"
    disk_target >/dev/null || die "geen bestandsschijf gevonden in ${DOMAIN}"

    ACTIVE_DISK="$(disk_source)"
    [[ -n "$ACTIVE_DISK" ]] || die "kan de actieve schijf van ${DOMAIN} niet bepalen"
    BASE_DISK="$(chain_bottom "$ACTIVE_DISK")" \
        || die "kan de backing chain van ${ACTIVE_DISK} niet lezen"
    DEPTH="$(chain_depth "$ACTIVE_DISK")"
    OPEN_COUNT="$(snapshot_count)"

    log "schijf ${DISK_TARGET}: ${ACTIVE_DISK}"
    log "bodem-image: ${BASE_DISK} (keten ${DEPTH} laag/lagen diep)"
    log "snapshots volgens libvirt: ${OPEN_COUNT}"
    step_ok preflight "situatie vastgesteld"
}

########################################################################
# 5. MAKEN
########################################################################

cmd_maken() {
    ACTION="maken"
    SNAP_NAME="${1:-${SNAP_PREFIX}-$(date +%Y%m%d-%H%M)}"
    local overlay="${SNAP_DIR}/${DOMAIN}-${SNAP_NAME}.qcow2"

    event PLAN run "stappen van deze run" "actie=maken" \
        "stappen=preflight,weigeringen,snapshot,nacontrole,einde"
    preflight

    # --- hard weigeren: een keten hoort maar een laag diep te zijn ---
    step_start weigeringen "controleren of er niet al iets openstaat"
    if (( OPEN_COUNT > 0 )); then
        local naam
        naam="$(snapshot_names | paste -sd, -)"
        die "er staat al een snapshot open (${naam%% }); ruim dat eerst op met: $(basename "$0") opruimen"
    fi
    if (( DEPTH > 1 )); then
        die "de gast draait al op een overlay (${ACTIVE_DISK}) zonder dat libvirt een snapshot kent; kijk met: $(basename "$0") controle"
    fi
    [[ -e "$overlay" ]] && die "${overlay} bestaat al; kies een andere naam of ruim dat bestand op"
    dom_running || die "${DOMAIN} draait niet; een snapshot met --quiesce vereist een draaiende gast"

    mkdir -p "$SNAP_DIR" 2>/dev/null || true
    [[ -d "$SNAP_DIR" ]] || die "${SNAP_DIR} bestaat niet en is niet te maken"
    local vrij; vrij="$(free_gb "$SNAP_DIR")"
    (( ${vrij:-0} >= MIN_FREE_GB )) \
        || die "nog ${vrij}G vrij op ${SNAP_DIR}; de overlay groeit mee met elke schrijfactie in de gast (grens: ${MIN_FREE_GB}G)"
    check "vrije ruimte op ${SNAP_DIR}: ${vrij}G"

    # --- de agent moet kunnen bevriezen, anders is het snapshot alleen
    #     crash-consistent en weten we dat niet ---
    if [[ "$QUIESCE" == "yes" ]]; then
        agent_ready 15 || die "de qemu-guest-agent in ${DOMAIN} antwoordt niet; zonder bevriezing is het snapshot alleen crash-consistent. Kijk in de gast met: systemctl status qemu-guest-agent (of gebruik --geen-quiesce als u dat bewust accepteert)"
        local vries; vries="$(agent_freeze_state)"
        case "$vries" in
            thawed) check "agent antwoordt, filesystem is ontdooid" ;;
            frozen) die "het filesystem in ${DOMAIN} staat al bevroren; ontdooien met: virsh domfsthaw ${DOMAIN}" ;;
            *)      die "de agent kent guest-fsfreeze-status niet; --quiesce werkt niet op ${DOMAIN}" ;;
        esac
    else
        warn "zonder --quiesce: het snapshot wordt crash-consistent, bij terugzetten doet het filesystem journal-replay"
    fi
    step_ok weigeringen "niets in de weg"

    # --- het snapshot zelf ---
    step_start snapshot "extern disk-only snapshot '${SNAP_NAME}' maken"
    local -a args=( snapshot-create-as "$DOMAIN" "$SNAP_NAME"
                    --disk-only --atomic
                    --diskspec "${DISK_TARGET},file=${overlay},snapshot=external" )
    [[ "$QUIESCE" == "yes" ]] && args+=( --quiesce )
    if [[ "$DRY_RUN" == "yes" ]]; then
        step_skip snapshot "droogloop; zou uitvoeren: virsh ${args[*]}"
        return 0
    fi
    logged virsh "${args[@]}" || die "snapshot maken mislukt"
    step_ok snapshot "snapshot '${SNAP_NAME}' gemaakt"

    # --- nacontrole: wijst de gast echt naar de overlay en staat de bodem stil ---
    step_start nacontrole "controleren of de keten klopt"
    DISK_TARGET=""; local nu; nu="$(disk_source)"
    [[ "$nu" == "$overlay" ]] || die "de gast schrijft naar ${nu} in plaats van naar ${overlay}"
    local bodem; bodem="$(chain_bottom "$overlay")"
    [[ "$bodem" == "$BASE_DISK" ]] || die "de overlay hangt onder ${bodem} in plaats van onder ${BASE_DISK}"
    check "gast schrijft nu naar ${overlay}"
    check "bodem-image ${BASE_DISK} is bevroren en wordt niet meer beschreven"
    RESULT_EXTRA="snapshot=${SNAP_NAME} overlay=${overlay}"
    step_ok nacontrole "keten klopt"

    cat <<EOF

  Snapshot '${SNAP_NAME}' staat open voor ${DOMAIN}.

    gemaakt      $(snapshot_created "$SNAP_NAME")
    bevroren     $([[ "$QUIESCE" == "yes" ]] && echo "ja, via de guest-agent (--quiesce)" || echo "NEE, alleen crash-consistent")
    bodem        ${BASE_DISK}   (staat stil, hier gaat u naar terug)
    overlay      ${overlay}   (vangt vanaf nu alles op)

  Ingreep geslaagd?  sudo $(basename "$0") opruimen ${SNAP_NAME}
  Mislukt?           sudo $(basename "$0") terug ${SNAP_NAME}

  Zolang dit snapshot openstaat weigert dit script een tweede te maken, en
  groeit de overlay mee met alles wat de gast schrijft.

EOF
}

########################################################################
# 6. TERUG (terugrollen naar het snapshotmoment)
########################################################################

cmd_terug() {
    ACTION="terug"
    event PLAN run "stappen van deze run" "actie=terug" \
        "stappen=preflight,keuze,afsluiten,vervangen,starten,einde"
    preflight

    # --- welk snapshot, en klopt de keten daarmee? ---
    step_start keuze "vaststellen waar naar teruggerold wordt"
    (( DEPTH >= 2 )) || die "${DOMAIN} draait rechtstreeks op ${BASE_DISK}; er is geen snapshot om naar terug te rollen"
    if (( DEPTH > 2 )); then
        warn "de keten is ${DEPTH} lagen diep; terugrollen gooit alle lagen boven ${BASE_DISK} weg"
    fi

    SNAP_NAME="${1:-}"
    if [[ -z "$SNAP_NAME" ]]; then
        if (( OPEN_COUNT == 1 )); then
            SNAP_NAME="$(snapshot_names)"
        elif (( OPEN_COUNT == 0 )); then
            SNAP_NAME=""           # overlay zonder metadata (bijv. van een oud script)
            warn "libvirt kent geen snapshot; er wordt teruggerold op wat de keten zelf zegt"
        else
            die "er staan ${OPEN_COUNT} snapshots open; noem er een: $(snapshot_names | paste -sd, -)"
        fi
    else
        snapshot_names | grep -qx "$SNAP_NAME" || die "snapshot '${SNAP_NAME}' bestaat niet voor ${DOMAIN}"
    fi

    local overlay="$ACTIVE_DISK" verlies gemaakt
    verlies="$(used_bytes "$overlay")"
    gemaakt="$([[ -n "$SNAP_NAME" ]] && snapshot_created "$SNAP_NAME" || stat -c %y "$overlay" | cut -d. -f1)"
    check "terug naar de stand van ${gemaakt}"
    check "weg te gooien: ${overlay} ($(human "$verlies") aan wijzigingen sinds het snapshot)"
    step_ok keuze "doel vastgesteld"

    cat <<EOF

  Terugrollen van ${DOMAIN} naar het snapshotmoment.

    naar de stand van   ${gemaakt}
    bodem-image         ${BASE_DISK}
    weg te gooien       ${overlay}
                        $(human "$verlies") - alles wat de gast sinds het snapshot heeft geschreven
    de gast gaat uit    en start daarna weer met de inhoud van de bodem-image
    het snapshot        blijft openstaan als vangnet voor een tweede poging

  De overlay wordt niet verwijderd maar hernoemd, dus een vergissing is nog
  terug te draaien zolang u dat bestand laat staan.

EOF
    if [[ "$DRY_RUN" == "yes" ]]; then
        step_skip afsluiten "droogloop; er wordt niets gewijzigd"
        return 0
    fi
    confirm "Doorgaan en ${DOMAIN} terugrollen?" || die "afgebroken op verzoek"

    # --- gast uit. Wat er nog in de gast gebeurt gooien we toch weg, dus na
    #     de wachttijd mag het hard; wel melden dat het zo gegaan is. ---
    step_start afsluiten "${DOMAIN} stoppen"
    if dom_running && [[ "$FORCE_STOP" == "yes" ]]; then
        warn "harde stop op verzoek (--hard); de wijzigingen in de gast gaan toch weg"
        logged virsh destroy "$DOMAIN" || die "kan ${DOMAIN} niet stoppen"
    elif dom_running; then
        logged virsh shutdown "$DOMAIN" || true
        local eind=$(( $(_now) + SHUTDOWN_WAIT )) laatste=0
        while dom_running && (( $(_now) < eind )); do
            if (( $(_now) - laatste >= 30 )); then
                laatste="$(_now)"
                event WAIT afsluiten "wachten tot ${DOMAIN} uit is" "resterend=$(( eind - $(_now) ))s"
            fi
            sleep 2
        done
        if dom_running; then
            warn "${DOMAIN} is na ${SHUTDOWN_WAIT}s niet netjes gestopt; harde stop (de wijzigingen gaan toch weg)"
            logged virsh destroy "$DOMAIN" || die "kan ${DOMAIN} niet stoppen"
        fi
    fi
    dom_running && die "${DOMAIN} draait nog"
    step_ok afsluiten "${DOMAIN} is uit"

    # --- de overlay vervangen door een lege op dezelfde bodem ---
    # De oude gaat opzij, niet weg: een vergissing is dan nog terug te draaien.
    step_start vervangen "overlay leegmaken; ${DOMAIN} ziet dan weer ${BASE_DISK}"
    local weg="${overlay}.weg-$(date +%Y%m%d-%H%M%S)"
    local eigenaar rechten
    eigenaar="$(stat -c '%U:%G' "$overlay")"
    rechten="$(stat -c '%a' "$overlay")"
    mv -f -- "$overlay" "$weg" || die "kan ${overlay} niet hernoemen"
    if ! logged qemu-img create -f qcow2 -b "$BASE_DISK" -F qcow2 "$overlay"; then
        mv -f -- "$weg" "$overlay"
        die "kan geen lege overlay maken; de oude staat weer op zijn plaats en er is niets veranderd"
    fi
    chown "$eigenaar" "$overlay" 2>/dev/null || warn "kan ${overlay} niet op ${eigenaar} zetten"
    chmod "$rechten"  "$overlay" 2>/dev/null || true
    local bodem_nu; bodem_nu="$(chain_bottom "$overlay")"
    [[ "$bodem_nu" == "$BASE_DISK" ]] \
        || die "de nieuwe overlay hangt onder ${bodem_nu} in plaats van onder ${BASE_DISK}"
    check "${overlay} is leeg en hangt weer onder ${BASE_DISK}"
    check "de oude overlay heet nu ${weg}"
    log "definitief opruimen als het herstel goed ging: rm -f ${weg}"
    step_ok vervangen "overlay vervangen"

    # --- weer aan ---
    step_start starten "${DOMAIN} starten"
    logged virsh start "$DOMAIN" || die "kan ${DOMAIN} niet starten"
    # Alleen wachten als er een agent te verwachten is; anders staat het
    # script AGENT_WAIT seconden voor niets stil.
    if ! virsh dumpxml "$DOMAIN" 2>/dev/null | grep -q "org.qemu.guest_agent.0"; then
        log "${DOMAIN} heeft geen guest-agent-kanaal; niet op de agent gewacht"
    elif agent_ready "$AGENT_WAIT"; then
        check "de agent in ${DOMAIN} antwoordt weer"
    else
        warn "${DOMAIN} is gestart maar de agent antwoordt niet binnen ${AGENT_WAIT}s; kijk met: virsh console ${DOMAIN}"
    fi
    RESULT_EXTRA="teruggerold_naar=${gemaakt// /T} weggegooid=$(human "$verlies") bewaard=${weg}"
    step_ok starten "${DOMAIN} draait weer"

    cat <<EOF

  ${DOMAIN} draait weer in de stand van ${gemaakt}.

    weggegooid   $(human "$verlies") aan wijzigingen
    bewaard als  ${weg}
    snapshot     '${SNAP_NAME:-onbekend}' staat nog open; u kunt het opnieuw proberen
    afronden     sudo $(basename "$0") opruimen    (maakt de keten weer plat)
    controleren  sudo $(basename "$0") lijst

  Draait er een database in de gast, dan doet die nu zijn eigen herstel
  (InnoDB redo-recovery). Kijk of dat goed ging voordat u ${weg} weggooit.

EOF
}

########################################################################
# 7. OPRUIMEN (overlay samenvoegen in de bodem)
########################################################################

# Samenvoegen zonder metadata: precies wat virsh snapshot-delete intern doet,
# maar dan met de hand omdat libvirt dit snapshot niet kent.
cmd_opruimen_wees() {
    local overlay="$ACTIVE_DISK" winst
    winst="$(used_bytes "$overlay")"
    warn "libvirt kent geen snapshot voor ${DOMAIN}; de overlay ${overlay} wordt met blockcommit samengevoegd"
    check "samen te voegen: ${overlay} ($(human "$winst")) in ${BASE_DISK}"
    step_ok keuze "doel vastgesteld"

    if [[ "$DRY_RUN" == "yes" ]]; then
        step_skip samenvoegen "droogloop; zou uitvoeren: virsh blockcommit ${DOMAIN} ${DISK_TARGET} --active --pivot"
        return 0
    fi
    dom_running || die "${DOMAIN} draait niet; blockcommit op de actieve laag vereist een draaiende gast"
    confirm "Overlay ${overlay} samenvoegen in ${BASE_DISK}? De teruggang vervalt daarmee." \
        || die "afgebroken op verzoek"

    step_start samenvoegen "overlay samenvoegen in ${BASE_DISK}"
    logged virsh blockcommit "$DOMAIN" "$DISK_TARGET" --active --pivot --verbose \
        || die "blockcommit mislukt; de gast draait nog op ${overlay}"
    step_ok samenvoegen "samengevoegd"

    step_start nacontrole "controleren of de keten weer plat is"
    DISK_TARGET=""; local nu diep
    nu="$(disk_source)"; diep="$(chain_depth "$nu")"
    [[ "$nu" == "$BASE_DISK" ]] || die "de gast draait op ${nu} in plaats van op ${BASE_DISK}"
    (( diep == 1 )) || die "de keten is nog ${diep} lagen diep"
    check "gast schrijft weer rechtstreeks naar ${BASE_DISK}"
    # De overlay is nu overbodig: de inhoud staat in de bodem en terugrollen
    # kan er niet meer mee, want de bodem is veranderd.
    if [[ -e "$overlay" ]]; then
        rm -f -- "$overlay" && log "${overlay} verwijderd (inhoud staat nu in ${BASE_DISK})"
    fi
    RESULT_EXTRA="samengevoegd=zonder-metadata verwerkt=$(human "$winst")"
    step_ok nacontrole "keten is plat"

    cat <<EOF

  De losse overlay is samengevoegd in ${BASE_DISK}.

    verwerkt     $(human "$winst") aan wijzigingen
    keten        plat, ${DOMAIN} schrijft weer rechtstreeks naar de bodem
    volgende     sudo $(basename "$0") maken   (die legt wel metadata aan)

EOF
    return 0
}

cmd_opruimen() {
    ACTION="opruimen"
    event PLAN run "stappen van deze run" "actie=opruimen" \
        "stappen=preflight,grendel,keuze,samenvoegen,nacontrole,einde"
    preflight

    # Samenvoegen verandert de bodem-image. Wie hem op dit moment leest (borg)
    # zou daar een archief aan overhouden dat bij geen enkele toestand hoort.
    step_start grendel "controleren of er geen backup van ${BASE_DISK} loopt"
    if ! grendel_pakken exclusief "$GRENDEL_WACHT"; then
        die "er loopt een backup die ${BASE_DISK} leest ($(grendel_houder)); wacht die af of gebruik --grendel-wacht SEC"
    fi
    local lezers
    lezers="$(bodem_lezers | tr '\n' ' ')"
    [[ -z "${lezers// }" ]] \
        || die "deze processen hebben ${BASE_DISK} nog open: ${lezers%% }; zolang die lezen wordt er niet samengevoegd"
    step_ok grendel "grendel is van ons; samenvoegen mag"

    step_start keuze "vaststellen wat er samengevoegd wordt"
    # Een overlay zonder metadata (afgebroken run, of een script met
    # --no-metadata) kan libvirt niet zelf opruimen; die gaat met de hand
    # dezelfde weg: blockcommit met pivot op de draaiende gast.
    if (( OPEN_COUNT == 0 )); then
        (( DEPTH > 1 )) || die "er is niets samen te voegen: ${DOMAIN} draait al rechtstreeks op ${BASE_DISK}"
        cmd_opruimen_wees
        return $?
    fi
    SNAP_NAME="${1:-}"
    if [[ -z "$SNAP_NAME" ]]; then
        (( OPEN_COUNT == 1 )) || die "er staan ${OPEN_COUNT} snapshots open; noem er een: $(snapshot_names | paste -sd, -)"
        SNAP_NAME="$(snapshot_names)"
    else
        snapshot_names | grep -qx "$SNAP_NAME" || die "snapshot '${SNAP_NAME}' bestaat niet voor ${DOMAIN}"
    fi
    local overlay winst
    overlay="$(snapshot_file "$SNAP_NAME")"
    winst="$(used_bytes "$overlay")"
    check "samen te voegen: ${overlay} ($(human "$winst")) in ${BASE_DISK}"
    step_ok keuze "doel vastgesteld"

    if [[ "$DRY_RUN" == "yes" ]]; then
        step_skip samenvoegen "droogloop; zou uitvoeren: virsh snapshot-delete ${DOMAIN} ${SNAP_NAME}"
        return 0
    fi
    confirm "Snapshot '${SNAP_NAME}' samenvoegen in ${BASE_DISK}? De teruggang vervalt daarmee." \
        || die "afgebroken op verzoek"

    # snapshot-delete doet de blockcommit met pivot op de draaiende gast en
    # ruimt overlay en metadata op. Dat kan even duren: alles wat de gast sinds
    # het snapshot schreef moet naar de bodem-image.
    step_start samenvoegen "overlay samenvoegen in ${BASE_DISK}"
    logged virsh snapshot-delete "$DOMAIN" "$SNAP_NAME" \
        || die "samenvoegen mislukt; de gast draait nog op ${overlay}"
    step_ok samenvoegen "samengevoegd"

    step_start nacontrole "controleren of de keten weer plat is"
    DISK_TARGET=""; local nu diep
    nu="$(disk_source)"; diep="$(chain_depth "$nu")"
    [[ "$nu" == "$BASE_DISK" ]] || die "de gast draait op ${nu} in plaats van op ${BASE_DISK}"
    (( diep == 1 )) || die "de keten is nog ${diep} lagen diep"
    [[ -e "$overlay" ]] && warn "${overlay} staat er nog; libvirt had dat moeten opruimen"
    check "gast schrijft weer rechtstreeks naar ${BASE_DISK}"
    RESULT_EXTRA="samengevoegd=${SNAP_NAME} verwerkt=$(human "$winst")"
    step_ok nacontrole "keten is plat"

    cat <<EOF

  Snapshot '${SNAP_NAME}' is samengevoegd in ${BASE_DISK}.

    verwerkt     $(human "$winst") aan wijzigingen
    keten        plat, ${DOMAIN} schrijft weer rechtstreeks naar de bodem
    volgende     sudo $(basename "$0") maken   (er kan er weer een open)

EOF
}

########################################################################
# 8. LIJST EN CONTROLE
########################################################################

# Een opdracht (borg, cp, rsync) draaien terwijl de bodem gegarandeerd
# stilstaat. De twee weigeringen halverwege zijn het punt van deze functie:
# een backup van de bodem terwijl de gast erin schrijft is geen backup.
cmd_backup() {
    ACTION="backup"
    (( $# > 0 )) || die "geen opdracht opgegeven; gebruik: $(basename "$0") backup -- borg create ..."
    event PLAN run "stappen van deze run" "actie=backup" \
        "stappen=preflight,grendel,uitvoeren,einde"
    preflight

    step_start grendel "grendel pakken zodat er niet samengevoegd wordt"
    grendel_pakken gedeeld "$GRENDEL_WACHT" \
        || die "er loopt een samenvoeging ($(grendel_houder)); die verandert ${BASE_DISK} onder u vandaan"

    # De kern: de bodem mag alleen gelezen worden als hij stilstaat.
    (( OPEN_COUNT > 0 )) \
        || die "er staat geen snapshot open; ${DOMAIN} schrijft nu rechtstreeks in ${BASE_DISK}. Eerst: $(basename "$0") maken"
    [[ "$ACTIVE_DISK" != "$BASE_DISK" ]] \
        || die "${DOMAIN} draait op ${BASE_DISK} zelf; een backup daarvan is niet consistent"
    check "bodem staat stil: ${BASE_DISK} ($(human "$(used_bytes "$BASE_DISK")")), snapshot '$(snapshot_names | paste -sd, -)' vangt de schrijfacties op"
    step_ok grendel "grendel is van ons"

    if [[ "$DRY_RUN" == "yes" ]]; then
        step_skip uitvoeren "droogloop; zou uitvoeren: $*"
        RESULT_EXTRA="bodem=${BASE_DISK}"
        return 0
    fi

    step_start uitvoeren "backupopdracht: $*"
    local rc=0
    # 9<&- : de opdracht erft de grendel niet, zodat een achterblijvend
    # kindproces hem niet vast kan houden nadat borg zelf klaar is.
    logged "$@" 9<&- || rc=$?
    RESULT_EXTRA="bodem=${BASE_DISK} snapshot=$(snapshot_names | paste -sd, -) opdracht_exit=${rc}"
    if (( rc != 0 )); then
        FAILED_STEP="uitvoeren"
        event FAIL uitvoeren "backupopdracht mislukt; ${BASE_DISK} is niet aangeraakt" "exit=${rc}"
        exit "$rc"
    fi
    step_ok uitvoeren "backupopdracht klaar"

    cat <<EOF

  De backup is klaar en ${BASE_DISK} is intussen niet veranderd.

    snapshot     '$(snapshot_names | paste -sd, -)' staat nog open
    samenvoegen  sudo $(basename "$0") opruimen

EOF
    return 0
}

cmd_lijst() {
    ACTION="lijst"
    preflight
    step_start lijst "openstaande snapshots van ${DOMAIN}"
    echo
    printf '  %-14s %s\n' "domein" "${DOMAIN} ($(virsh domstate "$DOMAIN" | head -1))"
    printf '  %-14s %s\n' "bodem-image" "${BASE_DISK} ($(human "$(used_bytes "$BASE_DISK")"))"
    printf '  %-14s %s\n' "actieve schijf" "${ACTIVE_DISK}"
    printf '  %-14s %s\n' "keten" "${DEPTH} laag/lagen diep"
    echo
    if (( OPEN_COUNT == 0 )); then
        printf '  geen openstaande snapshots\n\n'
    else
        printf '  %-22s %-21s %10s  %s\n' "SNAPSHOT" "GEMAAKT" "GROOTTE" "OVERLAY"
        local n f
        while read -r n; do
            [[ -n "$n" ]] || continue
            f="$(snapshot_file "$n")"
            printf '  %-22s %-21s %10s  %s\n' \
                "$n" "$(snapshot_created "$n")" "$(human "$(used_bytes "$f")")" "$f"
        done < <(snapshot_names)
        echo
    fi
    local los
    los="$(find "$SNAP_DIR" -maxdepth 1 -name "${DOMAIN}-*" -type f 2>/dev/null | sort || true)"
    if [[ -n "$los" ]]; then
        printf '  bestanden in %s:\n' "$SNAP_DIR"
        printf '%s\n' "$los" | while read -r f; do
            printf '    %10s  %s\n' "$(human "$(used_bytes "$f")")" "$f"
        done
        echo
    fi
    step_ok lijst "${OPEN_COUNT} snapshot(s)"
}

# Voor cron: exit 3 als de administratie niet klopt.
cmd_controle() {
    ACTION="controle"
    preflight
    step_start controle "administratie van ${DOMAIN} nalopen"
    local problemen=0

    if (( DEPTH > 2 )); then
        warn "de keten is ${DEPTH} lagen diep; gestapelde overlays kosten leessnelheid. Ruim op met: $(basename "$0") opruimen"
        problemen=$((problemen+1))
    fi
    if (( DEPTH > 1 && OPEN_COUNT == 0 )); then
        warn "${DOMAIN} draait op de overlay ${ACTIVE_DISK} maar libvirt kent geen snapshot; dat is een wees (bijv. van een afgebroken run of een script met --no-metadata). Terugrollen kan met: $(basename "$0") terug"
        problemen=$((problemen+1))
    fi
    if (( DEPTH == 1 && OPEN_COUNT > 0 )); then
        warn "libvirt kent ${OPEN_COUNT} snapshot(s) maar de gast draait op de bodem-image; die metadata slaat nergens meer op. Opruimen met: virsh snapshot-delete ${DOMAIN} NAAM --metadata"
        problemen=$((problemen+1))
    fi

    local n f
    while read -r n; do
        [[ -n "$n" ]] || continue
        f="$(snapshot_file "$n")"
        if [[ -z "$f" || ! -e "$f" ]]; then
            warn "snapshot '${n}' verwijst naar ${f:-onbekend}, maar dat bestand bestaat niet"
            problemen=$((problemen+1))
        fi
    done < <(snapshot_names)

    # bestanden in SNAP_DIR waar niemand meer naar wijst
    local bekend f2
    bekend="$(snapshot_names | while read -r n; do [[ -n "$n" ]] && snapshot_file "$n"; done)"
    while read -r f2; do
        [[ -n "$f2" ]] || continue
        [[ "$f2" == "$ACTIVE_DISK" ]] && continue
        printf '%s\n' "$bekend" | grep -qxF "$f2" && continue
        if [[ "$f2" == *.weg-* ]]; then
            log "bewaard van een eerdere terugrol: ${f2} ($(human "$(used_bytes "$f2")")) - weg te gooien als het herstel goed ging"
        else
            warn "los bestand zonder snapshot: ${f2} ($(human "$(used_bytes "$f2")"))"
            problemen=$((problemen+1))
        fi
    done < <(find "$SNAP_DIR" -maxdepth 1 -name "${DOMAIN}-*" -type f 2>/dev/null | sort || true)

    if (( problemen == 0 )); then
        check "keten ${DEPTH} laag diep, ${OPEN_COUNT} snapshot(s), geen losse bestanden"
        step_ok controle "administratie klopt"
        return 0
    fi
    FAILED_STEP="controle"
    event FAIL controle "${problemen} probleem/problemen gevonden"
    exit 3
}

########################################################################
# 9. PARAMETERS
########################################################################

usage() {
    cat <<EOF
Gebruik: sudo $(basename "$0") [opties] WERKWOORD [SNAPSHOTNAAM]
         sudo $(basename "$0") [opties] backup -- OPDRACHT ...

Alleen root mag dit script draaien: virsh, qemu-img en de images vragen erom.

Werkwoorden:
  maken [naam]      extern disk-only snapshot met --quiesce; weigert hard als
                    er al een snapshot openstaat (standaardnaam: ${SNAP_PREFIX}-JJJJMMDD-UUMM)
  terug [naam]      terugrollen naar het snapshotmoment: gast uit, overlay
                    opzij en vervangen door een lege, gast aan. Het snapshot
                    blijft openstaan, dus u kunt de ingreep opnieuw proberen
  opruimen [naam]   overlay samenvoegen in de bodem-image en de teruggang
                    laten vervallen (virsh snapshot-delete op de draaiende gast)
  lijst             wat staat er open, hoe diep is de keten, wat kost het
  controle          administratie nalopen; exit 3 als er iets niet klopt (cron)
  backup -- CMD ..  CMD draaien met de bodem-image vergrendeld, zodat er niet
                    samengevoegd wordt terwijl hij gelezen wordt. Weigert als
                    er geen snapshot openstaat, want dan schrijft de gast zelf
                    in de bodem en is een backup daarvan niet consistent

Opties:
  -d, --domein NAAM  ander domein dan ${DOMAIN}
  -y, --ja           niets vragen
  -n, --droogloop    alleen laten zien wat er zou gebeuren
      --wachttijd SEC hoe lang "terug" op een nette afsluiting wacht voordat
                     de gast hard uit gaat (standaard: ${SHUTDOWN_WAIT})
      --hard         bij "terug" niet netjes afsluiten maar meteen destroy; de
                     wijzigingen sinds het snapshot gaan toch weg
      --geen-quiesce snapshot zonder het filesystem te bevriezen; alleen voor
                     gasten zonder werkende qemu-guest-agent. Het snapshot is
                     dan crash-consistent: bruikbaar, maar bij terugzetten doet
                     het filesystem journal-replay.
      --grendel-wacht SEC
                     zoveel seconden wachten tot de ander (backup of
                     samenvoeging) klaar is; 0 = meteen weigeren (standaard)
      --log BESTAND  logbestand ("-" = niet naar bestand loggen)
  -h, --help         deze uitleg

Voorbeeld rond een upgrade:
  sudo $(basename "$0") maken voor-upgrade
  ... de ingreep ...
  sudo $(basename "$0") opruimen        # goed gegaan
  sudo $(basename "$0") terug           # mislukt

Voorbeeld rond een backup:
  sudo $(basename "$0") maken voor-backup
  sudo $(basename "$0") backup -- borg create /pad/repo::${DOMAIN}-{now} /t/kvm/${DOMAIN}.qcow2
  sudo $(basename "$0") opruimen

Meelezen:  tail -f ${LOG_DIR}/snapshot-${DOMAIN}-laatste.log
Stand:     cat ${LOG_DIR}/snapshot-${DOMAIN}.status
EOF
}

CMD=""
ARG=""
BACKUP_CMD=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--domein)     DOMAIN="$2"; shift 2 ;;
        -y|--ja|--yes)   ASSUME_YES="yes"; shift ;;
        -n|--droogloop|--dry-run) DRY_RUN="yes"; shift ;;
        --geen-quiesce)  QUIESCE="no"; shift ;;
        --wachttijd)     SHUTDOWN_WAIT="$2"; shift 2 ;;
        --grendel-wacht) GRENDEL_WACHT="$2"; shift 2 ;;
        --hard)          FORCE_STOP="yes"; shift ;;
        --log)           LOG_FILE="$2"; shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        maken|terug|opruimen|lijst|controle)
                         CMD="$1"; shift
                         [[ $# -gt 0 && "$1" != -* ]] && { ARG="$1"; shift; }
                         ;;
        backup)          CMD="backup"; shift
                         [[ "${1:-}" == "--" ]] && shift
                         BACKUP_CMD=( "$@" )   # de rest is de opdracht, ongemoeid
                         set --
                         ;;
        *)               echo "onbekende optie of werkwoord: $1" >&2; usage >&2; exit 1 ;;
    esac
done

[[ -n "$CMD" ]] || { usage >&2; exit 1; }

# Alleen root. Niet halverwege ontdekken: virsh praat dan tegen de sessie-
# libvirt in plaats van tegen het systeem, en logbestanden zouden van de
# verkeerde eigenaar worden.
if [[ $EUID -ne 0 ]]; then
    echo "$(basename "$0"): alleen root mag dit script draaien; gebruik: sudo $0 ${CMD}${ARG:+ $ARG}" >&2
    trap - EXIT           # geen RESULT-regel: er is niets begonnen
    exit 1
fi

init_logging
case "$CMD" in
    maken)    cmd_maken    "$ARG" ;;
    terug)    cmd_terug    "$ARG" ;;
    opruimen) cmd_opruimen "$ARG" ;;
    lijst)    cmd_lijst ;;
    controle) cmd_controle ;;
    backup)   cmd_backup "${BACKUP_CMD[@]}" ;;
esac
exit 0
