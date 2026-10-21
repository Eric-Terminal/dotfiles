#!/bin/zsh

set -euo pipefail

source "${0:A:h:h}/shell/external-eject.zsh"

summary="$(_external-eject-summarize <<'EOF'
p38376
cXcode
u501
LEric
ftxt
n/Volumes/nvme0n1/Applications/Xcode.app/Contents/MacOS/Xcode
ftxt
n/Volumes/nvme0n1/Applications/Xcode.app/Contents/Frameworks/DVT.framework/DVT
p30525
cnode
u501
LEric
f12
n/Volumes/nvme0n1/Users/Eric/.npm/_logs/debug.log
EOF
)"

expected=$'38376\tXcode\tEric\t2\t/Volumes/nvme0n1/Applications/Xcode.app/Contents/MacOS/Xcode\n30525\tnode\tEric\t1\t/Volumes/nvme0n1/Users/Eric/.npm/_logs/debug.log'
[[ "$summary" == "$expected" ]]

_external-eject-fit '/Volumes/nvme0n1/Applications/Xcode.app/Contents/MacOS/Xcode' 32
[[ "$REPLY" == '/Volumes/nvme0n…ents/MacOS/Xcode' ]]

[[ "$(alias xeject)" == "xeject=external-eject" ]]
external-eject --help | /usr/bin/grep -q '默认卷：/Volumes/nvme0n1'
external-eject --help | /usr/bin/grep -q '“a”与“ka”分别处理全部进程'
external-eject --help | /usr/bin/grep -q '严格的只扫描模式'

# 模拟正常、空结果和异常扫描，不访问或推出真实卷。
(
  function /usr/sbin/lsof() {
    case "$scan_case" in
      empty) return 1 ;;
      occupied) printf 'p12345\nc测试进程\nu501\nLEric\nf1\nn/测试卷/文件\n' ;;
      failure) printf '模拟扫描失败\n' >&2; return 1 ;;
      warning) printf '模拟扫描不完整\n' >&2; return 0 ;;
    esac
  }

  scan_case=empty
  output="$(_external-eject-scan /测试卷 0)"
  [[ -z "$output" ]]
  scan_case=occupied
  output="$(_external-eject-scan /测试卷 0)"
  [[ "$output" == $'12345\t测试进程\tEric\t1\t/测试卷/文件' ]]
  for scan_case in failure warning; do
    if output="$(_external-eject-scan /测试卷 0 2>&1)"; then
      printf '扫描失败或不完整时，不应返回成功。\n' >&2
      exit 1
    fi
    [[ "$output" == *模拟扫描* ]]
  done
)

/bin/sleep 30 &
test_pid=$!
_external-eject-send-signal "$test_pid" "$USER" TERM
wait "$test_pid" 2>/dev/null || true
if /bin/kill -0 "$test_pid" 2>/dev/null; then
  printf 'external-eject：TERM 应当结束测试进程。\n' >&2
  exit 1
fi

# 等待只观察测试进程；超时也不应自动升级为 KILL。
(
  /bin/sleep 0.2 &
  test_pid=$!
  _external-eject-wait "$test_pid" >/dev/null
  wait "$test_pid"

  /bin/sleep 30 &
  test_pid=$!
  trap '/bin/kill "$test_pid" 2>/dev/null; wait "$test_pid" 2>/dev/null || true' EXIT
  if _external-eject-wait "$test_pid" >/dev/null; then
    printf '进程尚未退出时，等待应当超时并返回失败。\n' >&2
    exit 1
  fi
  /bin/kill -0 "$test_pid"
)

if external-eject --unknown >/dev/null 2>&1; then
  printf 'external-eject：未知选项应当返回失败。\n' >&2
  exit 1
fi

printf '%s\n' 'external-eject 单元测试通过'
