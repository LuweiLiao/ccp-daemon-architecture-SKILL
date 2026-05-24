---
name: "ccp-daemon-architecture"
description: "CCP Daemon (Continuous Closed Probe) — 24/7 自治流水线架构。Hermes 作为大脑设计和兜底，CCP daemon 作为常驻 orchestrator+传感器桥接，Claude Code CLI + /goal 作为持久执行者。"
---

# CCP Daemon — 24/7 自治循环流水线（v2 混合架构）

## 架构总览

### 四体架构

```
┌──────────────────────────────────────────────────────────────────┐
│                                                                   │
│  🧠 Hermes Agent (大脑)                                          │
│  角色: 设计 daemon、兜底分析疑难杂症、出方案                       │
│  限制: ❌ 被 bash 门禁挡住，绝对接触不到 openocd/scons/gdb        │
│  激活条件: 仅 daemon 报 "3 次全跪" 时介入                         │
│                                                                   │
│  ⚙️ CCP Daemon (orchestrator + 传感器桥接)                       │
│  角色: Python 脚本常驻后台每 5 分钟 tick                          │
│  能力:                                                           │
│    - subprocess 调 scons 编译固件                                 │
│    - subprocess 调 OpenOCD 烧录+读内存调试变量                    │
│    - subprocess 调 pymavlink 收心跳                               │
│    - 写 /goal 目标文件给 CC                                       │
│    - kill 卡死的 CC 进程                                          │
│  限制: 不依赖 Hermes 响应                                         │
│                                                                   │
│  🖐️ Claude Code CLI + /goal (持久执行者)                         │
│  角色: 通过 /goal 持久目标连续工作数小时                           │
│  能力:                                                           │
│    - 读 daemon 写的 goal 文件（含当前故障现象+硬件读数）           │
│    - 改代码、git diff 检查                                        │
│    - 自己调用 scons 编译                                           │
│  限制: ❌ 不能调 OpenOCD（ST-Link 被 daemon 独占）                 │
│  保活: claude-goal 的 Stop hook 自动续行（默认 500 次）           │
│                                                                   │
│  🔧 硬件探针（bash/Python 工具集）                                │
│  角色: 由 daemon 调度，执行具体硬件操作                            │
│  包含:                                                           │
│    - openocd_probe.sh — 启动 OpenOCD → 读内存 → 关闭              │
│    - scons_build.sh — 编译固件                                    │
│    - openocd_burn.sh — 烧录固件                                   │
│    - mavlink_check.py — 收 MAVLink 心跳                           │
│                                                                   │
│  📱 飞书 (通知通道)                                              │
│  角色: 状态变更通知、异常上报                                     │
└──────────────────────────────────────────────────────────────────┘
```

### 核心思想：传感器桥接模式

```
daemon 的核心价值 = 把"CC 能看到的"和"硬件实际发生的"桥接起来

CC 能看到的:         daemon 桥接:             硬件实际:
  代码                     → compile             → bin 文件
  bin 文件                 → program + verify    → Flash
  Flash 内容              → reset + 等启动       → 固件运行
  不知道固件在干什么       → OpenOCD 读内存       → main_loop_iterations
  不知道心跳有没有         → MAVLink 监听        → USB CDC

这种桥接 = 闭环控制。daemon 是传感器, CC 是控制器。
```

## /goal 模板（与 claude-goal 集成）

CCP daemon 为每种已知故障类型准备预制的 `/goal` 模板，集成 claude-goal 的 Stop hook + 审计机制。

### 通用目标模板

```
/goal {客观目标}

当前现象:
  - OpenOCD 读数: setup_stage={N}, main_loop_iterations={M}, HFSR={h}, CFSR={c}
  - MAVLink: {心跳状态}
  - 上次改动: {git diff 摘要}

Scope:
  - {相关文件路径}

完工标准 (Done when):
  - main_loop_iterations > 0 (OpenOCD 0x20018fb4)
  - fast_loop_count > 0 (OpenOCD 0x20018fa8)
  - MAVLink HEARTBEAT 持续收到 (ttyACM1)

停止条件 (Stop if):
  - 固件烧录后 3 次验证都没有进展
  - 需要硬件物理操作（拔插、按按钮）
  - 怀疑硬件损坏

约束:
  - 每次改完代码后，daemon 会编译+烧录+验证
  - 你不需要自己管编译和烧录
  - daemon 每 5 分钟会给你新的硬件读数
  - 改代码前先读 ChibiOS 参考实现
```

