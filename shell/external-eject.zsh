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
  local scan_output scan_errors scan_status=0

  scan_errors="$(/usr/bin/mktemp -t xeject)" || return 1
  {
    if (( elevated )); then
      scan_output="$(/usr/bin/sudo -n /usr/sbin/lsof -nP -FpcuLfn +f -- "$mount_point" 2>"$scan_errors")" || scan_status=$?
    else
      scan_output="$(/usr/sbin/lsof -nP -FpcuLfn +f -- "$mount_point" 2>"$scan_errors")" || scan_status=$?
    fi

    # lsof 在没有匹配项时也返回 1；只有无输出、无诊断时才把它视为空结果。
    # 有警告的扫描可能遗漏进程，不能据此宣称卷没有被占用。
    if (( scan_status == 1 )) && [[ -z "$scan_output" && ! -s "$scan_errors" ]]; then
      scan_status=0
    fi
    if (( scan_status != 0 )) || [[ -s "$scan_errors" ]]; then
      /bin/cat "$scan_errors" >&2
      return 1
    fi

    _external-eject-summarize <<< "$scan_output"
  } always {
    /bin/rm -f -- "$scan_errors"
  }
}

_external-eject-send-signal() {
  emulate -L zsh

  local pid="$1"
  local owner="$2"
  local signal="$3"

  if [[ "$owner" == "$USER" || "$owner" == "$EUID" ]]; then
    /bin/kill -"$signal" "$pid" 2>/dev/null
  else
    /usr/bin/sudo /bin/kill -"$signal" "$pid"
  fi
}

