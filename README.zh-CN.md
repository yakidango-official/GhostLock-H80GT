[English](README.md) | 中文

# 荣耀80 GT 提权 PoC：GhostLock (CVE-2026-43499)

适用于荣耀80 GT（AGT-AN00，MagicOS 8.0.0.128，内核5.10.168）的本地提权exploit，以及配套的KernelSU内核模块加载方案。

> ⚠️ **警告**
>
> - 仅供在**自己的设备**上做安全研究。
> - **使用风险自负**。本软件不提供任何担保（见[LICENSE](LICENSE)）。单纯运行本项目理论上不会变砖或丢失数据，但仍建议先做好备份；无论后果来自运行本代码还是root之后的任何操作，都与本项目无关。
> - exploit借助UAF漏洞改写内核内存，失败时设备会自动重启，重启后复原。成功率不是100%，失败了重跑即可。
> - **获取root权限之后请自己把握好分寸**。本项目只负责帮你拿到root；刷镜像、写分区、关防护、乱装模块把机器搞砖，本项目概不负责。

## 仓库结构

```
exploit/     exploit源码(Android arm64)与构建系统
  src/         exploit核心：漏洞触发、KASLR、boot_id劫持、任意读写、
               cred/SELinux/sig_enforce修改、KSU加载
  src/targets/ 按固件划分的偏移表(target.h)
ksu/         自编译kernelsu.ko与PC侧adb加载脚本
  tools/       设备端加载辅助(源码、策略规则、加载脚本模板)
```

## 使用方法

需要：Docker、Android Platform Tools。

使用预构建包（仅在MagicOS 8.0.0.128上通过测试）：[h80gt_setup.sh](https://github.com/yakidango-official/GhostLock-H80GT/releases/download/v0.1/h80gt_setup.sh)

```sh
adb push h80gt_setup.sh /sdcard/
adb shell sh /sdcard/h80gt_setup.sh     # 或在Shizuku(rish)里跑
```

要自己编译的话：

```sh
# 1. 编译exploit
cd exploit && ./docker-build.sh bin             # 生成exploit_static
#    (./docker-build.sh ondevice生成免环境变量的静态版;
#     首次运行会下载NDK,约1.2GB)

# 2. 准备KSU相关文件到ksu/tools/
#    见ksu/tools/README.md(kernelsu_h80gt.ko的编译方法见ksu/README.md;
#    ksud已随仓库提供;magiskpolicy已随仓库提供;
#    load_ko/kmsg_dumper由./docker-build.sh tools编译)

# 3. 手机打开ADB调试，
bash ../ksu/ksu_load_ko.sh
```

脚本会自动完成：exploit提权并翻转`sig_enforce`→注入SELinux策略→bind-mount伪造的kallsyms→加载.ko→ksud初始化→最后恢复SELinux enforcing。`/proc/modules`里出现`kernelsu`后，打开KernelSU管理器（显示“工作中&lt;LKM&gt;[越狱模式]”）就能用了。

## 为什么要自编译.ko和自己的加载器

- `CONFIG_MODULE_SIG_FORCE=y`运行时`sig_enforce`标志会阻止未签名模块加载，exploit过程会将其临时翻转为0（模块加载完成后由加载脚本恢复为1）。
- kallsyms符号名被抹除。荣耀把`commit_creds`等符号从`/proc/kallsyms`里删掉了，内核加载模块时解析不到。解决办法是bind-mount一份伪造的kallsyms，把缺的符号按真实运行时地址（链接地址+KASLR slide）补在最前面。
- 另外，GKI的结构体布局和荣耀的不一样，官方GKI的`android12-5.10_kernelsu.ko`无法直接使用。所以`ksu/`用MagicOS 5.10.168内核源码和设备自己的`/proc/config.gz`重编了KernelSU v3.2.5，细节见`ksu/README.md`。

## 验证状态

完整链路（提权→KASLR→任意读写→cred→SELinux permissive→sig_enforce→KernelSU存活→恢复enforcing）已在真机跑通。

## 致谢

- [CyberMeowfia/IonStack](https://github.com/NebuSec/CyberMeowfia)
- [KernelSU](https://github.com/tiann/KernelSU) 
- [Magisk](https://github.com/topjohnwu/Magisk) 

## 许可证

- `exploit/`与文档：**Apache License 2.0**（见[LICENSE](LICENSE)），与上游PoC一致。
- `ksu/`：**GPL-2.0**（见[ksu/LICENSE](ksu/LICENSE)），`init-h80gt.patch`与`ksu_rules.annotated`衍生自KernelSU的`kernel/`目录。

