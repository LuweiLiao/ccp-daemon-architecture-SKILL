#!/usr/bin/env bash
# CCP 提醒钩子（已降级） — 不再作为安全边界
# 
# v3 变更：真正的安全边界已由 Linux 用户/设备权限接管。
# 这个脚本只剩下提醒功能，防止无意的交互式误操作。
# 
# 安全边界看这里：
# - /etc/udev/rules.d/99-stlink-ccp.rules → ccpd 组独占 ST-Link
# - 用户 llw 不在 ccpd 组 → openocd 连不上 ST-Link
# - 绕过需要 sudo → LLM 做不到

CCP_LOCK_FILE="/tmp/ccp_daemon.lock"

ccp_is_running() {
  [ -f "$CCP_LOCK_FILE" ] && \
    kill -0 $(cat "$CCP_LOCK_FILE" 2>/dev/null) 2>/dev/null
}

# ⚠️ 以下仅提醒，不拦截
# bash 函数无法拦截: /usr/bin/openocd, subprocess, 非交互 shell 等
FORBIDDEN_CMDS=(openocd scons arm-none-eabi-gdb st-flash)

for _cmd in "${FORBIDDEN_CMDS[@]}"; do
  eval "
    $_cmd() {
      if ccp_is_running; then
        echo '[CCP-REMINDER] daemon 正在管理 ST-Link。你确定要手动操作？输入 YES 继续:' >&2
        read confirm
        [ \"\$confirm\" = \"YES\" ] && command $_cmd \"\$@\"
      else
        command $_cmd \"\$@\"
      fi
    }
  "
done
unset _cmd
