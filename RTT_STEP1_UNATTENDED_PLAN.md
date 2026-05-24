# RTT 移植完整无人值守架构方案

> **核心理念**：把 ChibiOS 的四个核心技术（系统时钟/启动文件/链接脚本/外设驱动）移植到 RTT，加上 `--board=xxx` 硬件定义机制，全部被 CCP daemon 自循环驱动，24h 自动迭代直到全部完成。
> 迭代过程中 kanban 员工并行执行，失败自动换方向。

---

## 一、架构总图

```
┌──────────────────────────────────────────────────────────────────┐
│              CCP Daemon 自循环引擎（纯 Python/shell，无 LLM）      │
│                                                                   │
│   四径探针 ──→ 规则诊断 ──→ dispatch ──→ wait ──→ 四径再验 ──→ loop│
│      ↑                                                  │        │
│      └─────────────── 直到四径全部正常 ──────────────────┘        │
└──────────────────────────┬───────────────────────────────────────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
              ▼            ▼            ▼
  ┌──────────────┐  ┌──────────┐  ┌──────────┐
  │ Claude Code  │  │Claude Code│  │Claude Code│  ← 只修代码
  │ (SPI修复)    │  │(USB修复)  │  │(启动文件)  │
  └──────────────┘  └──────────┘  └──────────┘
       │                │              │
       └────────────────┼──────────────┘
                        ▼
               ┌──────────────┐
               │Kanban (审计)  │   ← 只记日志，不决定谁干活
               └──────────────┘
                           │ 产出
                           ▼
┌──────────────────────────────────────────────────────────────────┐
│            ChibiOS 核心内容 → RTT（4 项核心技术）                  │
│                                                                   │
│  ① 系统时钟 (HSE→PLL→216MHz, CMSIS寄存器)                        │
│  ② 启动文件 (双栈PSP/MSP, FPU寄存器, 看门狗寄存器)                │
│  ③ 链接脚本 (DTCM/SRAM1分拆, .mstack 1KB + .pstack 1KB)          │
│  ④ 外设驱动全部寄存器化 (SPI/USB/UART/I2C/PWM/RCInput/GPIO/...)   │
│  + --board=xxx 硬件定义自动发现                                    │
└──────────────────────────────────────────────────────────────────┘
```

---

## 二、四个核心技术（内容）

### 技术①：系统时钟

| 项目 | ChibiOS 方式 | RTT 当前 | 目标 |
|------|-------------|---------|------|
| HSE 频率 | 16MHz | 16MHz（同） | 不变 |
| PLL 配法 | 寄存器直接写 `RCC->PLLCFGR` | 通过 HAL `HAL_RCC_OscConfig()` | 改寄存器 |
| AHB 时钟 | 216MHz | 216MHz（同） | 不变 |
| APB1/APB2 | 54MHz/108MHz | 54MHz/108MHz | 不变 |
| Flash 等待 | 7 cycles | 7 cycles | 不变 |
| 代码风格 | CMSIS 寄存器 | STM32 HAL 库 | CMSIS 寄存器 |

**改哪个文件**：`modules/rt-thread/bsp/stm32/libraries/HAL_Drivers/config/stm32f7xx/stm32f7_clock_ll.c`（或者移植 ChibiOS 的 `__early_init` 代码过来直接替换）

**验收**：OpenOCD 读 `RCC->CFGR` 和 ChibiOS 完全一致

---

### 技术②：启动文件

| 项目 | ChibiOS 方式 | RTT 当前 | 目标 |
|------|-------------|---------|------|
| 栈模式 | 双栈 MSP(ISR) + PSP(主线程) | 单栈 MSP | 双栈 |
| 栈大小 | 1KB + 1KB = 2KB | 16KB | 1KB + 1KB |
| 栈位置 | DTCM(0x20000000) | 大 RAM 顶部 | DTCM |
| FPU 初化 | 寄存器 `FPCCR->CPACR` 直写 | 在 SystemInit 内 | 启动文件内直写 |
| I/D-Cache | `__cpu_init()` (SCB 寄存器) | 在 SystemClock_Config 内 | 启动文件内直写 |
| 看门狗 | `IWDG_KR` 寄存器直写 | HAL 库 | 寄存器直写 |
| 启动代码 | `crt0_v7m.S`（400行） | `startup_rtt_override.S`（200行） | 改为 ChibiOS 风格 |

