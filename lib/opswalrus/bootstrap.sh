#!/usr/bin/env bash

# if brew is already installed, initialize this shell environment with brew
if [ -x "$(command -v /home/linuxbrew/.linuxbrew/bin/brew)" ]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

  # exit early if ruby already exists
  if [ -x "$(command -v ruby)" ]; then
    echo 'Ruby is already installed.' >&2

    # make sure the latest opswalrus gem is installed
    # todo: figure out how to install this differently, so that test versions will work
    gem install opswalrus

    exit 0
  fi
fi

# https://github.com/chef/os_release documents the contents of /etc/os-release from a bunch of distros
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
  sudo dnf groupinstall -y 'Development Tools'
  sudo dnf -yq install procps-ng curl file git
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
brew install age    # https://github.com/FiloSottile/age

### install ruby

# 1. via homebrew
# brew install ruby
# this doesn't install some gems nicely

# 2. via ruby-install
# brew install bash grep wget curl md5sha1sum sha2 gnu-tar bzip2 xz patchutils gcc
brew install ruby-install
ruby-install --update
ruby-install ruby 3.2.2

# 3. rvm
# gpg2 --keyserver keyserver.ubuntu.com --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3 7D2BAF1CF37B13E2069D6956105BD0E739499BDB
# \curl -sSL https://get.rvm.io | bash -s stable --autolibs=homebrew
# rvm install 3.2.2

# install opswalrus gem
$HOME/.rubies/ruby-3.2.2/bin/gem install opswalrus
