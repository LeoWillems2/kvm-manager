# Wat er in deze map staat

Gereedschap voor KVM/libvirt-gasten op deze host: een gast aanmaken en
beveiligen, er snapshots van maken, hem backuppen en hem elders weer
opbouwen. Alles is bash, op `bupdaily` na (php); alles draait als root op de
host, `beveilig.sh` uitgezonderd — dat draait ín een gast.

## De keten in het kort

    makevm.sh   ->  gast aanmaken, en beveilig.sh er meteen in draaien
    snapshot.sh ->  vangnet rond een riskante ingreep, en de grendel
    bupvms      ->  herstelpakket per gast wegschrijven   (gebruikt snapshot.sh)
    cleanbup    ->  ruimte vrijmaken voor zo'n pakket
    bupdaily    ->  de dagelijkse ronde: cleanbup + bupvms per gast
    herstel.sh  ->  een pakket weer tot een draaiende gast maken

## Scripts

### `makevm.sh`
Maakt een KVM/QEMU-gast aan via `virt-install`. Bestaat er nog geen
base-image, dan wordt de gast onbeheerd geïnstalleerd vanaf de install-ISO
(Ubuntu autoinstall via een cloud-init NoCloud seed) en wordt daarna
`{naam}-base.qcow2` gemaakt; bestaat het al, dan wordt daaruit gekloond en
krijgt de kloon via cloud-init zijn eigen naam, IP, MAC, ssh-hostsleutels en
machine-id. Elke gast krijgt de qemu-guest-agent mee, en er wordt gecontroleerd
of die ook echt antwoordt en kan bevriezen — zonder werkende agent is een
snapshot hooguit crash-consistent. Voordat het base-image valt draait
`beveilig.sh` in de gast, zodat elke kloon dat erft. Kan ook opruimen (`-r`)
en hernoemen (`-m`). Elke stap meldt zich machineleesbaar in `logs/`.

De instellingen (netwerk, hardware, paden, pakketten) staan in deel 1 van het
script, maar horen daar niet vast te zitten: een `makevm.config` gaat er
overheen en de opdrachtregel gaat weer over de config heen, zodat een nieuwe
versie van het script uw eigen inrichting niet overschrijft. Met
`--dump-config` leest het script een bestaande gast uit — de definitie bij
libvirt en, via de qemu-guest-agent, tijdzone, toetsenbord, beheerder,
firewallregel en de met de hand geïnstalleerde pakketten — en schrijft het
daar zo'n configbestand van. Daarmee is een nieuwe gast te bouwen zoals een
bestaande. Het resultaat is een vertrekpunt, geen kopie: achter elke regel
staat waar de waarde vandaan komt, en `EXTRA_PACKAGES` en `IP_MODE` zijn
afgeleid, niet gemeten.

    sudo ./makevm.sh -n naam -i ip [-d GB] [-b base] [--iso x] [-y]
    sudo ./makevm.sh -r NAAM            # gast en boekhouding opruimen
    sudo ./makevm.sh -m OUD NIEUW       # hernoemen
    sudo ./makevm.sh --dump-config josefina > makevm-josefina.config
    sudo ./makevm.sh -c makevm-josefina.config -n nieuwe -i 192.168.100.40

### `beveilig.sh`
Zet de beveiligingsmaatregelen op een Ubuntu-server: apt dist-upgrade,
unattended security-updates, sysctl-hardening (IPv4 en IPv6), strakke sshd
met alleen sleutels, ufw, fail2ban, tmp-mounts zonder exec/suid/dev,
sudo-logging, apparmor in enforce en auditd-basisregels. Elke stap is
idempotent. Draait vanuit `makevm.sh` in een nieuwe gast, maar is los te
gebruiken op elke bestaande host — kopieer het erheen en start het.

    sudo ./beveilig.sh [--ssh-from "any|CIDR ..."] [--skip STAP,...] [-y]
    sudo ./beveilig.sh --dry-run

### `snapshot.sh`
Externe snapshots van een gast beheren: `maken` (disk-only, met `--quiesce`,
dus de bodem-image bevriest), `terug` (de overlay opzij, de gast ziet weer het
snapshotmoment), `opruimen` (overlay samenvoegen in de bodem), `lijst`,
`controle` (voor cron) en `backup` — een opdracht draaien met de bodem
vergrendeld. Die grendel is een `flock` in `/run/lock`, zodat niemand kan
samenvoegen terwijl er gelezen wordt; de kernel laat hem los zodra het proces
stopt, hoe het ook stopt. De keten is nooit dieper dan één laag.

