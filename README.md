## Immutable Home Server

## About

This instalation using Fedora CoreOS as baseline.

## System layer

Ignition config using for the first boot. Prepare iso file using

```bash
cd sys_layer

# Prepare iginition
butane --pretty --strict --files-dir=$PWD config.yml > config.ign

# Download stable CoreOS version
coreos-installer download --stream=stable --architecture=x86_64 --platform=metal --format=iso --directory=./

# Create ISO
coreos-installer iso customize --force --dest-device /dev/vda --dest-ignition ./config.ign -o ./homeserver14.iso ./ fedora-coreos-stable.iso

```

## System 

Prepare service layer. Build imagem with all necessary tools

```bash
cd service_layer

podman build -t ghcr.io/fedextm/homeserver:v01 -f Containerfile .

podman push ghcr.io/fedextm/homeserver:v01
```

## After Rebooting

Rebase service using after reboot to setup other services

```bash
ssh core@host

sudo systemcl start rebase.service

```

