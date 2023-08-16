#!/usr/bin/env bash

# install homebrew
NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

# install gcc, rust, ruby
brew install gcc
brew install rust
brew install ruby

# brew install rtx
# eval "$(rtx activate bash)"   # register a shell hook
# rtx use -g ruby@3.2   # install ruby via rtx

# download frum for ruby version management
# curl -L -o frum.tar.gz https://github.com/TaKO8Ki/frum/releases/download/v0.1.2/frum-v0.1.2-x86_64-unknown-linux-musl.tar.gz
# tar -zxf frum.tar.gz
# mv frum-v0.1.2-x86_64-unknown-linux-musl/frum ~/bin
# chmod 755 ~/bin/frum

