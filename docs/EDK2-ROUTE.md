# edk2 + xnuloader 路线 · 可执行计划

> 配套文档：`HANDOVER-FULL.md`（成果与差异表）、`polaris-work/GMU-HFI-HANDOVER.md`（HFI 排除矩阵）
> 目标：在 polaris 上用 UEFI 引导链替代 ABL shim，**根治 TrustZone 未给 GPU 授权**这一短板。

---

## 0. 为什么换这条链（一句话）

现有 ABL 链的唯一硬短板是：

```
adreno: 11: "supported", asked at once / as Linux asks: audio 0/0, modem 0/0, video 0/0, GPU 0/0
```

**TrustZone 从未注册 GPU** → `SECVID_TRUST_CNTL` 难以稳定归零 → CP 的内存写可能永远不生效。
dipper 之所以能跑通，是因为它的 edk2 固件在更底层完成了这项注册。

---

## 1. 现成证据（不用从零试）

`SPRMD/UniXNU-polaris` 的 2026-10-24 真机记录（本机同款 polaris）：

```
Renegade edk2-msm polaris 固件 → fastboot boot 成功
UEFI 菜单从 userdata 的 ESP 运行（GOP 1080×2160 真实输出）
DarwinBoot 交接: va=0xfffffff007004000 pa=0x100004000, video base=0x9d400000 row=4320 1080x2160
XNU 启动 → arm_init → 调度器 → PPI-19 定时器 → corecrypto FIPS POST → bsd_init → IOKit
→ panic "Failed to mount root device"（设计内终点）
```

**关键结论**：固件层在 polaris 上可用；屏幕参数与我们当前链**完全一致**（`0x9d400000` / 4320）。

---

## 2. 仓库与组件

| 组件 | 仓库 | 用途 |
|---|---|---|
| edk2-msm（Renegade） | `luuu20309/edk2-msm` | SDM845 UEFI 固件，支持 polaris |
| edk2-sdm845 补丁 | `youzjuzi/dipper-xnu` → `patches/edk2-sdm845.patch` | dipper 的适配补丁，polaris 参考 |
| XnuLoaderDxe | `youzjuzi/dipper-xnu` → `bootloader/uefi/XnuLoaderPkg/` | UEFI 里加载 XNU 的驱动 |
| UniXNU-polaris | `SPRMD/UniXNU-polaris` | **已验证 polaris 启动**的完整流程与文档 |
| 我们的内核 | `lxsc-zk/polaris-xnu-ci` → `xnu/patches/` | 沿用现有 XNU 8796 内核，先只换引导 |

---

## 3. 分阶段执行（每阶段一个验证点）

### M1 — 先把 UEFI 固件编出来（不需要 macOS）
```bash
git clone https://github.com/luuu20309/edk2-msm.git
cd edk2-msm
# 依赖：gcc-aarch64-linux-gnu / python3 / dtc / iasl（Debian/Ubuntu 均可）
./build.sh polaris          # 具体 target 名以仓库 README 为准
# 产物：boot-polaris.img
fastboot boot boot-polaris.img
```
**验证点**：手机屏幕出现 UEFI 菜单（说明固件 + 显示通路 OK）。

### M2 — 用 ESP 引导（先不换内核）
在 userdata 分区建最小 ESP：
```
/EFI/BOOT/BOOTAA64.EFI     ← XnuLoaderDxe（或 UniXNU 的启动管理器）
/kernel.macho              ← ★ 我们当前的内核（kernel.release.sweet 转 macho 或直接用）
/darwin,recovery/…         ← DarwinBoot 需要的附加文件
```
**验证点**：DarwinBoot 打印 `va=… pa=… video base=0x9d400000`，随后内核开始执行。

### M3 — 我们的内核在新链上跑起来（★ 决定性验证）
**验证点**：串口/屏幕出现我们内核的日志，例如：

```
adreno: 1: …            ← 我们驱动的 step 1
SWEET CPU: cpu=0 mpldr=… came alive
```
只要看到这类行，就证明 **同内核可换引导**，之后所有 GPU 知识都能在新链上复用。

### M4 — 在新链上重跑 GPU
- 先用现有 `polaris_mi8_flow()` 路径（我们已验证到 22 步）
- 观察 `TrustZone … GPU ?/?` 是否变成**非 0**（这是换链的核心收益）
- 若 TZ 放行 → `SECVID_TRUST_CNTL` 归零变得稳定 → CP 内存写生效 → `painting pass`

### M5 — 迁移 dipper 的完整 userland（可选，工作量最大）
`darwin.img`（APFS）+ prelinked kernelcache + trust cache 策略。dipper-xnu 的 `patches/hackios-userland.patch` 是参考。

---

## 4. 风险与回退

| 风险 | 缓解 |
|---|---|
| 迁移期失去「能启动到 iOS 界面」的现状 | **保留现有 ABL 镜像**（`E:\polaris\shim-polaris-xnu-394.img` 等），随时 `fastboot boot` 回退 |
| edk2 固件与本机 fuse/ABL 版本不兼容 | 先只做 `fastboot boot`（不刷分区）；必要时用 `fastboot flash abl` 备份后再动 |
| 分区操作风险 | 所有写操作前 `dd` 备份 GPT + 关键分区；ESP 只放 userdata |
| 内核格式不匹配（macho / raw） | 先用当前 CI 产物 `kernel.release.sweet`；必要时用 `mkpayload` 的转换逻辑 |

---

## 5. 与当前 ABL 链并行（推荐）

```
并行 A：ABL 链继续 0395 诊断 → 若 keep 决策修好、painting 出现，则「GPU 画图」目标先达成
并行 B：edk2 做 M1–M3（不需要手机长时间占用，编固件在 PC 上）
汇合点：M3 成功 → 把 A 的全部 GPU 知识搬到 B 上验证 TZ 是否放行
```

**两条腿互不阻塞**：A 用现有镜像，B 只做 `fastboot boot` 试验。

---

## 6. 新会话的第一步（照抄）

1. 读 `docs/HANDOVER-FULL.md` + 本文
2. 做 **M1**：`git clone edk2-msm` → `./build.sh polaris` → `fastboot boot boot-polaris.img`
3. 把屏幕结果反馈；若 UEFI 菜单出现即进入 M2
4. **同时**可让另一个会话/时间片继续 ABL 链的 0395（补丁已推送，构建结果可从 CI artifact 取）

---

## 7. 已备好的资产（不需要重新收集）

| 资产 | 位置 |
|---|---|
| 我们全部补丁（0001–0395） | `lxsc-zk/polaris-xnu-ci` → `xnu/patches/` |
| 当前内核产物 | `E:\polaris\ci-out\xnu-kernel\kernel.release.sweet` |
| 打包脚本 | `polaris-work/build_image_for.sh`、`mkpayload.py`、`mkbootimg.py` |
| dipper 驱动源码（4718 行） | `/root/polaris-drv/dipper-src/bsd/dev/mi8_adreno.c` |
| dipper 参考补丁 | `polaris-work/dipper/xnu-mi8.patch` |
| A630 实测结论（HFI/OOB/SECVID/板级常量） | `docs/HANDOVER-FULL.md` §2.2 与 §3 |
