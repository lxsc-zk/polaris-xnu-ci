# Polaris GPU 移植 · 会话交接包

> 生成时间：2026-11-04 01:45（Windows 侧，切换黑苹果之前）
> 目的：Windows 关机后，macOS 侧凭这份文件即可无缝接续。

## 一、当前状态（一句话）

**dipper 的 4718 行 Adreno 630 驱动已完整编进 polaris 内核，并在这台手机上跑完 22 步；SECVID 曾成功归零（退出安全模式）；只差「保持运行 → 画图」这一环。**

## 二、已完成的关键里程碑

| 项 | 证据 | 补丁 |
|---|---|---|
| GMU 地址空间用 bring-up 的 SMMU 实现 | 第 16 步不再复位 | 0333/0334 |
| **HFI 五条消息全部 `err=0`** | `HFI6: id=0..5 err=0x0` | **0365**（dipper 协议） |
| rail 授权 22/30、SPTPRAC、3D 核 16/24 | `ack 30 ACKED` / `status 0x28` | 0367/0368 |
| CX 上电含 clk-dis-wait=8 | 第 4 步 `CX is on` | 0372 |
| 22 步全过（我方式 bring-up） | `step 22: done` | 0379 |
| **dipper 驱动编入内核** | 内核含 `mi8_adreno.o` | 0384b/0385/0387/0388/0391 |
| GPU 独占 | `mi8gpu=22 given; dipper's mi8_adreno owns the GPU` | 0393 |
| 保持运行（未生效，待修） | — | 0394 |
| **SECVID 归零** | `SECVID=0x00000000 after 43173 polls` | （0391 那轮） |

## 三、下一步（唯一未完成项）

`mi8_keep = true` 没能阻止回滚，因为保持运行需要**三个条件同时成立**：

```c
if (mi8_keep && gpu_set && cp_ok && gpu_nonsecure) {
    ... gpu_keep_begin(); return true;
}
```

**0395 = 加一行诊断**，在 `bsd/dev/mi8_adreno.c` 该判断前打印：

```c
printf("mi8gpu: keep decision: mi8_keep=%d gpu_set=%d cp_ok=%d gpu_nonsecure=%d\n",
       mi8_keep, gpu_set, cp_ok, gpu_nonsecure);
```

日志里出现该行后，就能确定是 `cp_ok` 还是 `gpu_nonsecure` 为 false，然后针对性修。

## 四、仓库与文件位置

| 内容 | 位置 |
|---|---|
| 补丁（0001–0394，约 80 个） | `github.com/lxsc-zk/polaris-xnu-ci` → `xnu/patches/` |
| 构建定义（权威） | 同仓库 `.github/workflows/xnu.yml` |
| 驱动树快照（每补丁一份） | Windows: `/root/polaris-drv/treeNNN`（WSL） |
| 知识文档 | Windows: `polaris-work/*.md` |
| dipper 抽取源码 | Windows: `/root/polaris-drv/dipper-src/`、`polaris-work/dipper/` |
| 镜像与 CI 产物 | Windows: `E:\polaris\` |

## 五、macOS 侧构建步骤（照 CI 抄）

```bash
# 1. 工具链
xcode-select --install
# 装 Xcode 13.4.1 / 13.6（对应 macOS 13 的 SDK，与 XNU 8796 匹配）
xcrun --find iig                      # CI 用它做打包校验

# 2. 仓库
git clone https://github.com/lxsc-zk/polaris-xnu-ci.git
cd polaris-xnu-ci

# 3. 构建基座
git clone https://github.com/blacktop/darwin-xnu-build.git dxb
cd dxb && git checkout 663906528d1cd5ea8fde7de6f16de73db9511549

# 4. 套补丁（CI 的做法：按文件名顺序 apply 到 dxb/xnu）
for p in $(ls ../xnu/patches/*.patch | sort); do
  git apply -p1 --whitespace=nowarn --include='bsd/*' "$p" || echo "SKIP $(basename $p)"
done

# 5. 编译（与 CI 相同）
MAKEFLAGS='-k -s' bash build.sh 2>&1 | tee build.log
# 产物: build/xnu.obj/RELEASE_ARM64_SWEET/kernel.release.sweet
```

## 六、打包与刷机（macOS 侧）

```bash
brew install --cask android-platform-tools

# 打包（需要 mkpayload.py / mkbootimg.py / 六个 A630 blob）
python3 tools/mkpayload.py   <kernel> payload.bin
python3 tools/mkbootimg.py   payload.bin shim.img --kernel ... 
# 或者沿用 build_image_for.sh（需改内核路径）

fastboot devices
fastboot boot shim.img
```

> 注意：`E:\` 是 NTFS，macOS 只能读不能可靠写。切换前把 `E:\polaris\ci-out\` 与 `polaris-work\` 复制到 **exFAT 分区或 U 盘**。

## 七、板级差异清单（移植时必须遵守）

| 项 | dipper | polaris（实测） |
|---|---|---|
| MMIO 基址 / 寄存器偏移 | SDM845 通用 | 一致 ✅ |
| GMU SID / 3D SID | 4,5 / 0 | 一致 ✅ |
| RSCC 基址 | 0x0508db00 | **0x0508d000** |
| MX 索引来源 | `mx.lvl` | 查询失败 → **强制 3** |
| SPTPRAC 控制 / 状态 | 自带定义 | **0x204 / 0x340** |
| 帧缓冲 | — | **0x9d400000，stride 4320** |
| rail 与 HFI 顺序 | rail→HFI | 两序皆通 |
| TrustZone GPU 授权 | 有（edk2 链） | **`GPU 0/0`（ABL 链未注册）** |

## 八、长期路线（两条腿）

1. **主线**：修完 0395 → `painting pass` → 接 Mesa/EAGL
2. **副线**：edk2-msm + DarwinBoot（`SPRMD/UniXNU-polaris` 已证明在 polaris 能启动到 `Failed to mount root device`），可根治 TrustZone 未授权问题；edk2 固件**在 Linux 上就能编**，不需要 Mac

## 九、切换后如何恢复这个会话

1. macOS 里若 DSH 能装，新开会话后**把本文件与 `polaris-work/*.md` 发给模型**即可接上
2. 若 macOS 不支持，就用 GitHub Issue/README 承载，或切回 Windows 会话（历史仍在本机 `%USERPROFILE%\.dsh`）
3. 本文件建议同时提交到仓库 `docs/SESSION-HANDOVER.md`，保证任何机器都能 `git clone` 取到
