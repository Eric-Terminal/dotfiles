#!/bin/bash
# 修改了 /etc/ssh/sshd_config 的配置信息
# 文件最末尾这样写
# Match All
#     ForceCommand /Users/Eric/dotfiles/macos/bin/ssh-access-gate.sh

# 获取客户端 IP 地址
REMOTE_IP=$(echo "${SSH_CLIENT}" | awk '{print $1}')

# 获取当前登录用户名并统一转为小写
CURRENT_USER=$(whoami | tr '[:upper:]' '[:lower:]')

# 非目标用户直接放行
if [[ "$CURRENT_USER" != "eric" ]]; then
    if [ -n "$SSH_ORIGINAL_COMMAND" ]; then
        exec "$SHELL" -c "$SSH_ORIGINAL_COMMAND"
    else
        exec "$SHELL" -l
    fi
    exit 0
fi

# 回环地址白名单放行
if [[ "$REMOTE_IP" == "127.0.0.1" || "$REMOTE_IP" == "::1" ]]; then
    if [ -n "$SSH_ORIGINAL_COMMAND" ]; then
        exec "$SHELL" -c "$SSH_ORIGINAL_COMMAND"
    else
        exec "$SHELL" -l
    fi
    exit 0
fi

# AppleScript 弹窗认证逻辑
AS_SCRIPT=$(cat <<EOF
try
    tell application "System Events"
        activate
        set dialogResult to display dialog "SSH 登录请求：\n\n身份: $CURRENT_USER\n来源 IP: $REMOTE_IP\n\n是否允许连接？\n(30秒无响应将自动放行)" buttons {"DENY", "ALLOW"} default button "ALLOW" cancel button "DENY" giving up after 30 with title "SSH 访问控制" with icon caution

        if gave up of dialogResult is true then
            return "ALLOW"
        else
            return button returned of dialogResult
        end if
    end tell
on error errMsg number errNum
    if errNum is -128 then
        return "DENY"
    else
        return "ALLOW"
    end if
end try
EOF
)

# 异步执行弹窗逻辑并保存结果到临时文件
TMP_FILE=$(mktemp /tmp/ssh-gate.XXXXXX)
osascript -e "$AS_SCRIPT" > "$TMP_FILE" &
AS_PID=$!

# 交互式会话动态倒计时
if [ -n "$SSH_TTY" ]; then
    # 隐藏光标
    tput civis

    for (( i=30; i>0; i-- )); do
        # 检查弹窗进程是否已经结束
        if ! kill -0 $AS_PID 2>/dev/null; then
            break
        fi

        # 覆盖输出当前倒计时
        printf "\rAuthentication successful. Waiting for host authorization (timeout in %2ds)..." "$i"
        sleep 1
    done

    # 兜底等待：弥补 osascript 启动延迟带来的时间差
    wait $AS_PID 2>/dev/null

    # 换行并恢复光标
    echo ""
    tput cnorm
else
    # 非交互式环境等待进程结束
    wait $AS_PID
fi

# 获取最终结果并清理临时文件
RESULT=$(cat "$TMP_FILE")
rm -f "$TMP_FILE"

if [[ "$RESULT" == "ALLOW" ]]; then

    # 放行逻辑
    if [ -n "$SSH_TTY" ]; then
        # 清理 TTY 缓冲区残留输入 (兼容 macOS Bash 3.2)
        while read -r -t 1 -n 10000; do :; done
        echo "Access granted."
    fi

    if [ -n "$SSH_ORIGINAL_COMMAND" ]; then
        exec "$SHELL" -c "$SSH_ORIGINAL_COMMAND"
    else
        exec "$SHELL" -l
    fi

else

    # 拒绝与封禁逻辑
    if [ -n "$SSH_TTY" ]; then
        echo "Access denied by host. Connection closed."
    fi

    if [[ -n "$REMOTE_IP" ]]; then
        # 同步执行拉黑
        sudo /sbin/pfctl -t sshguard -T add "$REMOTE_IP" >/dev/null 2>&1

        # 开启作业控制 (Monitor mode)，强制分配独立的进程组 ID (PGID)
        # 从而避开 sshd 会话退出时对原进程组发送的 SIGKILL
        set -m
        (
            sleep 300
            sudo /sbin/pfctl -t sshguard -T delete "$REMOTE_IP"
        ) </dev/null >/dev/null 2>&1 &
        set +m
        disown
    fi

    exit 1
fi
