#!/usr/bin/env bash
#
# herstel.sh - een herstelpakket van bupvms opnemen in een libvirt-installatie.
#
# Een pakket is een map met de schijf, de domeindefinitie, de netwerken en een
# manifest; zie HERSTEL.md. Dit script zet zo'n pakket terug: het controleert
# de kopie, legt de schijf op zijn plek, past de hostgebonden delen van de XML
# aan, definieert het domein en start het.
#
# Gebruik:
#   sudo ./herstel.sh /t2/kvm-bup/proef-isms-20260822-154246
#   sudo ./herstel.sh --naam proefherstel --nieuwe-identiteit \
#        --netwerk default /pad/naar/pakket
#   sudo ./herstel.sh --vreemde-host --schijf-dir /var/lib/libvirt/images PAKKET
#
# Twee soorten herstel, en het verschil is geen detail:
#
#   uitwijk   dezelfde machine, ergens anders. Alles identiek houden: UUID,
#             MAC, hostname, IP. Zorg dat het origineel uit staat, anders
#             vechten twee exemplaren om hetzelfde adres. Dit is de standaard.
#   kloon     een tweede exemplaar ernaast. Dan --nieuwe-identiteit (verse
#             UUID en MAC) en meestal ook --sysprep, dat machine-id,
#             ssh-hostsleutels en hostname in de schijf zelf vernieuwt.
#
# Wat dit script niet doet: het IP binnen de gast aanpassen. Dat zit in de
# schijf (netplan) en staat in manifest.txt onder gast_ip. Op een ander
# netwerk komt de gast dus op zonder verbinding; via de console of de
# guest-agent is dat te repareren, of vooraf met virt-customize.

set -Eeuo pipefail

########################################################################
# INSTELLINGEN
########################################################################

NAAM=""                  # --naam: onder welke naam definiëren
SCHIJF_DIR=""            # --schijf-dir: waar de schijf heen gaat
NETWERK=""               # --netwerk: aan welk libvirt-netwerk hangen
NIEUWE_ID="nee"          # --nieuwe-identiteit: verse UUID en MAC
VREEMDE_HOST="nee"       # --vreemde-host: machine/cpu/emulator neutraal maken
ADRESSEN_VRIJ="nee"      # --adressen-vrijgeven: PCI-adressen laten hertekenen
SYSPREP="nee"            # --sysprep: identiteit binnen de schijf vernieuwen
STARTEN="ja"             # --niet-starten
CONTROLE="ja"            # --geen-controle: sha256 en qemu-img check overslaan
JA="nee"                 # -y
DROOG="nee"              # --droogloop

########################################################################
# MELDINGEN
########################################################################

melding() { printf '%s [herstel] %s\n' "$(date +%Y-%m-%dT%H:%M:%S%:z)" "$*"; }
fout()    { printf '%s [herstel] FOUT: %s\n' "$(date +%Y-%m-%dT%H:%M:%S%:z)" "$*" >&2; }
die()     { fout "$*"; exit 1; }

confirm() {
    [[ "$JA" == "ja" ]] && return 0
    local antwoord
    read -rp "$1 [j/N] " antwoord
    [[ "$antwoord" =~ ^([jJ]|[yY])$ ]]
}

usage() {
    awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$ZELF"
    cat <<EOF

Opties:
      --naam NAAM        onder welke naam definiëren (standaard: uit het manifest)
      --schijf-dir PAD   waar de schijf heen gaat (standaard: het pad uit het
                         manifest als die map bestaat, anders /var/lib/libvirt/images)
      --netwerk NAAM     aan dit libvirt-netwerk hangen in plaats van aan het
                         netwerk uit de definitie
      --nieuwe-identiteit  UUID en MAC weglaten; libvirt maakt verse. Nodig als
                         het origineel nog bestaat, want die botsen.
      --sysprep          machine-id, ssh-hostsleutels en hostname in de schijf
                         vernieuwen (virt-sysprep). Alleen voor een kloon.
      --vreemde-host     machine naar q35, cpu naar host-model en het
                         emulator-pad weglaten. Voor een andere distributie of
                         qemu-versie; zie HERSTEL.md paragraaf 5.
      --adressen-vrijgeven
                         alle PCI-adressen weglaten zodat libvirt ze opnieuw
                         toekent. LET OP: daarmee kan de netwerkinterface in de
                         gast een andere naam krijgen (enp1s0 -> ens3) en klopt
                         de netplan-configuratie niet meer.
      --geen-controle    sha256 en qemu-img check overslaan (sneller, dommer)
      --niet-starten     wel definiëren, niet starten
  -y, --ja               niets vragen
      --droogloop        alleen laten zien wat er zou gebeuren
  -h, --help             deze uitleg
EOF
}

