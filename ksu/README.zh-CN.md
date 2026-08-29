[English](README.md) | 中文

# 荣耀80 GT 定制 KernelSU.ko

官方GKI的`android12-5.10_kernelsu.ko`是按GKI头文件编译的，结构体布局与荣耀设备不一致，无法正常加载。需要用荣耀自己的内核源码（MagicOS开源包）以及设备原版的`/proc/config.gz`重新编译，以确保所有偏移都是正确的。在KernelSU源码上打了三处补丁：

1. **注入SELinux策略**。规则改为在加载模块前用magiskpolicy --live注入，而非由模块自己注入（`tools/ksu_rules`）。
2. **禁用自动恢复enforcing**。加载脚本把恢复enforcing放在最后一步手动做，过早恢复会导致exploit的root进程无法写文件、执行程序。
3. **修复boot_id指向**。exploit劫持了boot_id的内存指针且不会复原，这会导致app启动崩溃，模块加载时把它指回真正的缓冲区。


## 构建

需要荣耀MagicOS开源内核树（AGT-AN00开源包里的`Code_Opensource/kernel`目录，
子版本匹配目标固件：8.0.0.128 用 MagicOS 8.0 树（5.10.168），8.0.0.160 起用
MagicOS 9.0 树（5.10.209））：

```
KERNEL_SRC=/path/to/Code_Opensource/kernel bash ksu_ko_build.sh
```

本目录的 `kernel.config` 是一份 5.10.236 设备配置（5.10.236 各版本固件的
配置逐字节一致），作为构建默认值；发布的 kernelsu.ko 固定使用这份
配置编译，以保证任何人从仓库重新构建都能得到完全相同的文件。各支持
固件的配置编译出的内核结构布局相同，所以编出来的 .ko 在所有支持的
固件上都能加载；仍想用其他固件的配置编译的话，用 `KSU_DEVICE_CONFIG`
传入（设备的 `/proc/config.gz`，或 boot.img 的 `extract-ikconfig` 输出）：

```
KERNEL_SRC=/path/to/Code_Opensource/kernel KSU_DEVICE_CONFIG=/path/to/your_config bash ksu_ko_build.sh
```

设备config、KernelSU源码（首次运行自动克隆并打好补丁；上游版本由 ksu_ko_build.sh 锁定）、设备符号名列表都由脚本自动准备到`ksu/.build/`。产物为`ksu/.build/kernelsu.ko`，复制到`tools/kernelsu.ko`即可使用。

## 加载

```
bash ksu_load_ko.sh
```

脚本会自动完成：exploit提权→注入策略→加载.ko→ksud初始化→最后恢复enforcing。

## 已知边界：模块的 sepolicy.rule 与运行时策略变更

模块的`sepolicy.rule`由ksud的动态注入（`handle_sepolicy`）在加载窗口内应用——已真机验证，包括同一次会话内连续两轮应用。`handle_sepolicy`与`apply_kernelsu_rules`都采用"复制＋RCU替换＋销毁"的流程（均不调用`security_load_policy`）；该机制未在本设备上出过问题。2026-08的一次servicemanager故障曾归因于此，后查明真因是exploit自身的宽容化写清除了`selinux_state.initialized@+2`（见`init-bootid.patch`内注释）。在加载窗口之外运行时应用规则（如enforcing状态下安装/启用模块）尚未验证——此类模块请通过热重启生效。