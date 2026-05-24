---
name: "ccp-daemon-architecture"
description: "CCP Daemon (Continuous Closed Probe) — 24/7 自治流水线架构。Hermes 作为大脑设计和兜底，CCP daemon 作为常驻 orchestator，Claude Code CLI 作为执行者。硬件门禁防止 Hermes 越权执行。"
---

# CCP Daemon — 24/7 自治循环流水线

## 架构总览

```
┌─────────────────────────────────────────────────────────────┐
│                   三体架构                                    │
│                                                             │
│  🧠 Hermes Agent (大脑)                                      │
│  角色: 设计 daemon、兜底分析疑难杂症、出方案                   │
│  限制: ❌ 绝对不能执行任何终端命令（openocd/scons/gdb/CC）      │
│  提醒: 受 API 超时/context 压缩影响，必须靠架构不靠记忆不死扛  │
│                                                             │
│  ⚙️ CCP Daemon (orchestrator)                                │
│  角色: Python 脚本常驻后台，每 5 分钟 tick                    │
│  能力: subprocess 调 OpenOCD/CC/scons                        │
│  限制: 不依赖 Hermes 响应，Hermes 超时也不影响循环            │
│                                                             │
│  🖐️ Claude Code CLI (执行者)                                 │
│  角色: 改代码、编译、调试                                     │
│  限制: 5 分钟硬超时 + 看门狗检测活死                           │
│                                                             │
│  📱 飞书 (通知通道)                                          │
│  角色: 状态变更通知、异常上报                                 │
└─────────────────────────────────────────────────────────────┘
```

## 铁律（硬约束，非建议）

### 铁律 0：Hermes 绝对不能执行硬件操作

Hermes 在操作系统层面被 bash 门禁拦截，想干也干不了。

### 铁律 1：CCP daemon 不依赖 Hermes

Daemon 的全部 4 个阶段（Probe → Diagnose → Fix → Verify）都不经过 Hermes。Hermes 只负责设计 daemon 代码，以及异常兜底分析。

### 铁律 2：每个 CC 调用必须带超时

CC 卡死是最常见的失败模式。超时 = 5 分钟硬限制，到点就 kill -9。

### 铁律 3：3 次失败 = 暂停报人

L1 Retry(3次) → L2 Restart(3次) → 暂停。不无限循环。

## 门禁系统（bash 函数实现）

### 代码片段（写入 /etc/profile.d/ccp_gate.sh 或 .bashrc）

```bash
# CCP 门禁 — 防止 Hermes 越权执行硬件操作

CCP_LOCK_FILE="/tmp/ccp_daemon.lock"

ccp_is_running() {
  [ -f "$CCP_LOCK_FILE" ] && \
    kill -0 $(cat "$CCP_LOCK_FILE" 2>/dev/null) 2>/dev/null
}

# 被禁止的命令列表
FORBIDDEN_CMDS=(openocd scons arm-none-eabi-gdb \
                arm-none-eabi-gdb-py st-flash stlink-gui)

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
```

CCP daemon 内部调这些命令时用完整路径（如 `/usr/bin/openocd`）绕过 shell 函数。

### 文件锁（ST-Link 独占）

```python
import fcntl

STLINK_LOCK = "/tmp/ccp_stlink.lock"
def acquire_stlink():
    fd = open(STLINK_LOCK, "w")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except IOError:
        return None  # 锁被占着
```

## CCP Daemon 工作流

### 5 分钟一轮

```
[Probe]         OpenOCD 读内存调试变量 + MAVLink 心跳检查
    │
    ├── 状态无变化 ── 什么都不做，等下一轮
    │
    └── 状态变化 ── 推飞书通知
                        │
                   ┌────┴────┐
                   │         │
             一切正常     有问题
                   │         │
               等下一轮    [Diagnose]
                             │
                        判断阻塞类型
                             │
                   ┌─────────┼──────────┐
                   │         │          │
              HardFault  init卡住  心跳不通
                   │         │          │
             分析ESR→定位  查setup   查USB CDC
                             │
                        [Fix]
                             │
                     spawn CC CLI 修复
                             │
                     5分钟硬超时 + 看门狗
                             │
                        [Verify]
                             │
                     编译→烧录→OpenOCD验证
                             │
                    ┌────────┴────────┐
                    │                 │
                 通过 ✅        失败 ❌
                    │                 │
                 等下一轮     L1 Retry×3
                               │
                        还失败? L2 Restart
                               │
                        还失败? → 暂停报Hermes
```