### SPI IMU 阻塞专用模板

```
/goal 修复 CUAV V5 的 SPI IMU 驱动使 main_loop 正常运行

当前现象:
  - setup_stage=651 (初始化已完成)
  - main_loop_iterations=0 (卡在 wait_for_sample)
  - HFSR=0 CFSR=0 (无 HardFault)
  - ADC 正常: conversion_count={N}
  - hwdef 已加 ICM42688, FRXTH 已修复

Scope: libraries/AP_HAL_RTT/SPIDevice.cpp, SPIDevice.h

完工标准:
  - main_loop_iterations > 0 (OpenOCD 0x20018fb4)

停止条件:
  - 3 轮修复后 main_loop 仍为 0
  - 需要改 bootloader 或硬件

约束:
  - 每次改完后 daemon 会编译+烧录+验证
  - OpenOCD 读数变化会在下一轮 /goal 更新
  - 先读 ChibiOS 参考: libraries/AP_HAL_ChibiOS/SPIDevice.cpp
  - 不要修改 hwdef, bootloader, 或系统时钟
  - 不要怀疑硬件, 优先检查软件配置
```

### HardFault 专用模板

```
/goal 修复 CUAV V5 的 HardFault 错误

当前现象:
  - HFSR=0x{hfsr}, CFSR=0x{cfsr}
  - ESR 类型: {esr_type}
  - PC=0x{pc}, LR=0x{lr}

Scope: (根据 PC 所在的文件)

完工标准:
  - 烧录后 HFSR=0 CFSR=0 持续 60 秒
  - main_loop_iterations > 0

停止条件:
  - 3 轮修复后仍有 HardFault
```

## 硬件操作命令集（daemon 专用）

以下所有命令由 CCP daemon 通过 Python subprocess 执行。bash 门禁阻止 Hermes 直接使用。

### scons 编译

```python
import subprocess, os

PROJECT_DIR = "/data/firmare/pogo-apm"
TARGET = "cuav_v5"
VARIANT = "ArduCopter"
BUILD_DIR = f"{PROJECT_DIR}/build/rtt_{TARGET}"
BIN = f"{BUILD_DIR}/rtthread.bin"
ELF = f"/data/firmare/pogo-apm/build/rtt_deploy/{TARGET}/rt-thread.elf"

def scons_compile():
    """编译固件"""
    result = subprocess.run(
        ["scons", f"--v={VARIANT}", f"--target={TARGET}", f"-j{os.cpu_count()}"],
        cwd=PROJECT_DIR,
        capture_output=True, text=True,
        timeout=600  # 10 分钟超时
    )
    if result.returncode != 0:
        # 解析具体编译错误
        errors = [l for l in result.stderr.split('\n') if 'error:' in l.lower()]
        return {"status": "FAIL", "errors": errors, "full": result.stderr}
    
    # 确认 bin 文件生成
    if os.path.exists(BIN) and os.path.getsize(BIN) > 0:
        size_kb = os.path.getsize(BIN) / 1024
        return {"status": "OK", "bin": BIN, "size_kb": f"{size_kb:.1f}"}
    
    return {"status": "FAIL", "errors": ["bin not found"]}
```

### OpenOCD 探针（读板子状态）

