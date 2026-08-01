# 根据目标位置权限执行普通命令或请求管理员权限。
_external-move-run() {
  emulate -L zsh

  local use_sudo="$1"
  shift
  if (( use_sudo )); then
    command sudo "$@"
  else
    command "$@"
  fi
}

# 解析符号链接指向的位置，但不继续解析目标路径中的其他链接。
_external-move-link-path() {
  emulate -L zsh

  local link_path="$1"
  local link_value
  link_value="$(command readlink "$link_path")" || return 1
  if [[ "$link_value" == /* ]]; then
    REPLY="${link_value:a}"
  else
    REPLY="${link_path:h}/${link_value}"
    REPLY="${REPLY:a}"
  fi
}

# 复制数据时统一选择新版 Homebrew rsync 或系统 rsync。
_external-move-rsync() {
  emulate -L zsh
  setopt local_options no_sh_word_split

  local source_path="$1"
  local destination_dir="$2"
  local use_sudo="$3"
  local rsync_bin="/usr/bin/rsync"
  local -a rsync_options

  if [[ -x /opt/homebrew/bin/rsync ]]; then
    rsync_bin="/opt/homebrew/bin/rsync"
    rsync_options=(-aHAXNh --partial --no-inc-recursive --info=progress2,name0)
  elif [[ -x /usr/local/bin/rsync ]]; then
    rsync_bin="/usr/local/bin/rsync"
    rsync_options=(-aHAXNh --partial --no-inc-recursive --info=progress2,name0)
  else
    rsync_options=(-aEHh --partial --progress)
  fi

  if [[ "$rsync_bin" == "/usr/bin/rsync" ]]; then
    printf 'xmv：系统 rsync 不支持目录总进度，将显示逐文件进度。\n'
  else
    printf 'xmv：正在统计目录内容，随后会在同一行刷新总体进度。\n'
  fi
  _external-move-run "$use_sudo" "$rsync_bin" "${rsync_options[@]}" \
    "$source_path" "$destination_dir"
}

# 使用可续传的临时目录复制数据，成功后再原子放入最终位置。
_external-move-copy() {
  emulate -L zsh
  setopt local_options no_sh_word_split

  local source_path="$1"
  local target_path="$2"
  local use_sudo="${3:-0}"
  local target_parent="${target_path:h}"
  local target_name="${target_path:t}"
  local partial_root="${target_parent}/.${target_name}.xmv-partial"
  local partial_item="${partial_root}/${source_path:t}"
  local marker_path="${partial_root}/.xmv-source"
  local recorded_source

  _external-move-run "$use_sudo" /bin/mkdir -p "$target_parent" || {
    printf 'xmv：无法创建目标目录：%s\n' "$target_parent" >&2
    return 1
  }

  if [[ -e "$partial_root" || -L "$partial_root" ]]; then
    if [[ ! -d "$partial_root" || -L "$partial_root" || ! -f "$marker_path" ]]; then
      printf 'xmv：发现无法识别的临时路径，请先人工确认：%s\n' "$partial_root" >&2
      return 1
    fi
    recorded_source="$(<"$marker_path")"
    if [[ "$recorded_source" != "$source_path" ]]; then
      printf 'xmv：临时目录属于其他源路径，请先人工确认：%s\n' "$partial_root" >&2
      return 1
    fi
    printf 'xmv：发现上次未完成的复制，正在继续：%s\n' "$source_path"
  else
    _external-move-run "$use_sudo" /bin/mkdir "$partial_root" || {
      printf 'xmv：无法创建临时目录：%s\n' "$partial_root" >&2
      return 1
    }
    if (( use_sudo )); then
      printf '%s\n' "$source_path" | command sudo /usr/bin/tee "$marker_path" >/dev/null
    else
      printf '%s\n' "$source_path" >| "$marker_path"
    fi
    if (( $? != 0 )); then
      printf 'xmv：无法记录临时目录来源：%s\n' "$marker_path" >&2
      _external-move-run "$use_sudo" /bin/rmdir "$partial_root" 2>/dev/null
      return 1
    fi
  fi

  if ! _external-move-rsync "$source_path" "$partial_root/" "$use_sudo"; then
    printf 'xmv：复制未完成，Mac 原件保持不变；下次执行可继续复制。\n' >&2
    printf 'xmv：未完成的数据位于：%s\n' "$partial_root" >&2
    return 1
  fi

  if [[ ! -e "$partial_item" && ! -L "$partial_item" ]]; then
    printf 'xmv：复制完成后未找到预期数据：%s\n' "$partial_item" >&2
    return 1
  fi
  if [[ -e "$target_path" || -L "$target_path" ]]; then
    printf 'xmv：复制期间最终目标被占用，未覆盖它：%s\n' "$target_path" >&2
    return 1
  fi
  if ! _external-move-run "$use_sudo" /bin/mv "$partial_item" "$target_path"; then
    printf 'xmv：无法把复制结果放入最终位置：%s\n' "$target_path" >&2
    return 1
  fi

  _external-move-run "$use_sudo" /bin/rm "$marker_path" 2>/dev/null
  _external-move-run "$use_sudo" /bin/rmdir "$partial_root" 2>/dev/null || \
    printf 'xmv：数据已复制，但临时目录未能清理：%s\n' "$partial_root" >&2
  return 0
}

# 合并前确认两侧没有真实数据重名，只接受 xmv 生成的镜像链接。
_external-move-check-merge() {
  emulate -L zsh
  setopt local_options no_sh_word_split

  local source_dir="$1"
  local target_dir="$2"
  local source_child target_child link_path

  for source_child in "$source_dir"/*(DN); do
    target_child="${target_dir}/${source_child:t}"
    if [[ -L "$source_child" ]]; then
      _external-move-link-path "$source_child" || {
        printf 'xmv：无法读取符号链接：%s\n' "$source_child" >&2
        return 1
      }
      link_path="$REPLY"
      if [[ "$link_path" == "$target_child" ]]; then
        if [[ -e "$target_child" && ! -L "$target_child" ]]; then
          continue
        fi
        printf 'xmv：发现失效的迁移链接，无法合并：%s -> %s\n' \
          "$source_child" "$link_path" >&2
        return 1
      fi
      if [[ -e "$target_child" || -L "$target_child" ]]; then
        printf 'xmv：两侧存在同名项目，无法安全合并：%s\n' "$source_child" >&2
        return 1
      fi
      continue
    fi

    if [[ -d "$source_child" && -d "$target_child" && ! -L "$target_child" ]]; then
      _external-move-check-merge "$source_child" "$target_child" || return 1
    elif [[ -e "$target_child" || -L "$target_child" ]]; then
      printf 'xmv：两侧存在同名项目，无法安全合并：%s\n' "$source_child" >&2
      return 1
    fi
  done
}

# 把暂存目录逐项并入已有目标；每个重命名都发生在同一外置卷内。
_external-move-commit-merge() {
  emulate -L zsh
  setopt local_options no_sh_word_split

  local staged_dir="$1"
  local target_dir="$2"
  local use_sudo="$3"
  local staged_child target_child link_path

  [[ -e "$staged_dir" || -L "$staged_dir" ]] || return 0
  for staged_child in "$staged_dir"/*(DN); do
    target_child="${target_dir}/${staged_child:t}"
    if [[ -L "$staged_child" ]]; then
      _external-move-link-path "$staged_child" || return 1
      link_path="$REPLY"
      if [[ "$link_path" == "$target_child" && \
        -e "$target_child" && ! -L "$target_child" ]]; then
        _external-move-run "$use_sudo" /bin/rm "$staged_child" || return 1
      elif [[ ! -e "$target_child" && ! -L "$target_child" ]]; then
        _external-move-run "$use_sudo" /bin/mv "$staged_child" "$target_child" || return 1
      else
        printf 'xmv：合并期间目标出现同名项目，已停止：%s\n' "$target_child" >&2
        return 1
      fi
    elif [[ -d "$staged_child" && -d "$target_child" && ! -L "$target_child" ]]; then
      _external-move-commit-merge "$staged_child" "$target_child" "$use_sudo" || return 1
    elif [[ ! -e "$target_child" && ! -L "$target_child" ]]; then
      _external-move-run "$use_sudo" /bin/mv "$staged_child" "$target_child" || return 1
    else
      printf 'xmv：合并期间目标出现同名项目，已停止：%s\n' "$target_child" >&2
      return 1
    fi
  done

  _external-move-run "$use_sudo" /bin/rmdir "$staged_dir"
}

# 先完整暂存本地目录，再把新增项目安全并入已存在的外置目录。
_external-move-merge() {
  emulate -L zsh
  setopt local_options no_sh_word_split

  local source_path="$1"
  local target_path="$2"
  local use_sudo="$3"
  local merge_root="${target_path:h}/.${target_path:t}.xmv-merge"
  local staged_path="${merge_root}/${source_path:t}"
  local marker_path="${merge_root}/.xmv-source"
  local phase_path="${merge_root}/.xmv-phase"
  local recorded_source phase
  local resumed=0

  if [[ -e "$merge_root" || -L "$merge_root" ]]; then
    resumed=1
    if [[ ! -d "$merge_root" || -L "$merge_root" || \
      ! -f "$marker_path" || ! -f "$phase_path" ]]; then
      printf 'xmv：发现无法识别的合并暂存路径，请先人工确认：%s\n' "$merge_root" >&2
      return 1
    fi
    recorded_source="$(<"$marker_path")"
    if [[ "$recorded_source" != "$source_path" ]]; then
      printf 'xmv：合并暂存目录属于其他源路径，请先人工确认：%s\n' "$merge_root" >&2
      return 1
    fi
    phase="$(<"$phase_path")"
    printf 'xmv：发现上次未完成的目录合并，正在继续：%s\n' "$source_path"
  else
    _external-move-check-merge "$source_path" "$target_path" || return 1
    _external-move-run "$use_sudo" /bin/mkdir "$merge_root" || {
      printf 'xmv：无法创建合并暂存目录：%s\n' "$merge_root" >&2
      return 1
    }
    if (( use_sudo )); then
      printf '%s\n' "$source_path" | command sudo /usr/bin/tee "$marker_path" >/dev/null
      printf '%s\n' 'copy' | command sudo /usr/bin/tee "$phase_path" >/dev/null
    else
      printf '%s\n' "$source_path" >| "$marker_path"
      printf '%s\n' 'copy' >| "$phase_path"
    fi
    if (( $? != 0 )); then
      printf 'xmv：无法初始化合并暂存状态：%s\n' "$merge_root" >&2
      return 1
    fi
    phase="copy"
  fi

  if (( resumed )) && [[ "$phase" == "done" ]]; then
    printf 'xmv：上次合并已写入目标，但本地原件仍在；为避免遗漏后续写入，未自动删除：%s\n' \
      "$source_path" >&2
    return 1
  fi

  if [[ "$phase" == "copy" ]]; then
    _external-move-check-merge "$source_path" "$target_path" || return 1
    if ! _external-move-rsync "$source_path" "$merge_root/" "$use_sudo"; then
      printf 'xmv：目录合并尚未复制完成；下次执行可继续。\n' >&2
      printf 'xmv：未完成的数据位于：%s\n' "$merge_root" >&2
      return 1
    fi
    if (( use_sudo )); then
      printf '%s\n' 'commit' | command sudo /usr/bin/tee "$phase_path" >/dev/null
    else
      printf '%s\n' 'commit' >| "$phase_path"
    fi
    (( $? == 0 )) || return 1
    phase="commit"
  fi

  if [[ "$phase" == "commit" ]]; then
    _external-move-commit-merge "$staged_path" "$target_path" "$use_sudo" || return 1
    if (( use_sudo )); then
      printf '%s\n' 'done' | command sudo /usr/bin/tee "$phase_path" >/dev/null
    else
      printf '%s\n' 'done' >| "$phase_path"
    fi
    (( $? == 0 )) || return 1
    phase="done"
  fi

  if [[ "$phase" != "done" ]]; then
    printf 'xmv：无法识别合并阶段，请先人工确认：%s\n' "$phase_path" >&2
    return 1
  fi
  return 0
}

# 最终链接创建成功后再清除合并状态，便于中断后继续收尾。
_external-move-clean-merge() {
  emulate -L zsh

  local target_path="$1"
  local use_sudo="$2"
  local merge_root="${target_path:h}/.${target_path:t}.xmv-merge"

  [[ -d "$merge_root" && ! -L "$merge_root" ]] || return 0
  _external-move-run "$use_sudo" /bin/rm \
    "$merge_root/.xmv-source" "$merge_root/.xmv-phase" 2>/dev/null || return 1
  _external-move-run "$use_sudo" /bin/rmdir "$merge_root"
}

# 将整目录链接展开为真实目录，并为外置盘中的直接子项创建独立链接。
_external-move-split-link() {
  emulate -L zsh
  setopt local_options no_sh_word_split

  local source_path="$1"
  local target_path="$2"
  local use_sudo="$3"
  local temp_path="${source_path:h}/.${source_path:t}.xmv-expand"
  local backup_path="${source_path:h}/.${source_path:t}.xmv-link-backup"
  local target_child temp_child link_path

  _external-move-link-path "$source_path" || return 1
  link_path="$REPLY"
  if [[ "$link_path" != "$target_path" || ! -d "$target_path" || -L "$target_path" ]]; then
    printf 'xmv：无法展开非镜像目录链接：%s -> %s\n' "$source_path" "$link_path" >&2
    return 1
  fi
  if [[ -e "$temp_path" || -L "$temp_path" || -e "$backup_path" || -L "$backup_path" ]]; then
    printf 'xmv：展开链接所需的临时路径已存在，请先人工确认：%s\n' "$source_path" >&2
    return 1
  fi

  _external-move-run "$use_sudo" /bin/mkdir "$temp_path" || return 1
  for target_child in "$target_path"/*(DN); do
    temp_child="${temp_path}/${target_child:t}"
    if ! _external-move-run "$use_sudo" /bin/ln -s "$target_child" "$temp_child"; then
      for temp_child in "$temp_path"/*(DN); do
        _external-move-run "$use_sudo" /bin/rm "$temp_child" 2>/dev/null
      done
      _external-move-run "$use_sudo" /bin/rmdir "$temp_path" 2>/dev/null
      return 1
    fi
  done

  if ! _external-move-run "$use_sudo" /bin/mv "$source_path" "$backup_path"; then
    return 1
  fi
  if ! _external-move-run "$use_sudo" /bin/mv "$temp_path" "$source_path"; then
    _external-move-run "$use_sudo" /bin/mv "$backup_path" "$source_path" 2>/dev/null
    return 1
  fi
  if ! _external-move-run "$use_sudo" /bin/rm "$backup_path"; then
    printf 'xmv：目录链接已展开，但备份链接未能清理：%s\n' "$backup_path" >&2
    return 1
  fi
  printf 'xmv：已展开上级目录链接：%s\n' "$source_path"
}

# 查找路径中距离目标最近的符号链接祖先。
_external-move-find-link-ancestor() {
  emulate -L zsh

  local candidate="${1:h}"
  while [[ "$candidate" != "/" ]]; do
    if [[ -L "$candidate" ]]; then
      REPLY="$candidate"
      return 0
    fi
    candidate="${candidate:h}"
  done
  return 1
}

# 将任意文件迁移到外置 NVMe，并在原位置保留符号链接。
external-move() {
  emulate -L zsh
  setopt local_options no_sh_word_split

  local drive_root="/Volumes/nvme0n1"
  local mode="move"
  local dry_run=0
  local result=0

  while (( $# > 0 )); do
    case "$1" in
      -n|--dry-run)
        dry_run=1
        shift
        ;;
      -r|--restore)
        mode="restore"
        shift
        ;;
      -h|--help)
        cat <<'EOF'
用法：
  xmv [--dry-run] <路径> [更多路径...]
  xmv --restore [--dry-run] <路径> [更多路径...]

默认把路径移动到 /Volumes/nvme0n1 下的同名绝对路径，并在原位置
创建符号链接。复制时会在同一行显示总体进度，成功前不会删除 Mac 原件。例如：
  xmv ~/Documents/archive
  # /Users/Eric/Documents/archive
  # → /Volumes/nvme0n1/Users/Eric/Documents/archive

系统路径也遵循同一规则；需要写入权限时，xmv 会自动请求 sudo：
  xmv /Applications/Example.app
  # /Applications/Example.app
  # → /Volumes/nvme0n1/Applications/Example.app

已迁移部分子目录后可以继续迁移父目录，xmv 会安全合并；也可以从
已迁移的父目录中只恢复某个后代路径，其余项目会继续保留为链接。

选项：
  -n, --dry-run   只显示将执行的操作
  -r, --restore   移回 Mac，并移除原位置的符号链接
  -h, --help      显示帮助

若路径以连字符开头，请先写 --，例如：xmv -- ./-example
EOF
        return 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        printf 'xmv：未知选项：%s\n' "$1" >&2
        printf '运行 xmv --help 查看用法。\n' >&2
        return 2
        ;;
      *)
        break
        ;;
    esac
  done

  if (( $# == 0 )); then
    printf 'xmv：请至少提供一个要迁移或恢复的路径。\n' >&2
    printf '运行 xmv --help 查看用法。\n' >&2
    return 2
  fi

  local mount_output
  mount_output="$(command mount)"
  if [[ "$mount_output" != *" on ${drive_root} ("* ]]; then
    printf 'xmv：外置硬盘未挂载在 %s，未执行任何操作。\n' "$drive_root" >&2
    return 1
  fi

  if [[ ! -w "$drive_root" ]]; then
    printf 'xmv：外置硬盘不可写：%s\n' "$drive_root" >&2
    return 1
  fi

  local raw_path source_path target_path write_parent target_write_parent
  local link_value link_path link_ancestor expected_link
  local merge_state_path use_sudo merge_used split_failed
  for raw_path in "$@"; do
    source_path="${raw_path:a}"
    target_path="${drive_root}${source_path}"
    merge_used=0

    # 目标位于源目录内部时，复制会递归包含自身，因而无法成立。
    if [[ "$source_path" == "/" || "$target_path" == "$source_path"/* ]]; then
      printf 'xmv：目标路径位于源目录内部，无法递归迁移：%s\n' "$source_path" >&2
      result=1
      continue
    fi

    write_parent="${source_path:h}"
    while [[ ! -e "$write_parent" && "$write_parent" != "/" ]]; do
      write_parent="${write_parent:h}"
    done
    target_write_parent="${target_path:h}"
    while [[ ! -e "$target_write_parent" && "$target_write_parent" != "/" ]]; do
      target_write_parent="${target_write_parent:h}"
    done
    use_sudo=0
    if [[ ! -w "$write_parent" || ! -w "$target_write_parent" || \
      ( -e "$source_path" && ! -r "$source_path" ) || \
      ( -d "$source_path" && ! -w "$source_path" ) || \
      ( -d "$target_path" && ! -w "$target_path" ) ]]; then
      use_sudo=1
    fi

    if [[ "$mode" == "move" ]]; then
      if [[ -L "$source_path" ]]; then
        link_value="$(command readlink "$source_path")"
        if [[ "$link_value" == /* ]]; then
          link_path="${link_value:a}"
        else
          link_path="${source_path:h}/${link_value}"
          link_path="${link_path:a}"
        fi

        if [[ "$link_path" == "$target_path" ]]; then
          printf 'xmv：已经迁移，无需重复操作：%s\n' "$source_path"
        else
          printf 'xmv：原路径是指向其他位置的符号链接，已跳过：%s -> %s\n' \
            "$source_path" "$link_value" >&2
          result=1
        fi
        continue
      fi

      if [[ ! -e "$source_path" ]]; then
        if [[ -e "$target_path" && ! -L "$target_path" ]]; then
          if (( dry_run )); then
            printf '[预览] 创建链接：%s -> %s\n' "$source_path" "$target_path"
          else
            if (( use_sudo )) && ! command sudo -v; then
              printf 'xmv：未获得管理员权限：%s\n' "$source_path" >&2
              result=1
              continue
            fi
            _external-move-run "$use_sudo" /bin/mkdir -p "${source_path:h}" || {
              printf 'xmv：无法创建原路径的父目录：%s\n' "${source_path:h}" >&2
              result=1
              continue
            }
            if _external-move-run "$use_sudo" /bin/ln -s "$target_path" "$source_path"; then
              printf 'xmv：检测到硬盘中已有数据，已补建链接：%s -> %s\n' \
                "$source_path" "$target_path"
            else
              printf 'xmv：创建链接失败：%s\n' "$source_path" >&2
              result=1
            fi
          fi
        else
          printf 'xmv：找不到源路径：%s\n' "$source_path" >&2
          result=1
        fi
        continue
      fi

      if [[ -e "$target_path" || -L "$target_path" ]]; then
        if [[ -d "$source_path" && ! -L "$source_path" && \
          -d "$target_path" && ! -L "$target_path" ]]; then
          merge_state_path="${target_path:h}/.${target_path:t}.xmv-merge"
          if [[ ! -e "$merge_state_path" && ! -L "$merge_state_path" ]] && \
            ! _external-move-check-merge "$source_path" "$target_path"; then
            result=1
            continue
          fi
          if (( dry_run )); then
            printf '[预览] 合并目录：%s -> %s\n' "$source_path" "$target_path"
            printf '[预览] 创建链接：%s -> %s\n' "$source_path" "$target_path"
            (( use_sudo )) && printf '[预览] 需要管理员权限：是\n'
            continue
          fi
          merge_used=1
        else
          printf 'xmv：硬盘中的目标已存在，为避免覆盖已跳过：%s\n' "$target_path" >&2
          result=1
          continue
        fi
      fi

      if (( dry_run )); then
        printf '[预览] 移动：%s -> %s\n' "$source_path" "$target_path"
        printf '[预览] 创建链接：%s -> %s\n' "$source_path" "$target_path"
        (( use_sudo )) && printf '[预览] 需要管理员权限：是\n'
        continue
      fi

      if (( use_sudo )) && ! command sudo -v; then
        printf 'xmv：未获得管理员权限：%s\n' "$source_path" >&2
        result=1
        continue
      fi

      if (( merge_used )); then
        if ! _external-move-merge "$source_path" "$target_path" "$use_sudo"; then
          result=1
          continue
        fi
      else
        if ! _external-move-copy "$source_path" "$target_path" "$use_sudo"; then
          result=1
          continue
        fi
      fi

      if ! _external-move-run "$use_sudo" /bin/rm -rf "$source_path"; then
        printf 'xmv：复制已完成，但无法删除 Mac 原件。两处数据均被保留：\n' >&2
        printf '  Mac：%s\n' "$source_path" >&2
        printf '  硬盘：%s\n' "$target_path" >&2
        result=1
        continue
      fi

      if _external-move-run "$use_sudo" /bin/ln -s "$target_path" "$source_path"; then
        if (( merge_used )) && \
          ! _external-move-clean-merge "$target_path" "$use_sudo"; then
          printf 'xmv：迁移已完成，但合并状态未能清理。\n' >&2
          result=1
        fi
        printf 'xmv：迁移完成：%s -> %s\n' "$source_path" "$target_path"
      else
        printf 'xmv：创建链接失败，正在把数据移回原处。\n' >&2
        if _external-move-copy "$target_path" "$source_path" "$use_sudo" && \
          _external-move-run "$use_sudo" /bin/rm -rf "$target_path"; then
          (( merge_used )) && \
            _external-move-clean-merge "$target_path" "$use_sudo" >/dev/null 2>&1
          printf 'xmv：已回滚，数据仍在原路径：%s\n' "$source_path" >&2
        else
          printf 'xmv：自动回滚未完整完成，请检查这两个位置：\n' >&2
          printf '  Mac：%s\n' "$source_path" >&2
          printf '  硬盘：%s\n' "$target_path" >&2
        fi
        result=1
      fi
      continue
    fi

    # 请求恢复软链接祖先下的后代时，逐层把目录链接拆成子项链接。
    if [[ ! -L "$source_path" ]] && \
      _external-move-find-link-ancestor "$source_path"; then
      link_ancestor="$REPLY"
      expected_link="${drive_root}${link_ancestor}"
      _external-move-link-path "$link_ancestor" || {
        printf 'xmv：无法读取上级符号链接：%s\n' "$link_ancestor" >&2
        result=1
        continue
      }
      if [[ "$REPLY" != "$expected_link" ]]; then
        printf 'xmv：上级符号链接并非由 xmv 生成，已跳过：%s -> %s\n' \
          "$link_ancestor" "$REPLY" >&2
        result=1
        continue
      fi
      if [[ ! -e "$target_path" || -L "$target_path" ]]; then
        printf 'xmv：硬盘中的待恢复数据不存在：%s\n' "$target_path" >&2
        result=1
        continue
      fi
      if [[ ! -w "${link_ancestor:h}" ]]; then
        use_sudo=1
      fi
      if (( dry_run )); then
        printf '[预览] 展开上级目录链接：%s\n' "$link_ancestor"
        printf '[预览] 单独移回：%s -> %s\n' "$target_path" "$source_path"
        (( use_sudo )) && printf '[预览] 需要管理员权限：是\n'
        continue
      fi
      if (( use_sudo )) && ! command sudo -v; then
        printf 'xmv：未获得管理员权限：%s\n' "$source_path" >&2
        result=1
        continue
      fi

      split_failed=0
      while [[ ! -L "$source_path" ]]; do
        if ! _external-move-find-link-ancestor "$source_path"; then
          printf 'xmv：展开目录后未找到待恢复项目的链接：%s\n' "$source_path" >&2
          split_failed=1
          break
        fi
        link_ancestor="$REPLY"
        expected_link="${drive_root}${link_ancestor}"
        _external-move-link-path "$link_ancestor" || {
          split_failed=1
          break
        }
        if [[ "$REPLY" != "$expected_link" ]] || \
          ! _external-move-split-link "$link_ancestor" "$expected_link" "$use_sudo"; then
          split_failed=1
          break
        fi
      done
      if (( split_failed )); then
        printf 'xmv：无法为单独恢复展开目录结构：%s\n' "$source_path" >&2
        result=1
        continue
      fi
    fi

    if [[ -L "$source_path" ]]; then
      link_value="$(command readlink "$source_path")"
      if [[ "$link_value" == /* ]]; then
        link_path="${link_value:a}"
      else
        link_path="${source_path:h}/${link_value}"
        link_path="${link_path:a}"
      fi

      if [[ "$link_path" != "$target_path" ]]; then
        printf 'xmv：符号链接并非由 xmv 的镜像规则生成，已跳过：%s -> %s\n' \
          "$source_path" "$link_value" >&2
        result=1
        continue
      fi

      if [[ ! -e "$target_path" || -L "$target_path" ]]; then
        printf 'xmv：硬盘中的数据不存在，保留原链接：%s\n' "$target_path" >&2
        result=1
        continue
      fi

      if (( dry_run )); then
        printf '[预览] 移除链接：%s\n' "$source_path"
        printf '[预览] 移回：%s -> %s\n' "$target_path" "$source_path"
        (( use_sudo )) && printf '[预览] 需要管理员权限：是\n'
        continue
      fi

      if (( use_sudo )) && ! command sudo -v; then
        printf 'xmv：未获得管理员权限：%s\n' "$source_path" >&2
        result=1
        continue
      fi

      if ! _external-move-run "$use_sudo" /bin/rm "$source_path"; then
        printf 'xmv：无法移除原符号链接：%s\n' "$source_path" >&2
        result=1
        continue
      fi

      if ! _external-move-copy "$target_path" "$source_path" "$use_sudo"; then
        printf 'xmv：恢复失败，正在重新创建符号链接。\n' >&2
        if ! _external-move-run "$use_sudo" /bin/ln -s "$target_path" "$source_path"; then
          printf 'xmv：链接重建失败！数据当前位于：%s\n' "$target_path" >&2
        fi
        result=1
        continue
      fi

      if _external-move-run "$use_sudo" /bin/rm -rf "$target_path"; then
        printf 'xmv：已恢复到 Mac：%s\n' "$source_path"
      else
        printf 'xmv：数据已恢复到 Mac，但无法删除硬盘副本：%s\n' "$target_path" >&2
        result=1
      fi
      continue
    fi

    if [[ -e "$source_path" ]]; then
      if [[ -e "$target_path" || -L "$target_path" ]]; then
        printf 'xmv：Mac 与硬盘中都存在同一路径，无法判断应保留哪份：%s\n' \
          "$source_path" >&2
        result=1
      else
        printf 'xmv：数据已经位于 Mac，无需恢复：%s\n' "$source_path"
      fi
      continue
    fi

    if [[ ! -e "$target_path" || -L "$target_path" ]]; then
      printf 'xmv：Mac 与硬盘中都找不到该路径：%s\n' "$source_path" >&2
      result=1
      continue
    fi

    if (( dry_run )); then
      printf '[预览] 移回：%s -> %s\n' "$target_path" "$source_path"
      (( use_sudo )) && printf '[预览] 需要管理员权限：是\n'
      continue
    fi

    if (( use_sudo )) && ! command sudo -v; then
      printf 'xmv：未获得管理员权限：%s\n' "$source_path" >&2
      result=1
      continue
    fi

    _external-move-run "$use_sudo" /bin/mkdir -p "${source_path:h}" || {
      printf 'xmv：无法创建原路径的父目录：%s\n' "${source_path:h}" >&2
      result=1
      continue
    }
    if ! _external-move-copy "$target_path" "$source_path" "$use_sudo"; then
      printf 'xmv：恢复失败，数据仍在硬盘中：%s\n' "$target_path" >&2
      result=1
      continue
    fi
    if _external-move-run "$use_sudo" /bin/rm -rf "$target_path"; then
      printf 'xmv：已恢复到 Mac：%s\n' "$source_path"
    else
      printf 'xmv：数据已恢复到 Mac，但无法删除硬盘副本：%s\n' "$target_path" >&2
      result=1
    fi
  done

  return "$result"
}

alias xmv='external-move'