### `bupvms`
Schrijft per gast een compleet herstelpakket naar `/t2/kvm-bup`: de schijf,
`domein.xml`, de netwerkdefinities, nvram bij UEFI, een manifest, een LEESMIJ
en `herstel.sh` + `HERSTEL.md` — het pakket kan zichzelf uitleggen. De
definities worden vastgelegd vóórdat het snapshot valt, anders wijzen ze naar
een overlay die na het samenvoegen niet meer bestaat. De gast draait door;
alleen tijdens het snapshot staat zijn filesystem een fractie van een seconde
stil. Een gast die faalt komt in het eindoverzicht en levert exit 1 op, maar
de andere gasten worden afgemaakt.

    sudo ./bupvms isms lewi

### `cleanbup`
Maakt ruimte vrij in `/t2/kvm-bup` voor een nieuwe backup: ruimte ter grootte
van (grootste backup van de genoemde gasten × 1,5), door hun oudste backups te
verwijderen. Van elke gast blijven minimaal twee versies staan, en backups van
gasten die niet op de commandoregel staan worden nooit aangeraakt. Exit 0 = er
is genoeg ruimte, eventueel na opruimen.

    sudo ./cleanbup [--dry-run] [--dir DIR] [--simulate-free KB] <gast> [gast ...]

### `bupdaily`
De dagelijkse ronde, in php. Controleert eerst of het als root draait, neemt de
gasten van de commandoregel en draait per gast eerst `cleanbup <gast>` en dan
`bupvms <gast>` — per gast, want `cleanbup` maakt plaats voor precies één
backup en die ruimte is na de vorige gast weer op. Alle uitvoer van beide
scripts, ook stderr, gaat tegelijk naar het scherm, naar
`/var/log/bupdaily.log` en in een mail (PEAR Mail over smtps, instellingen in
`/etc/bupdaily.conf`). Die mail gaat altijd de deur uit, ook bij een fatale
fout. Een gast die faalt stopt de ronde niet.

Staat in de crontab van root:

    17 3 * * *  /pad/kvm-manager/bupdaily guest [guest...] >/dev/null 2>&1

### `herstel.sh`
Neemt een pakket van `bupvms` op in een libvirt-installatie: kopie
controleren, schijf op zijn plek, de hostgebonden delen van de XML aanpassen,
domein definiëren en starten. Twee soorten herstel, en dat verschil is geen
detail — *uitwijk* (dezelfde machine elders, alles identiek, origineel uit) of
*kloon* (een tweede exemplaar ernaast, met `--nieuwe-identiteit` en meestal
`--sysprep`). Past het IP binnen de gast niet aan; dat zit in de schijf.

    sudo ./herstel.sh /t2/kvm-bup/website-20260824-131652
    sudo ./herstel.sh --naam proef --nieuwe-identiteit --netwerk default PAKKET

## Documentatie

| bestand | inhoud |
|---|---|
| `HERSTEL.md` | wat er naast de qcow2 nodig is om een gast elders op te bouwen, hoe het pakket eruitziet, wat er onderweg stukgaat, en het verslag van de herstelproef |
| `MANIFEST.md` | dit bestand |

## Configuratie en sleutels

| bestand | inhoud |
|---|---|
| `makevm.config.voorbeeld` | model voor `makevm.config`: alle instellingen van `makevm.sh` met uitleg. De echte configbestanden (`makevm.config`, `makevm-{naam}.config`) staan niet in git — ze horen bij deze host en er kan een wachtwoordhash in staan |
| `bupdaily.conf.voorbeeld` | model voor `/etc/bupdaily.conf` (mailserver, afzender, ontvanger). Het echte bestand staat buiten deze map, root-only, want er staat een wachtwoord in |
| `authorized_keys` | publieke sleutels die in elke nieuwe gast terechtkomen (niet in git) |
| `id_ed25519` | sleutelpaar waarmee de host bij de gasten kan; de publieke helft gaat mee de gast in (niet in git) |
| `logs/` | log- en statusbestanden van `makevm.sh`: `makevm-{naam}-{tijd}.log`, `makevm-{naam}-laatste.log` en `makevm-{naam}.status` met de huidige stap (niet in git) |

Meelezen met een lopende run:

    tail -f logs/makevm-{naam}-laatste.log
    cat    logs/makevm-{naam}.status

## Wat er geïnstalleerd moet zijn

Deze scripts gaan uit van Ubuntu/Debian met libvirt. Het meeste is coreutils
en staat er toch al; hieronder alleen wat u echt apart moet installeren, met
per pakket wie het gebruikt en waarvoor.

### Op de host

