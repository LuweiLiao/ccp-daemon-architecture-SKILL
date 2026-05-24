---
name: "ccp-daemon-architecture"
description: "CCP Daemon (Continuous Closed Probe) — 24/7 自治流水线架构 v5（1594行）。三用户隔离 + CC done marker + ManagedProcess 跨 tick 恢复 + /proc/pid/stat starttime 校验 + diff 白名单 + L1-L4 功能验证 + 资源监护(磁盘/内存/uptime/日志/USB/OpenOCD/zombie) + 自动回归(快照+偏差检测+连续退化升级)。"
---

# CCP Daemon — 24/7 自治循环流水线 v5

## 版本历史

| 版本 | 变更 |
|------|------|
| v1 | 初始架构：三体（Hermes+daemon+CC） |
| v2 | 混合架构：/goal 集成 + 具体硬件命令 |
| v3 | 三层隔离（权限/进程/代码）+ SQLite + 精确进程管理 |
|| **v5 (当前)** | **v4 + L1-L4 功能验证（MAVLink 消息级）+ 资源监护（磁盘/内存/时间）+ 自动回归（快照对比、偏差检测）** |
| **v6 (规划)** | v5 + ccrunner OS 级命令限制（wrapper PATH 加固）+ done marker HMAC 防伪校验 + 全天候 72h 无人值守 |

## 设计原则

```
1. 安全边界 = 三用户隔离（hermes/ccpd/ccrunner）, 不同用户有不同设备权限
2. CC 只改 worktree 内代码, daemon 检查 diff 白名单
3. 每个子进程 = 独立 process group, 精确 kill, 跨 tick 恢复
4. 每次修复 = 独立 git worktree, 失败丢弃, 成功保留
5. 状态持久化 = SQLite WAL, 崩溃读最新 attempt 恢复
6. 3 层隔离: 权限隔离 > 进程隔离 > 代码隔离
7. CC 完成任务后写 done marker, daemon 检测到后才进入 build
| 8. daemon 是传感器桥接层, CC 是推理器, Hermes 是 L3 兜底
| 9. 验证分 4 级: L1(调度器) < L2(心跳) < L3(传感器) < L4(功能完整, 4 轮无退化)
| 10. 资源监护: 磁盘/内存/时间/日志/文件异常 — 所有子进程的笼子
| 11. 自动回归: 每 30 分钟快照, 比较偏差, 发现退化立即告警
```

## 四体架构

```
┌──────────────────────────────────────────────────────────────────┐
│                                                                   │
│  🧠 Hermes Agent (大脑) — 用户 hermes                                          │
│  角色: 设计 daemon、兜底分析疑难杂症、出方案                       │
│  权限: 无 stlink 设备访问（用户 hermes 不在 ccpd 组）              │
│  激活: 仅 daemon 报 "3 次全跪" 时介入（文件握手）                 │
│                                                                   │
│  ⚙️ CCP Daemon (orchestrator + 传感器桥接) — 用户 ccpd            │
│  角色: Python 脚本常驻后台每 5 分钟 tick                          │
│  权限: ccpd 组 → ST-Link rw + 源码 golden repo r + worktree rw    │
│  能力: subprocess(os.setsid) 调 scons/OpenOCD/pymavlink/git      │
│  限制: 所有子进程=独立 PG, 精确 kill, 不依赖 Hermes               │
│  状态: SQLite WAL 持久化, 崩溃可恢复                              │
│                                                                   │
│  🖐️ Claude Code CLI + /goal (持久执行者) — 用户 ccrunner          │
│  角色: 通过 /goal 持久目标连续工作                                │
│  权限: 无 stlink 设备访问（用户 ccrunner 不在 ccpd 组）           │
│  能力: 读 daemon 写的状态文件 + 读日志 + 改 worktree 代码 + git   │
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

| 组件 | Linux 用户 | 系统组 | 设备权限 | 文件系统 | 可执行命令 |
|------|-----------|--------|---------|---------|-----------|
| 🧠 Hermes Agent | `hermes`（或 `llw`） | `hermes` | 无 ST-Link 设备 | 源码 golden repo 只读 | 任意（但无设备权限） |
| ⚙️ CCP Daemon | `ccpd` | `ccpd` | ST-Link USB rw（udev → ccpd 组独占） | golden repo r + worktree rw + 日志 rw | scons, openocd, python3, git, cp, rm |
| 🖐️ Claude Code | `ccrunner` | `ccrunner` | 无 ST-Link 设备 | worktree rw（当前 attempt）+ golden repo 只读 | git, python3, cat, grep（禁止 scons/openocd） |

### 用户隔离实现

```bash
# 1. 创建 3 个用户
sudo useradd -m -G hermes hermes     # 或直接用 llw
sudo useradd -m -G ccpd ccpd
sudo useradd -m -G ccrunner ccrunner

# 2. 用户组
sudo groupadd ccpd
sudo usermod -aG ccpd ccpd            # daemon 用户在 ccpd 组
# hermes 和 ccrunner 不在 ccpd 组 ← 硬边界

# 3. ST-Link udev 规则
cat /etc/udev/rules.d/99-stlink-ccp.rules
SUBSYSTEM=="usb", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="374b", \
  GROUP="ccpd", MODE="0660"

# 4. 文件权限
chown -R ccpd:ccpd /data/firmare/pogo-apm-golden
chmod 750 /data/firmare/pogo-apm-golden          # hermes/ccrunner 不可写
chmod 750 /data/firmare/worktrees                 # daemon 管理
chmod -R 755 /tmp/ccp_logs                        # 所有用户可读

