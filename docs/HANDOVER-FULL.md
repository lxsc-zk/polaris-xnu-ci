# Polaris (小米 MIX 2S) GPU / iOS 移植 · 完整交接文档

> 生成时间：2026-11-04（Windows 侧，切换前）
> 用途：**新会话的唯一入口**。读完本文即可接续全部工作，无需历史对话。
> 后续路线：**edk2 + xnuloader（dipper 路线）**

---

## 0. 一句话现状

**Adreno 630 的 GPU 启动链已在本机（ABL shim 链）跑通：dipper 的 4718 行驱动编进内核、跑完 22 步、SMMU 页表全部校验通过、SECVID 曾成功归零；只差「保持运行 → 画图」一环。现决定转向 edk2+xnuloader，以根治 TrustZone 未授权这块短板。**

---

## 1. 设备与工程身份

| 项 | 值 |
|---|---|
| 设备 | 小米 MIX 2S，代号 **polaris** |
| SoC / GPU | SDM845 / **Adreno 630**（chip_id `0x06030001`） |
| 屏幕 | 1080×2160，stride **4320**，framebuffer 物理地址 **`0x9d400000`** |
| 当前内核基座 | **XNU 8796.141.3**，`MACHINE_CONFIG SWEET` |
| 当前引导链 | **ABL shim**（`boot.img` + `shim` + payload） |
| 用户态 | iOS 16.5（历史验证可到锁屏 + 触摸） |
| 参考实现 | `youzjuzi/dipper-xnu`（小米 8，同 SoC 同 GPU，跑通 GPU/触摸/WiFi） |
| CI 仓库 | `github.com/lxsc-zk/polaris-xnu-ci`（补丁 + workflow） |

---

## 2. 已取得的成果（按层，全部有实测证据）

### 2.1 GPU 启动链（ABL 链，当前内核）

| 里程碑 | 证据 | 关键补丁 |
|---|---|---|
| CX 上电正确（含 clk-dis-wait=8） | 第 4 步 `CX is on` | 0372 |
| GMU 地址空间 | 第 16 步不再复位 | **0333/0334** |
| **HFI 五条消息全部应答** | `HFI6: id=0..5 err=0x00000000` | **0365** |
| rail 授权 `set 22 / ack 30` | `ACKED (info 0x40000000, rpmh 0xf)` | 0367 |
| 3D 核授权 `set 16 / ack 24` | `ACKED (info 0x01000000)` | 0366 |
| SPTPRAC 上电 | `status 0x28 (on)` | 0368 |
| 22 步全过（我方式 bring-up） | `step 22: done` | 0379 |
| **SECVID 归零、退出安全模式** | `SECVID=0x00000000 after 43173 polls` | （0391 那轮） |
| dipper 驱动编入内核 | 内核含 `mi8_adreno.o`，尺寸 +119 KB | 0384b/0385/0387/0388/0391 |
| dipper 驱动跑到 22 步 | `mi8gpu: step 22: done` | — |
| dipper 驱动 SMMU 校验 | `0 of 13 pages translated wrong` / `0 of 4 pages wrong` | — |

### 2.2 关键发现（这些是本次最大的知识资产）

1. **HFI 必须照 dipper 的协议**（0365，五个点）：
   - 读 `write_index` **之前**先 `to_memory(header, 0x1000)` 失效缓存 ← 决定性
   - 队列空间检查 `space = (read - write - 1) & (N-1)`，不足则拒绝
   - 消息头显式写 type：`(seq<<20)|(0<<16)|(words<<8)|id`
   - 顺序：**刷数据页 → 写 write_index → 刷头页 → 门铃**
   - 3 轮 × 1 s 等待，每轮把应答队列**读空**