########################################################################
# ARGUMENTEN
########################################################################

ZELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
PAKKET=""
ARGV=( "$@" )        # voor het herstarten via sudo; na de lus is "$@" leeg

while [[ $# -gt 0 ]]; do
    case "$1" in
        --naam)               NAAM="$2"; shift 2 ;;
        --schijf-dir)         SCHIJF_DIR="$2"; shift 2 ;;
        --netwerk)            NETWERK="$2"; shift 2 ;;
        --nieuwe-identiteit)  NIEUWE_ID="ja"; shift ;;
        --sysprep)            SYSPREP="ja"; shift ;;
        --vreemde-host)       VREEMDE_HOST="ja"; shift ;;
        --adressen-vrijgeven) ADRESSEN_VRIJ="ja"; shift ;;
        --geen-controle)      CONTROLE="nee"; shift ;;
        --niet-starten)       STARTEN="nee"; shift ;;
        -y|--ja|--yes)        JA="ja"; shift ;;
        --droogloop|--dry-run) DROOG="ja"; shift ;;
        -h|--help)            usage; exit 0 ;;
        -*)                   echo "onbekende optie: $1" >&2; usage >&2; exit 1 ;;
        *)                    [[ -z "$PAKKET" ]] || die "meer dan één pakket opgegeven"
                              PAKKET="${1%/}"; shift ;;
    esac
done

[[ -n "$PAKKET" ]] || { usage >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
    if [[ -t 0 ]]; then exec sudo -- "$ZELF" "${ARGV[@]}"; fi
    die "moet als root draaien (sudo ${ZELF} ${PAKKET})"
fi

########################################################################
# HET PAKKET NALOPEN
########################################################################

for hulp in virsh qemu-img python3 sha256sum; do
    command -v "$hulp" >/dev/null || die "${hulp} ontbreekt"
done

[[ -d "$PAKKET" ]]                     || die "${PAKKET} is geen map"
[[ -r "${PAKKET}/manifest.txt" ]]      || die "${PAKKET}/manifest.txt ontbreekt; dit is geen bupvms-pakket"
[[ -r "${PAKKET}/definitie/domein.xml" ]] || die "${PAKKET}/definitie/domein.xml ontbreekt"

# manifest inlezen; alleen sleutels die we kennen, geen eval van vreemd spul
declare -A M=()
while IFS='=' read -r sleutel waarde; do
    [[ "$sleutel" == \#* || -z "$sleutel" ]] && continue
    M["$sleutel"]="$waarde"
done < "${PAKKET}/manifest.txt"

GAST="${M[gast]:-}"
[[ -n "$GAST" ]] || die "manifest noemt geen gast"
SCHIJF_IN_PAKKET="${PAKKET}/${M[schijf]:-}"
[[ -r "$SCHIJF_IN_PAKKET" ]] || die "de schijf ${SCHIJF_IN_PAKKET} ontbreekt in het pakket"

DOELNAAM="${NAAM:-$GAST}"

melding "pakket   ${PAKKET}"
melding "gast     ${GAST} (schijfmoment ${M[schijf_moment]:-onbekend}, snapshot ${M[snapshot]:-onbekend})"
melding "bron     ${M[bronhost]:-onbekend}, libvirt ${M[libvirt]:-?}, qemu ${M[qemu]:-?}"
melding "wordt    domein '${DOELNAAM}'"
[[ -n "${M[gast_ip]:-}" ]] && melding "in de gast: hostname ${M[gast_hostname]:-?}, ip ${M[gast_ip]}"

if virsh dominfo "$DOELNAAM" &>/dev/null; then
    die "domein '${DOELNAAM}' bestaat al op deze host; kies --naam, of ruim het eerst op"
fi

########################################################################
# DE KOPIE CONTROLEREN
########################################################################

if [[ "$CONTROLE" == "ja" ]]; then
    if [[ -n "${M[schijf_bytes]:-}" ]]; then
        nu="$(stat -c %s -- "$SCHIJF_IN_PAKKET")"
        [[ "$nu" == "${M[schijf_bytes]}" ]] \
            || die "de schijf is ${nu} bytes, het manifest zegt ${M[schijf_bytes]}"
    fi
    if [[ -n "${M[schijf_sha256]:-}" && "${M[schijf_sha256]}" != mislukt ]]; then
        melding "sha256 nalopen (dit leest de hele schijf)"
        som="$(sha256sum -- "$SCHIJF_IN_PAKKET" | awk '{print $1}')"
        [[ "$som" == "${M[schijf_sha256]}" ]] \
            || die "sha256 komt niet overeen; de kopie is beschadigd"
        melding "sha256 klopt"
    fi
    rc=0; qemu-img check -U "$SCHIJF_IN_PAKKET" >/dev/null 2>&1 || rc=$?
    case "$rc" in
        0) melding "qemu-img check: schoon" ;;
        3) melding "let op: qemu-img check meldt lekken (niet fataal)" ;;
        *) die "qemu-img check keurt de schijf af (exit ${rc})" ;;
    esac
