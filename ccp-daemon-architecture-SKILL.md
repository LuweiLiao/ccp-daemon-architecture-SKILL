---
name: "ccp-daemon-architecture"
description: "CCP Daemon (Continuous Closed Probe) — 24/7 自治流水线架构 v3。三层隔离（权限/进程/代码）+ SQLite 状态机 + daemon 传感器桥接 + CC /goal 持久执行。"
---

# CCP Daemon — 24/7 自治循环流水线 v3

## 版本历史

| 版本 | 变更 |
|------|------|
| v1 | 初始架构：三体（Hermes+daemon+CC） |
| v2 | 混合架构：/goal 集成 + 具体硬件命令 |
| **v3 (当前)** | **三层隔离（权限/进程/代码）+ SQLite 状态机 + 去掉 bash 门禁 + 精确进程管理** |

## 设计原则

```
1. 安全边界 = Linux 用户/设备权限, 不是 bash 函数
2. CC 只允许改代码+读日志+读 daemon 写的状态文件
3. 每个子进程 = 独立 process group, 精确 kill
4. 每次修复 = 独立 git worktree, 失败丢弃, 成功保留
5. 状态持久化 = SQLite WAL, 不是 JSON 文件
6. 3 层隔离: 权限隔离 > 进程隔离 > 代码隔离
7. daemon 是传感器桥接层, CC 是推理器, Hermes 是 L3 兜底
```

## 四体架构

```
┌──────────────────────────────────────────────────────────────────┐
│                                                                   │
│  🧠 Hermes Agent (大脑)                                          │
│  角色: 设计 daemon、兜底分析疑难杂症、出方案                       │
│  权限: 无 stlink 设备访问（用户 llw 不在 ccpd 组）                │
│  激活: 仅 daemon 报 "3 次全跪" 时介入（文件握手）                 │
│                                                                   │
│  ⚙️ CCP Daemon (orchestrator + 传感器桥接)                       │
│  角色: Python 脚本常驻后台每 5 分钟 tick                          │
│  权限: ccpd 组 → ST-Link rw + git worktree rw                    │
│  能力: subprocess(os.setsid) 调 scons/OpenOCD/pymavlink/git      │
│  限制: 所有子进程=独立 PG, 精确 kill, 不依赖 Hermes               │
│  状态: SQLite WAL 持久化, 崩溃可恢复                              │
│                                                                   │
│  🖐️ Claude Code CLI + /goal (持久执行者)                         │
│  角色: 通过 /goal 持久目标连续工作                                │
│  权限: 无 stlink 设备访问                                         │
│  能力: 读 daemon 写的状态文件 + 读日志 + 改代码 + git diff        │
│  限制: ❌ 不能调 OpenOCD/GDB/scons/烧录                          │
│  保活: claude-goal Stop hook（默认 500 次续行）                   │
│  工作区: git worktree（失败丢弃, 成功合入）                       │
│                                                                   │
│  🔧 硬件探针（由 daemon 调度）                                    │
│  包含: openocd / scons / pymavlink / git                          │
│  管理: ManagedProcess 类, 每个进程=独立 PG+日志+PID 元信息        │
│                                                                   │
│  📱 飞书 (通知通道)                                              │
│  角色: 状态变更通知、异常上报                                     │
└──────────────────────────────────────────────────────────────────┘
```

### 核心思想：传感器桥接模式

```
daemon 的核心价值 = 把"CC 能看到的"和"硬件实际发生的"桥接起来

CC 能看到的:         daemon 桥接:             硬件实际:
  代码                     → scons compile      → bin 文件
  bin 文件                 → openocd program    → Flash
  Flash 内容              → reset + 等启动      → 固件运行
  不知道固件在干什么       → OpenOCD 读内存      → main_loop_iterations
  不知道心跳有没有         → MAVLink 监听       → USB CDC

这种桥接 = 闭环控制。daemon 是传感器, CC 是控制器。
```

## 权限边界表