2. **GMU 地址空间必须用 bring-up 的那套 SMMU 实现**（0333/0334）：驱动自己的 `space_on()` 寄存器值相同、校验也通过，但页表建立方式不同 → 固件第一次读表就失败，表现是**整机复位**而不是报错。
3. **`SECVID_TRUST_CNTL`（3D 块 `+0xf400*4`）读 0 表示「已退出安全模式」**；`qcom,gpu-quirk-secid-set-once` 说明该寄存器**只能写一次**，第二次写会导致手机复位。dipper 的五个 caller-security-table 条目：
   ```
   0xf803 = 0   0xf800 = 0   0xf801 = 0   0xf802 = 0   0xf810 = 1
   ```
4. **`memptrs` 自检失败并不代表 CP 没工作**：能画图的那版同样报 `memptrs = 0x0 0x0`。CP 的 `RPTR==WPTR` 已证明命令被消费。
5. **dipper 驱动的 keep 决策是四条件**：`mi8_keep && gpu_set && cp_ok && gpu_nonsecure` —— 我方式只强设了 `mi8_keep`，仍回滚，说明后两者之一为 false（**0395 待验证**）。
6. **`mi8gpu=N` 与 `gpu=1` 语义不同**：
   - `mi8gpu=N`：走 N 步后**回滚善后**（调试用）
   - `gpu=1`：`mi8_gpu_start_by_itself()` + `mi8_keep = true`（但依赖 display/loader 上下文，在我们链上静默返回）

---

## 3. dipper ↔ polaris 差异全表（移植必须遵守）

| 项 | dipper | polaris（实测） | 处理 |
|---|---|---|---|
| MMIO 基址 / 寄存器偏移 | SDM845 通用 | 一致 | ✅ 直接照搬 |
| GMU SID / 3D SID | 4, 5 / 0 | 一致（与 stock DT 吻合） | ✅ |
| GPU 窗口 | GMU `0x506a000`、GPUCC `0x5090000`、SMMU `0x5040000`、GPU `0x5000000` | 完全一致 | ✅ |
| **RSCC 基址** | `0x0508db00` | **`0x0508d000`** | 必须改（0301） |
| **MX 索引** | 由 `mx.lvl` 读 | 查询失败 → **强制 3**（否则 `oob set 22` TIMEOUT + CM3 fault） | 必须改 |
| **SPTPRAC 控制 / 状态** | 自带宏 | **`gmu+0x204` / `gmu+0x340`** | 用 polaris 值 |
| rail 索引 | 动态读 | **gx = 3, mx = 3** | 实测值 |
| **rail 与 HFI 顺序** | rail → HFI → GPU_SET | 两序皆通（0358/0369 实测） | 保持 dipper 原序即可 |
| **帧缓冲** | — | **`0x9d400000`，stride 4320，1080×2160** | dipper 驱动日志也识别到同一地址 |
| **TrustZone GPU 授权** | 有（edk2 链注册） | **`GPU 0/0`（ABL 链从未注册）** | ← **换 edk2 的根本理由** |
| 命令库（cmd_db） | 硬编码 `0x85fe0000` | 从 `0x0c3f000c` 读指针 → 同为 `0x85fe0000` | 我们的更稳 |
| A630 hw_init 表 | 184 写 | 照抄可用（`9 differed`） | ✅ |
| 启动寄存器表 | 15 条 | 照抄可用 | ✅ |

---

## 4. 补丁清单（`xnu/patches/`，按编号顺序生效）

### 4.1 早期 bring-up 对齐（0294–0315）
`0294` 15 条启动寄存器 · `0296` gmu_clk_src 配方 · `0298` 绕过 AHB 频率计数器 · `0301` RSCC 基址 · `0303` RSC/PDC 49 项表 · `0305` 接受 `0xbabeface`