```python
import socket, time

OPENOCD_PORT = 4444
OPENOCD_CFG = "-f interface/stlink.cfg -f target/stm32f7x.cfg"

def openocd_read32(addr):
    """通过 OpenOCD telnet 读 32 位内存值"""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect(("localhost", OPENOCD_PORT))
        s.sendall(f"mdw {addr} 1\n".encode())
        time.sleep(0.2)
        data = s.recv(1024).decode(errors='replace')
        s.close()
        # 解析: "0x20018fb4: 00000000"
        for line in data.split('\n'):
            if hex(addr).lower() in line.lower():
                parts = line.split(':')
                if len(parts) > 1:
                    return int(parts[1].strip(), 16)
        return None
    except Exception as e:
        return f"ERR:{e}"

def probe_board():
    """完整板子探针"""
    state = {}
    state["setup_stage"]     = openocd_read32(0x2001b2c8)
    state["main_loop_iters"] = openocd_read32(0x20018fb4)
    state["fast_loop_count"] = openocd_read32(0x20018fa8)
    state["rtt_dbg_main_loop_entry"] = openocd_read32(0x20000108)
    state["hfsr"]            = openocd_read32(0xE000ED2C)
    state["cfsr"]            = openocd_read32(0xE000ED28)
    
    # 解析
    state["is_alive"] = (isinstance(state["main_loop_iters"], int) 
                         and state["main_loop_iters"] > 0)
    state["has_hardfault"] = (isinstance(state["hfsr"], int) and state["hfsr"] != 0)
    state["setup_done"] = (isinstance(state["setup_stage"], int) 
                           and state["setup_stage"] >= 0x28b)  # 651
    return state
```

### OpenOCD 启动/停止

```python
import subprocess, time, os, signal

OPENOCD_CMD = ["openocd", "-f", "interface/stlink.cfg", "-f", "target/stm32f7x.cfg",
               "-c", "adapter speed 1000"]

def openocd_start():
    """后台启动 OpenOCD"""
    proc = subprocess.Popen(
        OPENOCD_CMD,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        preexec_fn=lambda: signal.signal(signal.SIGTERM, signal.SIG_DFL)
    )
    time.sleep(2)  # 等启动
    # 确认端口开放
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(2)
        s.connect(("localhost", OPENOCD_PORT))
        s.close()
        return {"status": "OK", "pid": proc.pid}
    except:
        return {"status": "FAIL", "msg": "openocd didn't start"}

def openocd_stop():
    """关闭 OpenOCD（telnet shutdown）"""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(3)
        s.connect(("localhost", OPENOCD_PORT))
        s.sendall(b"shutdown\n")
        s.close()
        time.sleep(1)
        return {"status": "OK"}
    except:
        # 暴力杀
        subprocess.run(["killall", "-9", "openocd"], capture_output=True)
        return {"status": "KILLED"}
```

### OpenOCD 烧录

```python
def openocd_burn(bin_path, addr="0x08008000"):
    """用 OpenOCD 烧录固件"""
    
    # 方案 A: 通过 telnet（可靠，不会被安全守护杀）
    def burn_via_telnet():
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(120)  # 烧录可能 60 秒+
            s.connect(("localhost", OPENOCD_PORT))
            
            # 擦除+写入
            s.sendall(f"program {bin_path} {addr}\n".encode())
            time.sleep(0.5)
            
            # 等完成
            data = b""
            while True:
                try:
                    chunk = s.recv(4096)
                    if not chunk:
                        break
                    data += chunk
                    if b"verified" in chunk.lower() or b"error" in chunk.lower():
                        break
                except socket.timeout:
                    break
            
            s.close()
            output = data.decode(errors='replace')
            
            if "verified" in output.lower():
                return {"status": "OK", "detail": output[:200]}
            elif "error" in output.lower():
                return {"status": "FAIL", "detail": output[:200]}
            else:
                return {"status": "UNKNOWN", "detail": output[:200]}
        except Exception as e:
            return {"status": "ERR", "detail": str(e)}
    
    # 方案 B: 一次性 program（简单但可能被杀）
    def burn_one_shot():
        result = subprocess.run(
            ["openocd", "-f", "interface/stlink.cfg", "-f", "target/stm32f7x.cfg",
             "-c", f"program {bin_path} {addr} verify",
             "-c", "reset run", "-c", "shutdown"],
            capture_output=True, text=True,
            timeout=180
        )
        if "verified" in result.stdout.lower():
            return {"status": "OK"}
        return {"status": "FAIL", "output": result.stdout + result.stderr}
    
    # 优先 telnet（已经启动的情况下）
    if is_openocd_running():
        return burn_via_telnet()
    return burn_one_shot()

def verify_flash():
    """烧录后验证向量表"""
    vec_sp  = openocd_read32(0x08008000)
    vec_reset = openocd_read32(0x08008004)
    if vec_sp is None or vec_reset is None:
        return {"status": "FAIL", "msg": "can't read vector table"}
    if vec_sp == 0xFFFFFFFF or vec_reset == 0xFFFFFFFF:
        return {"status": "FAIL", "msg": "flash is empty"}
    return {"status": "OK", "sp": f"{vec_sp:#x}", "reset": f"{vec_reset:#x}"}
```

