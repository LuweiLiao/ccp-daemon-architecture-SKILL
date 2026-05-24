#!/usr/bin/env bash
# CCP 门禁 — 防止 Hermes 越权执行硬件操作
# 写入 /etc/profile.d/ccp_gate.sh（全局生效）
# 或追加到 ~/.bashrc（用户生效）

CCP_LOCK_FILE="/tmp/ccp_daemon.lock"

ccp_is_running() {
  [ -f "$CCP_LOCK_FILE" ] && \
    kill -0 $(cat "$CCP_LOCK_FILE" 2>/dev/null) 2>/dev/null
}

# 被禁止的命令列表 — 只要 CCP daemon 在运行，这些命令对 Hermes 就是禁用的
FORBIDDEN_CMDS=(
  openocd
  scons
  arm-none-eabi-gdb
  arm-none-eabi-gdb-py
  st-flash
  stlink-gui
  cuav-v5-bl
)

for _cmd in "${FORBIDDEN_CMDS[@]}"; do
  eval "
    $_cmd() {
      if ccp_is_running; then
        echo '[CCP-GATE] ❌ 禁止：$_cmd 由 CCP daemon 管理。Hermes 不得执行硬件操作。' >&2
        return 1
      fi
      command $_cmd \"\$@\"
    }
  "
done
unset _cmd