**改哪个文件**：
- `libraries/AP_HAL_RTT/hwdef/common/board/startup_rtt_override.S`
- 或者直接引用 ChibiOS 的 `crt0_v7m.S` + 改 vector table

**验收**：`CONTROL` 寄存器 = 0x02（PSP+特权），`MSP` = DTCM 顶部，`PSP` = DTCM 顶部-1KB

---

### 技术③：链接脚本

**ChibiOS 内存布局**（STM32F767）：
```
DTCM (0x20000000, 128KB):  ← CPU 零等待，无 DMA
  .mstack      1KB
  .pstack      1KB
  .bss         大部分全局变量
  .nocache     DMA 缓冲区

SRAM1 (0x20020000, 368KB):  ← DMA 可达
  .data       初始化的全局变量
  HEAP        malloc/new

SRAM2 (0x2007C000, 0KB):
  给 RT-Thread 用
```

**RTT 当前布局**：
```
RAM (0x20000000, 512KB):   ← 不分 DTCM/SRAM1，全混在一起
  .stack       16KB
  .data + .bss 混在一起
```

**改哪个文件**：`libraries/AP_HAL_RTT/hwdef/common/board/linker_scripts/link.lds`

**验收**：`arm-none-eabi-objdump -h rtthread.elf` 显示 `.stack` + `.bss` 在 0x20000000-0x2001FFFF，`.data` 在 0x20020000+

---

### 技术④：外设驱动全部寄存器化

| 驱动 | 当前状态 | 目标 | 改哪个文件 | 估计行数 |
|------|---------|------|----------|---------|
| SPI | RT-Thread Framework + drv_spi.c（含 HAL 调用） | drv_spi.c 内寄存器直写（FRXTH=1, TXE/RXNE轮询） | `modules/rt-thread/.../drv_spi.c` | 120 行 |
| USB CDC | CherryUSB（整个 USB 协议栈） | 去掉 CherryUSB，接入已有 `hal_usb_lld_rtt.c`（DWC2 寄存器直写） | 新建 `usb_cdc_rtt.c` + 改 `UARTDriver.cpp` | 500 行 |
| UART | drv_usart.c（HAL 库） | 寄存器直写（TXE/TC/RXNE 中断） | `modules/rt-thread/.../drv_usart.c` | 150 行 |
| I2C | 软 bitbang（`I2CDevice.cpp` 内 GPIO 模拟时序） | 硬件 I2C3 寄存器（I2C_CR1/CR2/ISR 轮询） | `I2CDevice.cpp` + `drv_i2c.c` | 200 行 |
| PWM | drv_pwm.c（TIM HAL） | TIM 寄存器直写（CR1/CCMR/CCR/ARR） | `drv_pwm.c` | 150 行 |
| RCInput | drv_pulse_capture.c（TIM HAL） | TIM 寄存器直写 | `drv_pulse_capture.c` | 100 行 |
| GPIO | drv_gpio.c（HAL） | GPIO 寄存器直写（MODER/OSPEEDR/PUPDR/BSRR/AFR） | `drv_gpio.c` | 80 行 |
| CAN | bxCAN（HAL） | CAN 寄存器直写 | `drv_can.c` | 200 行 |
| Flash | drv_flash.c（HAL） | Flash 寄存器直写 | `drv_flash.c` | 80 行 |

**总改动量**：~1600 行 CMSIS 寄存器代码

**铁律**：每个驱动改写前，必须读 ChibiOS 的对应文件（`spi_lld.c` / `uart_lld.c` / `i2c_lld.c`），照搬寄存器配置。

---

### 技术⑤：`--board=xxx` 硬件定义自动发现

```
scons --board=cuav_v5
  → SConstruct 自动扫描 hwdef/cuav_v5/hwdef.dat
  → 读取 hwdef/cuav_v5/board_config.py（板级编译标志）
  → deploy → 编译 → 烧录

scons --board=pixhawk6c_mini
  → 同样流程，自动发现 hwdef/pixhawk6c_mini/
```

**改哪个文件**：`SConstruct` + `Tools/scripts/rtt_bsp_deploy.py` + 新建 `board_config.py`
**改动量**：+129 行净增

---

## 三、CCP Daemon 自循环引擎 — 四径探测

### 四径探针（什么是四径）