| 组件 | Linux 用户 | 设备权限 | 文件系统 | 可执行命令 |
|------|-----------|---------|---------|-----------|
| Hermes Agent | `llw` | 无 ST-Link 设备 | 源码只读 | 任意（但无设备权限） |
| CCP Daemon | `llw`（专用组 `ccpd`） | ST-Link USB rw | 源码 worktree rw + 日志 rw | scons, openocd, python3, git, cp, rm |
| Claude Code | `llw` | 无 ST-Link 设备 | 源码 worktree 只读 + 日志只读 | git, python3, cat, grep |

### 为什么不用 bash 门禁

v1/v2 的 bash 门禁方案有根本性缺陷：

| 绕过方式 | 能防吗 |
|----------|--------|
| Hermes 用 `/usr/bin/openocd` 完整路径 | ❌ bash 函数只覆盖裸命令 |
| Hermes 用 Python `subprocess.run("openocd")` | ❌ subprocess 不走 bash |
| Hermes 在非交互 shell 中执行 | ❌ .bashrc 不加载 |
| Hermes 改 PATH 把恶意脚本放前面 | ❌ 任意绕过 |
| Hermes 用 `env -i bash -c openocd` | ❌ 环境隔离 |

**真正边界**：
- udev 规则让 ST-Link 设备只向 `ccpd` 组开放
- 用户 `llw` 不在 `ccpd` 组
- Hermes 调 openocd → openocd open ST-Link → `EACCES` → 失败
- 绕过需要 `sudo`/root → 超出了 LLM 的能力范围

## 三层隔离（核心设计）

### 第一层：权限隔离（硬边界）

#### ST-Link USB 独占

```bash
# 找出 ST-Link USB 设备
$ lsusb | grep -i stlink
Bus 001 Device 003: ID 0483:374b STMicroelectronics ST-Link/V2.J41S7

# udev 规则：只允许 ccpd 组访问
$ cat /etc/udev/rules.d/99-stlink-ccp.rules
SUBSYSTEM=="usb", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="374b", \
  GROUP="ccpd", MODE="0660"

# 创建 ccpd 组，只把 daemon 放进去
$ sudo groupadd ccpd
$ sudo usermod -aG ccpd llw       # daemon 用户加入
$ 注意：不加 Hermes（即不加自己）#

# 生效
$ sudo udevadm control --reload-rules
$ sudo udevadm trigger
```

Hermes 调 openocd 时：
```
OpenOCD: Error: libusb_open() failed with LIBUSB_ERROR_ACCESS
OpenOCD: Error: unable to open CMSIS-DAP device
```

### 第二层：进程隔离

#### ManagedProcess 类

