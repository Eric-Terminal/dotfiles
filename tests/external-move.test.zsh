#!/bin/zsh

set -euo pipefail

repo_root="${0:A:h:h}"
source "$repo_root/shell/external-move.zsh"

test_parent="$(mktemp -d "$HOME/.xmv-test.XXXXXX")"
mirror_test_parent="/Volumes/nvme0n1${test_parent}"
test_source="$test_parent/含 空格的目录"
test_target="/Volumes/nvme0n1${test_source}"
outside_parent="$(mktemp -d /private/tmp/.xmv-test.XXXXXX)"
outside_source="$outside_parent/主目录之外"
outside_target="/Volumes/nvme0n1${outside_source}"
protected_parent="$test_parent/只读父目录"
protected_source="$protected_parent/需要权限"
tree_source="$test_parent/分层归档/2026/07"
tree_target="/Volumes/nvme0n1${tree_source}"
test_output=""

cleanup() {
  set +e
  if [[ -L "$test_source" && -e "$test_target" ]]; then
    external-move --restore "$test_source" >/dev/null
  fi
  if [[ -L "$outside_source" && -e "$outside_target" ]]; then
    external-move --restore "$outside_source" >/dev/null
  fi
  chmod 755 "$protected_parent" 2>/dev/null
  [[ -e "$tree_source" || -L "$tree_source" ]] && rm -rf "$tree_source"
  [[ -e "$tree_target" || -L "$tree_target" ]] && rm -rf "$tree_target"
  [[ -d "$test_parent/分层归档/2026" ]] && rmdir "$test_parent/分层归档/2026"
  [[ -d "$test_parent/分层归档" ]] && rmdir "$test_parent/分层归档"
  [[ -d "$mirror_test_parent/分层归档/2026" && \
    ! -L "$mirror_test_parent/分层归档/2026" ]] && \
    rmdir "$mirror_test_parent/分层归档/2026"
  [[ -d "$mirror_test_parent/分层归档" && \
    ! -L "$mirror_test_parent/分层归档" ]] && \
    rmdir "$mirror_test_parent/分层归档"
  [[ -f "$protected_source" ]] && rm "$protected_source"
  [[ -d "$protected_parent" ]] && rmdir "$protected_parent"
  [[ -L "$outside_source" ]] && rm "$outside_source"
  [[ -f "$outside_source/验证文件" ]] && rm "$outside_source/验证文件"
  [[ -d "$outside_source" ]] && rmdir "$outside_source"
  [[ -f "$outside_target/验证文件" ]] && rm "$outside_target/验证文件"
  [[ -d "$outside_target" ]] && rmdir "$outside_target"
  [[ -d "$outside_parent" ]] && rmdir "$outside_parent"
  [[ -L "$test_source" ]] && rm "$test_source"
  [[ -f "$test_source/验证文件" ]] && rm "$test_source/验证文件"
  [[ -d "$test_source" ]] && rmdir "$test_source"
  [[ -f "$test_target/验证文件" ]] && rm "$test_target/验证文件"
  [[ -d "$test_target" ]] && rmdir "$test_target"
  [[ -d "$mirror_test_parent" && ! -L "$mirror_test_parent" ]] && \
    rmdir "$mirror_test_parent"
  [[ -d "$test_parent" ]] && rmdir "$test_parent"
}
trap cleanup EXIT HUP INT TERM

mkdir "$test_source"
mkfile 4m "$test_source/验证文件"
xattr -w com.eric-terminal.xmv-test '保留扩展属性' "$test_source/验证文件"

external-move --dry-run "$test_source" >/dev/null
[[ -d "$test_source" && ! -L "$test_source" ]]

test_output="$(external-move "$test_source")"
[[ "$test_output" == *'100%'* ]]
[[ "$test_output" != *'验证文件'* ]]
[[ -L "$test_source" ]]
[[ "$(readlink "$test_source")" == "$test_target" ]]
[[ -f "$test_target/验证文件" ]]
[[ "$(xattr -p com.eric-terminal.xmv-test "$test_target/验证文件")" == '保留扩展属性' ]]