# 批量操作共用一个等待期限；ps 能检查其他用户的进程，避免 kill -0 把无权限误判为退出。
_external-eject-wait() {
  emulate -L zsh

  local selected_pids="${(j:,:)@}"
  local -F SECONDS=0

  [[ -n "$selected_pids" ]] || return 0
  printf 'xeject：等待进程退出（最多约 5 秒）……\n'
  while [[ -n "$(/bin/ps -p "$selected_pids" -o pid=)" ]]; do
    if (( SECONDS >= 5 )); then
      printf 'xeject：部分进程尚未退出，将重新扫描占用情况。\n'
      return 1
    fi
    /bin/sleep 0.2
  done
  return 0
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
  local mount_point eject_output scan_output answer confirmation selector
  local pid process owner count sample signal index
  local target_count success_count failure_count
  local scan_only=0 elevated=0 should_eject=1 scan_failed path_width
  local -a pids processes owners counts samples signaled_pids
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
输入序号或 PID 可发送 TERM；“k 序号”发送 KILL；“a”与“ka”分别处理全部进程。
“h”会将当前终端切换到主目录，再重试推出；扫描模式下只重新扫描。
--scan 是严格的只扫描模式；结束进程后只会重新扫描，不会推出卷。
EOF
        return 0
        ;;
      --scan)
        scan_only=1
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

    if (( elevated )); then
      # 认证必须发生在前台，sudo 才能关闭密码回显并启用终端的安全输入。
      if ! /usr/bin/sudo -n -v 2>/dev/null && ! /usr/bin/sudo -v; then
        printf '%sxeject：管理员认证失败，已恢复普通扫描。%s\n' "$c_red" "$c_reset" >&2
        elevated=0
      fi
    fi

    # 先取得扫描状态，避免进程替换吞掉失败并被误报成没有占用。
    scan_failed=0
    scan_output="$(_external-eject-scan "$mount_point" "$elevated")" || scan_failed=1
    while IFS=$'\t' read -r pid process owner count sample; do
      [[ "$pid" == <-> ]] || continue
      pids+=("$pid")
      processes+=("${process:-未知进程}")
      owners+=("${owner:-未知用户}")
      counts+=("${count:-0}")
      samples+=("$sample")
    done <<< "$scan_output"

    printf '\n%s%s 的占用情况%s\n' "$c_bold" "$mount_point" "$c_reset"
    if (( scan_failed )); then
      printf '%s扫描未能完整完成，无法确定占用情况；可输入 s 重试或 p 使用管理员扫描。%s\n' \
        "$c_red" "$c_reset"
    elif (( ${#pids} == 0 )); then
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
          printf '    %s这是当前终端，可输入 h 返回主目录后重试。%s\n' "$c_yellow" "$c_reset"
        if [[ -n "$sample" ]]; then
          path_width=$(( ${COLUMNS:-80} - 4 ))
          (( path_width >= 32 )) || path_width=76
          _external-eject-fit "$sample" "$path_width"
          printf '    %s%s%s\n' "$c_dim" "$REPLY" "$c_reset"
        fi
      done
    fi

    printf '\n%s操作%s：序号/PID 结束 · k 序号/PID 强制结束\n' "$c_bold" "$c_reset"
    printf '      a 全部结束 · ka 全部强制结束'
    if (( scan_only )); then
      printf ' · s 重新扫描'
    else
      printf ' · r 推出 · s 扫描'
    fi
    printf ' · h 回到主目录'
    (( elevated )) || printf ' · p 管理员'
    printf ' · q 取消\n'
    printf '%sxeject>%s ' "$c_cyan" "$c_reset"
    read -r answer || return 1

    case "${answer:l}" in
      q|quit|exit)
        printf 'xeject：已取消，硬盘仍保持挂载。\n'
        return 1
        ;;
      r)
        if (( scan_only )); then
          printf 'xeject：--scan 模式不会推出卷；请退出后运行普通 xeject。\n'
          continue
        fi
        should_eject=1
        continue
        ;;
      s|'')
        continue
        ;;
      h)
        # 直接改变调用者的目录；恢复原目录会再次占用刚要推出的卷。
        if builtin cd -- "$HOME"; then
          printf 'xeject：当前目录已切换到 %s。\n' "$PWD"
          should_eject=$(( !scan_only ))
        else
          printf 'xeject：无法切换到主目录，当前目录未改变。\n' >&2
        fi
        continue
        ;;
      p)
        elevated=1
        printf 'xeject：管理员扫描会请求密码，以查看系统服务的占用。\n'
        continue
        ;;
    esac

    if [[ "${answer:l}" == a || "${answer:l}" == ka ]]; then
      signal=TERM
      [[ "${answer:l}" == ka ]] && signal=KILL

      target_count=0
      for pid in "${pids[@]}"; do
        [[ "$pid" == $$ ]] || (( target_count++ ))
      done

      if (( target_count == 0 )); then
        printf '%sxeject：当前没有可结束的占用进程。%s\n' "$c_yellow" "$c_reset"
        continue
      fi

      if [[ "$signal" == KILL ]]; then
        printf '%s强制结束全部 %d 个占用进程可能造成未保存数据丢失，确认吗？[y/N]%s ' \
          "$c_red" "$target_count" "$c_reset"
      else
        printf '结束全部 %d 个占用进程？未保存的数据可能丢失。[y/N] ' "$target_count"
      fi
      read -r confirmation || return 1
      [[ "${confirmation:l}" == y || "${confirmation:l}" == yes || "$confirmation" == 是 ]] || {
        printf 'xeject：没有结束任何进程。\n'
        continue
      }

      success_count=0
      failure_count=0
      signaled_pids=()
      for (( index = 1; index <= ${#pids}; index++ )); do
        pid="${pids[$index]}"
        [[ "$pid" == $$ ]] && continue

        if _external-eject-send-signal "$pid" "${owners[$index]}" "$signal"; then
          (( success_count++ ))
          signaled_pids+=("$pid")
        else
          (( failure_count++ ))
        fi
      done

      printf 'xeject：已向 %d 个进程发送 %s' "$success_count" "$signal"
      (( failure_count > 0 )) && \
        printf '，另有 %d 个进程已退出或权限不足' "$failure_count"
      if (( scan_only )); then
        printf '；稍后重新扫描。\n'
      else
        printf '；稍后重试推出。\n'
      fi
      should_eject=0
      if _external-eject-wait "${signaled_pids[@]}"; then
        should_eject=$(( !scan_only ))
      fi
      continue
    fi

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
      printf '%sxeject：不会结束当前终端。可输入 h 返回主目录后重试。%s\n' "$c_yellow" "$c_reset"
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

    if ! _external-eject-send-signal "$pid" "$owner" "$signal"; then
      printf '%sxeject：无法结束 PID %s；它可能已经退出，或当前权限不足。%s\n' \
        "$c_red" "$pid" "$c_reset"
      continue
    fi

    if (( scan_only )); then
      printf 'xeject：已向 %s（PID %s）发送 %s，稍后重新扫描。\n' \
        "$process" "$pid" "$signal"
    else
      printf 'xeject：已向 %s（PID %s）发送 %s，稍后重试推出。\n' \
        "$process" "$pid" "$signal"
    fi
    should_eject=0
    if _external-eject-wait "$pid"; then
      should_eject=$(( !scan_only ))
    fi
  done
}

alias xeject='external-eject'