### 4.2 HFI 攻坚（0317–0365）
| 补丁 | 作用 | 结果 |
|---|---|---|
| 0333/0334 | **移植 bring-up 的 SMMU 实现** | ✅ 第 16 步不再复位 |
| 0341 | 保持 working space 的队列表 | ✅ |
| 0342 | `hfi_send` 前后 `dc civac` | ✅ |
| 0343–0345 | 写索引显式写入、按字数推进 | ✅ |
| 0346 | 应答 type = 2 | ✅ |
| 0347–0349 | 接受慢一拍的应答 + 末尾 drain | ✅ |
| 0351 | 映射 13 → 20 页 | 无效（排除） |
| 0353 | 读指针按字数推进 | 部分 |
| 0354/0355/0356 | drain / 去门禁 / 发送器逐字对齐 | 逐个排除 |
| **0365** | **HFI 协议照 dipper（五点）** | ✅ **五条全 `err=0`** |

### 4.3 3D 核与电源（0366–0372）
`0366` 核心 OOB 16/24 · `0367` rail OOB 22/30 · `0368` SPTPRAC enable · `0370` OOB 按文档（BOOT_SLUMBER_OPTION + 双位清除）· `0372` CX clk-dis-wait=8

### 4.4 接管路线（0371–0394）
| 补丁 | 作用 |
|---|---|
| 0371 | 第 13 步调用 `polaris_mi8_flow()` |
| 0374 | 钩子里自加载 GMU 固件 |
| 0375 | 步骤 14/15/16 让路 |
| 0379 | 让路扩到 22 步 → **22 步全过** |
| **0384b** | **dipper `mi8_adreno.c`（4718 行）编入内核** |
| 0385 | 登记 `bsd/conf/files` |
| 0387 | 补 `sys/redwood_input.h` + `mi8_a630_hw_init.inc` |
| 0388 | 修 `redwood_input.h` 的 include guard |
| 0391 | shim：`redwood_wifi_file` / `RedwoodGPUStart` / `redwood_battery_temperature` |
| 0393 | `mi8gpu=` 时 dipper 驱动独占，我方式让路 |
| 0394 | `mi8_keep = true`（未生效，待 0395） |

---

## 5. 构建 / 打包 / 刷机

### 5.1 CI（现用，macOS runner）
```
push 到 xnu/patches/** → .github/workflows/xnu.yml 触发
产物 artifact：xnu-kernel / xnu-errors / xnu-buildlog（新增，含完整构建日志）/ xnu-buildtree
runner：macos-14（macos-13/15 会长时间排队）
```

### 5.2 本地 macOS（黑苹果后，照 CI 抄）
```bash
xcode-select --install          # + Xcode 13.4.1/13.6（对应 macOS 13 SDK）
git clone https://github.com/lxsc-zk/polaris-xnu-ci.git
git clone https://github.com/blacktop/darwin-xnu-build.git dxb
cd dxb && git checkout 663906528d1cd5ea8fde7de6f16de73db9511549
for p in $(ls ../xnu/patches/*.patch | sort); do
  git apply -p1 --whitespace=nowarn --include='bsd/*' "$p" || echo "SKIP $(basename $p)"
done
MAKEFLAGS='-k -s' bash build.sh 2>&1 | tee build.log
# 产物 build/xnu.obj/RELEASE_ARM64_SWEET/kernel.release.sweet
```

### 5.3 打包与刷机（Windows 侧脚本）
```
polaris-work/build_image_for.sh  KERNEL OUT.img   # 组装 payload + shim，自动带命令行长
默认 cmdline 关键项：sweetfb_polaris=1 adreno=22 adreno_watch=0 [gpu=1 | mi8gpu=22]
fastboot boot OUT.img
```
> ⚠️ 该脚本曾被写成 CRLF 导致 `$'\r'` 错误、参数没进镜像；改动后用
> `grep -c -a "gpu=1" OUT.img` 校验。

---

## 6. 未完成项与下一步

### 6.1 当前链（ABL）上的最后一步：0395
`mi8_keep = true` 没阻止回滚 → 说明四条件里 `cp_ok` 或 `gpu_nonsecure` 为 false。
在 `bsd/dev/mi8_adreno.c` 的 `if (mi8_keep && gpu_set && cp_ok && gpu_nonsecure)` **之前**加：

