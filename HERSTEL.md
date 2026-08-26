# Een gast die elders terug te zetten is

Wat er naast de qcow2 nodig is om een KVM-gast op een andere host weer op te
bouwen, hoe dat pakket eruitziet, en wat er onderweg stukgaat.

Aanleiding: op 22 augustus 2026 verdween `isms` van deze host — domein,
schijf én de backup in `/t2/kvm-bup`. Wat er dan ontbreekt is niet de data
maar de machine-instructie: zonder XML is een qcow2 een schijf zonder
machine.

## 1. Waar een gast uit bestaat

| onderdeel | waar | in bupvms? |
|---|---|---|
| systeemschijf | `/t/kvm/{naam}.qcow2` | ja |
| domeindefinitie | `virsh dumpxml {naam} --inactive` | ja |
| netwerkdefinitie | `virsh net-dumpxml tthomlw` | ja |
| nvram (UEFI) | `/var/lib/libvirt/qemu/nvram/{naam}_VARS.fd` | n.v.t. |
| libvirt-secrets | `virsh secret-list` | n.v.t. |

Op deze host booten de gasten via SeaBIOS — er staat geen `<loader>` of
`<nvram>` in de XML — en `virsh secret-list` is leeg. Beide regels worden
toch nagelopen: zodra er een UEFI-gast bijkomt, hoort dat bestand in het
pakket, en zonder dat bestand komt zo'n gast niet door zijn bootmenu heen.

Zonder de netwerkdefinitie krijgt u op de doelhost:

    error: Network not found: no network with matching name 'tthomlw'

## 2. Volgorde: de XML vóór het snapshot

Zolang een extern snapshot openstaat, wijst óók de opgeslagen definitie naar
de overlay. Gemeten op `proef-isms`:

    tijdens snapshot:  <source file='/t/kvm-ss/proef-isms-bundeltest.qcow2'/>
                       <backingStore>
                         <source file='/t/kvm/proef-isms.qcow2'/>
    na opruimen:       <source file='/t/kvm/proef-isms.qcow2'/>

Wie de XML tijdens het snapshot vastlegt, bundelt dus een definitie die
verwijst naar een overlay die niet in het pakket zit én die na het
samenvoegen niet meer bestaat. De volgorde ligt daarmee vast:

1. XML's ophalen (gast draait, geen snapshot open)
2. `snapshot.sh maken` — vanaf hier staat de bodem stil
3. `snapshot.sh backup -- …` — schijf kopiëren, `qemu-img check`
4. manifest schrijven
5. `snapshot.sh opruimen`

## 3. Het pakket

Eén map per gast per moment:

    /t2/kvm-bup/proef-isms-20260822-151907/
        schijf/proef-isms.qcow2
        definitie/domein.xml              virsh dumpxml --inactive
        definitie/netwerk-tthomlw.xml     virsh net-dumpxml
        definitie/nvram.fd                alleen bij UEFI
        manifest.txt
        LEESMIJ.txt
        herstel.sh + HERSTEL.md           het gereedschap gaat mee

`manifest.txt` bevat wat de restore nodig heeft en wat u bij twijfel wilt
kunnen nalezen: bronhost, tijdstip, de snapshotnaam waaruit gekopieerd is en
of dat met `--quiesce` ging, libvirt- en qemu-versie, machine-type,
cpu-modus, sha256 en grootte van de schijf, en de gast-interne gegevens
(hostname, IP, gateway). Dat laatste blok staat nergens anders opgeschreven
en is precies wat u op de doelhost moet aanpassen.

## 4. Terugzetten

Twee routes, omdat ze op verschillende soorten doelhosts werken.

**Route A — dezelfde soort host (Ubuntu, libvirt):** de XML is een exacte
kopie, dus overnemen en aanpassen.

    virsh net-define definitie/netwerk-tthomlw.xml    # alleen als het ontbreekt
    virsh net-start tthomlw && virsh net-autostart tthomlw
    cp schijf/proef-isms.qcow2 /var/lib/libvirt/images/
    virsh define definitie/domein.xml                 # na de aanpassingen uit §5
    virsh start proef-isms

**Route B — een vreemde host (andere distributie, andere qemu):** laat de
doelhost zelf een definitie maken uit de parameters in het manifest.

    virt-install --import --name proef-isms --memory 4096 --vcpus 2 \
      --disk /var/lib/libvirt/images/proef-isms.qcow2,bus=virtio \
      --network network=default,model=virtio --osinfo ubuntu24.04 \
      --graphics none --noautoconsole

