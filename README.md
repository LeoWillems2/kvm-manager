# kvm-manager
Manage bouwen, backuppen en herbouwen QEMU VM guests

Zie MANIFEST.md aan het einde als je deze paden niet hebt:

```
/t/kvm          ## hier komen de qcow2's
/t/kvm/iso	## je ISO's
/t/kvm-ss	## tmp voor snapshots
/t2/kvm-bup	## backups, bij voorkeur andere (externe) disk
```


Pas (eenmalig) makevm.sh aan voor alle variabelen in jouw omgeving.

Het script bupdaily is PHP, het heeft package 'Mail.php' nodig.