```c
printf("mi8gpu: keep decision: mi8_keep=%d gpu_set=%d cp_ok=%d gpu_nonsecure=%d\n",
       mi8_keep, gpu_set, cp_ok, gpu_nonsecure);
```

出现该行即可定位，然后修对应的板级假设，`painting pass` 即会执行。

### 6.2 转向 edk2 + xnuloader 的路线计划

**理由**：ABL 链的唯一短板是 **TrustZone 未注册 GPU**（`GPU 0/0`），这决定 `SECVID` 能否稳定归零；edk2 链由固件层完成注册。

**已有证据**：`SPRMD/UniXNU-polaris` 记录 2026-10-24 真机 —— Renegade edk2-msm 固件可启动，UniXNU 菜单 → DarwinBoot 交接 `va=0xfffffff007004000 pa=0x100004000`、`video base=0x9d400000 4320 1080x2160` → XNU 跑到 `Failed to mount root device`（设计内终点）。

**步骤**：
1. 用 `edk2-msm` 编 polaris 的 `boot-polaris.img`（**Linux/黑苹果均可，不需要 Xcode**）
2. 在 userdata 放最小 ESP：DarwinBoot + **我们当前的内核**（先不换内核，只换引导）
3. 验证点：新链上能出现 `adreno: step 1` 这类日志 → 基座可换
4. 之后决定是否迁 dipper 的完整 userland（`darwin.img` + prelinked kernelcache + trust cache）

**风险**：迁移期间可能失去「能启动到 iOS 界面」的现状；建议保留现有 ABL 镜像作回退。

---

## 7. 参考资源

| 内容 | 位置 |
|---|---|
| dipper 参考补丁（831 KB，含 `mi8_adreno.c` 原文） | `polaris-work/dipper/xnu-mi8.patch` |
| dipper 驱动抽取源码（4718 行） | `/root/polaris-drv/dipper-src/bsd/dev/mi8_adreno.c` |
| dipper 关键函数 | `gpu_init()`（hw_init 184 写 + SECVID 表）、`gmu_boot()`、`hfi_send()`、`gpu_zap_and_command()`、`gpu_fill_screen()` |
| UniXNU-polaris（edk2 路线参考） | `github.com/SPRMD/UniXNU-polaris`，尤其 `research/a630-port-gap.md`、`docs/HISTORY.md`、`NOTES.md` |
| 本机知识文档 | `polaris-work/GMU-HFI-HANDOVER.md`、`BRINGUP-FINAL-FLOW.md`、`DRIVER-VS-BRINGUP.md`、`GPU-BRINGUP-DONE.md`、`GPU-HFI-2026-10-30.md` |
| stock DT 解析结果（SID/中断/频率/quirks） | `polaris-work/unixnu/polaris-a630-resources.json` |

---

## 8. 关键 URLs / 命令速查

```bash
# CI 手动触发/查看
gh run list --repo lxsc-zk/polaris-xnu-ci
# 或 API：GET /repos/lxsc-zk/polaris-xnu-ci/actions/runs

# 检查某个补丁是否真的生效（CI 会静默跳过失败补丁！）
grep -c "<关键字符串>" 内核树/文件

# 确认启动参数进了镜像
grep -c -a "gpu=1" 镜像.img
```

> **重要教训**：CI 对 apply 失败的补丁是**静默跳过**（只打 warning）。每次加补丁后务必用上面的 grep 确认代码真的进了构建，否则会白跑几轮。

---

## 9. 新会话如何开始

1. 把本文 + `polaris-work/` 下四份知识文档作为上下文发送
2. 说明当前动作：「按 edk2 路线，第 1 步是编 `boot-polaris.img`」
3. 若继续 ABL 链：直接做 **0395**（keep decision 诊断）
4. 环境：Windows + WSL（`/root/polaris-ci` 仓库、`/root/polaris-drv` 驱动树）或 macOS（`git clone` 后按 §5.2 构建）
