# 将主目录中的文件迁移到外置 NVMe，并在原位置保留符号链接。
external-move() {
  emulate -L zsh
  setopt local_options no_sh_word_split

  local drive_root="/Volumes/nvme0n1"
  local home_root="${HOME:a}"
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
创建符号链接。例如：
  xmv ~/Documents/archive
  # /Users/Eric/Documents/archive
  # → /Volumes/nvme0n1/Users/Eric/Documents/archive

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

  local raw_path source_path target_path target_parent
  local link_value link_path
  for raw_path in "$@"; do
    source_path="${raw_path:a}"

    # 只允许迁移主目录内部的具体项目，避免误操作整个主目录或系统路径。
    if [[ "$source_path" != "$home_root"/* ]]; then
      printf 'xmv：路径必须位于主目录 %s 内：%s\n' "$home_root" "$source_path" >&2
      result=1
      continue
    fi

    target_path="${drive_root}${source_path}"
    target_parent="${target_path:h}"

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
            command mkdir -p "${source_path:h}" || {
              printf 'xmv：无法创建原路径的父目录：%s\n' "${source_path:h}" >&2
              result=1
              continue
            }
            if command ln -s "$target_path" "$source_path"; then
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
        continue
      fi

      command mkdir -p "$target_parent" || {
        printf 'xmv：无法创建硬盘目录：%s\n' "$target_parent" >&2
        result=1
        continue
      }

      if ! command mv "$source_path" "$target_path"; then
        printf 'xmv：移动失败，原路径未改为链接：%s\n' "$source_path" >&2
        result=1
        continue
      fi

      if command ln -s "$target_path" "$source_path"; then
        printf 'xmv：迁移完成：%s -> %s\n' "$source_path" "$target_path"
      else
        printf 'xmv：创建链接失败，正在把数据移回原处。\n' >&2
        if command mv "$target_path" "$source_path"; then
          printf 'xmv：已回滚，数据仍在原路径：%s\n' "$source_path" >&2
        else
          printf 'xmv：回滚失败！数据当前位于：%s\n' "$target_path" >&2
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
        continue
      fi

      if ! command rm "$source_path"; then
        printf 'xmv：无法移除原符号链接：%s\n' "$source_path" >&2
        result=1
        continue
      fi

      if command mv "$target_path" "$source_path"; then
        printf 'xmv：已恢复到 Mac：%s\n' "$source_path"
      else
        printf 'xmv：恢复失败，正在重新创建符号链接。\n' >&2
        if ! command ln -s "$target_path" "$source_path"; then
          printf 'xmv：链接重建失败！数据当前位于：%s\n' "$target_path" >&2
        fi
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
      continue
    fi

    command mkdir -p "${source_path:h}" || {
      printf 'xmv：无法创建原路径的父目录：%s\n' "${source_path:h}" >&2
      result=1
      continue
    }
    if command mv "$target_path" "$source_path"; then
      printf 'xmv：已恢复到 Mac：%s\n' "$source_path"
    else
      printf 'xmv：恢复失败，数据仍在硬盘中：%s\n' "$target_path" >&2
      result=1
    fi
  done

  return "$result"
}

alias xmv='external-move'