### MAVLink 心跳检查

```python
def mavlink_check():
    """检查 MAVLink 心跳"""
    import pymavlink.dialects.v20.ardupilotmega as dialect
    from pymavlink import mavutil
    
    try:
        master = mavutil.mavlink_connection(
            "/dev/ttyACM1", baud=921600,
            dialect=dialect, timeout=3
        )
        msg = master.wait_heartbeat(timeout=10)
        if msg:
            return {
                "status": "OK",
                "type": msg.type,
                "autopilot": msg.autopilot,
                "state": "STANDBY" if msg.type == 1 else f"type={msg.type}"
            }
        return {"status": "NO_HEARTBEAT"}
    except Exception as e:
        return {"status": "ERR", "detail": str(e)}
```

## 完整工作流

### daemon 主循环

```python
import json, time, os

STATE_FILE = "/tmp/ccp_state.json"
GOAL_DIR = "/tmp/ccp_goals"
LOCK_FILE = "/tmp/ccp_daemon.lock"
CC_PID_FILE = "/tmp/ccp_claude_code.pid"

def main():
    # 文件锁防并发
    with open(LOCK_FILE, 'w') as f:
        try:
            import fcntl
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            f.write(str(os.getpid()))
        except IOError:
            return  # 已有实例
    
    last_state = load_state(STATE_FILE)
    current = probe_board()
    
    # 状态变更 → 推飞书
    if state_changed(current, last_state):
        notify_state(current, last_state)
        save_state(STATE_FILE, current)
    
    cc_pid = read_pid(CC_PID_FILE)
    cc_alive = (cc_pid and is_process_alive(cc_pid))
    
    if current["is_alive"]:
        # 固件活了
        if cc_alive:
            kill_cc(cc_pid)  # 目的达成了，停 CC
            clear_pid(CC_PID_FILE)
        # 不需要行动
    
    elif not cc_alive and retries_remaining():
        # CC 不在跑，需要派活
        goal = build_goal(current, last_state)
        spawn_cc_with_goal(goal)
    
    elif cc_alive and no_progress_for_n_ticks(current, last_state, n=3):
        # CC 跑了 3*5=15 分钟没进展 → 杀掉重来
        kill_cc(cc_pid)
        clear_pid(CC_PID_FILE)
        goal = build_goal(current, last_state, note="上次修复没效果，换方法")
        spawn_cc_with_goal(goal)
    
    # 检查是否有 Hermes 的分析结果
    pending = check_hermes_analysis()
    if pending:
        execute_hermes_plan(pending)
        clear_hermes_analysis()
```

### spawn CC + /goal

```python
def spawn_cc_with_goal(goal_text):
    """启动 CC 并设置 /goal 持久目标"""
    # 写 goal 文件
    os.makedirs(GOAL_DIR, exist_ok=True)
    with open(f"{GOAL_DIR}/current_goal.txt", 'w') as f:
        f.write(goal_text)
    
    # 启动 CC
    proc = subprocess.Popen(
        ["claude", "code", "-p", goal_text],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        stdin=subprocess.DEVNULL,
        preexec_fn=lambda: signal.signal(signal.SIGTERM, signal.SIG_DFL)
    )
    write_pid(CC_PID_FILE, proc.pid)
    
    notify_feishu({
        "type": "GOAL_STARTED",
        "objective": goal_text.split('\n')[0][:100],
        "cc_pid": proc.pid
    })
```

### CC 保活检测

```python
def is_process_alive(pid):
    """检查进程是否活着"""
    try:
        os.kill(pid, 0)
        return True
    except:
        return False

def kill_cc(pid):
    """强制 kill CC"""
    try:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    except:
        pass
    # 也杀 zombie 子进程
    subprocess.run(["pkill", "-f", "claude"], capture_output=True)
```

## 自愈机制（3 层，由 daemon 完全自主执行）

