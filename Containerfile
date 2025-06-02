FROM quay.io/fedora/fedora-coreos:stable

RUN rpm-ostree override remove \
        nfs-utils-coreos \
        audit

COPY mopidy/mopidy.kube /etc/containers/systemd/users/1000/mopidy.kube
COPY mopidy/mopidy.yml /etc/containers/systemd/users/1000/mopidy.yml
COPY mopidy/mopidy.conf /data/contaiers_data/mopidy/config/mopidy.conf

COPY transmission/transmission.kube /etc/containers/systemd/users/1000/transmission.kube
COPY transmission/transmission.yml /etc/containers/systemd/users/1000/transmission.yml
COPY transmission/settings.json /data/contaiers_data/transmission/config/settings.json

COPY pihole/pihole.yml /etc/containers/systemd/pihole.yml
COPY pihole/pihole.kube /etc/containers/systemd/pihole.kube

COPY plex/plex.yml /etc/containers/systemd/plex.yml
COPY plex/plex.kube /etc/containers/systemd/plex.kube

RUN rpm-ostree install \
        flatpak \
        fedora-flathub-remote \
        cockpit-networkmanager \
        cockpit-podman \
        cockpit-system \
        cockpit \
        samba \
        nfs-utils \
        pulseaudio-utils \
        vim \
        firewalld \
        wget \
        fish

COPY podman/registries.conf /etc/containers/registries.conf
COPY samba/smb.conf /etc/samba/smb.conf
COPY nfs/exports /etc/exports
COPY firewall/trusted.xml /etc/firewalld/zones/trusted.xml
COPY firewall/public.xml /etc/firewalld/zones/public.xml
COPY sound/pipewire.conf /etc/pipewire/pipewire.conf
COPY sound/pipewire-pulse.conf /etc/pipewire/pipewire-pulse.conf
COPY sound/org.freedesktop.RealtimeKit1.policy /usr/share/polkit-1/rules.d/org.freedesktop.RealtimeKit1.policy
RUN systemctl enable --global pipewire.service pipewire-pulse.service
RUN systemctl enable smb.service nmb.service nfs-server.service cockpit.socket firewalld.service && \
    ostree container commit

