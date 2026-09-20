# 让 fzf-tab 接管候选菜单，并保留参数说明和候选分组。
zstyle ':completion:*' menu no
zstyle ':completion:*:descriptions' format '[%d]'
zstyle ':completion:*:git-checkout:*' sort false
zstyle ':fzf-tab:*' switch-group '<' '>'
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'ls -la -- "$realpath"'

# 文件预览限制行数，避免大文件拖慢选择；目录则显示内容。
export FZF_DEFAULT_OPTS='--height=40% --layout=reverse --border'
export FZF_CTRL_T_OPTS="--preview 'if [ -d {} ]; then ls -la -- {}; else bat --color=always --style=numbers --line-range=:200 -- {}; fi'"
export FZF_ALT_C_OPTS="--preview 'ls -la -- {}'"

# run-help 能识别别名、内建命令和 Git 子命令，看完手册后保留正在编辑的命令。
(( $+aliases[run-help] )) && unalias run-help
autoload -Uz run-help run-help-git run-help-sudo
bindkey '\eh' run-help