external-move "$test_source" >/dev/null
[[ -L "$test_source" ]]

external-move --restore --dry-run "$test_source" >/dev/null
[[ -L "$test_source" ]]

test_output="$(external-move --restore "$test_source")"
[[ "$test_output" == *'100%'* ]]
[[ "$test_output" != *'验证文件'* ]]
[[ -d "$test_source" && ! -L "$test_source" ]]
[[ -f "$test_source/验证文件" ]]
[[ "$(xattr -p com.eric-terminal.xmv-test "$test_source/验证文件")" == '保留扩展属性' ]]
[[ ! -e "$test_target" && ! -L "$test_target" ]]

# 已迁移一天后，迁移整月应合并数据并收拢成一个上级链接。
mkdir -p "$tree_source/01" "$tree_source/02"
touch "$tree_source/01/第一天" "$tree_source/02/第二天"
external-move "$tree_source/01" >/dev/null
[[ -L "$tree_source/01" ]]
[[ -d "$tree_target/01" && ! -L "$tree_target/01" ]]

# 两侧真实数据重名时必须拒绝，不能以合并名义覆盖任意一侧。
mkdir "$tree_target/02"
touch "$tree_target/02/第二天"
if external-move --dry-run "$tree_source" >/dev/null 2>&1; then
  printf '%s\n' 'external-move 未拒绝目录合并冲突' >&2
  exit 1
fi
rm "$tree_target/02/第二天"
rmdir "$tree_target/02"

test_output="$(external-move --dry-run "$tree_source")"
[[ "$test_output" == *'合并目录'* ]]
[[ -d "$tree_source" && ! -L "$tree_source" ]]

external-move "$tree_source" >/dev/null
[[ -L "$tree_source" ]]
[[ "$(readlink "$tree_source")" == "$tree_target" ]]
[[ -f "$tree_target/01/第一天" ]]
[[ -f "$tree_target/02/第二天" ]]
[[ ! -e "$tree_target/01/01" && ! -L "$tree_target/01/01" ]]

# 从整月链接中只恢复一天时，上级变为真实目录，其余日期保留独立链接。
test_output="$(external-move --restore --dry-run "$tree_source/02")"
[[ "$test_output" == *'展开上级目录链接'* ]]
[[ -L "$tree_source" ]]

external-move --restore "$tree_source/02" >/dev/null
[[ -d "$tree_source" && ! -L "$tree_source" ]]
[[ -L "$tree_source/01" ]]
[[ "$(readlink "$tree_source/01")" == "$tree_target/01" ]]
[[ -d "$tree_source/02" && ! -L "$tree_source/02" ]]
[[ -f "$tree_source/02/第二天" ]]
[[ ! -e "$tree_target/02" && ! -L "$tree_target/02" ]]

# 再次迁移整月会把恢复的日期并回去，之后仍可完整恢复。
external-move "$tree_source" >/dev/null
[[ -L "$tree_source" ]]
[[ -f "$tree_target/01/第一天" ]]
[[ -f "$tree_target/02/第二天" ]]
external-move --restore "$tree_source" >/dev/null
[[ -d "$tree_source" && ! -L "$tree_source" ]]
[[ -f "$tree_source/01/第一天" ]]
[[ -f "$tree_source/02/第二天" ]]
[[ ! -e "$tree_target" && ! -L "$tree_target" ]]

mkdir "$outside_source"
touch "$outside_source/验证文件"
external-move "$outside_source" >/dev/null
[[ -L "$outside_source" ]]
[[ "$(readlink "$outside_source")" == "$outside_target" ]]
[[ -f "$outside_target/验证文件" ]]
external-move --restore "$outside_source" >/dev/null
[[ -d "$outside_source" && ! -L "$outside_source" ]]
[[ ! -e "$outside_target" && ! -L "$outside_target" ]]

mkdir "$protected_parent"
touch "$protected_source"
chmod 555 "$protected_parent"
test_output="$(external-move --dry-run "$protected_source")"
[[ "$test_output" == *'需要管理员权限：是'* ]]
chmod 755 "$protected_parent"

printf '%s\n' 'external-move 集成测试通过'
