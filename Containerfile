FROM ghcr.io/ublue-os/bazzite-nvidia-open:testing
RUN dnf5 -y install --allowerasing mokutil sbsigntools

RUN rm -rf /usr/etc
LABEL containers.bootc 1
RUN bootc container lint
