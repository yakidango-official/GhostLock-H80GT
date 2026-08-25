[English](README.md) | 中文

# 荣耀80 GT 定制 KernelSU.ko

官方GKI的`android12-5.10_kernelsu.ko`是按GKI头文件编的，结构体布局和荣耀的对不上，无法正常加载。需要用荣耀自己的内核源码（MagicOS开源包）以及设备原版的`/proc/config.gz`重新编译，以确保所有偏移都是正确的。在KernelSU v3.2.5的`kernel/core/init.c`上打了三处补丁：

1. **注入SELinux策略**。规则改成在加载模块前用magiskpolicy --live注入（`tools/ksu_rules`）。
2. **禁用自动恢复enforcing**。加载脚本把恢复enforcing放在最后一步手动做，过早恢复会导致kernel域的anchor无法写文件、执行程序。
3. **修复boot_id指向**。exploit劫持了boot_id的内存指针且不会复原，这会导致app启动崩溃，模块加载时把它指回真正的缓冲区。  


## 构建

只需要荣耀MagicOS 8.0开源内核树（AGT-AN00开源包里的`Code_Opensource/kernel`目录）：

```
KERNEL_SRC=/path/to/Code_Opensource/kernel bash ksu_ko_build.sh
```

本目录的 `kernel.config` 是 8.0.0.128 的设备配置（取自 `/proc/config.gz`），
作为构建默认值。编出来的 .ko 在所有支持的固件上都能加载；想用自己固件的
配置编译的话，用 `KSU_DEVICE_CONFIG` 传入（设备的 `/proc/config.gz`，或
boot.img 的 `extract-ikconfig` 输出）：

```
KERNEL_SRC=/path/to/Code_Opensource/kernel KSU_DEVICE_CONFIG=/path/to/kernel.config bash ksu_ko_build.sh
```

设备config、KernelSU v3.2.5源码（首次运行自动克隆并打好补丁）、设备符号名列表都由脚本自动准备到`ksu/.build/`。产物为`ksu/.build/kernelsu.ko`，复制到`tools/kernelsu.ko`即可使用。

## 加载

```
APK=/path/to/KernelSU_v3.2.5_32525-release.apk bash ksu_load_ko.sh
```

脚本会自动完成：exploit提权→注入策略→加载.ko→ksud初始化→最后恢复enforcing。