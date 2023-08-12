#!/bin/bash
set -e
# My personal init script for Linux/WSL

export GIT_NAME=${GIT_NAME:-"XUJINKAI"}
export GIT_EMAIL=${GIT_EMAIL:-"XUJINKAI@users.noreply.github.com"}

function config_git() {
    git config --global credential.helper store
    git config --global core.ignorecase false
    git config --global http.sslVerify false
    git config --global user.name "$GIT_NAME"
    git config --global user.email "$GIT_EMAIL"
    # git config --global user.name "XUJINKAI"
    # git config --global user.email "XUJINKAI@users.noreply.github.com"
}

function config_wsl() {
    git config --global credential.helper "/mnt/c/Program\ Files/Git/mingw64/bin/git-credential-manager.exe"

    local file = "/etc/wsl.conf"
    if [ ! -f $file ]; then
        touch $file
    fi
    if [ ! grep -q "default=root" $file ]; then
        echo "[user]" >> $file
        echo "default=root" >> $file
    fi
}

function install_base() {
    apt-get install -y \
        curl \
        vim \
        iputils-ping \
        git
}

function install_zsh() {
    ping -c 1 github.com

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

function install_dotnet() {
    wget https://dot.net/v1/dotnet-install.sh -O dotnet-install.sh
    chmod +x dotnet-install.sh
    ./dotnet-install.sh --version latest
    # ./dotnet-install.sh --channel 7.0
    rm dotnet-install.sh
    if ! grep -q "DOTNET_ROOT" ~/.zshrc; then
        echo Writting to ~/.zshrc
        echo "export DOTNET_ROOT=\$HOME/.dotnet" >> ~/.zshrc
        echo "export PATH=\$PATH:\$HOME/.dotnet:\$HOME/.dotnet/tools" >> ~/.zshrc
    fi
}

arg_config_wsl=false
arg_base=false
arg_config_git=false
arg_zsh=false
arg_cpp=false
arg_dotnet=false
arg_clean=false

if [ $# -eq 0 ]; then
    echo "Usage: $0 [--docker|--wsl] [--base] [--config-git] [--config-wsl] [--zsh] [--cpp] [--dotnet] [--clean]"
    exit 1
fi
while [ $# -gt 0 ]; do
    case "$1" in
    --docker)
        arg_base=true
        arg_config_git=true
        arg_zsh=true
        arg_clean=true
        ;;
    --wsl)
        arg_config_wsl=true
        arg_base=true
        arg_config_git=true
        arg_zsh=true
        ;;
    --base)         arg_base=true;;
    --config-git)   arg_config_git=true;;
    --config-wsl)   arg_config_wsl=true;;
    --zsh)          arg_zsh=true;;
    --cpp)          arg_cpp=true;;
    --dotnet)       arg_dotnet=true;;
    --clean)        arg_clean=true;;
    *)
        echo "Unknown option: $1"
        exit 1
        ;;
    esac
    shift
done

# real start

if [ "$arg_config_wsl" = true ]; then
    config_wsl
fi

if [ "$arg_base" = true ]; then
    apt-get update
    install_base
fi

if [ "$arg_config_git" = true ]; then
    config_git
fi

if [ "$arg_zsh" = true ]; then
    install_zsh
fi

if [ "$arg_cpp" = true ]; then
    install_cpp
fi

if [ "$arg_dotnet" = true ]; then
    install_dotnet
fi

if [ "$arg_clean" = true ]; then
    apt-get clean
    rm -rf /var/lib/apt/lists/*
fi