```python
import os, signal, subprocess, time, hashlib, json

class ManagedProcess:
    """
    管理子进程生命周期。每个进程 = 独立 process group + 日志文件 + PID 元信息。
    核心原则：只杀自己管理的，不碰其他进程的。
    """
    def __init__(self, name):
        self.name = name
        self.pid = None
        self.pgid = None
        self.start_time = None
        self.cmd_hash = None
        self.log_file = None
    
    def spawn(self, cmd_args, cwd=None, log_dir="/tmp/ccp_logs"):
        """启动进程到独立 process group"""
        os.makedirs(log_dir, exist_ok=True)
        ts = int(time.time())
        self.log_file = f"{log_dir}/{self.name}_{ts}.log"
        
        f = open(self.log_file, 'w')
        proc = subprocess.Popen(
            cmd_args,
            stdout=f, stderr=subprocess.STDOUT,
            cwd=cwd,
            preexec_fn=os.setsid  # 新会话 → 新 PG
        )
        self.pid = proc.pid
        self.pgid = proc.pid
        self.start_time = ts
        self.cmd_hash = hashlib.md5(' '.join(cmd_args).encode()).hexdigest()[:8]
        self._save_meta()
        return proc
    
    def _save_meta(self):
        """写 PID 元信息，防止 PID 复用误杀"""
        with open(f"/tmp/ccp_proc_{self.name}.json", 'w') as f:
            json.dump({
                "pid": self.pid, "pgid": self.pgid,
                "start_time": self.start_time, "cmd_hash": self.cmd_hash,
                "name": self.name, "log": self.log_file
            }, f)
    
    def kill(self):
        """精确 kill process group"""
        if not self._verify_pid():
            return False
        try:
            os.killpg(self.pgid, signal.SIGTERM)
            time.sleep(2)
            os.killpg(self.pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        self._cleanup()
        return True
    
    def _verify_pid(self):
        """PID 复用检测：校验 cmdline hash"""
        try:
            meta = json.load(open(f"/tmp/ccp_proc_{self.name}.json"))
            cmdline = open(f"/proc/{self.pid}/cmdline").read().replace('\0', ' ')
            return hashlib.md5(cmdline.encode()).hexdigest()[:8] == meta.get("cmd_hash")
        except:
            return False
    
    def is_alive(self):
        if not self.pid: return False
        try:
            os.kill(self.pid, 0)
            return True
        except: return False

# 典型用法
openocd_proc = ManagedProcess("openocd")
openocd_proc.spawn(["openocd", "-f", "interface/stlink.cfg",
                     "-f", "target/stm32f7x.cfg",
                     "-c", "adapter speed 1000"],
                    log_dir="/tmp/ccp_logs")

cc_proc = ManagedProcess("claude_code")
cc_proc.spawn(
    ["claude", "code", "-p", "/goal 修复 SPI 驱动..."],
    cwd="/data/firmare/worktrees/attempt_001",
    log_dir="/tmp/ccp_logs"
)

# 精确 kill：只杀这个 CC，不碰其他会话的
cc_proc.kill()
```

#### 日志管理

- 全部 stdout/stderr → 日志文件，不 pipe 到主进程
- 日志路径：`/tmp/ccp_logs/{name}_{timestamp}.log`
- 轮转：Python logging RotatingFileHandler（10MB × 5）
- 避免 pipe buffer 写满导致进程阻塞

### 第三层：代码隔离

#### Git Worktree 工作流

```python
import subprocess, os

GOLDEN_REPO = "/data/firmare/pogo-apm-golden"  # 只读基准
WORKTREE_BASE = "/data/firmare/worktrees"
PATCH_ARCHIVE = "/tmp/ccp_patches"

class CodeIsolation:
    def prepare(self, attempt_id, description):
        """创建独立 worktree"""
        os.makedirs(WORKTREE_BASE, exist_ok=True)
        os.makedirs(PATCH_ARCHIVE, exist_ok=True)
        
        baseline = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=GOLDEN_REPO, capture_output=True, text=True
        ).stdout.strip()
        
        branch = f"ccp-fix/{attempt_id}"
        worktree = f"{WORKTREE_BASE}/{attempt_id}"
        
        subprocess.run(["git", "branch", branch, baseline],
                       cwd=GOLDEN_REPO, check=True)
        subprocess.run(["git", "worktree", "add", worktree, branch],
                       cwd=GOLDEN_REPO, check=True)
        
        return {"attempt_id": attempt_id, "baseline": baseline,
                "branch": branch, "worktree_path": worktree,
                "description": description}
    
    def discard(self, ctx):
        """失败：丢弃整个 worktree"""
        subprocess.run(["git", "worktree", "remove", ctx["worktree_path"]],
                       cwd=GOLDEN_REPO, capture_output=True)
        subprocess.run(["git", "branch", "-D", ctx["branch"]],
                       cwd=GOLDEN_REPO, capture_output=True)
        subprocess.run(["rm", "-rf", ctx["worktree_path"]])
    
    def accept(self, ctx):
        """成功：归档 diff → merge → 清理"""
        diff = subprocess.run(
            ["git", "diff", ctx["baseline"], ctx["branch"]],
            cwd=GOLDEN_REPO, capture_output=True, text=True
        ).stdout
        patch_path = f"{PATCH_ARCHIVE}/patch_{ctx['attempt_id']}.diff"
        with open(patch_path, 'w') as f:
            f.write(diff)
        
        subprocess.run(
            ["git", "merge", ctx["branch"], "--no-ff",
             "-m", f"ccp: {ctx['description'][:80]}"],
            cwd=GOLDEN_REPO, check=True)
        self.discard(ctx)
        return patch_path
```

