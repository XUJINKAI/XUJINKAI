#!/bin/bash
set -e
# My personal init script for Linux/WSL

export GIT_NAME=${GIT_NAME:-"XUJINKAI"}
export GIT_EMAIL=${GIT_EMAIL:-"XUJINKAI@users.noreply.github.com"}

function install_base() {
    apt-get install -y \
        curl \
        vim \
        iputils-ping \
        git
}

function setup_git() {
    git config --global credential.helper store
    git config --global core.ignorecase false
    git config --global http.sslVerify false
    git config --global user.name "$GIT_NAME"
    git config --global user.email "$GIT_EMAIL"
}

function install_zsh() {
    install_base
    apt-get install -y zsh
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting
    rm -rf ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting/.git
    git clone https://github.com/zsh-users/zsh-autosuggestions ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions
    rm -rf ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions/.git

    sed -i 's/plugins=(.*)/plugins=(git sudo zsh-syntax-highlighting zsh-autosuggestions)/g' ~/.zshrc
    sed -i 's/ZSH_THEME=".*"/ZSH_THEME="ys"/g' ~/.zshrc
    sed -i 's/HIST_STAMPS=".*"/HIST_STAMPS="yyyy-mm-dd"/g' ~/.zshrc
    sed -i 's/# DISABLE_AUTO_UPDATE="true"/DISABLE_AUTO_UPDATE="true"/g' ~/.zshrc
    echo "alias c='clear'" >> ~/.zshrc
    chsh -s /usr/bin/zsh
}

function install_cpp() {
    apt-get install -y \
        build-essential \
        cmake \
        valgrind \
        cppcheck \
        gdb \
        clang-format-15
    ln -s /usr/bin/clang-format-15 /usr/bin/clang-format
}

apt-get update

install_base
ping -c 1 github.com

setup_git
install_zsh
install_cpp

apt-get clean
rm -rf /var/lib/apt/lists/*