```
┌─ ① CPU 径 ─────────────────────────────────────────────────┐
│  读 PC / LR / SP / xPSR → CPU 在哪个函数卡死（精确到行号）  │
│  查 HFSR / CFSR → 有没有 HardFault                          │
│  查 LR[2] → 异常返回时是线程模式还是 Handler 模式             │
│  目标: 知道 CPU 在干什么、卡在哪里                             │
├─ ② 外设径 ─────────────────────────────────────────────────┐
│  读 SPI1->CR1/CR2/SR → SPI 配了没？RXNE 触发了吗？          │
│  读 USART1->CR1/ISR → UART 配了没？TXE/TC 通了？           │
│  读 USB DWC2 寄存器 → 枚举到哪一步了？                       │
│  目标: 知道每个外设的寄存器状态                                │
├─ ③ 应用径 ─────────────────────────────────────────────────┐
│  读 rtt_dbg_setup_stage → setup 到哪一步了（0x000~0x28b）   │
│  读 rtt_dbg_main_loop_iterations → main_loop 跑了没        │
│  读 rtt_dbg_fast_loop_count → fast_loop 跑了没              │
│  读 rtt_adc_conversion_count → ADC 转换正常吗               │
│  读 rtt_dbg_hal_run_called → hal.run() 进了吗              │
│  目标: 知道应用层初始化到哪了                                  │
├─ ④ 通信径 ─────────────────────────────────────────────────┐
│  检查 /dev/ttyACM1 存在 → USB CDC 枚举了没                  │
│  pymavlink wait_heartbeat → MAVLink 心跳通了没             │
│  读 DIEPMSK/DOEPMSK → USB 端点使能了没                     │
│  目标: 知道飞控和地面站之间能不能说话                          │
└──────────────────────────────────────────────────────────────┘
```

### 四径聚合诊断

```
四径数据汇总到 daemon 后，用规则匹配（不用 LLM）：

if ①(PC_in_SPI_func) AND ②(CR2.FRXTH=0):
    → 诊断: "SPI CR2 缺 FRXTH bit → 8bit 轮询死循环"
    → 派工: "请修 drv_spi.c 的 CR2 配置，设 FRXTH=1"

if ③(setup_stage < 0x262) AND ②(I2C_CR1.PE=0):
    → 诊断: "I2C 外设未使能 → setup 在 I2C probe 卡住"
    → 派工: "请配 I2C_CR1.PE bit"

if ③(main_loop=0) AND ③(setup_stage=0x28b) AND ①(PC_in_wait_for_sample):
    → 诊断: "main_loop 进了但 wait_for_sample 卡住 → SPI IMU 不通"
    → 派工: "请修复 SPI IMU 驱动"

if ④(/dev/ttyACM1 不存在) AND ②(USB_DWC2 寄存器未配):
    → 诊断: "USB DWC2 未正确初始化"
    → 派工: "请按 ChibiOS USB LLD 配 DWC2 寄存器"
```

### 循环流程（每 5 分钟一圈）

```
                     ┌──────────┐
                     │ 四径探针 │  ← 纯 shell/Python：OpenOCD + lsusb + pymavlink
                     └────┬─────┘      无 LLM 调用
                          │
                          ▼
                    ┌──────────────┐
               ┌───│ 四径全部正常? │───┐
               │   └──────┬───────┘   │
               │          │           │
               │        是的         不是
               │          │           │
               ▼          ▼           ▼
            ┌────┐    ┌──────────────┐
            │通  │    │ 规则诊断      │  ← if-then-else 规则，无 LLM
            │知你│    └──────┬───────┘
            │✅  │           │
            └────┘           ▼
                     ┌──────────────┐
                     │ dispatch     │  ← spawn Claude Code + /goal
                     │ Claude Code  │     不用 kanban
                     └──────┬───────┘
                            │
                            ▼
                     ┌──────────────┐
                     │ wait         │  ← 等 done marker（最多30分钟）
                     │ done marker  │     每 1 分钟检查一次
                     └──────┬───────┘
                            │
                            ▼
                     ┌──────────────┐
                     │ build        │  ← scons（纯 shell）
                     └──────┬───────┘
                            │
                            ▼
                     ┌──────────────┐
                     │ flash        │  ← OpenOCD（纯 shell）
                     └──────┬───────┘
                            │
                            ▼
                     ┌──────────────┐
                ┌────│ 四径再验     │────┐
                │    └──────┬───────┘    │
                │           │            │
                │        通过         不通过
                │           │            │
                │           ▼            ▼
                │       回到四径      ┌──────────┐
                │       (下一圈)     │ 日志+重试 │
                └────────────────────└────┬─────┘
                                          │
                                    ┌───────────┐
                                    │ ≥3次不通过?│
                                    └─────┬─────┘
                                      是／    ＼否
                                       ▼       ▼
                                 ┌────────┐ ┌──────────┐
                                 │换方向   │ │再试      │
                                 │+通知你  │ │          │
                                 └────────┘ └──────────┘
```

