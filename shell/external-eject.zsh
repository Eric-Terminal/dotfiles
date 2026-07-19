# 将 lsof 的字段输出按进程聚合，避免一个应用的每个动态库各占一行。
_external-eject-summarize() {
  /usr/bin/awk '
    /^p/ {
      pid = substr($0, 2)
      if (!(pid in seen)) {
        seen[pid] = 1
        order[++total] = pid
      }
      next
    }
    /^c/ { command[pid] = substr($0, 2); next }
    /^L/ { owner[pid] = substr($0, 2); next }
    /^u/ {
      if (owner[pid] == "") owner[pid] = substr($0, 2)
      next
    }
    /^n/ {
      opened[pid]++
      if (sample[pid] == "") sample[pid] = substr($0, 2)
    }
    END {
      for (i = 1; i <= total; i++) {
        pid = order[i]
        printf "%s\t%s\t%s\t%d\t%s\n", \
          pid, command[pid], owner[pid], opened[pid], sample[pid]
      }
    }
  '
}

_external-eject-scan() {
  emulate -L zsh

  local mount_point="$1"
  local elevated="$2"

  if (( elevated )); then
    /usr/bin/sudo /usr/sbin/lsof -nP -FpcuLfn -- "$mount_point" 2>/dev/null |
      _external-eject-summarize
  else
    /usr/sbin/lsof -nP -FpcuLfn -- "$mount_point" 2>/dev/null |
      _external-eject-summarize
  fi
}