### Probe 模块

```python
def probe():
    """读板子状态，返回结构化结果"""
    state = {}
    
    # 1. OpenOCD 连接
    if not openocd_alive():
        restart_openocd()
    
    # 2. 读调试变量
    state["setup_stage"]     = read32(0x2001b2c8)
    state["main_loop_iters"] = read32(0x20018fb4)
    state["fast_loop_count"] = read32(0x20018fa8)
    state["hfsr"]            = read32(0xE000ED2C)
    state["cfsr"]            = read32(0xE000ED28)
    
    # 3. 判断死活
    state["is_alive"] = (state["main_loop_iters"] > 0)
    state["has_hardfault"] = (state["hfsr"] != 0 or state["cfsr"] != 0)
    
    return state
```

### Diagnose 模块

```python
def diagnose(state):
    """分析阻塞点"""
    if state["has_hardfault"]:
        return {
            "type": "HARDFAULT",
            "detail": f"HFSR={state['hfsr']:#x} CFSR={state['cfsr']:#x}"
        }
    
    if not state["is_alive"]:
        stage = state["setup_stage"]
        # 查 init_ardupilot 卡在了哪一步
        if stage < 651:
            return {"type": "INIT_BLOCKED", "detail": f"setup_stage={stage}"}
        # setup 完成了但 main_loop 没跑 → wait_for_sample
        return {"type": "SPI_IMU_BLOCKED", "detail": "wait_for_sample"}
    
    return {"type": "OK"}
```

### Fix 模块 — 派 CC 干活

```python
def fix_by_cc(prompt, timeout_sec=300):
    """用 Claude Code CLI 执行修复，带超时和看门狗"""
    proc = subprocess.Popen(
        ["claude", "code", "-p", prompt],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        preexec_fn=lambda: signal.signal(signal.SIGTERM, signal.SIG_DFL)
    )
    
    # 并行看门狗：检查输出活性
    last_output = time.time()
    output_lines = []
    
    while proc.poll() is None:
        line = proc.stdout.readline()
        if line:
            output_lines.append(line.decode(errors='replace'))
            last_output = time.time()
        
        # 硬超时
        elapsed = time.time() - start_time
        if elapsed > timeout_sec:
            proc.kill()
            proc.wait()
            return {"status": "TIMEOUT", "output": "".join(output_lines)}
        
        # 看门狗：60 秒无输出
        if time.time() - last_output > 60:
            proc.kill()
            proc.wait()
            return {"status": "STUCK", "output": "".join(output_lines)}
    
    # 正常结束
    stdout, stderr = proc.communicate()
    return {"status": "DONE" if proc.returncode == 0 else "FAILED",
            "stdout": stdout.decode(errors='replace'),
            "stderr": stderr.decode(errors='replace')}
```

### 自愈机制（3 层）

```python
class SelfHealing:
    MAX_RETRIES = 3
    RETRY_DELAY = 30  # 秒
    
    def attempt(self, prompt, stage_name):
        for attempt in range(1, self.MAX_RETRIES + 1):
            log(f"[{stage_name}] Attempt {attempt}/{self.MAX_RETRIES}")
            
            result = fix_by_cc(prompt)
            
            if result["status"] == "DONE":
                # 编译 + 烧录验证
                if verify_burn():
                    return {"status": "VERIFIED"}
            
            if attempt < self.MAX_RETRIES:
                if result["status"] == "TIMEOUT" or "STUCK":
                    # L2: 重启一下 OpenOCD 再重试
                    restart_openocd()
                time.sleep(self.RETRY_DELAY)
        
        # 3 次全跪 → 暂停，报 Hermes
        return {"status": "GIVE_UP", "attempts": self.MAX_RETRIES}
```

## Hermes 超时保护

### 问题场景

Hermes 是 LLM，可能：
- API 超时断片
- context window 满
- 用户发 /new 换会话

### 解决方案：文件握手

