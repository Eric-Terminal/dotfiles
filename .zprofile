[[ -x /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"

# Created by `pipx` on 2025-04-15 17:46:49
export PATH="$PATH:$HOME/.local/bin"

command -v fnm >/dev/null 2>&1 && eval "$(fnm env --shell zsh --use-on-cd --version-file-strategy recursive --log-level quiet)"
export PATH="$HOME/.npm-global/bin:$PATH"

# 检测最近是否有非本机 SSH 登录，只在本机交互式登录 shell 中执行。
if [[ "$OSTYPE" == darwin* && -o interactive && -z "${SSH_CONNECTION:-}" && -z "${SSH_CLIENT:-}" && -z "${SSH_TTY:-}" ]]; then
  ssh_remote_login=$(
    LC_ALL=C last -20 "$USER" | awk '
      /^wtmp begins/ { exit }
      $3 ~ /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun|一|二|三|四|五|六|日)$/ { next }
      $3 ~ /^(localhost|127\.0\.0\.1|::1)$/ { next }
      { print; exit }
    '
  )

  if [[ -n "$ssh_remote_login" ]]; then
    ssh_alert_dir="${XDG_CACHE_HOME:-$HOME/.cache}"
    ssh_alert_state="$ssh_alert_dir/etos-ssh-login-alert"
    ssh_remote_from=$(awk '{ print $3 }' <<< "$ssh_remote_login")

    mkdir -p "$ssh_alert_dir"
    if [[ ! -r "$ssh_alert_state" || "$(cat "$ssh_alert_state")" != "$ssh_remote_login" ]]; then
      print -P "%F{red}%B警报：SSH 检测到非本机登录。来源：$ssh_remote_from%b%f"
      osascript \
        -e 'on run argv' \
        -e 'display alert "SSH 检测到非本机登录" message ("来源：" & item 1 of argv) as critical' \
        -e 'end run' \
        "$ssh_remote_from" >/dev/null
      print -r -- "$ssh_remote_login" > "$ssh_alert_state"
    fi
  fi

  unset ssh_remote_login ssh_remote_from ssh_alert_dir ssh_alert_state
fi