# 路径过长时保留首尾，既能看到所属应用，也能辨认最终文件。
_external-eject-fit() {
  emulate -L zsh

  local value="$1"
  local max_length="$2"
  local left_length right_length

  if (( ${#value} <= max_length )); then
    REPLY="$value"
    return
  fi

  left_length=$(( (max_length - 1) / 2 ))
  right_length=$(( max_length - left_length - 1 ))
  REPLY="${value[1,$left_length]}…${value[-$right_length,-1]}"
}

_external-eject-mount-point() {
  emulate -L zsh

  local target="$1"
  local disk_info

  if [[ "$target" != /* && -e "/Volumes/$target" ]]; then
    target="/Volumes/$target"
  fi

  disk_info="$(/usr/sbin/diskutil info -plist "$target" 2>/dev/null)" || return 1
  REPLY="$(
    printf '%s' "$disk_info" |
      /usr/bin/plutil -extract MountPoint raw -o - - 2>/dev/null
  )" || return 1

  [[ -n "$REPLY" && "$REPLY" != null && -d "$REPLY" ]]
}

external-eject() {
  emulate -L zsh

  local target='/Volumes/nvme0n1'
  local mount_point eject_output answer confirmation selector
  local pid process owner count sample signal index
  local elevated=0 should_eject=1 path_width
  local -a pids processes owners counts samples
  local -A pid_by_index process_by_pid owner_by_pid

  local c_bold=$'\e[1m'
  local c_cyan=$'\e[36m'
  local c_yellow=$'\e[33m'
  local c_red=$'\e[31m'
  local c_dim=$'\e[2m'
  local c_reset=$'\e[0m'

  while (( $# )); do
    case "$1" in
      --help|-h)
        /bin/cat <<'EOF'
用法：
  xeject [卷路径或卷名]
  xeject --scan [卷路径或卷名]

默认卷：/Volumes/nvme0n1

xeject 会先尝试正常推出；若卷正被占用，则按进程汇总占用项并进入交互菜单。
菜单中可输入序号或 PID 发送 TERM，输入“k 序号”在二次确认后发送 KILL。
EOF
        return 0
        ;;
      --scan)
        should_eject=0
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        printf 'xeject：未知选项：%s\n' "$1" >&2
        printf '运行 xeject --help 查看用法。\n' >&2
        return 2
        ;;
      *)
        break
        ;;
    esac
  done

  if (( $# > 1 )); then
    printf 'xeject：一次只能处理一个卷。\n' >&2
    return 2
  elif (( $# == 1 )); then
    target="$1"
  fi

  if [[ ! -t 0 || ! -t 1 ]]; then
    printf 'xeject：需要在交互式终端中运行。\n' >&2
    return 1
  fi

  if ! _external-eject-mount-point "$target"; then
    printf 'xeject：找不到已挂载的卷：%s\n' "$target" >&2
    return 1
  fi
  mount_point="$REPLY"

  while true; do
    if (( should_eject )); then
      printf '%sxeject%s：正在正常推出 %s……\n' "$c_bold$c_cyan" "$c_reset" "$mount_point"
      eject_output="$(/usr/sbin/diskutil eject "$mount_point" 2>&1)"
      if (( $? == 0 )); then
        printf '%sxeject：已经安全推出：%s%s\n' "$c_cyan" "$mount_point" "$c_reset"
        return 0
      fi

      printf '%sxeject：暂时无法推出，正在检查占用进程。%s\n' "$c_yellow" "$c_reset"
      [[ -n "$eject_output" ]] && printf '%s  %s%s\n' "$c_dim" "$eject_output" "$c_reset"
      should_eject=0
    fi

    pids=()
    processes=()
    owners=()
    counts=()
    samples=()
    pid_by_index=()
    process_by_pid=()
    owner_by_pid=()

    while IFS=$'\t' read -r pid process owner count sample; do
      [[ "$pid" == <-> ]] || continue
      pids+=("$pid")
      processes+=("${process:-未知进程}")
      owners+=("${owner:-未知用户}")
      counts+=("${count:-0}")
      samples+=("$sample")
    done < <(_external-eject-scan "$mount_point" "$elevated")

    printf '\n%s%s 的占用情况%s\n' "$c_bold" "$mount_point" "$c_reset"
    if (( ${#pids} == 0 )); then
      printf '%s当前扫描没有发现占用进程。%s\n' "$c_yellow" "$c_reset"
    else
      for (( index = 1; index <= ${#pids}; index++ )); do
        pid="${pids[$index]}"
        process="${processes[$index]}"
        owner="${owners[$index]}"
        count="${counts[$index]}"
        sample="${samples[$index]}"

        pid_by_index[$index]="$pid"
        process_by_pid[$pid]="$process"
        owner_by_pid[$pid]="$owner"

        printf '%s[%d]%s PID %-6s  %s%-28.28s%s  %s%s  ·  %s 个打开项%s\n' \
          "$c_cyan" "$index" "$c_reset" "$pid" "$c_bold" "$process" "$c_reset" \
          "$c_dim" "$owner" "$count" "$c_reset"
        [[ "$pid" == $$ ]] && \
          printf '    %s这是当前终端，请先执行 cd ~，不要结束它。%s\n' "$c_yellow" "$c_reset"
        if [[ -n "$sample" ]]; then
          path_width=$(( ${COLUMNS:-80} - 4 ))
          (( path_width >= 32 )) || path_width=76
          _external-eject-fit "$sample" "$path_width"
          printf '    %s%s%s\n' "$c_dim" "$REPLY" "$c_reset"
        fi
      done
    fi

    printf '\n%s操作%s：序号/PID 结束进程 · k 序号/PID 强制结束 · r 重试推出 · s 重新扫描' \
      "$c_bold" "$c_reset"
    (( elevated )) || printf ' · p 管理员扫描'
    printf ' · q 取消\n'
    printf '%sxeject>%s ' "$c_cyan" "$c_reset"
    read -r answer || return 1

    case "${answer:l}" in
      q|quit|exit)
        printf 'xeject：已取消，硬盘仍保持挂载。\n'
        return 1
        ;;
      r)
        should_eject=1
        continue
        ;;
      s|'')
        continue
        ;;
      p)
        elevated=1
        printf 'xeject：管理员扫描会请求密码，以查看系统服务的占用。\n'
        continue
        ;;
    esac

    signal=TERM
    selector="$answer"
    if [[ "${answer:l}" == k\ * ]]; then
      signal=KILL
      selector="${answer#* }"
    fi

    if [[ "$selector" != <-> ]]; then
      printf '%sxeject：请输入列表序号、PID 或菜单命令。%s\n' "$c_yellow" "$c_reset"
      continue
    fi

    if [[ -n "${pid_by_index[$selector]:-}" ]]; then
      pid="${pid_by_index[$selector]}"
    elif [[ -n "${process_by_pid[$selector]:-}" ]]; then
      pid="$selector"
    else
      printf '%sxeject：这个序号或 PID 不在当前扫描结果中。%s\n' "$c_yellow" "$c_reset"
      continue
    fi

    process="${process_by_pid[$pid]}"
    owner="${owner_by_pid[$pid]}"

    if [[ "$pid" == $$ ]]; then
      printf '%sxeject：不会结束当前终端。请先执行 cd ~，再输入 r。%s\n' "$c_yellow" "$c_reset"
      continue
    fi

    if [[ "$signal" == KILL ]]; then
      printf '%s强制结束 %s（PID %s）可能造成未保存数据丢失，确认吗？[y/N]%s ' \
        "$c_red" "$process" "$pid" "$c_reset"
    else
      printf '向 %s（PID %s）发送结束信号？未保存的数据可能丢失。[y/N] ' \
        "$process" "$pid"
    fi
    read -r confirmation || return 1
    [[ "${confirmation:l}" == y || "${confirmation:l}" == yes || "$confirmation" == 是 ]] || {
      printf 'xeject：没有结束该进程。\n'
      continue
    }

    if [[ "$owner" == "$USER" ]]; then
      /bin/kill -"$signal" "$pid" 2>/dev/null
    else
      /usr/bin/sudo /bin/kill -"$signal" "$pid"
    fi

    if (( $? != 0 )); then
      printf '%sxeject：无法结束 PID %s；它可能已经退出，或当前权限不足。%s\n' \
        "$c_red" "$pid" "$c_reset"
      continue
    fi

    printf 'xeject：已向 %s（PID %s）发送 %s，稍后重试推出。\n' "$process" "$pid" "$signal"
    /bin/sleep 1
    should_eject=1
  done
}

alias xeject='external-eject'
