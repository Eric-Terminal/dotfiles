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
external-eject --help | /usr/bin/grep -q '自动识别当前连接的外置物理盘'
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
  output="$(_external-eject-scan 0 /测试卷)"
  [[ -z "$output" ]]
  scan_case=occupied
  output="$(_external-eject-scan 0 /测试卷)"
  [[ "$output" == $'12345\t测试进程\tEric\t1\t/测试卷/文件' ]]
  for scan_case in failure warning; do
    if output="$(_external-eject-scan 0 /测试卷 2>&1)"; then
      printf '扫描失败或不完整时，不应返回成功。\n' >&2
      exit 1
    fi
    [[ "$output" == *模拟扫描* ]]
  done
)

# APFS 卷与物理盘的编号不同，卷名也不能作为筛选或排序依据。
(
  physical_fixture='<plist version="1.0"><dict><key>WholeDisks</key><array><string>disk6</string><string>disk10</string></array></dict></plist>'
  volumes_fixture="$(/usr/bin/plutil -convert xml1 -o - - <<'JSON'
{"AllDisksAndPartitions": [
  {"DeviceIdentifier": "disk6", "Partitions": []},
  {"DeviceIdentifier": "disk7", "APFSPhysicalStores": [{"DeviceIdentifier": "disk6s2"}],
   "APFSVolumes": [{"MountPoint": "/Volumes/工作盘"}, {"MountPoint": "/Volumes/其他资料"}]},
  {"DeviceIdentifier": "disk10", "Partitions": [{"MountPoint": "/Volumes/Mac Backup"}]},
  {"DeviceIdentifier": "disk61", "APFSPhysicalStores": [{"DeviceIdentifier": "disk60s1"}],
   "APFSVolumes": [{"MountPoint": "/Volumes/磁盘镜像"}]}
]}
JSON
)"
  function /usr/sbin/diskutil() {
    case "$*" in
      'list -plist external physical') printf '%s' "$physical_fixture" ;;
      'list -plist external') printf '%s' "$volumes_fixture" ;;
      *) return 1 ;;
    esac
  }

  output="$(_external-eject-disks)"
  [[ "$output" == $'disk6\0disk10' ]]
  output="$(_external-eject-disks disk6)"
  [[ "$output" == $'/Volumes/工作盘\0/Volumes/其他资料' ]]
  output="$(_external-eject-disks disk10)"
  [[ "$output" == '/Volumes/Mac Backup' ]]
  output="$(_external-eject-disks disk11)"
  [[ -z "$output" ]]
  physical_fixture='<plist version="1.0"><dict><key>WholeDisks</key><array/></dict></plist>'
  output="$(_external-eject-disks)"
  [[ -z "$output" ]]
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