fi

########################################################################
# WAAR DE SCHIJF HEEN GAAT
########################################################################

if [[ -z "$SCHIJF_DIR" ]]; then
    kandidaat="$(dirname -- "${M[bron_pad]:-/var/lib/libvirt/images/x}")"
    if [[ -d "$kandidaat" ]]; then SCHIJF_DIR="$kandidaat"; else SCHIJF_DIR="/var/lib/libvirt/images"; fi
fi
[[ -d "$SCHIJF_DIR" ]] || die "${SCHIJF_DIR} bestaat niet"

SCHIJF_UIT="${SCHIJF_DIR}/${DOELNAAM}.qcow2"
[[ -e "$SCHIJF_UIT" ]] && die "${SCHIJF_UIT} bestaat al; ruim dat eerst op of kies --naam"

nodig=$(( $(stat -c %s -- "$SCHIJF_IN_PAKKET") / 1073741824 + 2 ))
vrij="$(df -BG --output=avail "$SCHIJF_DIR" 2>/dev/null | tail -1 | tr -dc '0-9')"
(( ${vrij:-0} >= nodig )) || die "${vrij:-0}G vrij in ${SCHIJF_DIR}, ongeveer ${nodig}G nodig"
melding "schijf   ${SCHIJF_UIT} (${vrij}G vrij, ${nodig}G nodig)"

########################################################################
# NETWERK
########################################################################

NET_IN_XML="$(awk -F"'" '/<source network=/{print $2; exit}' "${PAKKET}/definitie/domein.xml")"
NET_DOEL="${NETWERK:-$NET_IN_XML}"

if [[ -n "$NET_DOEL" ]] && ! virsh net-info "$NET_DOEL" &>/dev/null; then
    NET_XML="${PAKKET}/definitie/netwerk-${NET_DOEL}.xml"
    if [[ -r "$NET_XML" ]]; then
        melding "netwerk '${NET_DOEL}' bestaat hier niet, maar zit wel in het pakket"
        if [[ "$DROOG" == "ja" ]]; then
            melding "droogloop; zou uitvoeren: virsh net-define ${NET_XML} && virsh net-start ${NET_DOEL}"
        elif confirm "Netwerk '${NET_DOEL}' uit het pakket definiëren en starten?"; then
            virsh net-define "$NET_XML" || die "net-define mislukt"
            virsh net-start "$NET_DOEL" || die "net-start mislukt"
            virsh net-autostart "$NET_DOEL" || true
            melding "netwerk '${NET_DOEL}' gedefinieerd en gestart"
        else
            die "zonder netwerk '${NET_DOEL}' start het domein niet; gebruik --netwerk NAAM"
        fi
    else
        die "netwerk '${NET_DOEL}' bestaat hier niet en zit niet in het pakket; gebruik --netwerk NAAM"
    fi
fi

########################################################################
# DE XML AANPASSEN
########################################################################

