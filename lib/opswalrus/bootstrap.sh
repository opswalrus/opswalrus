#!/usr/bin/env bash

# if brew is already installed, initialize this shell environment with brew
if [ -x "$(command -v /home/linuxbrew/.linuxbrew/bin/brew)" ]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

  # exit early if ruby already exists
  if [ -x "$(command -v ruby)" ]; then
    echo 'Ruby is already installed.' >&2
    exit 0
  fi
fi

OS=$(cat /etc/os-release | grep "^ID=")
if echo $OS | grep -q 'ubuntu'; then
  # update package list
  sudo apt update -qy

  if [ -f /var/run/reboot-required ]; then
    echo 'A system reboot is required!'
    exit 1
  fi

  # there are probably some services that need restarting because they're using old libraries, so we'll just do the easy thing and reboot
  sudo DEBIAN_FRONTEND=noninteractive apt install -yq needrestart

  # install homebrew dependencies, per https://docs.brew.sh/Homebrew-on-Linux
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq build-essential procps curl file git

  # restart services that need it
  sudo needrestart -q -r a
  sudo needrestart -q -r a
  sudo needrestart -q -r a
elif echo $OS | grep -q 'fedora'; then
  sudo yum groupinstall -y 'Development Tools'
  sudo yum install -y procps-ng curl file git
elif echo $OS | grep -q 'arch'; then
  sudo pacman -Syu --noconfirm base-devel procps-ng curl file git
else
  echo "unsupported OS"
  exit 1
fi


# install homebrew
NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# initialize brew in shell session
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

# install gcc, ruby, age
brew install gcc
brew install ruby
brew install age    # https://github.com/FiloSottile/age

# install opswalrus gem
gem install opswalrus
