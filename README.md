# kvm-manager
Manage bouwen, backuppen en herbouwen QEMU VM guests

Zie MANIFEST.md aan het einde als je deze paden niet hebt:

```
/t/kvm          ## hier komen de qcow2's
/t/kvm/iso	## je ISO's
/t/kvm-ss	## tmp voor snapshots
/t2/kvm-bup	## backups, bij voorkeur andere (externe) disk
```


## Instellen

Zet je eigen waarden in `makevm.config`; `makevm.sh` zelf hoef je niet aan te
raken, ook niet bij een nieuwe versie ervan. Kopieer `makevm.config.voorbeeld`
en pas aan wat afwijkt — wat je weglaat blijft op de standaard uit het script
staan. De volgorde is:

```
makevm.sh  <  makevm.config  <  de opdrachtregel
```

Van een guest die al draait maakt het script zo'n bestand voor je, inclusief
tijdzone, toetsenbord, beheerder en de pakketten die er met de hand op gezet
zijn. Daarmee bouw je een nieuwe guest zoals een bestaande:

```
sudo ./makevm.sh --dump-config josefina > makevm-josefina.config
chmod 600 makevm-josefina.config
sudo ./makevm.sh -c makevm-josefina.config -n nieuwe -i 192.168.100.40
```

Lees dat bestand wel na voor je ermee bouwt: achter elke regel staat waar de
waarde vandaan komt, en niet alles is gemeten — sommige dingen zijn afgeleid.

## Wat je nodig hebt

Libvirt, qemu-utils, xorriso en een handvol andere pakketten; `bupdaily` is
PHP en heeft `php-mail` nodig. De volledige lijst — host, bupdaily en guest
apart, met wat elk pakket doet en wat er juist *niet* nodig is — staat in
MANIFEST.md onder "Wat er geïnstalleerd moet zijn".