# Structureel met ElementTree en niet met sed: dit is het bestand waar het
# hele herstel op leunt, en een halfgeslaagde reguliere expressie levert een
# XML op die libvirt wél accepteert maar die de verkeerde schijf aanwijst.
xml_aanpassen() {
    local bron="$1" doel="$2"
    NAAM="$DOELNAAM" BRON_PAD="${M[bron_pad]:-}" SCHIJF_PAD="$SCHIJF_UIT" \
    NETWERK_DOEL="$NET_DOEL" NIEUWE_ID="$NIEUWE_ID" VREEMDE_HOST="$VREEMDE_HOST" \
    ADRESSEN_VRIJ="$ADRESSEN_VRIJ" NVRAM_PAD="$NVRAM_UIT" \
    python3 - "$bron" "$doel" <<'PYTHON'
import os, sys
import xml.etree.ElementTree as ET

ET.register_namespace('qemu', 'http://libvirt.org/schemas/domain/qemu/1.0')
bron, doel = sys.argv[1], sys.argv[2]
boom = ET.parse(bron)
dom = boom.getroot()
wijz = []

el = dom.find('name')
if el is not None and el.text != os.environ['NAAM']:
    wijz.append("naam: %s -> %s" % (el.text, os.environ['NAAM']))
    el.text = os.environ['NAAM']

if os.environ['NIEUWE_ID'] == 'ja':
    for tag in ('uuid', 'genid'):
        el = dom.find(tag)
        if el is not None:
            dom.remove(el)
            wijz.append("%s verwijderd; libvirt maakt een nieuwe" % tag)
    for iface in dom.findall('devices/interface'):
        mac = iface.find('mac')
        if mac is not None:
            wijz.append("mac %s verwijderd" % mac.get('address'))
            iface.remove(mac)

nieuw = os.environ['SCHIJF_PAD']
for schijf in dom.findall("devices/disk"):
    if schijf.get('device') != 'disk':
        continue
    src = schijf.find('source')
    if src is not None and src.get('file'):
        wijz.append("schijf: %s -> %s" % (src.get('file'), nieuw))
        src.set('file', nieuw)
    # een <backingStore> uit de bronhost wijst naar een bestand dat hier niet
    # bestaat; libvirt vult hem zelf opnieuw in
    bs = schijf.find('backingStore')
    if bs is not None and len(bs):
        schijf.remove(bs)
        wijz.append("verouderde <backingStore> verwijderd")

net = os.environ.get('NETWERK_DOEL', '')
if net:
    for iface in dom.findall('devices/interface'):
        src = iface.find('source')
        if src is None:
            continue
        huidig = src.get('network') or src.get('bridge') or src.get('dev') or ''
        if iface.get('type') != 'network' or huidig != net:
            wijz.append("netwerk: %s -> %s" % (huidig or iface.get('type'), net))
            iface.set('type', 'network')
            src.attrib.clear()
            src.set('network', net)

if os.environ['VREEMDE_HOST'] == 'ja':
    ost = dom.find('os/type')
    if ost is not None and ost.get('machine') not in (None, 'q35'):
        wijz.append("machine: %s -> q35" % ost.get('machine'))
        ost.set('machine', 'q35')
    cpu = dom.find('cpu')
    if cpu is not None and cpu.get('mode') == 'host-passthrough':
        wijz.append("cpu: host-passthrough -> host-model")
        cpu.attrib.clear()
        cpu.set('mode', 'host-model')
        cpu.set('check', 'partial')
    dev = dom.find('devices')
    if dev is not None:
        em = dev.find('emulator')
        if em is not None:
            wijz.append("emulator-pad %s verwijderd; libvirt vult zelf in" % em.text)
            dev.remove(em)

# hostgebonden en altijd weg: op een SELinux-host weigert libvirt een
# apparmor-label en andersom
for sl in dom.findall('seclabel'):
    dom.remove(sl)
    wijz.append("seclabel (%s) verwijderd" % sl.get('model'))

nv = os.environ.get('NVRAM_PAD', '')
if nv:
    el = dom.find('os/nvram')
    if el is not None:
        wijz.append("nvram: %s -> %s" % (el.text, nv))
        el.text = nv

if os.environ['ADRESSEN_VRIJ'] == 'ja':
    n = 0
    for ouder in dom.iter():
        for adres in list(ouder.findall('address')):
            ouder.remove(adres)
            n += 1
    if n:
        wijz.append("%d PCI/USB-adressen verwijderd; libvirt tekent ze opnieuw" % n)

boom.write(doel, encoding='unicode', xml_declaration=False)
print('\n'.join(wijz) if wijz else "geen aanpassingen nodig")
PYTHON
}

# nvram alleen als het pakket er een heeft
NVRAM_UIT=""
if [[ -r "${PAKKET}/definitie/nvram.fd" ]]; then
    NVRAM_UIT="/var/lib/libvirt/qemu/nvram/${DOELNAAM}_VARS.fd"
fi

WERK="$(mktemp -d /var/tmp/herstel-XXXXXX)"
trap 'rm -rf -- "$WERK"' EXIT
XML_UIT="${WERK}/domein.xml"

melding "definitie aanpassen"
xml_aanpassen "${PAKKET}/definitie/domein.xml" "$XML_UIT" | sed 's/^/    /'
grep -q "<source file='${SCHIJF_UIT}'" "$XML_UIT" \
    || grep -q "<source file=\"${SCHIJF_UIT}\"" "$XML_UIT" \
    || die "de aangepaste XML wijst niet naar ${SCHIJF_UIT}; er is niets gedefinieerd"