### 合成主循环

```python
class CCPDaemon:
    def __init__(self):
        self.sm = StateMachine()          # SQLite
        self.ci = CodeIsolation()         # git worktree
        self.openocd = ManagedProcess("openocd")
        self.cc = ManagedProcess("claude_code")
        self.scons = ManagedProcess("scons")
    
    def tick(self):
        """每分钟 cron 触发，但实际每 5 分钟工作一次"""
        # 1. 崩溃恢复检查
        pending = self.sm.get_latest_attempt()
        if pending and pending["state"] in ("fixing", "building", "flashing"):
            self._recover(pending)
            return
        
        # 2. 探针
        state = self._probe()
        last = self.sm.get_last_probe_result()
        
        if state == last:
            return  # 状态不变，等下一轮
        
        self._notify_state_change(state, last)
        
        if state["is_alive"]:
            self._on_alive()
        else:
            self._on_stuck(state)
    
    def _on_stuck(self, state):
        """固件卡死 → 诊断 → 修复"""
        diagnosis = self._diagnose(state)
        
        # 检查同一问题的重试次数
        retries = self.sm.get_retry_count(diagnosis["type"])
        if retries >= 3:
            self._escalate(diagnosis)
            return
        
        # 准备 worktree
        attempt_id = self.sm.create_attempt(diagnosis, ...)
        ctx = self.ci.prepare(attempt_id, diagnosis["description"])
        
        # 写 goal 文件
        goal = self._build_goal(diagnosis, ctx)
        
        # spawn CC
        self.sm.transition(attempt_id, "fixing", goal_text=goal)
        self.cc.spawn(
            ["claude", "code", "-p", goal],
            cwd=ctx["worktree_path"]
        )
    
    def _on_alive(self):
        """固件活了 → 检查有没有 CC 在跑 → 有则停"""
        if self.cc.is_alive():
            self.cc.kill()  # 目标达成
    
    def _recover(self, pending):
        """daemon 崩溃后恢复"""
        if pending["state"] == "fixing":
            if self.cc.is_alive():
                return  # CC 还在跑，继续等
            # CC 死了，重新 spawn
            self.cc.spawn(["claude", "code", "-p", pending["goal_text"]],
                          cwd=pending["worktree_path"])
        
        elif pending["state"] in ("building", "flashing"):
            self._do_build(pending["worktree_path"])
    
    def _probe(self):
        """完整探针"""
        # OpenOCD 启动（如未启动）
        if not self.openocd.is_alive():
            self.openocd.spawn([...])
            time.sleep(2)
        
        # 读调试变量
        s = self._openocd_read32(0x2001b2c8)
        m = self._openocd_read32(0x20018fb4)
        f = self._openocd_read32(0x20018fa8)
        h = self._openocd_read32(0xE000ED2C)
        c = self._openocd_read32(0xE000ED28)
        
        return {"setup_stage": s, "main_loop_iters": m,
                "fast_loop_count": f, "hfsr": h, "cfsr": c,
                "is_alive": m > 0}
    
    def _do_build(self, worktree_path):
        """编译 → 烧录 → 验证"""
        # scons
        result = self.scons.spawn(
            ["scons", "--v=ArduCopter", "--target=cuav_v5", "-j8"],
            cwd=worktree_path
        )
        result.wait(timeout=600)
        
        if result.returncode != 0:
            return self._on_build_fail()
        
        # openocd burn
        bin_path = f"{worktree_path}/build/rtt_cuav_v5/rtthread.bin"
        result = self._openocd_burn(bin_path)
        
        if result["status"] != "OK":
            return self._on_flash_fail()
        
        # verify
        time.sleep(30)  # 等跑起来
        state = self._probe()
        
        if state["is_alive"]:
            return self._on_verify_pass()
        else:
            return self._on_verify_fail()
```

