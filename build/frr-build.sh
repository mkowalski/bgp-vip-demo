#!/bin/sh
set -ex
dnf install -y dnf-plugins-core >/dev/null; dnf config-manager --set-enabled crb >/dev/null; dnf install -y epel-release >/dev/null 2>&1 || true; dnf install -y --setopt=tsflags=nodocs autoconf automake libtool make gcc gcc-c++ \
  flex bison python3-devel \
  libyang-devel json-c-devel readline-devel c-ares-devel pcre2-devel \
  protobuf-c-devel libcap-devel elfutils-libelf-devel pam-devel git >/dev/null
cd /src
./bootstrap.sh >/dev/null 2>&1 || autoreconf -fi >/dev/null 2>&1
./configure \
  --prefix=/usr --sbindir=/usr/libexec/frr --sysconfdir=/etc \
  --localstatedir=/var --libdir=/usr/lib64/frr \
  --with-moduledir=/usr/lib64/frr/modules \
  --enable-user=frr --enable-group=frr --enable-vty-group=frrvty \
  --disable-doc --disable-grpc --disable-snmp --disable-fpm \
  --enable-multipath=64 --enable-vtysh >/dev/null
make -j"$(nproc)" >/dev/null 2>/tmp/build-err.log || { tail -20 /tmp/build-err.log; exit 1; }
mkdir -p /out
cp zebra/.libs/zebra /out/zebra 2>/dev/null || cp zebra/zebra /out/zebra
/out/zebra --version | head -2
