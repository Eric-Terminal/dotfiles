#!/bin/zsh

set -euo pipefail

repo_root="${0:A:h:h}"
source "$repo_root/shell/external-move.zsh"

test_parent="$(mktemp -d "$HOME/.xmv-test.XXXXXX")"
test_source="$test_parent/含 空格的目录"
test_target="/Volumes/nvme0n1${test_source}"
test_output=""

cleanup() {
  set +e
  if [[ -L "$test_source" && -e "$test_target" ]]; then
    external-move --restore "$test_source" >/dev/null
  fi
  [[ -L "$test_source" ]] && rm "$test_source"
  [[ -f "$test_source/验证文件" ]] && rm "$test_source/验证文件"
  [[ -d "$test_source" ]] && rmdir "$test_source"
  [[ -f "$test_target/验证文件" ]] && rm "$test_target/验证文件"
  [[ -d "$test_target" ]] && rmdir "$test_target"
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
[[ -d "$test_source" && ! -L "$test_source" ]]
[[ -f "$test_source/验证文件" ]]
[[ "$(xattr -p com.eric-terminal.xmv-test "$test_source/验证文件")" == '保留扩展属性' ]]
[[ ! -e "$test_target" && ! -L "$test_target" ]]

printf '%s\n' 'external-move 集成测试通过'
