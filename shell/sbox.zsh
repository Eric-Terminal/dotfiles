# sbox: 用 sandbox-exec 给不完全可信的命令加一层 Home 目录保护。

typeset -ga _SBOX_RULE_SCOPES _SBOX_RULE_OPS _SBOX_RULE_PATHS
typeset -ga _SBOX_OPS _SBOX_FALLBACK_OPS
typeset -g _SBOX_ALLOW_PWD _SBOX_NETWORK

_SBOX_FALLBACK_OPS=(
  'appleevent-send'
  'authorization-right-obtain'
  'darwin-notification-post'
  'default'
  'device-microphone'
  'distributed-notification-post'
  'dynamic-code-generation'
  'file*'
  'file-fsctl'
  'file-ioctl'
  'file-issue-extension'
  'file-issue-extension*'
  'file-map-executable'
  'file-mount'
  'file-read*'
  'file-read-data'
  'file-read-metadata'
  'file-read-xattr'
  'file-search'
  'file-test-existence'
  'file-write*'
  'file-write-create'
  'file-write-data'
  'file-write-mode'
  'file-write-mount'
  'file-write-setugid'
  'file-write-umount'
  'file-write-unlink'
  'file-write-xattr'
  'generic-issue-extension'
  'iokit*'
  'iokit-get-properties'
  'iokit-open'
  'iokit-open-user-client'
  'iokit-set-properties'
  'ipc-posix-shm'
  'ipc-posix-shm-read*'
  'ipc-posix-shm-read-data'
  'ipc-posix-shm-write*'
  'ipc-posix-shm-write-create'
  'ipc-posix-shm-write-data'
  'job-creation'
  'lsopen'
  'mach-bootstrap'
  'mach-issue-extension'
  'mach-lookup'
  'mach-per-user-lookup'
  'mach-register'
  'network*'
  'network-bind'
  'network-inbound'
  'network-outbound'
  'nvram-get'
  'nvram-set'
  'process-exec'
  'process-exec*'
  'process-fork'
  'process-info*'
  'process-info-codesignature'
  'process-info-listpids'
  'process-info-pidinfo'
  'pseudo-tty'
  'signal'
  'syscall-mach'
  'syscall-unix'
  'sysctl*'
  'sysctl-read'
  'sysctl-write'
  'system-fcntl'
  'system-fsctl'
  'system-info'
  'system-kext*'
  'system-mac-syscall'
  'system-package-check'
  'system-privilege'
  'system-sched'
  'system-socket'
  'user-preference*'
  'user-preference-read'
  'user-preference-write'
)

_sbox_config_dir() {
  print -r -- "${XDG_CONFIG_HOME:-$HOME/.config}/sbox"
}

_sbox_profile_dir() {
  print -r -- "$(_sbox_config_dir)/profiles"
}

_sbox_workspace_path() {
  print -r -- "$(_sbox_config_dir)/workspaces.tsv"
}

_sbox_profile_name_ok() {
  [[ "$1" =~ '^[A-Za-z0-9._-]+$' ]]
}

_sbox_profile_path() {
  local name="${1:-default}"

  _sbox_profile_name_ok "$name" || {
    print -u2 "sbox: profile 名只能包含字母、数字、点、下划线和连字符: $name"
    return 2
  }

  print -r -- "$(_sbox_profile_dir)/$name.conf"
}

_sbox_workspace_key() {
  local workspace="${PWD:A}"

  if [[ "$workspace" == *$'\n'* || "$workspace" == *$'\t'* ]]; then
    print -u2 "sbox: 当前目录不能包含换行或制表符: $workspace"
    return 2
  fi

  print -r -- "$workspace"
}

_sbox_remembered_profile() {
  local file workspace stored_workspace stored_profile

  file=$(_sbox_workspace_path)
  [[ -f "$file" ]] || return 1
  workspace=$(_sbox_workspace_key) || return

  while IFS=$'\t' read -r stored_workspace stored_profile; do
    [[ "$stored_workspace" == "$workspace" ]] || continue
    _sbox_profile_name_ok "$stored_profile" || return 1
    print -r -- "$stored_profile"
    return 0
  done < "$file"

  return 1
}