########################################################################
# UITVOEREN
########################################################################

if [[ "$DROOG" == "ja" ]]; then
    melding "droogloop; zou nu doen:"
    melding "  cp ${SCHIJF_IN_PAKKET} -> ${SCHIJF_UIT}"
    [[ -n "$NVRAM_UIT" ]] && melding "  cp nvram.fd -> ${NVRAM_UIT}"
    [[ "$SYSPREP" == "ja" ]] && melding "  virt-sysprep op ${SCHIJF_UIT}"
    melding "  virsh define (aangepaste XML staat in ${WERK}, verdwijnt zo)"
    [[ "$STARTEN" == "ja" ]] && melding "  virsh start ${DOELNAAM}"
    exit 0
fi

confirm "Domein '${DOELNAAM}' aanmaken uit dit pakket?" || die "afgebroken op verzoek"

melding "schijf kopiëren naar ${SCHIJF_UIT}"
cp --sparse=always -- "$SCHIJF_IN_PAKKET" "${SCHIJF_UIT}.bezig" \
    || { rm -f -- "${SCHIJF_UIT}.bezig"; die "kopiëren mislukt"; }
mv -f -- "${SCHIJF_UIT}.bezig" "$SCHIJF_UIT"
chown libvirt-qemu:kvm "$SCHIJF_UIT" 2>/dev/null || chown qemu:qemu "$SCHIJF_UIT" 2>/dev/null || true
chmod 0640 "$SCHIJF_UIT"
sync -f -- "$SCHIJF_UIT" 2>/dev/null || sync

if [[ -n "$NVRAM_UIT" ]]; then
    mkdir -p "$(dirname "$NVRAM_UIT")"
    cp -- "${PAKKET}/definitie/nvram.fd" "$NVRAM_UIT" || die "nvram kopiëren mislukt"
    chown libvirt-qemu:kvm "$NVRAM_UIT" 2>/dev/null || true
    melding "nvram teruggezet: ${NVRAM_UIT}"
fi

if [[ "$SYSPREP" == "ja" ]]; then
    command -v virt-sysprep >/dev/null || die "virt-sysprep ontbreekt (pakket libguestfs-tools)"
    melding "identiteit in de schijf vernieuwen (virt-sysprep)"
    virt-sysprep -a "$SCHIJF_UIT" \
        --operations machine-id,ssh-hostkeys,net-hostname,net-hwaddr \
        || die "virt-sysprep mislukt; de schijf staat er wel, het domein niet"
fi

melding "domein definiëren"
virsh define "$XML_UIT" || die "virsh define mislukt; ${SCHIJF_UIT} staat er nog"

if [[ "$STARTEN" != "ja" ]]; then
    melding "klaar; '${DOELNAAM}' is gedefinieerd maar niet gestart"
    exit 0
fi

melding "domein starten"
virsh start "$DOELNAAM" || die "starten mislukt; '${DOELNAAM}' is wel gedefinieerd"

# De guest-agent antwoordt ook zonder netwerk, dus dit is de eerlijkste
# controle of de gast echt opkomt.
melding "wachten tot de guest-agent antwoordt (hoogstens 120 s)"
gelukt="nee"
for _ in $(seq 1 24); do
    if virsh qemu-agent-command "$DOELNAAM" '{"execute":"guest-ping"}' &>/dev/null; then
        gelukt="ja"; break
    fi
    sleep 5
done

cat <<EOF

  Pakket teruggezet.

    domein       ${DOELNAAM} ($(virsh domstate "$DOELNAAM" 2>/dev/null | head -1))
    schijf       ${SCHIJF_UIT}
    netwerk      ${NET_DOEL:-geen}
    schijfmoment ${M[schijf_moment]:-onbekend}
    guest-agent  ${gelukt}
EOF

if [[ "$gelukt" == "ja" ]]; then
    melding "in de gast: $(virsh guestinfo "$DOELNAAM" --hostname 2>/dev/null | awk -F': *' '/hostname/{print $2; exit}')"
    virsh domifaddr "$DOELNAAM" --source agent 2>/dev/null | awk 'NR>2 && NF' | sed 's/^/    /'
else
    melding "de agent antwoordde niet; kijk mee met: virsh console ${DOELNAAM}"
fi

cat <<EOF

  Het IP zit in de schijf, niet in de definitie. Volgens het manifest was dat
  ${M[gast_ip]:-onbekend}; op een ander netwerk moet dat via de console om.

EOF
exit 0