Dat is het inzicht achter dit plan: de meest draagbare machine-instructie is
niet de XML maar de parameterlijst. De XML is de exacte kopie voor gelijke
hosts; het manifest is wat op elke host werkt.

## 5. Wat er onderweg stukgaat

Uit de echte XML van `proef-isms`; geen theoretische gevallen.

| in de XML | waarom het elders breekt | aanpassing |
|---|---|---|
| `machine='pc-q35-noble'` | Ubuntu-alias; bestaat niet op RHEL/Debian/Fedora | `machine='q35'` |
| `cpu mode='host-passthrough'` | andere CPU: gast start niet of valt om op ontbrekende instructies | `host-model` of een benoemd model |
| `<emulator>/usr/bin/qemu-system-x86_64</emulator>` | RHEL gebruikt `/usr/libexec/qemu-kvm` | regel weglaten, libvirt vult zelf in |
| `<source network='tthomlw'/>` | netwerk bestaat daar niet | net-define, of `bridge=br0` / `network=default` |
| `<seclabel model='apparmor'>` | doelhost draait SELinux | regel weglaten |
| `<mac address='52:54:00:…'/>` | botst als het origineel nog draait | weglaten; libvirt genereert een nieuwe |
| `<uuid>…</uuid>` | idem | weglaten bij een kloon, behouden bij uitwijk |
| spice, virtio-vga, usbredir | doelhost zonder spice | `--graphics none` of vnc |

`virsh dumpxml --migratable` haalt een deel van de rommel er al af
(ps2-toetsenbord, spice-audio, itco-watchdog) maar zet er wél een
AppArmor-`<seclabel>` in. Daarom bundelen we `--inactive` en gebeuren de
aanpassingen expliciet bij het terugzetten.

## 6. Het stuk dat ín de schijf zit

Hier gaat een restore elders meestal mis, en geen enkel bestand buiten de
qcow2 herinnert u eraan. `proef-isms` heeft een statisch `192.168.100.19/24`
in zijn netplan, plus hostname, machine-id en ssh-hostsleutels. Op een
andere host in een ander netwerk boot hij zonder verbinding.

Twee smaken; het pakket moet zeggen welke het is:

- **Uitwijk** (dezelfde machine, ergens anders): alles identiek houden.
  Zorg dat het origineel uit staat en pas hooguit het IP aan via de console.
- **Kloon** (een tweede exemplaar ernaast): identiteit vernieuwen vóór de
  eerste boot, anders vecht u met dubbele machine-id's, dezelfde hostkeys en
  een IP-conflict:

      virt-sysprep -a schijf.qcow2 \
        --operations machine-id,ssh-hostkeys,net-hostname

Offline aanpassen van het netwerk kan met `virt-customize` of `guestfish` op
het kopiebestand, vóór het definiëren.

## 7. Verifiëren

De enige echte controle is terugzetten. Het pakket op déze host onder een
andere naam definiëren, in het NAT-netwerk, met verse MAC/UUID/machine-id;
dan boot hij naast het origineel zonder iets te verstoren en controleert u
via de guest-agent (die werkt zonder netwerk) of hij opkomt.

## 8. Wat er staat

1. **`bupvms` maakt pakketten in plaats van losse bestanden** — de
   `dumpxml`-regels, het manifest, een LEESMIJ, en `herstel.sh` en dit
   document gaan mee zodat het pakket zichzelf kan uitleggen.
2. **`herstel.sh`** zet een pakket terug, met de aanpassingen uit §5 als
   vlaggen (`--nieuwe-identiteit`, `--netwerk NAAM`, `--vreemde-host`,
   `--sysprep`).
3. **Herstelproef** gedaan op 22 augustus 2026: het pakket
   `proef-isms-20260822-154246` teruggezet als `proefherstel` met verse
   identiteit op het NAT-netwerk, naast het draaiende origineel. sha256
   klopte, `qemu-img check` schoon, domein gedefinieerd en gestart, de
   guest-agent antwoordde binnen twintig seconden.

De omvang van deze opzet: drie generaties per gast op `/t2`, elke generatie
een volle kopie. Kopieën buiten deze machine vallen erbuiten.