## SQLite 持久化状态机

### Schema

```sql
CREATE TABLE attempts (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    state           TEXT NOT NULL DEFAULT 'created',
    -- created|probing|fixing|building|flashing|verifying|done|failed|escalated
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at      TEXT NOT NULL DEFAULT (datetime('now')),
    
    diag_type       TEXT,   -- SPI_IMU_BLOCKED|HARDFAULT|INIT_BLOCKED|HEARTBEAT_GONE
    goal_text       TEXT,
    attempt_number  INTEGER DEFAULT 1,
    
    baseline_commit TEXT,
    branch_name     TEXT,
    worktree_path   TEXT,
    diff_path       TEXT,
    
    probe_before    TEXT,  -- JSON
    probe_after     TEXT,  -- JSON
    
    build_status    TEXT,  -- OK|FAIL|TIMEOUT
    flash_status    TEXT,  -- OK|FAIL
    verify_status   TEXT,  -- OK|FAIL
    
    cc_pid          INTEGER,
    cc_log_path     TEXT,
    cc_status       TEXT,
    
    retry_count     INTEGER DEFAULT 0,
    escalated       INTEGER DEFAULT 0,
    
    notified        INTEGER DEFAULT 0
);

CREATE INDEX idx_attempts_state ON attempts(state);
CREATE INDEX idx_attempts_diag ON attempts(diag_type, created_at);
```

### 状态转换图

```
created
  ↓
probing ←── 正常／无变化 ──→ probing (5分钟后)
  ↓ 状态变化且固件卡死
fixing (spawn CC + /goal)
  ↓ CC 退出
building (scons compile)
  ↓┐ 编译失败 → 重试（最多3次）
  ↓└ 3次全跪 → escalated
flashing (openocd program + verify)
  ↓┐ 烧录失败 → 重试
  ↓└ 3次全跪 → escalated
verifying (probe after)
  ↓┐ main_loop=0 → 回到 fixing（重试）
  ↓└ 3次全跪 → escalated
done ✅
```

### 恢复机制

daemon 重启后：

```python
def recover():
    sm = StateMachine()
    latest = sm.get_latest_attempt()
    if not latest:
        return  # 正常 probe
    
    if latest["state"] == "fixing" and not is_cc_alive():
        # daemon 崩溃后 CC 也死了 → 重新 spawn
        spawn_cc_with_goal(latest["goal_text"], latest["worktree_path"])
    
    elif latest["state"] in ("building", "flashing"):
        # daemon 正在编译/烧录时崩溃 → 重做
        do_build(latest["worktree_path"])
```

## 硬件操作命令集

### scons 编译

```python
def scons_compile(worktree_path):
    """编译固件, 10 分钟超时"""
    proc = ManagedProcess("scons")
    proc.spawn(
        ["scons", "--v=ArduCopter", "--target=cuav_v5", f"-j{os.cpu_count()}"],
        cwd=worktree_path
    )
    
    # 等完成（10 分钟超时）
    import time
    t0 = time.time()
    while proc.is_alive():
        if time.time() - t0 > 600:
            proc.kill()
            return {"status": "TIMEOUT"}
        time.sleep(5)
    
    # 读日志尾部判断
    with open(proc.log_file) as f:
        log = f.read()
    
    if "error:" in log.lower():
        errors = [l for l in log.split('\n') if 'error:' in l.lower()]
        return {"status": "FAIL", "errors": errors[:5]}
    
    bin_path = f"{worktree_path}/build/rtt_cuav_v5/rtthread.bin"
    if os.path.exists(bin_path) and os.path.getsize(bin_path) > 0:
        return {"status": "OK", "bin": bin_path,
                "size_kb": f"{os.path.getsize(bin_path)/1024:.1f}"}
    
    return {"status": "FAIL", "errors": ["bin not found"]}
```

