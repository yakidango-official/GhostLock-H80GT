[English](README.md) | 中文

# 荣耀80 GT 提权 PoC：GhostLock (CVE-2026-43499)

适用于荣耀80 GT（AGT-AN00）的本地提权exploit（CVE-2026-43499，内核rtmutex `remove_waiter`路径的UAF），以及配套的KernelSU内核模块加载方案。

原理上，本项目的漏洞和利用手法对9.0.0.230及之前的所有MagicOS版本都成立。已适配的版本：

| MagicOS | 内核 | 状态 |
|---|---|---|
| 8.0.0.128 | 5.10.168 | ✅ 已验证 |
| 8.0.0.160 | 5.10.209 | ✅ 已验证 |
| 9.0.0.157 | 5.10.209 | ✅ 已验证 |
| 9.0.0.200SP1 | 5.10.236 | ✅ 已验证 |
| 9.0.0.220SP2 / SP4 | 5.10.236 | ✅ 已验证（SP4与SP2的boot镜像相同） |
| 9.0.0.230 | 5.10.236 | ✅ 已验证 |
| 8.0.0.131 | 5.10.198 | ⚠️ 未验证 |
| 8.0.0.161 | 5.10.209 | ⚠️ 未验证 |
| 9.0.0.102 / 120 / 130 / 165 | 5.10.209 | ⚠️ 未验证 |
| 9.0.0.175SP1 / 187 | 5.10.226 | ⚠️ 未验证 |
| 9.0.0.210 | 5.10.236 | ⚠️ 未验证 |

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

预构建包一个包覆盖所有支持的固件：在[Releases](../../releases)里下载，在电脑上解压后运行

```sh
./setup.sh            # 电脑上运行（需adb）：识别内核、自动选择对应的
                      # exploit、启动整条链，偶发失败会自动重试
```

没有电脑的话，把包解压到手机上，用Shizuku的shell（rish）跑同一个脚本即可——脚本会自动识别运行环境：

```sh
sh /sdcard/ghostlock/setup.sh
```

脚本按运行中的内核匹配清单：已验证版本直接执行，已知但未验证的版本会先确认，其余拒绝执行。

要自己编译的话：

```sh
# 1. 编译exploit
cd exploit && ./docker-build.sh bin             # 生成exploit_static(8.0.0.128)
#    8.0.0.160: ./docker-build.sh PROJECT=annap-AGT-AN00_8.0.0.160 bin
#    (./docker-build.sh ondevice生成免环境变量的静态版;
#     首次运行会下载NDK,约1.2GB)

# 2. 准备KSU相关文件到ksu/tools/
#    见ksu/tools/README.md(kernelsu.ko的编译方法见ksu/README.md,
#    需用与固件内核子版本匹配的开源树编译;
#    ksud已随仓库提供;magiskpolicy已随仓库提供;
#    load_ko/kmsg_dumper由./docker-build.sh tools编译)

# 3. 手机打开ADB调试，
bash ../ksu/ksu_load_ko.sh
#    8.0.0.160: PROJECT=annap-AGT-AN00_8.0.0.160 bash ../ksu/ksu_load_ko.sh
```

脚本会自动完成：exploit提权并翻转`sig_enforce`→注入SELinux策略→bind-mount伪造的kallsyms→加载.ko→ksud初始化→最后恢复SELinux enforcing。`/proc/modules`里出现`kernelsu`后，打开KernelSU管理器（显示“工作中&lt;LKM&gt;[越狱模式]”）就能用了。

## 为什么要自编译.ko和自己的加载器

- `CONFIG_MODULE_SIG_FORCE=y`运行时`sig_enforce`标志会阻止未签名模块加载，exploit过程会将其临时翻转为0（模块加载完成后由加载脚本恢复为1）。
- kallsyms符号名被抹除。荣耀把`commit_creds`等符号从`/proc/kallsyms`里删掉了，内核加载模块时解析不到。解决办法是bind-mount一份伪造的kallsyms，把缺的符号按真实运行时地址（链接地址+KASLR slide）补在最前面。
- 另外，GKI的结构体布局和荣耀的不一样，官方GKI的`android12-5.10_kernelsu.ko`无法直接使用。所以`ksu/`用与固件内核子版本匹配的MagicOS内核源码和设备自己的内核配置重编了KernelSU v3.2.5，细节见`ksu/README.md`。

## 验证状态

上表所有版本均在真机上跑通完整链条（UAF→KASLR→任意读写→cred→SELinux宽容→sig_enforce→KernelSU加载、恢复enforcing、还原boot_id）。单次运行有约四分之一的概率中途失败并重启手机，setup.sh会自动重试，手动重跑一次也可以。


## 致谢

- [CyberMeowfia/IonStack](https://github.com/NebuSec/CyberMeowfia)
- [KernelSU](https://github.com/tiann/KernelSU) 
- [Magisk](https://github.com/topjohnwu/Magisk) 

## 许可证

- `exploit/`与文档：**Apache License 2.0**（见[LICENSE](LICENSE)），与上游PoC一致。
- `ksu/`：**GPL-2.0**（见[ksu/LICENSE](ksu/LICENSE)），`init-bootid.patch`与`ksu_rules.annotated`衍生自KernelSU的`kernel/`目录。

