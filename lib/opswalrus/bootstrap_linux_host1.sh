#!/usr/bin/env bash

# update package list
sudo apt update -y

# update OS
# sudo DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" dist-upgrade -q -y --allow-downgrades --allow-remove-essential --allow-change-held-packages

if [ -f /var/run/reboot-required ]; then
echo 'A system reboot is required!'
sudo reboot
fi