### 防卡死机制（6 种风险全覆盖，同原方案）

| 风险 | 防护 | 实现方式 |
|------|------|---------|
| ① 修不好死循环 | **3 次换方向** | `retry_count≥3` → 换不同的 Claude Code goal |
| ② 假修好 | **daemon 自己验证** | 不信任 CC 的自报，必须四径再验 |
| ③ 新问题掩盖 | **四径全部检查** | 不只看 main_loop，四个径同时查 |
| ④ 并行冲突 | **独立 worktree** | 每个 fix 独立 git worktree |
| ⑤ 硬件断开 | **CPU 径先连 OpenOCD** | 连不上不派工，先试 xhci reset |
| ⑥ 超时回收 | **最长 30 分钟等待** | CC 30 分钟不写 done marker → 杀掉重来 |

---

## 四、24h 自循环执行顺序

### 阶段① — 基础设施打通（30 分钟）

```
启动 daemon → probe → 发现 main_loop=0 → 派工 ce-system
ce-system: 时钟+启动文件+链接脚本对齐 ChibiOS
daemon verify → main_loop > 0?
  ├─ 是 → 进入阶段②
  └─ 否 → 3 次后换 ce-openocd-gdb 诊断
```

### 阶段② — 驱动逐个寄存器化（2-6 小时）

```
daemon: probe 发现哪个驱动还没通 → 派对应 ce-*
并行两条：
  A 线: SPI 不通 → ce-spidevice → CMSIS 寄存器
  B 线: I2C 不通 → ce-i2cdevice → 硬件寄存器

每个驱动：
  fix → compile → flash → verify
  过 → 下一个
  不过 → 3 次 → 换人/通知
```

### 阶段③ — `--board=xxx` 改造（1 小时）

```
ce-scons: SConstruct + deploy 脚本改造
ce-system: hwdef.dat 加 BOARD_TYPE
ce-mavros: 验证板级自动发现 + 编译通过
```

### 阶段④ — 全部完成通知

```
daemon: probe L1-L4 全部通过 → 通知飞书
        记录完成时间 → 进入闲置模式（只探针不派工）
        如果 24h 内再次异常 → 自动唤醒
```

---

## 五、执行计划（精确到每一步）

### Step 1 — CCP daemon 启动自循环（30 分钟）

```bash
# 1. 恢复 ccp-daemon-tick cron（每5分钟）
# 2. daemon 首次 probe：读 main_loop / setup_stage / HFSR
# 3. main_loop=0 → 进入 diagnose 模式
# 4. 第一个诊断结果：SPI IMU 未通 → 创建 kanban task
```

### Step 2 — 时钟+启动文件+链接脚本对齐（60 分钟）

```bash
# daemon 派 ce-system
# ce-system 先后做三件事：
#   ① 时钟：stm32f7_clock_ll.c → CMSIS 寄存器（读 ChibiOS __early_init 照搬）
#   ② 启动文件：startup_rtt_override.S → 双栈 PSP + FPU 寄存器
#   ③ 链接脚本：link.lds → DTCM/SRAM1 分拆
# daemon build → flash → verify
# 如果 main_loop > 0 → 进入驱动对齐阶段
```

### Step 3 — 外设驱动逐个寄存器化（并行 2-6 小时）

```bash
# daemon 同时派两条线：
# A 线: ce-spidevice → drv_spi.c CMSIS 化（120行）
# B 线: ce-uartdriver → usb_cdc_rtt.c 接入（500行）
# 每完成一个 → daemon build→flash→verify
# 通过 → 派下一个：I2C → PWM → RCInput → GPIO → CAN → Flash
```

### Step 4 — `--board=xxx` 改造（60 分钟）

