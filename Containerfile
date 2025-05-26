FROM quay.io/fedora/fedora-coreos:stable

RUN rpm-ostree override remove \
        nfs-utils-coreos \
        audit \
        systemd-resolved

RUN rm -f /etc/resolv.conf

RUN mkdir /etc/transmission
RUN mkdir /etc/mopidy

COPY mopidy/mopidy.kube /etc/containers/systemd/users/1000/mopidy.kube
COPY mopidy/mopidy.yml /etc/containers/systemd/users/1000/mopidy.yml
#COPY ./mopidy /etc/mopidy/

COPY transmission/transmission.kube /etc/containers/systemd/users/1000/transmission.kube
COPY transmission/transmission.yml /etc/containers/systemd/users/1000/transmission.yml
#COPY ./transmission /etc/transmission/

#RUN chown -R 1000:1000 /etc/transmission
#RUN chown -R 1000:1000 /etc/mopidy

COPY pihole/pihole.yml /etc/containers/systemd/pihole.yml
COPY pihole/pihole.kube /etc/containers/systemd/pihole.kube
RUN podman volume create pihole_pihole && podman volume create pihole_dnsmasq

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
        firewalld

COPY samba/smb.conf /etc/samba/smb.conf
COPY nfs/exports /etc/exports
COPY firewall/trusted.xml /etc/firewalld/zones/trusted.xml
COPY firewall/public.xml /etc/firewalld/zones/public.xml
COPY sound/pipewire.conf /etc/pipewire/pipewire.conf
COPY sound/pipewire-pulse.conf /etc/pipewire/pipewire-pulse.conf
COPY sound/org.freedesktop.RealtimeKit1.policy /usr/share/polkit-1/rules.d/org.freedesktop.RealtimeKit1.policy

RUN systemctl --machine=core@.host --user enable pipewire.service pipewire-pulse.service
RUN systemctl enable smb.service nfs-server.service cockpit.socket firewalld.service && \
    ostree container commit