### OpenOCD 烧录

```python
def openocd_burn(bin_path, addr="0x08008000"):
    """烧录固件到 Flash"""
    proc = ManagedProcess("openocd_burn")
    # 通过 telnet 发送 program 命令
    # OpenOCD 必须已经在后台运行（由 ManagedProcess("openocd") 管理）
    
    import socket
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(120)
        s.connect(("localhost", 4444))
        s.sendall(f"program {bin_path} {addr}\n".encode())
        time.sleep(0.5)
        
        data = b""
        while True:
            try:
                chunk = s.recv(4096)
                if not chunk: break
                data += chunk
                if b"verified" in chunk.lower() or b"error" in chunk.lower():
                    break
            except socket.timeout: break
        s.close()
        
        output = data.decode(errors='replace')
        if "verified" in output.lower():
            return {"status": "OK"}
        return {"status": "FAIL", "detail": output[:200]}
    except Exception as e:
        return {"status": "ERR", "detail": str(e)}
```

### OpenOCD 读内存（探针）

```python
def openocd_read32(addr):
    """通过 OpenOCD telnet 读 32 位内存"""
    import socket
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect(("localhost", 4444))
        s.sendall(f"mdw {addr} 1\n".encode())
        time.sleep(0.3)
        data = s.recv(1024).decode(errors='replace')
        s.close()
        
        for line in data.split('\n'):
            if hex(addr).lower() in line.lower():
                parts = line.split(':')
                if len(parts) > 1:
                    return int(parts[1].strip(), 16)
        return None
    except Exception as e:
        return f"ERR:{e}"
```

### MAVLink 心跳

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
            return {"status": "OK",
                    "type": msg.type, "autopilot": msg.autopilot}
        return {"status": "NO_HEARTBEAT"}
    except Exception as e:
        return {"status": "ERR", "detail": str(e)}
```

## /goal 模板集成 claude-goal

### 通用模板

```
/goal {客观目标}

当前现象:
  - OpenOCD: setup_stage={N}, main_loop={M}, HFSR={h}, CFSR={c}
  - MAVLink: {心跳状态}
  - 上次改动: {git diff 摘要}
  - 工作区: {worktree_path}

Scope:
  - {文件路径白名单}

完工标准 (Done when):
  - main_loop_iterations > 0 (OpenOCD 0x20018fb4)
  - fast_loop_count > 0 (OpenOCD 0x20018fa8)
  - MAVLink HEARTBEAT 持续收到 (ttyACM1)

停止条件 (Stop if):
  - 3 次验证后 main_loop 仍为 0
  - 需要硬件物理操作

约束:
  - 你只能修改: libraries/AP_HAL_RTT/ 下的文件
  - 不能修改: hwdef, bootloader, 系统时钟, modules/
  - 每次改完后 daemon 会自动编译+烧录+验证
  - 不需要你自己调 OpenOCD/scons/烧录
  - 先读 ChibiOS 参考: libraries/AP_HAL_ChibiOS/
  - 失败不会丢失你的改动（patch 已归档）
