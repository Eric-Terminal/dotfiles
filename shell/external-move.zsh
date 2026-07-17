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

  printf 'xmv：开始复制，下面会实时显示每个文件的进度。\n'
  if ! _external-move-run "$use_sudo" /usr/bin/rsync -aEHh --partial --progress \
    "$source_path" "$partial_root/"; then
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
创建符号链接。复制时会实时显示进度，成功前不会删除 Mac 原件。例如：
  xmv ~/Documents/archive
  # /Users/Eric/Documents/archive
  # → /Volumes/nvme0n1/Users/Eric/Documents/archive

系统路径也遵循同一规则；需要写入权限时，xmv 会自动请求 sudo：
  xmv /Applications/Example.app
  # /Applications/Example.app
  # → /Volumes/nvme0n1/Applications/Example.app

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
  local link_value link_path
  local use_sudo
  for raw_path in "$@"; do
    source_path="${raw_path:a}"
    target_path="${drive_root}${source_path}"

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
      ( -d "$source_path" && ! -w "$source_path" ) ]]; then
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
        printf 'xmv：硬盘中的目标已存在，为避免覆盖已跳过：%s\n' "$target_path" >&2
        result=1
        continue
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

      if ! _external-move-copy "$source_path" "$target_path" "$use_sudo"; then
        result=1
        continue
      fi

      if ! _external-move-run "$use_sudo" /bin/rm -rf "$source_path"; then
        printf 'xmv：复制已完成，但无法删除 Mac 原件。两处数据均被保留：\n' >&2
        printf '  Mac：%s\n' "$source_path" >&2
        printf '  硬盘：%s\n' "$target_path" >&2
        result=1
        continue
      fi

      if _external-move-run "$use_sudo" /bin/ln -s "$target_path" "$source_path"; then
        printf 'xmv：迁移完成：%s -> %s\n' "$source_path" "$target_path"
      else
        printf 'xmv：创建链接失败，正在把数据移回原处。\n' >&2
        if _external-move-copy "$target_path" "$source_path" "$use_sudo" && \
          _external-move-run "$use_sudo" /bin/rm -rf "$target_path"; then
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