_sbox_effective_default_profile() {
  local remembered

  remembered=$(_sbox_remembered_profile) || {
    print "default"
    return
  }

  print -r -- "$remembered"
}

_sbox_remember_workspace_profile() {
  local profile_name="$1" file tmp workspace stored_workspace stored_profile

  _sbox_profile_name_ok "$profile_name" || return 2
  workspace=$(_sbox_workspace_key) || return
  file=$(_sbox_workspace_path)
  mkdir -p "$(_sbox_config_dir)" || return

  tmp=$(mktemp "$file.tmp.XXXXXX") || return
  if {
    if [[ -f "$file" ]]; then
      while IFS=$'\t' read -r stored_workspace stored_profile; do
        [[ -n "$stored_workspace" && "$stored_workspace" != "$workspace" ]] || continue
        printf '%s\t%s\n' "$stored_workspace" "$stored_profile"
      done < "$file"
    fi
    printf '%s\t%s\n' "$workspace" "$profile_name"
  } > "$tmp"; then
    chmod 600 "$tmp"
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    return 1
  fi
}

_sbox_lock_dir() {
  local file

  file=$(_sbox_profile_path "${1:-default}") || return
  print -r -- "$file.lock"
}

_sbox_lock_alive() {
  local lock_dir="$1" owner_pid

  [[ -r "$lock_dir/pid" ]] || return 1
  IFS= read -r owner_pid < "$lock_dir/pid" || return 1
  [[ "$owner_pid" == <-> ]] || return 1
  kill -0 "$owner_pid" 2>/dev/null
}

_sbox_acquire_profile_lock() {
  local name="${1:-default}" lock_dir owner_pid

  mkdir -p "$(_sbox_profile_dir)" || return
  lock_dir=$(_sbox_lock_dir "$name") || return

  while ! mkdir "$lock_dir" 2>/dev/null; do
    if _sbox_lock_alive "$lock_dir"; then
      IFS= read -r owner_pid < "$lock_dir/pid"
      print -u2 "sbox: profile '$name' 正在被另一个菜单编辑，pid=$owner_pid"
      return 3
    fi

    print -u2 "sbox: 清理陈旧 profile 锁: $lock_dir"
    rm -rf "$lock_dir" || return
  done

  {
    print -r -- "$$"
  } > "$lock_dir/pid"
  {
    printf 'profile\t%s\n' "$name"
    printf 'pid\t%s\n' "$$"
    printf 'shell\t%s\n' "${SHELL:-zsh}"
  } > "$lock_dir/owner"

  _sbox_init_profile "$name" || {
    rm -rf "$lock_dir"
    return 1
  }

  print -r -- "$lock_dir"
}

_sbox_release_profile_lock() {
  local lock_dir="$1" owner_pid

  [[ -n "$lock_dir" && -d "$lock_dir" ]] || return 0
  IFS= read -r owner_pid < "$lock_dir/pid" 2>/dev/null || owner_pid=
  [[ "$owner_pid" == "$$" ]] && rm -rf "$lock_dir"
}

_sbox_init_profile() {
  local file tmp
  file=$(_sbox_profile_path "${1:-default}") || return

  [[ -f "$file" ]] && return 0
  mkdir -p "$(_sbox_profile_dir)" || return

  tmp=$(mktemp "$file.tmp.XXXXXX") || return
  if {
    print "# sbox profile"
    printf 'setting\tallow_pwd\t1\n'
    printf 'setting\tnetwork\tallow\n'
  } > "$tmp"; then
    chmod 600 "$tmp"
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    return 1
  fi
}

