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

    sudo ./makevm.sh -n naam -i ip [-d GB] [-b base] [--iso x] [-y]
    sudo ./makevm.sh -r NAAM            # gast en boekhouding opruimen
    sudo ./makevm.sh -m OUD NIEUW       # hernoemen

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
| `bupdaily.conf.voorbeeld` | model voor `/etc/bupdaily.conf` (mailserver, afzender, ontvanger). Het echte bestand staat buiten deze map, root-only, want er staat een wachtwoord in |
| `authorized_keys` | publieke sleutels die in elke nieuwe gast terechtkomen (niet in git) |
| `id_ed25519` | sleutelpaar waarmee de host bij de gasten kan; de publieke helft gaat mee de gast in (niet in git) |
| `logs/` | log- en statusbestanden van `makevm.sh`: `makevm-{naam}-{tijd}.log`, `makevm-{naam}-laatste.log` en `makevm-{naam}.status` met de huidige stap (niet in git) |

Meelezen met een lopende run:

    tail -f logs/makevm-{naam}-laatste.log
    cat    logs/makevm-{naam}.status

## Waar het spul staat

Als je andere paden gebruikt dan hieronder moet je de parameters voorin elk script aanpassen.

| pad | wat |
|---|---|
| `/t/kvm/{naam}.qcow2` | de schijven van de gasten |
| `/t/kvm-ss/` | de overlays van openstaande snapshots |
| `/t2/kvm-bup/{naam}-JJJJMMDD-UUMMSS/` | de herstelpakketten |
| `/run/lock/` | de grendels van `snapshot.sh` en `bupvms` |
| `/etc/bupdaily.conf` | mailinstellingen voor `bupdaily` (root, 600) |
| `/var/log/bupdaily.log` | het log van de dagelijkse ronde |
| `./authorized_keys` | ssh authorized keys |
| `./id_ed25519` | ssh private key (of dummy) |
