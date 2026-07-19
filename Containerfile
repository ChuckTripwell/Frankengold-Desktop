FROM quay.io/fedora/fedora-coreos@sha256:5e2534d6794bf3b910e1b01dfd6073d028f600676b339429322e7c4af9e70f1e

#  :::::: finish :::::: 
RUN rm -rf /usr/etc
LABEL containers.bootc 1
RUN bootc container lint