_sbox_load_profile() {
  local name="${1:-default}" file kind field value

  _SBOX_RULE_SCOPES=()
  _SBOX_RULE_OPS=()
  _SBOX_RULE_PATHS=()
  _SBOX_ALLOW_PWD=1
  _SBOX_NETWORK=allow

  _sbox_init_profile "$name" || return
  file=$(_sbox_profile_path "$name") || return

  while IFS=$'\t' read -r kind field value; do
    [[ -z "$kind" || "$kind" == \#* ]] && continue

    case "$kind:$field" in
      setting:allow_pwd)
        [[ "$value" == 0 ]] && _SBOX_ALLOW_PWD=0 || _SBOX_ALLOW_PWD=1
        ;;
      setting:network)
        [[ "$value" == deny ]] && _SBOX_NETWORK=deny || _SBOX_NETWORK=allow
        ;;
      rule:*)
        _sbox_rule_op_ok "$field" || continue
        _SBOX_RULE_SCOPES+=("path")
        _SBOX_RULE_OPS+=("$field")
        _SBOX_RULE_PATHS+=("$value")
        ;;
      global:*)
        _sbox_rule_op_ok "$field" || continue
        _SBOX_RULE_SCOPES+=("global")
        _SBOX_RULE_OPS+=("$field")
        _SBOX_RULE_PATHS+=("")
        ;;
      path:r)
        _SBOX_RULE_SCOPES+=("path")
        _SBOX_RULE_OPS+=("file-read*")
        _SBOX_RULE_PATHS+=("$value")
        ;;
      path:w)
        _SBOX_RULE_SCOPES+=("path")
        _SBOX_RULE_OPS+=("file-write*")
        _SBOX_RULE_PATHS+=("$value")
        ;;
      path:rw)
        _SBOX_RULE_SCOPES+=("path")
        _SBOX_RULE_OPS+=("file-read*")
        _SBOX_RULE_PATHS+=("$value")
        _SBOX_RULE_SCOPES+=("path")
        _SBOX_RULE_OPS+=("file-write*")
        _SBOX_RULE_PATHS+=("$value")
        ;;
    esac
  done < "$file"
}

