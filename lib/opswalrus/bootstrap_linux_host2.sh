#!/usr/bin/env bash

# there are probably some services that need restarting because they're using old libraries, so we'll just do the easy thing and reboot
sudo DEBIAN_FRONTEND=noninteractive apt install -yq needrestart

# install basic development tools
sudo DEBIAN_FRONTEND=noninteractive apt install -yq build-essential

# install ruby dependencies
sudo DEBIAN_FRONTEND=noninteractive apt install -yq autoconf patch rustc libssl-dev libyaml-dev libreadline6-dev zlib1g-dev libgmp-dev libncurses5-dev libffi-dev libgdbm6 libgdbm-dev libdb-dev uuid-dev

# restart services that need it
sudo needrestart -q -r a

# vagrant@ubuntu-jammy:~$ sudo needrestart -q -r a
#  systemctl restart unattended-upgrades.service

# vagrant@ubuntu-jammy:~$ sudo needrestart -r l
# Scanning processes...
# Scanning candidates...
# Scanning linux images...
#
# Running kernel seems to be up-to-date.
#
# Services to be restarted:
#
# Service restarts being deferred:
#  systemctl restart unattended-upgrades.service
#
# No containers need to be restarted.
#
# No user sessions are running outdated binaries.
#
# No VM guests are running outdated hypervisor (qemu) binaries on this host.

# reboot just in case
# sudo reboot