```bash
# ce-scons: SConstruct discover_boards() + board_config.py
# ce-system: hwdef.dat define BOARD_TYPE
# ce-mavros: 验 scons --board=cuav_v5 编译通过
```

### Step 5 — 24h 无人值守验收

```bash
# daemon 连续跑 24 小时
# 中途任何异常：自动恢复 / 自动换方向 / 自动通知
# 24h 后检查日志：有人介入过吗？没有 = 通过
```

---

## 六、总改动量

| 技术模块 | 涉及文件 | 改动行数 | 预计执行时间 |
|---------|---------|---------|------------|
| ① 系统时钟 CMSIS 化 | `stm32f7_clock_ll.c` | +50 行 | 15 分钟 |
| ② 启动文件对齐 ChibiOS | `startup_rtt_override.S` | +150 行 | 20 分钟 |
| ③ 链接脚本 DTCM/SRAM1 | `link.lds` | +60 行 | 10 分钟 |
| ④ SPI 寄存器化 | `drv_spi.c` | +120 行 | 30 分钟 |
| USB CDC 去 CherryUSB | `usb_cdc_rtt.c` + `UARTDriver.cpp` | +500 行 | 2 小时 |
| UART 寄存器化 | `drv_usart.c` | +150 行 | 30 分钟 |
| I2C 硬件寄存器化 | `I2CDevice.cpp` | +200 行 | 1 小时 |
| PWM/RCInput/GPIO/... | 各驱动文件 | +500 行 | 1-2 小时 |
| `--board=xxx` | `SConstruct` + `deploy.py` | +129 行 | 1 小时 |
| CCP daemon 自循环 | `ccp_daemon.py` | +450 行 | 2 小时 |
| **总计** | **~15 个文件** | **~2300 行** | **6-10 小时** |

---

## 七、风险防护总表

```
┌──────┬──────────────────┬──────────────────────────────────────────┐
│ 编号 │ 风险             │ 防护措施                                 │
├──────┼──────────────────┼──────────────────────────────────────────┤
│ R-01 │ 员工修不好死循环   │ retry_count≥3 → 换员工/换方向/通知人      │
│ R-02 │ 假修好            │ daemon 独立验证，不信任 worker 自报        │
│ R-03 │ 新问题掩盖         │ L1-L4 全层次验证，不只查 main_loop         │
│ R-04 │ 并行冲突           │ git worktree 隔离，每条线独立分支          │
│ R-05 │ 硬件断开           │ probe 先验 OpenOCD 连接，不通不派工       │
│ R-06 │ 超时回收           │ 任务 ≤ 5 分钟，大的拆子 task              │
│ R-07 │ daemon 自己崩了   │ cron 每分钟检查 daemon 存活，死了自动重启  │
│ R-08 │ 多个 daemon 冲突   │ flock -n 文件锁防并发                     │
│ R-09 │ 工作目录不对        │ 每个 task body 第一行写 workdir            │
│ R-10 │ kanban 不派单      │ 巡检每 3 分钟自动解阻塞/清锁/重置失败计数  │
└──────┴──────────────────┴──────────────────────────────────────────┘
```

---

## 八、验收清单

```
☐ 时钟寄存器化 — OpenOCD 读 RCC->CFGR 与 ChibiOS 一致
☐ 启动文件双栈 — CONTROL=0x02, MSP=DTCM顶, PSP=DTCM顶-1KB
☐ 链接脚本 DTCM/SRAM1 — objdump 确认段位置正确
☐ SPI 寄存器化 — drv_spi.c 无 HAL 调用，RXNE 触发正常
☐ USB 去 CherryUSB — 无 HAL 调用，CDC 枚举正常
☐ I2C 硬件寄存器 — I2C_CR1/CR2/ISR 直写，IST8310 探测通过
☐ PWM/RCInput/GPIO 全部寄存器化
☐ scons --board=cuav_v5 编译通过
☐ CCP daemon 每5分钟自动探针不报错
☐ main_loop=0 → 自动诊断 → 自动派工
☐ worker 完成后 → daemon 自动 build→flash→verify
☐ 3 次失败 → 自动换方向（不卡死）
☐ 24h 无人介入运行 ✅
```

---

你要不要现在从头开始执行？从 Step 1 — 启动 CCP daemon 自循环开始，然后 Step 2 时钟+启动+链接脚本对齐。**你一句话我就直接动手，不再规划了。**