_sbox_save_profile() {
  local name="${1:-default}" file tmp i

  file=$(_sbox_profile_path "$name") || return
  mkdir -p "$(_sbox_profile_dir)" || return

  tmp=$(mktemp "$file.tmp.XXXXXX") || return
  if {
    print "# sbox profile"
    printf 'setting\tallow_pwd\t%s\n' "$_SBOX_ALLOW_PWD"
    printf 'setting\tnetwork\t%s\n' "$_SBOX_NETWORK"

    for (( i = 1; i <= ${#_SBOX_RULE_OPS}; i++ )); do
      if [[ "${_SBOX_RULE_SCOPES[$i]}" == global ]]; then
        printf 'global\t%s\n' "${_SBOX_RULE_OPS[$i]}"
      else
        printf 'rule\t%s\t%s\n' "${_SBOX_RULE_OPS[$i]}" "${_SBOX_RULE_PATHS[$i]}"
      fi
    done
  } > "$tmp"; then
    chmod 600 "$tmp"
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    return 1
  fi
}

_sbox_normalize_path() {
  local target="$1"

  [[ -e "$target" ]] || {
    print -u2 "sbox: 路径不存在: $target"
    return 2
  }

  target="${target:A}"
  if [[ "$target" == *$'\n'* || "$target" == *$'\t'* ]]; then
    print -u2 "sbox: 路径不能包含换行或制表符: $target"
    return 2
  fi

  print -r -- "$target"
}

_sbox_sb_string() {
  local s="$1"

  s="${s:A}"
  [[ "$s" == *$'\n'* ]] && {
    print -u2 "sbox: 路径不能包含换行: $1"
    return 2
  }

  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  print -r -- "\"$s\""
}

_sbox_path_filter() {
  local target="$1" q

  q=$(_sbox_sb_string "$target") || return
  if [[ -d "$target" ]]; then
    print -r -- "(subpath $q)"
  else
    print -r -- "(literal $q)"
  fi
}

_sbox_add_op_once() {
  local op="$1" existing

  for existing in "${_SBOX_OPS[@]}"; do
    [[ "$existing" == "$op" ]] && return 0
  done
  _SBOX_OPS+=("$op")
}

_sbox_load_ops() {
  local op

  (( ${#_SBOX_OPS} )) && return 0
  _SBOX_OPS=("${_SBOX_FALLBACK_OPS[@]}")

  [[ -d /usr/share/sandbox ]] || return 0
  while IFS= read -r op; do
    [[ -n "$op" ]] && _sbox_add_op_once "$op"
  done < <(grep -RhoE '\((allow|deny) [A-Za-z0-9_*-]+' /usr/share/sandbox 2>/dev/null | awk '{print $2}' | sort -u)
}

_sbox_rule_op_ok() {
  local op="$1" allowed

  _sbox_load_ops
  for allowed in "${_SBOX_OPS[@]}"; do
    [[ "$op" == "$allowed" ]] && return 0
  done

  return 1
}

_sbox_op_uses_path() {
  [[ "$1" == file* ]]
}

_sbox_is_cli_option() {
  case "$1" in
    +r|+w|+rw|+op|-net|+net|--no-pwd|+pwd)
      return 0
      ;;
  esac

  return 1
}

_sbox_emit_parent_metadata() {
  local target="$1" home_real="${HOME:A}" dir q

  [[ "$target" == "$home_real" || "$target" != "$home_real"/* ]] && return 0

  if [[ -d "$target" ]]; then
    dir="$target"
  else
    dir="${target:h}"
  fi

  while [[ "$dir" == "$home_real"/* ]]; do
    dir="${dir:h}"
    q=$(_sbox_sb_string "$dir") || return
    print "(allow file-read-metadata (literal $q))"
  done
}

_sbox_add_rule_unique() {
  local op="$1" target="$2" i

  _sbox_rule_op_ok "$op" || {
    print -u2 "sbox: 不支持的 sandbox operation: $op"
    return 2
  }
  target=$(_sbox_normalize_path "$target") || return

  for (( i = 1; i <= ${#_SBOX_RULE_OPS}; i++ )); do
    [[ "${_SBOX_RULE_SCOPES[$i]}" == path && "${_SBOX_RULE_OPS[$i]}" == "$op" && "${_SBOX_RULE_PATHS[$i]}" == "$target" ]] && return 0
  done

  _SBOX_RULE_SCOPES+=("path")
  _SBOX_RULE_OPS+=("$op")
  _SBOX_RULE_PATHS+=("$target")
}

_sbox_add_global_rule_unique() {
  local op="$1" i

  _sbox_rule_op_ok "$op" || {
    print -u2 "sbox: 不支持的 sandbox operation: $op"
    return 2
  }

  for (( i = 1; i <= ${#_SBOX_RULE_OPS}; i++ )); do
    [[ "${_SBOX_RULE_SCOPES[$i]}" == global && "${_SBOX_RULE_OPS[$i]}" == "$op" ]] && return 0
  done

  _SBOX_RULE_SCOPES+=("global")
  _SBOX_RULE_OPS+=("$op")
  _SBOX_RULE_PATHS+=("")
}

_sbox_emit_profile() {
  local profile_name="${1:-default}" network_override="$2" allow_pwd_override="$3"
  shift 3
  local -a rule_scopes rule_ops rule_paths extra_rule_scopes extra_rule_ops extra_rule_paths metadata_lines
  local -A seen_metadata
  local scope op target filter network allow_pwd home_q i metadata_line metadata_output

  while (( $# )); do
    scope="$1"
    op="$2"
    target="$3"
    _sbox_rule_op_ok "$op" || {
      print -u2 "sbox: 不支持的 sandbox operation: $op"
      return 2
    }
    [[ "$scope" == path || "$scope" == global ]] || {
      print -u2 "sbox: 不支持的规则类型: $scope"
      return 2
    }
    extra_rule_scopes+=("$scope")
    extra_rule_ops+=("$op")
    extra_rule_paths+=("$target")
    shift 3
  done

  _sbox_load_profile "$profile_name" || return

  rule_scopes=("${_SBOX_RULE_SCOPES[@]}" "${extra_rule_scopes[@]}")
  rule_ops=("${_SBOX_RULE_OPS[@]}" "${extra_rule_ops[@]}")
  rule_paths=("${_SBOX_RULE_PATHS[@]}" "${extra_rule_paths[@]}")

  network="${network_override:-$_SBOX_NETWORK}"
  allow_pwd="${allow_pwd_override:-$_SBOX_ALLOW_PWD}"
  if [[ "$allow_pwd" == 1 && "${PWD:A}" != "${HOME:A}" ]]; then
    rule_scopes+=("path" "path")
    rule_ops+=("file-read*" "file-write*")
    rule_paths+=("${PWD:A}" "${PWD:A}")
  fi

  print "(version 1)"
  print "(allow default)"
  [[ "$network" == deny ]] && print "(deny network*)"

  home_q=$(_sbox_sb_string "$HOME") || return
  print "(deny file-read* file-write* (subpath $home_q))"

  for (( i = 1; i <= ${#rule_scopes}; i++ )); do
    if [[ "${rule_scopes[$i]}" == path ]]; then
      metadata_output=$(_sbox_emit_parent_metadata "${rule_paths[$i]}") || return
      metadata_lines+=("${(@f)metadata_output}")
    fi
  done
  for metadata_line in "${metadata_lines[@]}"; do
    [[ -z "$metadata_line" || -n "${seen_metadata[$metadata_line]}" ]] && continue
    seen_metadata[$metadata_line]=1
    print "$metadata_line"
  done

  for (( i = 1; i <= ${#rule_ops}; i++ )); do
    if [[ "${rule_scopes[$i]}" == global ]]; then
      print "(allow ${rule_ops[$i]})"
    else
      filter=$(_sbox_path_filter "${rule_paths[$i]}") || return
      print "(allow ${rule_ops[$i]} $filter)"
    fi
  done
}

_sbox_run() {
  local profile_name="$1" network_override="$2" allow_pwd_override="$3"
  shift 3
  local -a rule_args cmd
  local profile shell_state cmdline exit_code

  while (( $# )); do
    [[ "$1" == -- ]] && {
      shift
      cmd=("$@")
      break
    }
    rule_args+=("$1" "$2" "$3")
    shift 3
  done

  (( ${#cmd} )) || {
    print -u2 "用法: sbox [@profile] [+r 路径] [+w 路径] [+rw 路径] [+op OP 路径] [-net] [--no-pwd] -- 命令 ..."
    return 2
  }

  profile=$(mktemp "${TMPDIR:-/tmp}/sbox.XXXXXX") || return
  shell_state=$(mktemp "${TMPDIR:-/tmp}/sbox-shell.XXXXXX") || {
    rm -f "$profile"
    return
  }
  chmod 600 "$profile"
  chmod 600 "$shell_state"
  alias -L > "$shell_state"

  if ! _sbox_emit_profile "$profile_name" "$network_override" "$allow_pwd_override" "${rule_args[@]}" > "$profile"; then
    rm -f "$profile" "$shell_state"
    return 2
  fi

  cmdline="${(j: :)${(q)cmd[@]}}"
  SBOX_SHELL_STATE="$shell_state" SBOX_CMDLINE="$cmdline" sandbox-exec -f "$profile" /bin/zsh -fc 'source "$SBOX_SHELL_STATE"; eval "$SBOX_CMDLINE"'
  exit_code=$?
  rm -f "$profile" "$shell_state"
  return "$exit_code"
}

_sbox_print_rules() {
  local i idx=1

  print "profile 默认设置："
  print "  当前目录自动读写: $([[ "$_SBOX_ALLOW_PWD" == 1 ]] && print 开启 || print 关闭)"
  print "  网络访问: $([[ "$_SBOX_NETWORK" == deny ]] && print 禁止 || print 允许)"
  print ""
  print "持久化路径规则："

  if (( ! ${#_SBOX_RULE_OPS} )); then
    print "  暂无"
    return
  fi

  for (( i = 1; i <= ${#_SBOX_RULE_OPS}; i++ )); do
    if [[ "${_SBOX_RULE_SCOPES[$i]}" == global ]]; then
      printf '  %2d. %-8s %-22s\n' "$idx" "global" "${_SBOX_RULE_OPS[$i]}"
    else
      printf '  %2d. %-8s %-22s %s\n' "$idx" "path" "${_SBOX_RULE_OPS[$i]}" "${_SBOX_RULE_PATHS[$i]}"
    fi
    (( idx++ ))
  done
}

_sbox_menu_choose_operation() {
  local i choice

  _sbox_load_ops
  print ""
  print "可选 sandbox operation："
  for (( i = 1; i <= ${#_SBOX_OPS}; i++ )); do
    printf '  %2d. %s\n' "$i" "${_SBOX_OPS[$i]}"
  done

  read -r "choice?编号或 operation: "
  [[ -n "$choice" ]] || return 1

  if [[ "$choice" == <-> && "$choice" -ge 1 && "$choice" -le "${#_SBOX_OPS}" ]]; then
    REPLY="${_SBOX_OPS[$choice]}"
    return 0
  fi

  _sbox_rule_op_ok "$choice" || {
    print -u2 "sbox: 不支持的 sandbox operation: $choice"
    return 1
  }

  REPLY="$choice"
}

_sbox_menu_add_rule() {
  local profile_name="$1" op target

  _sbox_menu_choose_operation || return
  op="$REPLY"
  if _sbox_op_uses_path "$op"; then
    read -r "target?路径: "
    [[ -n "$target" ]] || return 0
    _sbox_add_rule_unique "$op" "$target" || return
  else
    _sbox_add_global_rule_unique "$op" || return
  fi
  _sbox_save_profile "$profile_name"
}

_sbox_menu_add_shortcut() {
  local profile_name="$1" shortcut="$2" target

  read -r "target?路径: "
  [[ -n "$target" ]] || return 0
  case "$shortcut" in
    r)
      _sbox_add_rule_unique "file-read*" "$target" || return
      ;;
    w)
      _sbox_add_rule_unique "file-write*" "$target" || return
      ;;
    rw)
      _sbox_add_rule_unique "file-read*" "$target" || return
      _sbox_add_rule_unique "file-write*" "$target" || return
      ;;
  esac
  _sbox_save_profile "$profile_name"
}

_sbox_menu_remove_path() {
  local profile_name="$1"
  local i idx=1 choice item_index

  for (( i = 1; i <= ${#_SBOX_RULE_OPS}; i++ )); do
    if [[ "${_SBOX_RULE_SCOPES[$i]}" == global ]]; then
      printf '  %2d. %-8s %-22s\n' "$idx" "global" "${_SBOX_RULE_OPS[$i]}"
    else
      printf '  %2d. %-8s %-22s %s\n' "$idx" "path" "${_SBOX_RULE_OPS[$i]}" "${_SBOX_RULE_PATHS[$i]}"
    fi
    (( idx++ ))
  done

  (( ${#_SBOX_RULE_OPS} )) || {
    print "没有可删除的路径。"
    return 0
  }

  read -r "choice?删除编号: "
  [[ "$choice" == <-> && "$choice" -ge 1 && "$choice" -le "${#_SBOX_RULE_OPS}" ]] || return 0

  item_index="$choice"
  _SBOX_RULE_SCOPES[$item_index]=()
  _SBOX_RULE_OPS[$item_index]=()
  _SBOX_RULE_PATHS[$item_index]=()

  _sbox_save_profile "$profile_name"
}

_sbox_menu_run_command() {
  local profile_name="$1" line
  local -a cmd
  local exit_code

  read -r "line?命令: "
  [[ -n "$line" ]] || return 0
  cmd=("${(z)line}")
  _sbox_run "$profile_name" "" "" -- "${cmd[@]}"
  exit_code=$?
  _sbox_remember_workspace_profile "$profile_name"
  return "$exit_code"
}

_sbox_menu_switch_profile() {
  local name

  read -r "name?profile 名: "
  [[ -n "$name" ]] || return 1
  _sbox_profile_name_ok "$name" || {
    print -u2 "sbox: profile 名只能包含字母、数字、点、下划线和连字符"
    return 1
  }
  REPLY="$name"
}

_sbox_menu() {
  emulate -L zsh

  local profile_name="${1:-default}" choice next_profile lock_dir next_lock_dir
  lock_dir=$(_sbox_acquire_profile_lock "$profile_name") || return

  {
    while true; do
      _sbox_load_profile "$profile_name" || return

      print ""
      print "sbox 菜单 [$profile_name]"
      print "----------------------------------------"
      _sbox_print_rules
      print ""
      print "1) 添加原始 sandbox operation 规则"
      print "2) 快捷添加 file-read* 路径"
      print "3) 快捷添加 file-write* 路径"
      print "4) 快捷添加 file-read* + file-write* 路径"
      print "5) 删除路径规则"
      print "6) 切换当前目录自动读写"
      print "7) 切换网络访问"
      print "8) 预览生成的 .sb"
      print "9) 用当前 profile 运行命令"
      print "10) 切换/创建 profile"
      print "0) 退出"
      read -r "choice?选择: "

      case "$choice" in
        1)
          _sbox_menu_add_rule "$profile_name"
          ;;
        2)
          _sbox_menu_add_shortcut "$profile_name" r
          ;;
        3)
          _sbox_menu_add_shortcut "$profile_name" w
          ;;
        4)
          _sbox_menu_add_shortcut "$profile_name" rw
          ;;
        5)
          _sbox_menu_remove_path "$profile_name"
          ;;
        6)
          [[ "$_SBOX_ALLOW_PWD" == 1 ]] && _SBOX_ALLOW_PWD=0 || _SBOX_ALLOW_PWD=1
          _sbox_save_profile "$profile_name"
          ;;
        7)
          [[ "$_SBOX_NETWORK" == deny ]] && _SBOX_NETWORK=allow || _SBOX_NETWORK=deny
          _sbox_save_profile "$profile_name"
          ;;
        8)
          _sbox_emit_profile "$profile_name" "" ""
          ;;
        9)
          _sbox_menu_run_command "$profile_name"
          ;;
        10)
          _sbox_menu_switch_profile || continue
          next_profile="$REPLY"
          [[ -z "$next_profile" || "$next_profile" == "$profile_name" ]] && continue
          next_lock_dir=$(_sbox_acquire_profile_lock "$next_profile") || continue
          _sbox_release_profile_lock "$lock_dir"
          lock_dir="$next_lock_dir"
          profile_name="$next_profile"
          ;;
        0|q|quit|exit)
          return 0
          ;;
      esac
    done
  } always {
    _sbox_release_profile_lock "$lock_dir"
  }
}

_sbox_list_profiles() {
  local dir file

  dir=$(_sbox_profile_dir)
  [[ -d "$dir" ]] || {
    print "default"
    return
  }

  for file in "$dir"/*.conf(N); do
    print -r -- "${${file:t}%.conf}"
  done
}

_sbox_help() {
  cat <<'EOF'
用法:
  sbox -- 命令 ...                         使用当前目录记住的 profile，否则 default
  sbox @profile -- 命令 ...                使用指定 profile 运行命令
  sbox [+r 路径] [+w 路径] [+rw 路径] -- 命令 ...
  sbox +op file-read-data 路径 -- 命令 ... 临时追加原始 file 路径规则
  sbox +op network-outbound -- 命令 ...    临时追加原始全局 operation 规则
  sbox +op network-outbound mach-lookup file-read-data 路径 -- 命令 ...
  sbox -net -- 命令 ...                    本次运行禁止网络
  sbox +net -- 命令 ...                    本次运行允许网络
  sbox --no-pwd -- 命令 ...                本次运行不自动放行当前目录
  sbox menu [profile]                      打开交互式菜单
  sbox show [profile]                      预览生成的 .sb
  sbox list                                列出 profile
  sbox workspace                           显示当前目录记住的 profile

默认策略:
  allow default
  deny file-read* file-write* $HOME
  allow 当前目录 file-read* 和 file-write*
EOF
}

sbox() {
  emulate -L zsh

  local profile_name network_override="" allow_pwd_override="" profile_explicit=0 exit_code
  local -a rule_args cmd
  local mode op target saw_op

  case "$1" in
    help|-h|--help)
      _sbox_help
      return
      ;;
    menu|config)
      shift
      _sbox_menu "${1:-$(_sbox_effective_default_profile)}"
      return
      ;;
    list|profiles)
      _sbox_list_profiles
      return
      ;;
    workspace)
      print "当前目录: $(_sbox_workspace_key)"
      print "默认 profile: $(_sbox_effective_default_profile)"
      print "映射文件: $(_sbox_workspace_path)"
      return
      ;;
    show)
      shift
      _sbox_emit_profile "${1:-$(_sbox_effective_default_profile)}" "" ""
      return
      ;;
  esac

  if [[ "$1" == @* ]]; then
    profile_name="${1#@}"
    profile_explicit=1
    shift
  else
    profile_name=$(_sbox_effective_default_profile)
  fi

  while (( $# )); do
    case "$1" in
      --)
        shift
        cmd=("$@")
        break
        ;;
      +r|+w|+rw)
        mode="${1#+}"
        (( $# >= 2 )) || {
          print -u2 "sbox: $1 需要路径"
          return 2
        }
        target=$(_sbox_normalize_path "$2") || return
        case "$mode" in
          r)
            rule_args+=("path" "file-read*" "$target")
            ;;
          w)
            rule_args+=("path" "file-write*" "$target")
            ;;
          rw)
            rule_args+=("path" "file-read*" "$target" "path" "file-write*" "$target")
            ;;
        esac
        shift 2
        ;;
      +op)
        shift
        saw_op=0

        while (( $# )); do
          [[ "$1" == -- ]] && break
          if (( saw_op )) && _sbox_is_cli_option "$1"; then
            break
          fi

          op="$1"
          if ! _sbox_rule_op_ok "$op"; then
            (( saw_op )) && break
            print -u2 "sbox: 不支持的 sandbox operation: $op"
            return 2
          fi

          if _sbox_op_uses_path "$op"; then
            if (( $# < 2 )) || [[ "$2" == -- ]] || _sbox_rule_op_ok "$2"; then
              print -u2 "sbox: $op 需要紧跟一个路径"
              return 2
            fi
            target=$(_sbox_normalize_path "$2") || return
            rule_args+=("path" "$op" "$target")
            shift 2
          else
            rule_args+=("global" "$op" "")
            shift
          fi

          saw_op=1
        done

        (( saw_op )) || {
          print -u2 "sbox: +op 需要 operation"
          return 2
        }
        ;;
      -net)
        network_override=deny
        shift
        ;;
      +net)
        network_override=allow
        shift
        ;;
      --no-pwd)
        allow_pwd_override=0
        shift
        ;;
      +pwd)
        allow_pwd_override=1
        shift
        ;;
      *)
        cmd=("$@")
        break
        ;;
    esac
  done

  _sbox_run "$profile_name" "$network_override" "$allow_pwd_override" "${rule_args[@]}" -- "${cmd[@]}"
  exit_code=$?

  if (( profile_explicit && ${#cmd} )); then
    _sbox_remember_workspace_profile "$profile_name"
  fi

  return "$exit_code"
}