```

## 自愈机制

| 层级 | 触发 | 操作 | 耗时 |
|------|------|------|------|
| L0 | 状态正常 | idle，等下一轮 tick | 0 |
| L1 Retry | CC 进程退出且编译失败 | 从 SQLite 读 goal 重新 spawn CC | 5 分钟 |
| L2 Restart | L1 3 次失败 | 重启 OpenOCD 实例 + 重试 | 10 分钟 |
| L3 Escalate | L2 3 次失败 | 放弃 worktree → 写 pending → 飞书通知 Hermes | 无限 |

## 通知协议

| 类型 | 示例 |
|------|------|
| daemon 上线 | "🟢 CCP daemon v3 上线，5 分钟 tick 开始" |
| 固件活了 | "🟢 main_loop={N} fast_loop={M}" |
| 固件死了 | "🔴 main_loop 从 {N} 降到 0，诊断中" |
| 派 CC | "🔧 派 CC 修 {diag_type} attempt #{N}" |
| CC 卡死 | "⚠️ CC 15 分钟无进展，杀掉重来 (attempt #{N})" |
| 编译失败 | "❌ 编译失败: {top_error}" |
| 烧录失败 | "❌ 烧录失败: {detail}" |
| 需 Hermes | "⛔ attempt #{N} 3 次失败，已归档到 /tmp/ccp_patches/patch_{N}.diff" |
| 超时催 | "⏰ Hermes 30 分钟无回应" |
| 暂停 | "🛑 90 分钟无回应，已暂停" |

只通知状态变化，不刷屏。

## daemon 保活

```bash
# crontab -e:
* * * * * flock -n /tmp/ccp_daemon.lock \
  /home/llw/.hermes/scripts/ccp_daemon.py --tick \
  >> /tmp/ccp_daemon.log 2>&1
```

- `flock -n` 文件锁防并发
- 每分钟 cron 触发，但 daemon 内部状态检查决定是否干活
- 崩溃后 1 分钟内 cron 重新拉起
- SQLite WAL 保证崩溃不丢状态

## daemon 生命周期

```
daemon 脚本逻辑（用伪代码表达整体结构）：

def main():
    # 1. 取文件锁（flock -n），失败则退出
    lock = acquire_lock()
    if not lock: return
    
    # 2. 初始化
    sm = StateMachine()
    ci = CodeIsolation()
    openocd = ManagedProcess("openocd")
    
    # 3. 检查未完成的 attempt（崩溃恢复）
    pending = sm.get_latest_attempt()
    if pending and pending.state in ("fixing","building","flashing"):
        if pending.state == "fixing":
            if is_cc_alive(): return  # CC 还在跑
            # CC 死了，重新 spawn
            cc_spawn(pending.goal_text, pending.worktree_path)
            return
        else:  # building/flashing
            do_build(pending.worktree_path)
            return
    
    # 4. 正常 probe
    if not openocd.is_alive():
        openocd.spawn([...])
        time.sleep(2)
    
    state = probe_board()
    last = sm.get_last_state()
    
    # 5. 状态变更 → 通知
    if state != last:
        notify_feishu(state)
    
    # 6. 决策
    if state.is_alive:
        if is_cc_alive(): cc_kill()
        return  # 一切正常
    
    # 7. 固件卡死 → 诊断
    diag = diagnose(state)
    retries = sm.get_retry_count(diag.type)
    
    if retries >= 3:
        escalate(diag)
        return
    
    # 8. 创建 attempt
    attempt_id = sm.create(diag)
    ctx = ci.prepare(attempt_id, diag.description)
    goal = build_goal(diag, ctx, state)
    
    sm.transition(attempt_id, "fixing", goal_text=goal)
    cc_spawn(goal, ctx.worktree_path)
```

## 边界条件

| 场景 | 处理 |
|------|------|
| ST-Link 未插入 | openocd 启动失败 → log → 下一 tick 再试 |
| ST-Link 物理断开 | openocd read 超时 → kill → 重启 → 失败 → 下一 tick |
| scons 卡死 10 分钟 | ManagedProcess kill → L1 Retry |
| 烧录时断电 | 下一 tick probe 不到 → 重新烧录 |
| 飞书 API 限流 | 写日志，下轮重试 |
| 磁盘满 | daemon 启动时检查磁盘空间（<1GB 报警） |
| claude-goal DB 损坏 | 删 ~/.claude/goal/goals.sqlite → 重装 |
| CC 装了坏 skill | 杀掉 CC → 清理 ~/.claude/skills/ → 重试 |
| PID 文件被误删 | ManagedProcess._verify_pid() 失败 → 通过 cmdline 确认 |
| git worktree 冲突 | 丢弃旧 worktree → 重新创建 |
| golden repo 被污染 | git stash → 从 origin 重新拉 |