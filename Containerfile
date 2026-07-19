FROM quay.io/fedora/fedora-coreos:rawhide

#  :::::: finish :::::: 
RUN rm -rf /usr/etc
LABEL containers.bootc 1
RUN bootc container lint
