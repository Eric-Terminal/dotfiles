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

/bin/sleep 30 &
test_pid=$!
_external-eject-send-signal "$test_pid" "$USER" TERM
wait "$test_pid" 2>/dev/null || true
if /bin/kill -0 "$test_pid" 2>/dev/null; then
  printf 'external-eject：TERM 应当结束测试进程。\n' >&2
  exit 1
fi

if external-eject --unknown >/dev/null 2>&1; then
  printf 'external-eject：未知选项应当返回失败。\n' >&2
  exit 1
fi

printf '%s\n' 'external-eject 单元测试通过'