| pakket | commando | wie | waarvoor |
|---|---|---|---|
| `libvirt-daemon-system` | `libvirtd` | alles | de virtualisatielaag zelf |
| `libvirt-clients` | `virsh` | `makevm.sh`, `snapshot.sh`, `bupvms`, `herstel.sh` | domeinen, netwerken, snapshots, de guest-agent |
| `virtinst` | `virt-install` | `makevm.sh` | de gast aanmaken |
| `qemu-utils` | `qemu-img` | `makevm.sh`, `snapshot.sh`, `bupvms`, `herstel.sh` | schijven maken, kopiëren, meten en samenvoegen |
| `xorriso` | `xorriso` | `makevm.sh` | de cloud-init seed-ISO bouwen |
| `openssh-client` | `ssh`, `ssh-keygen`, `ssh-keyscan` | `makevm.sh` | wachten op de gast en `known_hosts` bijwerken |
| `openssl` | `openssl` | `makevm.sh` | de wachtwoordhash voor de beheerder |
| `util-linux` | `flock` | `snapshot.sh`, `bupvms` | de grendel om de bodem-image |
| `python3` | `python3` | `herstel.sh` | de hostgebonden delen van `domein.xml` aanpassen |
| `libguestfs-tools` | `virt-sysprep` | `herstel.sh --sysprep` | identiteit in de schijf vernieuwen bij een kloon |

    sudo apt install libvirt-daemon-system libvirt-clients virtinst qemu-utils \
                     xorriso openssh-client openssl util-linux python3

`libguestfs-tools` staat bewust niet in die regel: het is alleen nodig voor
`herstel.sh --sysprep` en het is een fors pakket. **Op deze host staat het
niet.** `herstel.sh --naam X --nieuwe-identiteit --sysprep` stopt daardoor met
"virt-sysprep ontbreekt" — de rest van het herstel werkt wel. Wilt u die weg
gebruiken, dan moet het erbij:

    sudo apt install libguestfs-tools

Dat `makevm.sh` de gast via de qemu-guest-agent bewerkt in plaats van via
libguestfs komt uit dezelfde hoek: er is op deze host geen libguestfs, en in
de gast vraagt sudo een wachtwoord.

### Voor `bupdaily` (php)

| pakket | waarvoor |
|---|---|
| `php-cli` | `bupdaily` is php, geen bash |
| `php-mail` | PEAR `Mail` — de dagelijkse mail |
| `php-net-smtp` | smtps-verbinding voor PEAR Mail |
| `php-net-socket` | wat `php-net-smtp` daaronder gebruikt |
| `cron` | de dagelijkse ronde om 03:17 |

    sudo apt install php-cli php-mail php-net-smtp php-net-socket cron

### In de gast

`makevm.sh` installeert dit zelf bij het bouwen; het staat hier omdat een gast
die op een andere manier is ontstaan het ook nodig heeft.

| pakket | waarvoor |
|---|---|
| `qemu-guest-agent` | **de spil.** `snapshot.sh --quiesce` bevriest het filesystem ermee, `makevm.sh` draait er `beveilig.sh` mee in de gast, en `--dump-config` leest de gast er mee uit. Zonder agent is een snapshot hooguit crash-consistent |
| `openssh-server` | inloggen, en waar `makevm.sh` op wacht |
| `cloud-init` | naam, IP, MAC, hostsleutels en machine-id van een kloon |
| `ufw`, `fail2ban` | door `beveilig.sh` gezet en verwacht |

`beveilig.sh` installeert daarbovenop zelf `unattended-upgrades`,
`apt-listchanges`, `needrestart`, `apparmor`, `apparmor-utils`, `auditd` en
`audispd-plugins`.

Verder leest `makevm.sh --dump-config` de gast uit met `dpkg-query`,
`apt-mark`, `resolvectl`, `timedatectl`, `findmnt`, `lsblk` en `ufw`. Die zitten
alle in een standaard Ubuntu Server; ontbreekt er een, dan blijft die regel in
het configbestand leeg in plaats van dat het misgaat.


## Waar het spul staat

Als je andere paden gebruikt dan hieronder moet je de parameters voorin elk
script aanpassen — voor `makevm.sh` kan dat ook in `makevm.config`.

| pad | wat |
|---|---|
| `/t/kvm/{naam}.qcow2` | de schijven van de gasten |
| `/t/kvm-ss/` | de overlays van openstaande snapshots |
| `/t2/kvm-bup/{naam}-JJJJMMDD-UUMMSS/` | de herstelpakketten |
| `/run/lock/` | de grendels van `snapshot.sh` en `bupvms` |
| `/etc/makevm.conf` | instellingen voor `makevm.sh` voor de hele host (optioneel); `./makevm.config` en `./makevm-{naam}.config` gaan daar overheen |
| `/etc/bupdaily.conf` | mailinstellingen voor `bupdaily` (root, 600) |
| `/var/log/bupdaily.log` | het log van de dagelijkse ronde |
| `./authorized_keys` | ssh authorized keys |
| `./id_ed25519` | ssh private key (of dummy) |
