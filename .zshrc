setopt HIST_IGNORE_SPACE

# ================= Eric 的登录信息 =================
if [[ -o interactive ]]; then
  _eric_login_info() {
    local c_blue=$'\e[96m'
    local c_red=$'\e[31m'
    local c_yellow=$'\e[33m'
    local c_cyan=$'\e[36m'
    local c_green=$'\e[32m'
    local c_reset=$'\e[0m'
    local uptime_text disk_text ipv4_text

    if command -v figlet >/dev/null 2>&1; then
      printf "%s%s%s\n" "${c_blue}" "$(figlet -f standard "Eric Terminal")" "${c_reset}"
    else
      printf "%sEric Terminal%s\n" "${c_blue}" "${c_reset}"
    fi
    echo ""

    echo -e "Welcome, ${c_red}$(whoami)${c_reset} on ${c_yellow}$(hostname)${c_reset}"
    echo -e "Current location: ${c_cyan}$(pwd)${c_reset}"
    echo ""

    uptime_text=$(uptime | sed -E 's/, [0-9]+ users?.*//' | sed 's/.*up //')
    disk_text=$(df -h / | awk 'NR==2 {print "free " $4 " of " $2 " (" $5 ")"}')
    ipv4_text=$(ipconfig getifaddr en0 2>/dev/null || echo "No IP")

    printf "${c_green}%-12s:${c_reset} %s\n" "Uptime" "${uptime_text}"
    printf "${c_green}%-12s:${c_reset} %s\n" "Usage of /" "${disk_text}"
    printf "${c_green}%-12s:${c_reset} (LAN) ${c_green}%s${c_reset}\n" "IPv4" "${ipv4_text}"
    echo ""
  }

  _eric_login_info
  unfunction _eric_login_info
fi

# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"

plugins=(git zsh-syntax-highlighting zsh-autosuggestions)

[[ -d "$HOME/.docker/completions" ]] && fpath=($HOME/.docker/completions ${fpath:#$HOME/.docker/completions})

zsh_cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
mkdir -p "$zsh_cache_dir"
ZSH_COMPDUMP="$zsh_cache_dir/.zcompdump-${HOST:-zsh}-${ZSH_VERSION}"
unset zsh_cache_dir

[[ -s "$ZSH/oh-my-zsh.sh" ]] && source "$ZSH/oh-my-zsh.sh"

# ================= Eric 的常用配置 =================

alias ll='ls -l'
alias la='ls -A'
alias l='ls -CF'
alias cx='codex'
alias cc='claude'

export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk

export PATH="$PATH:$HOME/.local/bin"

export PATH="$PATH:$HOME/.npm-global/bin"

# ================= Pyenv 配置 (静默加载) =================
export PYENV_ROOT="$HOME/.pyenv"
[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
# 通过重定向输出到 /dev/null 来静默化 pyenv 的初始化过程
command -v pyenv >/dev/null 2>&1 && eval "$(pyenv init -)" >/dev/null 2>&1

# ================= Node.js 配置 =================
export NODE_OPTIONS=--max-old-space-size=4096

# ================= 本机私有配置 =================
# API Key、Token、私有代理等写在 ~/.zshrc.local，不提交仓库。
[[ -f ~/.zshrc.local ]] && source ~/.zshrc.local

# ================= Go 配置 =================
export GOPATH=$HOME/go
export PATH=$PATH:$GOPATH/bin

[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
export NODE_NO_WARNINGS=1
export GPG_TTY=$(tty)

# CLOUDFLARE_API_TOKEN 放在 ~/.zshrc.local
# CLOUDFLARE_ACCOUNT_ID 放在 ~/.zshrc.local

command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init zsh)"
alias unblock='xattr -d com.apple.quarantine'

# 实现按一次 Ctrl+Z 挂起，在命令行空白时再按一次 Ctrl+Z 自动恢复前台
fancy-ctrl-z () {
  if [[ $#BUFFER -eq 0 ]]; then
    BUFFER="fg"
    zle accept-line
  else
    zle push-line
    zle clear-screen
  fi
}
zle -N fancy-ctrl-z
bindkey '^Z' fancy-ctrl-z

# GPG 相关
alias gpg-search='gpg --keyserver hkps://keys.openpgp.org --search-keys'
alias gpg-recv='gpg --keyserver hkps://keys.openpgp.org --recv-keys'
alias gpg-wkd='gpg --auto-key-locate clear,wkd,nodefault --locate-keys'
alias gpg-fetch='gpg --locate-external-keys'
alias gpg-list='gpg --list-keys --keyid-format LONG'
alias gpg-list-sec='gpg --list-secret-keys --keyid-format LONG'
alias gpg-export='gpg -a --export'
alias gpg-update='gpg --refresh-keys --keyserver hkps://keys.openpgp.org'
alias gpg-del='gpg --delete-keys'
alias gpg-enc='gpg -e -a -r'
alias gpg-dec='gpg -d'
alias gpg-sign='gpg --clear-sign'
alias gpg-verify='gpg --verify'

alias gola='export TZ="America/Los_Angeles" LANG="en_US.UTF-8" LC_ALL="en_US.UTF-8"'