| 层级 | 触发条件 | 处理 | 耗时 |
|------|---------|------|------|
| L0 | 状态正常 | 什么都不做 | 0 |
| L1 Retry | CC 进程死了 / 编译失败 | 重新 spawn CC + /goal | 5 分钟 |
| L2 Restart | 同一问题 L1 失败 3 次 | 重启 OpenOCD，重连 ST-Link，重 spawn | 10 分钟 |
| L3 Escalate | L2 失败 3 次 | 暂停 → 写 /tmp/ccp_pending_analysis.json → 飞书通知 Hermes | 不回 Hermes 就暂停 |

## 通知协议（飞书）

| 类型 | 触发 | 示例 |
|------|------|------|
| 首次启动 | daemon 开始跑 | "🟢 CCP daemon 上线，5 分钟 tick 开始" |
| 固件活了 | main_loop > 0 | "🟢 固件活了！main_loop={N} fast_loop={M}" |
| 固件死了 | main_loop 从 >0 变 0 | "🔴 固件挂了！上次 main_loop={N}，现在=0" |
| 派 CC | spawn goal | "🔧 派 CC 修复 {objective[:60]} PID={pid}" |
| CC 卡死 | 15 分钟没进展 | "⚠️ CC(PID={pid}) 15 分钟无进展，杀掉重来" |
| 编译失败 | scons 返回非零 | "❌ 编译失败: {top_3_errors}" |
| 烧录失败 | verify 失败 | "❌ 烧录失败: {detail}" |
| 需 Hermes 介入 | L3 Escalate | "⛔ 3 次修复失败，等待 Hermes 分析。暂存在 /tmp/ccp_pending_analysis.json" |
| Hermes 回应 | analysis_result 写好 | "📋 Hermes 方案已出：{root_cause[:100]}" |
| 超时提醒 | 30 分钟无回应 | "⏰ Hermes 还没回应，还是卡在 {stage}" |
| 彻底暂停 | 90 分钟无回应 | "🛑 已暂停，等待人工介入" |

只通知状态变化，不刷屏。

## daemon 保活

```bash
# crontab -e 添加:
* * * * * /home/llw/.hermes/scripts/ccp_daemon.py --tick >> /tmp/ccp_daemon.log 2>&1
```

每分钟触发一次，daemon 内部用文件锁确保只有实例在跑。锁文件 `ccp_daemon.lock` 同时也充当 bash 门禁的开关（门禁脚本检测这个文件是否存在来决定是否拦截命令）。

## 验证标准

```
启动 CCP daemon + 安装 claude-goal 后:
  □ bash 门禁已安装（/etc/profile.d/ccp_gate.sh）
  □ daemon 每 5 分钟 tick 一次
  □ 首次 probe 成功读到 5 个调试变量
  □ 飞书收到 "CCP daemon 上线" 通知
  □ 固件卡死时 daemon 自动 spawn CC + /goal
  □ CC 通过 /goal 持久目标连续工作
  □ daemon 正确感知 CC 进程死活
  □ CC 卡死 15 分钟 → daemon 杀掉重来
  □ 编译成功 → 自动烧录
  □ 烧录成功 → 自动 verify 向量表
  □ verify 通过 → 自动 probe 新状态
  □ 3 次修复失败 → 写 pending → 通知飞书
  □ Hermes 出方案 → daemon 读到并执行
  □ 固件活了 → 自动停 CC，进入 idle
  □ Hermes 超时不阻塞 daemon
  □ 门禁阻止 Hermes 执行 openocd/scons/gdb
  □ claude-goal 的 Stop hook 正常运行
```

## 边界条件

| 场景 | 处理 |
|------|------|
| OpenOCD 端口被占 | `killall -9 openocd` → 重启 |
| ST-Link 物理断开重连 | 重启 OpenOCD + 重新 probe |
| scons 编译 10 分钟超时 | 判定为编译卡死 → kill → retry |
| 烧录中途断电 | 下一轮 probe 读不到值 → 重烧 |
| 飞书 API 限流 | 写日志，下轮重试 |
| 磁盘满 | daemon 日志轮转 |
| CC 装了坏 skill 导致崩溃 | 杀掉 CC → 清除 ~/.claude/skills/ 中无关项 → 重试 |
| claude-goal DB 损坏 | 删 ~/.claude/goal/goals.sqlite → 重装 |
