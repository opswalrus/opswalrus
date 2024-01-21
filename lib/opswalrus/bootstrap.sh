#!/usr/bin/env bash

export PATH="$HOME/.local/bin:$PATH"    # this is key for activating mise without running `eval "$($MISE activate bash)"`
MISE="$HOME/.local/bin/mise"
# mise_init() { eval "$($MISE activate bash)"; }
# MISE_RUBY="$HOME/.local/bin/mise x ruby -- ruby"
# MISE_GEM="$HOME/.local/bin/mise x ruby -- gem"
MISE_RUBY="$HOME/.local/share/mise/shims/ruby"
MISE_GEM="$HOME/.local/share/mise/shims/gem"
RUBY_CMD=$MISE_RUBY
GEM_CMD=$MISE_GEM
# RUBY_CMD="ruby"
# GEM_CMD="gem"

if [ -x $MISE ]; then
  # mise_init;
  # if brew is already installed, initialize this shell environment with brew
  # if [ -x "$(command -v /home/linuxbrew/.linuxbrew/bin/brew)" ]; then
  if $RUBY_CMD -e "major, minor, patch = RUBY_VERSION.split('.'); exit 1 unless major.to_i >= 3"; then
    # eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

    # exit early if ruby already exists
    # if [ -x "$(command -v $HOME/.rubies/ruby-3.2.2/bin/ruby)" ]; then
      echo 'Ruby is already installed.'

      # make sure the latest opswalrus gem is installed
      # todo: figure out how to install this differently, so that test versions will work
      # gem install opswalrus
      $GEM_CMD install opswalrus
      $MISE reshim

      exit 0
    # fi
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
  (sudo needrestart -b | grep -q 'NEEDRESTART-KSTA: 1') || { echo 'Reboot needed. Exiting.'; exit 1; }
  # sudo needrestart -q -r a
elif echo $OS | grep -q 'fedora'; then
  sudo dnf groupinstall -y 'Development Tools'
  sudo dnf -yq install procps-ng curl file git
elif echo $OS | grep -q 'rocky'; then
  sudo dnf groupinstall -y 'Development Tools'
  sudo dnf -yq install procps-ng curl file git
elif echo $OS | grep -q 'arch'; then
  sudo pacman -Syu --noconfirm --needed base-devel procps-ng curl file git
else
  echo "unsupported OS"
  exit 1
fi


# install homebrew
# NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# initialize brew in shell session
# eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

# install gcc, age
# brew install gcc
# brew install age    # https://github.com/FiloSottile/age


### install ruby via mise

if echo $OS | grep -q 'ubuntu'; then
  # update package list
  sudo apt update -qy

  # reboot if needed
  (sudo needrestart -b | grep -q 'NEEDRESTART-KSTA: 1') || { echo 'Reboot needed. Exiting.'; exit 1; }

  # install ruby dependencies
  # see https://github.com/rbenv/ruby-build/wiki#suggested-build-environment
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq libgdbm6
  if [ $? -ne 0 ]; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq libgdbm5
  fi
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq autoconf patch build-essential rustc libssl-dev libyaml-dev libreadline6-dev zlib1g-dev libgmp-dev libncurses5-dev libffi-dev libgdbm-dev libdb-dev uuid-dev

  # reboot if needed
  (sudo needrestart -b | grep -q 'NEEDRESTART-KSTA: 1') || { echo 'Reboot needed. Exiting.'; exit 1; }
elif echo $OS | grep -q 'fedora'; then
  # from https://github.com/rbenv/ruby-build/wiki#suggested-build-environment
  sudo yum install -y gcc patch bzip2 openssl-devel libyaml-devel libffi-devel readline-devel zlib-devel gdbm-devel ncurses-devel
elif echo $OS | grep -q 'rocky'; then
  sudo yum --enablerepo=powertools install -y libyaml-devel libffi-devel
  sudo yum install -y gcc patch bzip2 openssl-devel libyaml-devel libffi-devel readline-devel zlib-devel gdbm-devel ncurses-devel
elif echo $OS | grep -q 'arch'; then
  # from https://github.com/rbenv/ruby-build/wiki#suggested-build-environment
  sudo pacman -Syu --noconfirm --needed base-devel rust libffi libyaml openssl zlib
else
  echo "unsupported OS"
  exit 1
fi
curl https://mise.jdx.dev/install.sh | sh
$MISE use -g ruby@latest
$MISE reshim


# 5. age encryption
if echo $OS | grep -q 'ubuntu'; then
  # update package list
  sudo apt update -qy

  # reboot if needed
  (sudo needrestart -b | grep -q 'NEEDRESTART-KSTA: 1') || { echo 'Reboot needed. Exiting.'; exit 1; }

  sudo DEBIAN_FRONTEND=noninteractive apt install -yq age

  # restart services that need it
  sudo needrestart -q -r a
elif echo $OS | grep -q 'fedora'; then
  sudo dnf -yq install age
elif echo $OS | grep -q 'rocky'; then
  sudo curl -o /usr/local/bin/age https://dl.filippo.io/age/latest?for=linux/amd64
  sudo chmod 755 /usr/local/bin/age
elif echo $OS | grep -q 'arch'; then
  sudo pacman -Syu --noconfirm --needed age
else
  echo "unsupported OS"
  exit 1
fi

# install opswalrus gem
$GEM_CMD install opswalrus
$MISE reshim