# 5. CC 以 ccrunner 身份运行
# daemon 通过 sudo -u ccrunner claude code ... 启动 CC
# 或者 daemon 自身以 ccpd 身份运行（systemd User=ccpd）
```

### 为什么不用 bash 门禁

v1/v2 的 bash 门禁方案有根本性缺陷：

| 绕过方式 | 能防吗 |
|----------|--------|
| Hermes 用 `/usr/bin/openocd` 完整路径 | ❌ bash 函数只覆盖裸命令 |
| Hermes 用 Python `subprocess.run("openocd")` | ❌ subprocess 不走 bash |
| Hermes 在非交互 shell 中执行 | ❌ .bashrc 不加载 |
| Hermes 改 PATH 把恶意脚本放前面 | ❌ 任意绕过 |
| Hermes 用 `env -i bash -c openocd` | ❌ 环境隔离 |

### 为什么不用 bash 门禁

v1/v2 的 bash 门禁方案有根本性缺陷：

| 绕过方式 | 能防吗 |
|----------|--------|
| Hermes 用 `/usr/bin/openocd` 完整路径 | ❌ bash 函数只覆盖裸命令 |
| Hermes 用 Python `subprocess.run("openocd")` | ❌ subprocess 不走 bash |
| Hermes 在非交互 shell 中执行 | ❌ .bashrc 不加载 |
| Hermes 改 PATH 把恶意脚本放前面 | ❌ 任意绕过 |
| Hermes 用 `env -i bash -c openocd` | ❌ 环境隔离 |

**三用户模型才是真正边界**：
- udev 规则让 ST-Link 设备只向 `ccpd` 组开放
- 用户 `hermes` 和 `ccrunner` 不在 `ccpd` 组
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
    管理子进程生命周期。每个进程 = 独立 process group。
    
    跨 tick 恢复：__init__ 时尝试从 JSON 文件加载之前启动的进程信息，
    避免每个 tick 都重新启动 OpenOCD。
    
    PID 复用检测：使用 /proc/PID/stat 中的 starttime（自系统启动以来的 jiffies），
    比 cmdline hash 更可靠（不受 cmdline 格式差异影响）。
    """
    def __init__(self, name):
        self.name = name
        self.pid = None
        self.pgid = None
        self.start_time_jiffies = None  # /proc/pid/stat[22], 系统启动后的 jiffies
        self.log_file = None
        self._attempt_recovery()  # 跨 tick 恢复
    
    def _attempt_recovery(self):
        """从 JSON 文件恢复进程信息（跨 tick/重启）"""
        meta_path = f"/tmp/ccp_proc_{self.name}.json"
        try:
            meta = json.load(open(meta_path))
            pid = meta.get("pid")
            if pid and self._check_pid_starttime(pid, meta.get("start_time_jiffies")):
                self.pid = pid
                self.pgid = meta.get("pgid")
                self.start_time_jiffies = meta.get("start_time_jiffies")
                self.log_file = meta.get("log")
                # 进程还活着
        except:
            pass
    
    def _check_pid_starttime(self, pid, expected_jiffies):
        """
        核心 PID 复用检测。
        比较 /proc/PID/stat[22]（process starttime in jiffies）与预期的值。
        如果 PID 被内核回收后重新分配，新的进程一定有更大的 starttime。
        """
        if pid is None or expected_jiffies is None:
            return False
        try:
            stat = open(f"/proc/{pid}/stat").read()
            # stat[22] = starttime (第 22 个字段, 0-indexed = 21)
            fields = stat.split(')')
            if len(fields) < 2:
                return False
            rest = fields[1].strip()
            parts = rest.split()
            if len(parts) < 20:
                return False
            actual_jiffies = int(parts[19])  # starttime = 第 20 个空格分隔字段
            return actual_jiffies == expected_jiffies
        except:
            return False
    
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
        self.start_time_jiffies = self._read_starttime(proc.pid)
        self._save_meta()
        return proc
    
    def _read_starttime(self, pid):
        """读取进程的 /proc/pid/stat starttime"""
        try:
            stat = open(f"/proc/{pid}/stat").read()
            fields = stat.split(')')
            rest = fields[1].strip().split()
            return int(rest[19])  # starttime = 第 20 个字段
        except:
            return int(time.time())  # fallback: 不精确但不会误杀
    
    def _save_meta(self):
        """写 PID 元信息"""
        with open(f"/tmp/ccp_proc_{self.name}.json", 'w') as f:
            json.dump({
                "pid": self.pid, "pgid": self.pgid,
                "start_time_jiffies": self.start_time_jiffies,
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
        """PID 复用检测：/proc/pid/stat starttime 双重校验"""
        try:
            meta = json.load(open(f"/tmp/ccp_proc_{self.name}.json"))
            return self._check_pid_starttime(
                meta.get("pid"), meta.get("start_time_jiffies")
            )
        except:
            return False
    
    def is_alive(self):
        """检查进程是否活着。支持跨 tick（pid=None 时尝试 JSON 恢复）"""
        if self.pid is None:
            self._attempt_recovery()
        if self.pid is None:
            return False
        if not self._verify_pid():
            self.pid = None
            return False
        try:
            os.kill(self.pid, 0)
            return True
        except:
            self.pid = None
            return False
    
    def _cleanup(self):
        for p in [f"/tmp/ccp_proc_{self.name}.json"]:
            try: os.remove(p)
            except: pass

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

### CC Done Marker 协议

```
CC 完成代码修改后，必须写 marker 文件表示"我干完了"，
daemon 才能进入 build 阶段。

文件: /tmp/ccp_attempt_{attempt_id}_done
格式: JSON

{
  "attempt_id": 42,
  "cc_status": "DONE",
  "completion_note": "修改了 SPIDevice.cpp CR2 配置",
  "modified_files": ["libraries/AP_HAL_RTT/SPIDevice.cpp"]
}