```
daemon 无法自愈:
  → 写 /tmp/ccp_pending_analysis.json
      {
        "stage": "spi_frxth",
        "retries_exhausted": true,
        "last_error": "...",
        "waiting_since": "2026-05-24T23:30:00",
        "diagnostic_data": {"hfsr": 0, "setup_stage": 651, ...}
      }
  → 推飞书通知 "阻塞在 xxx，等待 Hermes 分析"
  → daemon 转入 idle 模式（每 5 分钟 probe 但不干活）

Hermes 下次被唤醒:
  → 读到 /tmp/ccp_pending_analysis.json 仍然存在
  → 分析根本原因
  → 写 /tmp/ccp_analysis_result.json
      {
        "root_cause": "SPI CR2.FRXTH=0 导致 RXNE 不触发",
        "fix_plan": "在 SPIDevice.cpp start_peripheral() 添加 CR2=FRXTH",
        "files_to_modify": ["libraries/AP_HAL_RTT/SPIDevice.cpp"],
        "chibios_reference": "SPIDevice.cpp:start_peripheral"
      }
  → 推飞书 "方案已出"
  → daemon 下次 tick 读到结果文件
  → 清空 pending 文件
  → 按方案创建 kanban 任务或派 CC
```

### 超时兜底

```
daemon idle 状态下:
  30 分钟内无 Hermes 回应 → 再飞书催一次
  90 分钟 (3 次催) 无回应 → 彻底暂停，写日志
  Hermes 回应后自动恢复
```

## 通知协议（飞书）

### 通知类型

| 类型 | 触发 | 格式 |
|------|------|------|
| 状态变更 | 状态变化 | "🟢 固件活了！main_loop={N} fast_loop={M}" |
| 开始修复 | 诊断出问题 | "🔧 诊断结果：{type} → 派 CC 修复中" |
| 修复成功 | 验证通过 | "✅ {stage} 修复验证通过" |
| 修复失败 | 3 次重试全跪 | "❌ {stage} 3 次修复失败 → 等待 Hermes 分析" |
| Hermes 方案已出 | analysis_result 写好 | "📋 方案已出：{root_cause[:100]}" |
| 无回应催 | 30 分钟无回应 | "⏰ Hermes 还没回应，仍然卡在 {stage}" |
| 彻底暂停 | 90 分钟无回应 | "🛑 已暂停。等待人工介入。" |

只通知状态变化（当前状态 ≠ 上次状态），避免刷屏。

## daemon 保活

```cron
# 每 5 分钟触发，如果 daemon 已经在跑则跳过
* * * * * /home/llw/.hermes/scripts/ccp_daemon.py --cron-tick
```

daemon 内部用文件锁防止并发：

```python
def main():
    lock_fd = acquire_lock()
    if not lock_fd:
        return  # 上一次的还在跑，跳过
    
    state = probe()
    if state_changed(state, load_last_state()):
        notify_feishu(state)
        save_last_state(state)
    
    if not state["is_alive"]:
        diagnosis = diagnose(state)
        if diagnosis["type"] == "OK":
            pass
        elif seek_pending_result():  # 看 Hermes 有没有出方案
            execute_plan(load_pending_result())
            clear_pending_result()
        else:
            result = fix(diagnosis)  # 派 CC
            if result["status"] == "GIVE_UP":
                write_pending_analysis(diagnosis)
                notify_feishu("需要 Hermes 介入")
```

## 边界条件

| 场景 | 处理 |
|------|------|
| CC 卡死 | 5 分钟硬超时 → kill -9 → L1 Retry |
| CC 返回代码没改好 | 编译不通过 → 自动重试 |
| OpenOCD 端口被占 | killall openocd → 重启 |
| 飞书通知发不出去 | 写日志，下轮重试 |
| daemon 进程挂了 | cron 下轮重新拉起 |
| Hermes 超时没回应 | daemon idle 等待，不无限发CC |
| 硬件物理损坏 | 诊断链 3 次全跪 → 暂停报人 |

## 验证标准

```
启动 CCP daemon 后:
  □ daemon 每 5 分钟 tick 一次
  □ 首次 probe 成功读到调试变量
  □ 飞书收到状态变更通知
  □ 发现阻塞后自动派 CC 修复
  □ CC 超时被正确 kill -9
  □ 修复成功 → 编译 → 烧录 → 验证通过
  □ 修复 3 次失败 → 暂停 → 写 pending 文件
  □ Hermes 出方案 → daemon 读到并执行
  □ Hermes 超时不阻塞 daemon
  □ bash 门禁拦截 Hermes 执行 openocd/scons/gdb
```