daemon 每次 tick 检测:
  - CC 活着 → 等
  - CC 死了 + done marker 存在 → transition to building
  - CC 死了 + done marker 不存在 → CC 异常退出 → respawn

CC 的 /goal 末尾显式要求:
  "完成任务后写 marker: python3 -c '
   import json; open(\"/tmp/ccp_attempt_{id}_done\",\"w\").write(json.dumps(...))'"
```

## L1-L4 功能验证层级

在 main_loop_iterations > 0 基础上，逐级验证功能完整性。

| 层级 | 验证内容 | 方法 | 通过标准 | 失败后 |
|------|---------|------|---------|--------|
| L1 | 调度器存活 | OpenOCD 读 main_loop_iterations | > 0 | 创建 attempt |
| L2 | MAVLink 心跳 | pymavlink wait_heartbeat | 15s 内收到 HEARTBEAT | L1.5：跳过 CC 直接重烧 |
| L3 | 传感器数据 | MAVLink RAW_IMU / SYS_STATUS 消息 | 3 条有效 IMU 数据 | 创建 attempt |
| L4 | 功能完整 | 4 轮 L1-L3 全通过且值无退化 | 3/4 轮通过 | L3 escalate → Hermes |

```python
import pymavlink.dialects.v20.ardupilotmega as dialect
from pymavlink import mavutil
import time, os, json, socket

class FunctionalVerifier:
    """
    多层级功能验证。
    
    每轮 tick 逐级做：
      L1 调度器存活 → L2 MAVLink 心跳 → L3 传感器数据 → L4 稳定性
      
    如果 L1 卡死直接创建 CC attempt。
    如果 L1 通过但 L2 卡死 → L1.5：跳过 CC 直接重烧（可能是静默崩溃）。
    如果 L2 通过但 L3 失败 → 传感器驱动问题 → 派 CC。
    如果 L1-L3 都通过 → L4 检查连续 4 轮快照无退化。
    """

    def verify_all(self, state):
        """逐级验证，返回完整的验证树"""
        result = {"l1": {}, "l2": {}, "l3": {}, "l4": {}, "decisions": []}

        # ═══ L1: 调度器存活 ═══
        iterations = state.get("main_loop_iterations", 0)
        result["l1"] = {
            "pass": iterations > 0,
            "iterations": iterations,
        }
        if not result["l1"]["pass"]:
            result["decisions"].append("CREATE_ATTEMPT")
            return result

        # ═══ L2: MAVLink 心跳 ═══
        try:
            master = mavutil.mavlink_connection(
                "/dev/ttyACM1", baud=921600,
                dialect=dialect, timeout=15
            )
            msg = master.wait_heartbeat(timeout=13)
            has_beat = msg is not None
            payload = {}
            if has_beat:
                payload = {"type": msg.type, "autopilot": msg.autopilot}
                master.close()
            result["l2"] = {"pass": has_beat, **payload}
        except Exception as e:
            result["l2"] = {"pass": False, "error": str(e)}

        if not result["l2"]["pass"]:
            result["decisions"].append("L1_5_REBURN")
            return result

        # ═══ L3: 传感器数据 ═══
        try:
            master = mavutil.mavlink_connection(
                "/dev/ttyACM1", baud=921600,
                dialect=dialect, timeout=20
            )
            raw_imus = []
            for _ in range(5):
                msg = master.recv_match(
                    type='RAW_IMU', blocking=True, timeout=4
                )
                if msg:
                    raw_imus.append({
                        "xacc": msg.xacc, "yacc": msg.yacc,
                        "zacc": msg.zacc, "temp": msg.temperature
                    })
                    if len(raw_imus) >= 3:
                        break
            master.close()

            imu_valid = len(raw_imus) >= 3
            result["l3"] = {
                "pass": imu_valid,
                "imu_count": len(raw_imus),
                "samples": raw_imus[:2],  # 只存前 2 条
            }
        except Exception as e:
            result["l3"] = {"pass": False, "error": str(e)}

        if not result["l3"]["pass"]:
            result["decisions"].append("CREATE_ATTEMPT")
            return result

        # ═══ L4: 功能完整（4 轮无退化） ═══
        history = state.get("l4_history", [])
        current_round = {
            "l1_pass": result["l1"]["pass"],
            "l2_pass": result["l2"]["pass"],
            "l3_pass": result["l3"]["pass"],
            "iterations": iterations,
            "timestamp": time.time(),
        }
        history.append(current_round)
        if len(history) < 4:
            result["l4"] = {
                "pass": "IN_PROGRESS",
                "round": len(history),
                "need": 4,
            }
            state["l4_history"] = history
            return result

        passes = sum(1 for h in history for k in ["l1_pass","l2_pass","l3_pass"]
                     if h.get(k))
        stable = passes >= 9  # 4 轮 × 3 项 = 12, 9 = 75%
        result["l4"] = {
            "pass": stable,
            "total_checks": 12,
            "passes": passes,
            "degraded": not stable,
        }

        if stable:
            result["decisions"].append("ALL_OK")
        else:
            result["decisions"].append("L4_DEGRADED")
            state["l4_history"] = history[-3:]  # 保留最近 3 轮

        return result


## 资源监护

监控 daemon 运行环境和固件运行状态的资源使用情况。

| 监控项 | 检查频率 | 阈值 | 操作 |
|--------|---------|------|------|
| 磁盘可用 | 每 tick | < 1GB → CRITICAL | L3 Escalate |
| 内存占用 | 每 tick | > 80% → WARNING | 杀空闲子进程 |
| 系统运行时间 | 每 tick | > 6h → REBOOT | 自动 reboot |
| 日志膨胀 | 每 tick | > 500MB | 轮转压缩 + 清理 |
| worktree 异常 | 每 tick | > 20 个目录 或 异常增长 | 清理超过24h的失败attempt |
| USB CDC | 每 tick | /dev/ttyACM1 消失 | L1.5：重启 CDC 驱动 |
| OpenOCD 响应 | 每 tick | 3 次连续无响应 | kill → 重启 → 报警 |
| 子进程泄露 | 每 tick | 残留 zombie > 5 | 收割 zombie + 清理 |

```python
import shutil, glob, os, time

class ResourceGuardian:
    """
    每 tick 检查所有系统资源，确保 daemon 和固件运行环境健康。
    
    check_all() 返回 {"status": "OK"|"WARNING"|"CRITICAL", "details": {...}}
    CRITICAL → 跳过本轮 attempt 创建，直接报警
    WARNING → 自动修复（杀进程/清理/轮转），记录日志
    """

    def check_all(self):
        results = {}
        results["disk"] = self._check_disk()
        results["memory"] = self._check_memory()
        results["uptime"] = self._check_uptime()
        results["logs"] = self._check_logs()
        results["worktrees"] = self._check_worktrees()
        results["usb"] = self._check_usb()
        results["openocd"] = self._check_openocd()
        results["zombies"] = self._check_zombies()

        # 综合状态
        criticals = [k for k, v in results.items()
                     if v.get("status") == "CRITICAL"]
        warnings = [k for k, v in results.items()
                    if v.get("status") == "WARNING"]

        return {
            "status": "CRITICAL" if criticals
                      else "WARNING" if warnings
                      else "OK",
            "critical_items": criticals,
            "warning_items": warnings,
            **results,
        }

    def _check_disk(self):
        """磁盘可用空间 — < 1GB 抛 CRITICAL"""
        usage = shutil.disk_usage("/data")
        gb_free = usage.free / (1024**3)
        return {"status": "OK" if gb_free > 1 else "CRITICAL",
                "free_gb": round(gb_free, 1)}

    def _check_memory(self):
        """系统内存使用率 — > 80% 报警"""
        with open("/proc/meminfo") as f:
            mem = {}
            for line in f:
                k, v = line.split(":")
                mem[k.strip()] = int(v.strip().split()[0]) * 1024
        used = mem["MemTotal"] - mem["MemAvailable"]
        pct = used / mem["MemTotal"] * 100
        return {"status": "OK" if pct < 80 else "WARNING",
                "used_pct": round(pct, 1)}

    def _check_uptime(self):
        """系统运行时间 — > 6h 需要 reboot"""
        with open("/proc/uptime") as f:
            seconds = float(f.read().split()[0])
        hours = seconds / 3600
        return {"status": "REBOOT_NEEDED" if hours > 6 else "OK",
                "hours": round(hours, 1)}

    def _check_logs(self):
        """日志占用 — > 500MB 轮转"""
        total = sum(
            os.path.getsize(f)
            for f in glob.glob("/tmp/ccp_logs/*.log")
        )
        return {"status": "OK" if total < 500*1024**2 else "WARNING",
                "total_mb": round(total / 1024**2, 1)}

    def _check_worktrees(self):
        """worktree 目录异常增长"""
        wt = "/data/firmare/worktrees"
        if not os.path.exists(wt):
            return {"status": "OK", "count": 0}
        entries = os.listdir(wt)
        status = "OK" if len(entries) <= 20 else "WARNING"
        return {"status": status, "count": len(entries)}

    def _check_usb(self):
        """USB CDC 设备"""
        exists = os.path.exists("/dev/ttyACM1")
        return {"status": "OK" if exists else "WARNING",
                "device": "/dev/ttyACM1" if exists else None}

    def _check_openocd(self):
        """OpenOCD 响应 — 读一个已知地址"""
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(3)
            s.connect(("localhost", 4444))
            s.sendall(b"mdw 0x20018fb4 1\n")
            time.sleep(0.3)
            data = s.recv(1024)
            s.close()
            responded = len(data) > 0
            return {"status": "OK" if responded else "ERR",
                    "responded": responded}
        except Exception as e:
            return {"status": "ERR", "error": str(e)[:60]}

    def _check_zombies(self):
        """残留 zombie 进程"""
        try:
            zombies = 0
            for pid in os.listdir("/proc"):
                if not pid.isdigit():
                    continue
                try:
                    stat = open(f"/proc/{pid}/status").read()
                    if "Zombie" in stat and "State:\tZ (zombie)" in stat.split('\n')[2]:
                        zombies += 1
                except:
                    pass
            return {"status": "OK" if zombies <= 5 else "WARNING",
                    "zombie_count": zombies}
        except:
            return {"status": "OK", "zombie_count": 0}


## 自动回归

每 30 分钟拍一次运行状态快照，比较与上次的偏差。发现退化（main_loop 减半、心跳消失、IMU 丢失、磁盘异常收缩）立即告警，但不打断运行。

快照结构:
```json
{
  "timestamp": "2026-05-24T23:00:00Z",
  "l1": {"main_loop_iterations": 42, "fast_loop_count": 38},
  "l2": {"heartbeat": true, "type": 1, "autopilot": 3},
  "l3": {"imu_sensors": ["ICM42688"], "temp_c": 28.5},
  "openocd": {"setup_stage": 651, "HFSR": 0, "CFSR": 0},
  "resources": {"disk_gb": 42.3, "mem_pct": 35, "uptime_h": 3.2}
}
```

```python
from datetime import datetime

class AutoRegression:
    """
    每 30 分钟快照对比。
    
    退化类型：
    - MAIN_LOOP_DEGRADATION: main_loop_iterations 减半
    - HEARTBEAT_LOST: 之前有心跳现在没了
    - IMU_LOST: 之前有 IMU 数据现在没了
    - DISK_SHRINK: 磁盘可用空间骤降 > 1GB
    
    策略：发现退化 → 告警日志 → 继续运行观察下一轮，
    连续 3 次退化 → 升级为 attempt 创建。
    """

    def __init__(self):
        self.snapshot_dir = "/tmp/ccp_snapshots"
        os.makedirs(self.snapshot_dir, exist_ok=True)
        self.degradation_counter = {}

    def take_snapshot(self, state, openocd_vars):
        """拍一次运行时快照"""
        snapshot = {
            "timestamp": datetime.utcnow().isoformat(),
            "l1": {
                "main_loop_iterations": state.get("main_loop_iterations"),
                "fast_loop_count": state.get("fast_loop_count"),
            },
            "l2": {
                "heartbeat": state.get("heartbeat"),
                "type": state.get("heartbeat_type"),
            },
            "l3": {
                "imu_count": state.get("imu_count"),
                "last_imu": state.get("last_raw_imu"),
            },
            "resources": state.get("resources", {}),
            "openocd": openocd_vars,
        }
        path = f"{self.snapshot_dir}/snapshot_{int(time.time())}.json"
        with open(path, 'w') as f:
            json.dump(snapshot, f, indent=2)
        return snapshot

    def compare_with_last(self):
        """
        与最近一次快照比较，返回偏差列表。
        
        只保留最近 20 个快照（避免磁盘被快照占满）。
        """
        snapshots = sorted(glob.glob(f"{self.snapshot_dir}/snapshot_*.json"))

        # 清理超量快照
        while len(snapshots) > 20:
            os.remove(snapshots.pop(0))

        if len(snapshots) < 2:
            return {"status": "NEED_MORE", "count": len(snapshots)}

        with open(snapshots[-1]) as f:  last = json.load(f)
        with open(snapshots[-2]) as f:  prev = json.load(f)

        diffs = []

        # 1. main_loop 退化检测
        l1_last = last.get("l1", {})
        l1_prev = prev.get("l1", {})
        if l1_prev.get("main_loop_iterations") and l1_last.get("main_loop_iterations"):
            ratio = l1_last["main_loop_iterations"] / l1_prev["main_loop_iterations"]
            if ratio < 0.5:
                diffs.append({
                    "type": "MAIN_LOOP_DEGRADATION",
                    "severity": "WARNING",
                    "from": l1_prev["main_loop_iterations"],
                    "to": l1_last["main_loop_iterations"],
                    "ratio": round(ratio, 2),
                })

        # 2. 心跳消失
        l2_last = last.get("l2", {})
        l2_prev = prev.get("l2", {})
        if l2_prev.get("heartbeat") and not l2_last.get("heartbeat"):
            diffs.append({
                "type": "HEARTBEAT_LOST",
                "severity": "WARNING",
            })

        # 3. IMU 丢失
        l3_last = last.get("l3", {})
        l3_prev = prev.get("l3", {})
        if l3_prev.get("imu_count", 0) > 0 and l3_last.get("imu_count", 0) == 0:
            diffs.append({
                "type": "IMU_LOST",
                "severity": "CRITICAL",
                "from": l3_prev["imu_count"],
                "to": 0,
            })

        # 4. 磁盘异常收缩
        r_last = last.get("resources", {})
        r_prev = prev.get("resources", {})
        disk_diff = r_prev.get("disk_gb", 0) - r_last.get("disk_gb", 0)
        if disk_diff > 1:
            diffs.append({
                "type": "DISK_SHRINK",
                "severity": "WARNING",
                "from": r_prev.get("disk_gb"),
                "to": r_last.get("disk_gb"),
                "drop_gb": round(disk_diff, 1),
            })

        # 更新退化计数器
        for d in diffs:
            key = d["type"]
            self.degradation_counter[key] = self.degradation_counter.get(key, 0) + 1

        # 连续 3 次同类型退化 → 升级
        should_escalate = any(
            cnt >= 3 for cnt in self.degradation_counter.values()
        )

        return {
            "status": "CHANGED" if diffs else "STABLE",
            "diffs": diffs,
            "should_escalate": should_escalate,
            "degradation_counts": dict(self.degradation_counter),
        }


### 合成主循环

```python
import time, os, json

class CCPDaemon:
    def __init__(self):
        self.sm = StateMachine()
        self.ci = CodeIsolation()
        self.openocd = ManagedProcess("openocd")
        self.cc = ManagedProcess("claude_code")
        self.scons = ManagedProcess("scons")
        # v5 新增模块
        self.verifier = FunctionalVerifier()
        self.guardian = ResourceGuardian()
        self.regression = AutoRegression()
        self._tick_count = 0
    
    # ─── 主入口 ──────────────────────────────────
    
    def tick(self):
        """每分钟 cron 触发"""
        self._tick_count += 1

        # 0. 资源监护（每 tick 都跑）
        resources = self.guardian.check_all()
        if resources["status"] == "CRITICAL":
            self._notify_resources_critical(resources)
            return  # 跳过所有操作
        if resources["status"] == "WARNING":
            self._auto_fix_resources(resources)

        # 1. 自动回归快照（每 30 tick ≈ 30 分钟）
        if self._tick_count % 30 == 0:
            state_snapshot = self._probe()
            if state_snapshot:
                openocd_vars = self._read_openocd_vars(state_snapshot)
                self.regression.take_snapshot(state_snapshot, openocd_vars)
                rd = self.regression.compare_with_last()
                if rd["status"] == "CHANGED":
                    self._notify_regression(rd)

        pending = self.sm.get_latest_attempt()
        
        # 1. 如果有未完成的 attempt → 恢复或推进
        if pending and pending["state"] in ("fixing", "building", "flashing"):
            self._advance_attempt(pending)
            return
        
        # 2. 正常探针
        state = self._probe()
        if not state:  # OpenOCD 挂了
            return
        
        last = self.sm.get_last_state()
        if state == last:
            return  # 状态不变, 不动
        
        self._notify_state_change(state, last)
        self.sm.save_last_state(state)
        
        if state["is_alive"]:
            self._on_alive()
        else:
            self._on_stuck(state)
    
    # ─── attempt 推进（修复关键漏洞）───────────────
    
    def _advance_attempt(self, pending):
        """
        推进现有 attempt 到下一阶段。
        
        关键协议: CC 写 done marker 表示"干完了"，
        daemon 检测到后才进入 build。
        CC 异常退出（无 marker）→ respawn。
        """
        attempt_id = pending["id"]
        
        if pending["state"] == "fixing":
            cc_alive = self.cc.is_alive()
            done_marker = self._check_done_marker(attempt_id)
            
            if cc_alive and not done_marker:
                return  # CC 还在工作, 继续等
            elif not cc_alive and done_marker:
                # ✅ CC 干完了 → 进入 build
                self.sm.transition(attempt_id, "building")
                self._do_build(pending["worktree_path"], attempt_id)
            elif not cc_alive and not done_marker:
                # ❌ CC 异常退出 → respawn
                if self._should_retry(pending):
                    self.cc.spawn(
                        ["claude", "code", "-p", pending["goal_text"]],
                        cwd=pending["worktree_path"],
                        log_dir="/tmp/ccp_logs"
                    )
                    self._notify_cc_restart(attempt_id)
                else:
                    self._escalate_attempt(pending)
            # cc_alive and done_marker → CC 在干别的, 等它退出
        
        elif pending["state"] == "building":
            # scons 应该已经退出或超时
            if self.scons.is_alive():
                return  # 还在编译
            self._check_build_result(attempt_id)
        
        elif pending["state"] == "flashing":
            # OpenOCD 应该已经完成或超时
            self._verify_flash(attempt_id)
    
    def _check_done_marker(self, attempt_id):
        """检查 CC 是否写入了完成 marker"""
        marker_path = f"/tmp/ccp_attempt_{attempt_id}_done"
        try:
            with open(marker_path) as f:
                return json.load(f)
        except:
            return None
    
    # ─── 状态分支 ────────────────────────────────
    
    def _on_stuck(self, state):
        """固件卡死 → 诊断 → 创建新 attempt"""
        # 检查是否已有 fixing 中的 attempt（避免重复创建）
        existing = self.sm.get_latest_attempt()
        if existing and existing["state"] == "fixing":
            return  # 已经在修了
        
        diagnosis = self._diagnose(state)
        
        retries = self.sm.get_retry_count(diagnosis["type"])
        if retries >= 3:
            self._escalate(diagnosis)
            return
        
        # 创建 attempt
        attempt_id = self.sm.create_attempt(diagnosis)
        ctx = self.ci.prepare(attempt_id, diagnosis["description"])
        
        # 写 goal（末尾包含 done marker 指令）
        goal = self._build_goal(diagnosis, ctx, attempt_id)
        self.sm.transition(attempt_id, "fixing", goal_text=goal,
                           worktree_path=ctx["worktree_path"])
        
        # CC 以 ccrunner 身份运行
        self.cc.spawn(
            ["sudo", "-u", "ccrunner", "claude", "code", "-p", goal],
            cwd=ctx["worktree_path"]
        )
        self._notify_goal_started(diagnosis["type"], attempt_id)
    
    def _on_alive(self):
        """固件活了 — 用 L1-L4 验证判断真实状态"""
        # 获取当前 probe 状态并执行多级验证
        state = self._probe()
        if not state:
            return

        vr = self.verifier.verify_all(state)

        if vr["l1"]["pass"]:
            # L1 通过：记录运行状态
            self.sm.save_l1_alive(state, vr["l1"])
            # 自动回归快照
            openocd_vars = self._read_openocd_vars(state)
            self.regression.take_snapshot(state, openocd_vars)
            rd = self.regression.compare_with_last()
            if rd["status"] == "CHANGED":
                self._notify_regression(rd)

        decision = vr["decisions"][0] if vr["decisions"] else None

        if decision == "ALL_OK":
            # L1-L4 全通过
            if self.cc.is_alive():
                self.cc.kill()
            self.sm.close_completed_attempts()
            self._notify_l4_pass(vr["l4"])

        elif decision == "L4_DEGRADED":
            # L1-L3 通过但 L4 退化 — 记录不退，观察
            self._notify_l4_degraded(vr["l4"])

        elif decision == "L1_5_REBURN":
            # L1 通过但 L2 失败 — 可能是静默崩溃，直接重烧
            self._set_reburn_state()
            self._notify_l2_fail()

        # 其他决策（CREATE_ATTEMPT）由 _on_stuck 处理

    def _set_reburn_state(self):
        """标记为需要重烧状态（L1.5：跳过 CC，直接重烧最新固件）"""
        # 找到上一个成功的 bin
        attempt = self.sm.get_last_successful_attempt()
        if attempt and os.path.exists(attempt.get("bin_path", "")):
            self._do_flash(attempt["worktree_path"], attempt["id"])
            self._notify("L1.5 固件重置：重烧上个成功固件")
    
    # ─── 编译／烧录／验证 ─────────────────────────
    
    def _do_build(self, worktree_path, attempt_id):
        """编译 → 烧录 → 验证"""
        # 1. scons
        self.scons.spawn(
            ["scons", "--v=ArduCopter", "--target=cuav_v5", f"-j{os.cpu_count()}"],
            cwd=worktree_path
        )
        self.sm.save_build_start(attempt_id)
        
        # 等最多 10 分钟
        t0 = time.time()
        while self.scons.is_alive():
            if time.time() - t0 > 600:
                self.scons.kill()
                self._on_build_fail("TIMEOUT", attempt_id)
                return
            time.sleep(5)
        
        # 2. 检查结果
        if self._scons_succeeded(worktree_path):
            self.sm.transition(attempt_id, "flashing")
            self._do_flash(worktree_path, attempt_id)
        else:
            self._on_build_fail(self._read_build_errors(), attempt_id)
    
    def _do_flash(self, worktree_path, attempt_id):
        """烧录"""
        bin_path = f"{worktree_path}/build/rtt_cuav_v5/rtthread.bin"
        if not os.path.exists(bin_path):
            self._on_flash_fail("bin not found", attempt_id)
            return
        
        result = self._openocd_burn(bin_path)
        if result["status"] == "OK":
            self.sm.transition(attempt_id, "verifying")
            self._do_verify(attempt_id)
        else:
            self._on_flash_fail(result["detail"], attempt_id)
    
    def _do_verify(self, attempt_id):
        """验证 — 用 L1-L4 逐级确认"""
        time.sleep(30)  # 等固件启动
        state = self._probe()

        self.sm.save_probe_after(attempt_id, state)

        # L1-L4 验证
        vr = self.verifier.verify_all(state)
        self.sm.save_verification_result(attempt_id, vr)

        decision = vr["decisions"][0] if vr["decisions"] else None

        if decision == "ALL_OK":
            # L1-L4 全通过
            self.ci.accept(self.sm.get_attempt_ctx(attempt_id))
            self._mark_done(attempt_id)
            self._notify(f"✅ attempt #{attempt_id} L1-L4 全通过")

        elif decision == "L1_5_REBURN":
            # L1 通过但 L2 失败 → 重烧
            self._on_verify_fail(attempt_id, reason="L2_FAIL")

        elif vr["l1"]["pass"]:
            # L1 通过但不满足更高标准 → 部分成功，归档 patch 但标记警告
            self.ci.accept(self.sm.get_attempt_ctx(attempt_id))
            self.sm.transition(attempt_id, "done_warning")
            self._notify(f"⚠️ attempt #{attempt_id} L1 通过但 L2/L3 失败, 已归档")

        else:
            self._on_verify_fail(attempt_id, reason="L1_FAIL")
    
    def _mark_done(self, attempt_id):
        """attempt 成功完成"""
        self.sm.transition(attempt_id, "done")
        # 如果还有 CC 在跑, 停掉
        if self.cc.is_alive():
            self.cc.kill()
        self._notify_success(attempt_id)
    
    # ─── diff 白名单检查 ─────────────────────────
    
    WHITELIST_PREFIXES = [
        "libraries/AP_HAL_RTT/",
        "libraries/AP_HAL/",
    ]
    BLACKLIST = [
        "modules/", "Tools/bootloaders/",
        "libraries/AP_HAL_ChibiOS/",
    ]
    
    def _check_diff_whitelist(self, baseline, branch, worktree_path):
        """
        检查 CC 的修改是否在白名单内。
        如果改了黑名单文件 → 直接失败归档, 不编译。
        """
        diff = subprocess.run(
            ["git", "diff", baseline, branch, "--name-only"],
            cwd=self.GOLDEN_REPO, capture_output=True, text=True
        ).stdout.strip().split('\n')
        
        violations = [f for f in diff if f and any(
            f.startswith(b) for b in self.BLACKLIST
        )]
        if violations:
            return {"status": "BLACKLIST_VIOLATION",
                    "files": violations, "diff": diff}
        
        allowed = [f for f in diff if f and any(
            f.startswith(w) for w in self.WHITELIST_PREFIXES
        )]
        
        return {"status": "OK", "files": allowed, "diff": diff}
    
    # ─── 失败处理 ────────────────────────────────
    
    def _should_retry(self, pending):
        """判断是否应该重试"""
        return self.sm.get_retry_count(
            pending["diag_type"], window_minutes=60
        ) < 3
    
    def _escalate_attempt(self, pending):
        """L3 Escalate"""
        self.sm.transition(pending["id"], "escalated")
        # 归档 diff
        self.ci.discard(self.sm.get_attempt_ctx(pending["id"]))
        # 写 pending_analysis
        with open("/tmp/ccp_pending_analysis.json", 'w') as f:
            json.dump({
                "attempt_id": pending["id"],
                "diag_type": pending["diag_type"],
                "last_state": pending
            }, f)
        self._notify_escalate(pending)
```

## SQLite 持久化状态机

### Schema

```sql
CREATE TABLE attempts (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    state           TEXT NOT NULL DEFAULT 'created',
    -- created|probing|fixing|building|flashing|verifying|done|done_warning|failed|escalated
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
    
    -- v5: 多层级验证结果
    verify_status   TEXT,  -- L1_OK|L2_OK|L3_OK|L4_OK|FAIL
    verify_l1       TEXT,  -- JSON: {pass, iterations}
    verify_l2       TEXT,  -- JSON: {pass, type, autopilot}
    verify_l3       TEXT,  -- JSON: {pass, imu_count, samples}
    verify_l4       TEXT,  -- JSON: {pass, total_checks, passes}
    
    -- v5: 资源监护快照
    resource_snap   TEXT,  -- JSON: resources at time of attempt
    
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
  - L1: main_loop_iterations > 0 (OpenOCD 0x20018fb4)
  - L1: fast_loop_count > 0 (OpenOCD 0x20018fa8)
  - L2: MAVLink HEARTBEAT 持续收到 (ttyACM1, 921600)
  - L3: RAW_IMU 消息 ≥ 3 条 (xacc/yacc/zacc 非零)
  - L4: 连续 4 轮 L1-L3 全通过

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
| **L0** | 所有资源 OK + L4 通过 | idle，等下一轮 tick | 0 |
| **L0.5** | L1-L3 通过但 L4 退化 | 创建 auto-regression 告警，继续运行不 kill | 0 |
| **L1 Retry** | CC 进程退出且编译失败 | 从 SQLite 读 goal 重新 spawn CC | 5 分钟 |
| **L1.5** | L1 通过但 L2 失败（无心跳） | 跳过 CC，直接重烧固件 + 重置 | 2 分钟 |
| **L2 Restart** | L1 3 次失败 | 重启 OpenOCD 实例 + 重试 | 10 分钟 |
| **L2.5** | 资源监护告警（磁盘/内存/日志） | 杀空闲子进程 → 轮转日志 → 报警 | 1 分钟 |
| **L3 Escalate** | L2 3 次失败 | 放弃 worktree → 写 pending → 飞书通知 Hermes | 无限 |
| **L4 AutoReboot** | uptime > 6h | 自动 reboot 系统 | 2 分钟 |

## 通知协议

| 类型 | 示例 |
|------|------|
| daemon 上线 | "🟢 CCP daemon v5 上线，5 分钟 tick 开始" |
| 固件L1通过 | "🟢 main_loop={N} fast_loop={M}" |
| 固件L2通过 | "💚 MAVLink HEARTBEAT type={T} autopilot={A}" |
| 固件L3通过 | "📊 IMU {N} 条数据, {sensors}" |
| 固件L4通过 | "🏆 L4 稳定运行 {N} 轮无退化" |
| L4退化 | "⚠️ L4 退化: {passes}/{total} 通过" |
| 固件死了 | "🔴 main_loop 从 {N} 降到 0，诊断中" |
| L1.5重烧 | "🔥 L1通过但无心跳，直接重烧上个成功固件" |
| 派 CC | "🔧 派 CC 修 {diag_type} attempt #{N}" |
| CC 卡死 | "⚠️ CC 15 分钟无进展，杀掉重来 (attempt #{N})" |
| 编译失败 | "❌ 编译失败: {top_error}" |
| 编译通过 | "✅ 编译通过 ({size_kb}KB)" |
| 烧录失败 | "❌ 烧录失败: {detail}" |
| L1-L4 通过 | "✅ attempt #{N} L1-L4 全通过" |
| L1通过/L2失败 | "⚠️ attempt #{N} L1通过但L2/L3失败, 已归档" |
| 资源告警 | "📦 资源告警: {items} — {actions}" |
| 自动回归 | "📉 回归检测: {diffs}" |
| 需 Hermes | "⛔ attempt #{N} 3 次失败，已归档到 /tmp/ccp_patches/patch_{N}.diff" |
| 超时催 | "⏰ Hermes 30 分钟无回应" |
| 暂停 | "🛑 90 分钟无回应，已暂停" |

只通知状态变化，不刷屏。

## daemon 保活

## daemon 保活

```bash
# crontab -e:
* * * * * flock -n /tmp/ccp_daemon.lock \
  sudo -u ccpd /home/ccpd/.hermes/scripts/ccp_daemon.py --tick \
  >> /tmp/ccp_daemon.log 2>&1
```

- `flock -n` 文件锁防并发
- `sudo -u ccpd` 以 daemon 专用用户身份运行（确保 ST-Link 权限）
- 每分钟 cron 触发，但 daemon 内部状态检查决定是否干活
- 崩溃后 1 分钟内 cron 重新拉起
- SQLite WAL 保证崩溃不丢状态

> 📎 参考文件: `references/hardware-addresses.md` — CUAV V5 调试变量地址表
> 📎 参考文件: `references/openocd-workflow.md` — OpenOCD 操作速查

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
    
    # 4.5 资源监护（每 tick 都跑）
    guardian = ResourceGuardian()
    resources = guardian.check_all()
    if resources.status == "CRITICAL":
        notify_feishu(f"CRITICAL: {resources.critical_items}")
        return  # 不 probe 不诊断
    
    state = probe_board()
    last = sm.get_last_state()
    
    # 5. 状态变更 → L1-L4 验证 → 通知
    if state != last:
        verifier = FunctionalVerifier()
        vr = verifier.verify_all(state)
        notify_feishu_with_level(state, vr)
        sm.save_verification_snapshot(vr)
    
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
| 磁盘满 | ResourceGuardian CRITICAL → 跳过所有操作 → 飞书告警 |
| 内存 > 80% | ResourceGuardian WARNING → 杀空闲子进程 → 轮转日志 |
| 系统运行 > 6h | ResourceGuardian REBOOT_NEEDED → 自动 reboot |
| USB CDC 消失 | ResourceGuardian WARNING → L1.5 重烧策略 |
| 日志膨胀 > 500MB | ResourceGuardian WARNING → 轮转压缩 |
| worktree > 20 个 | ResourceGuardian WARNING → 清理超过 24h 的失败 attempt |
| zombie > 5 | ResourceGuardian WARNING → 收割僵尸进程 |
| L4 连续 3 次退化 | AutoRegression should_escalate → 创建 attempt |
| claude-goal DB 损坏 | 删 ~/.claude/goal/goals.sqlite → 重装 |
| CC 装了坏 skill | 杀掉 CC → 清理 ~/.claude/skills/ → 重试 |
| PID 文件被误删 | ManagedProcess._verify_pid() 失败 → 通过 cmdline 确认 |
| git worktree 冲突 | 丢弃旧 worktree → 重新创建 |
| golden repo 被污染 | git stash → 从 origin 重新拉 |