# ublk-musl —— 针对 Android/Termux 的 musl 静态 ublk 工具集

用 zig 自带的 `aarch64-linux-musl` 工具链，把
[liburing](https://github.com/axboe/liburing) 与
[ublksrv](https://github.com/ublk-org/ublksrv) 编成**完全静态**的二进制。

产物不依赖 Termux、bionic、libc++ 或任何 `.so`，可以直接放进
`/data/adb/`，在开机脚本（此时 `LD_LIBRARY_PATH`/`$PREFIX` 都不可靠）
里使用。

## 为什么需要这些补丁

上游两个项目都假设 glibc + 可写的 `/run`：

| 补丁 | 问题 | 影响 |
|---|---|---|
| liburing/0001 | `configure` 里 `mktemp /tmp/test_bpf_XXXXXX` | Termux 的 `/tmp` 不可写 → `has_bpf_clang` 探测误判，configure 报错退出 |
| ublksrv/0001 | `demo_null`/`demo_event` 依赖 glibc 专有的 `<error.h>`；`ublk_user_id` 用 CC 链接 C++ 库 | bionic/musl 下 `make` 直接失败。都是示例/辅助程序，从 `noinst_PROGRAMS` 移除并让 aux 程序用 CXX 链接 |
| ublksrv/0002 | `sys/prctl.h` + `linux/prctl.h` 双包含 | musl 的两个头都定义了 `struct prctl_mm_map` → 重复定义报错 |
| ublksrv/0003 | `strdupa()` 在 C++ 里不可用 | musl/glibc 的实现是 `strcpy(alloca(...))`，`void*`→`char*` 在 C++ 非法 |
| ublksrv/0004 | `uint32_t __unused[...]`（sheepdog 协议头） | `__unused` 是编译器的属性宏，做字段名会炸 |
| ublksrv/0005 | `.msg_iovlen = ... ? 2UL : 1UL` | clang 对 `unsigned long`→`int` 的窄化报错 |
| ublksrv/0006 | run dir 固定 `/run/ublksrvd` | Android 的 `/` 只读 → 每条命令报 `ENOENT`。改为在 `/run` 不可写时回落到 `$TMPDIR/ublksrvd` 或 `/data/local/tmp/ublksrvd` |
| ublksrv/0007 | 日志只走 `syslog()` | Android 没有 `/dev/log`，出错时完全静默。镜像一份到 `stderr` |
| ublksrv/0008 | `libublksrv.so` 的 C++ 源（`ublksrv_json.cpp`）拿不到 `LIBURING_CFLAGS` | 用外置/自编 liburing 时 `<liburing.h>` 找不到 |

## 用法

```sh
pkg install zig autoconf automake libtool m4 patch   # 一次性
./build.sh                                            # → out/bin/
./build.sh --prefix /data/adb/ublk                    # 顺便装到指定目录
./build.sh --clean --jobs 4
```

固定版本（构建可复现）：

| 项目 | commit | tarball sha256 |
|---|---|---|
| liburing | `236c1525ff1b2ea5870ecada04951eb2d053275e` | `6424a1e7…7096` |
| ublksrv | `6d0d922614ec18e6f2b5d476af8d540a1d9c1de8` | `229ed8eb…e4bb` |

## 产物

`out/bin/` 下四个静态二进制（strip 后各约 660–700 KB）：

| 程序 | 作用 |
|---|---|
| `ublk` | 主控：`add` / `del` / `list` / `features` |
| `ublk.loop` | 后端 = 本地镜像文件（`-f image`，默认 direct IO） |
| `ublk.null` | 后端 = 空设备（压测/自检） |
| `ublk.nbd` | 后端 = NBD 服务器（`--host/--port` 或 `--unix`） |

## 在 Android 上使用

```sh
# 1. 起一个后端（前台占住，或用 setsid/nohup 放后台）
ublk.loop add -n 0 -f /data/local/tmp/disk.img &

# 2. udev 不会替你建节点，自己来
DEV=$(cat /sys/block/ublkb0/dev)
mknod /dev/ublkb0 b ${DEV%:*} ${DEV#*:}

# 3. 当普通块设备用
mkfs.ext4 -F /dev/ublkb0
mount -t ext4 /dev/ublkb0 /mnt/x

# 4. 收尾
umount /mnt/x; ublk del -n 0
```

要点：

* **`/dev/ublk-control` 需要 root**（`crw------- root root`）。
* `ublkbN` 的节点 **ueventd 不会创建**（没有对应规则），必须自己 `mknod`。
* 后端是用户态进程：**进程退出设备就没了**，长期使用请配 `runit`/`supervisord` 或前台常驻。
* 与 loop 的差别：ublk 的 IO 由你的进程直接 `read/write` backing file，
  **不经过 loop 的 LSM 复查**，所以镜像文件放在 `shell_data_file`（`/data/local/tmp`）
  也能正常工作——这是 loop 会 `EIO` 的那类场景。
* `pid_max` 无关；ublk 不碰 pid。

## 验证

`build.sh` 结束时自检：每个产物都必须没有 `INTERP`（即静态）。
端到端（`mkfs` → `mount` → 写文件 → `umount` → 用 `strings` 在 backing
file 里找到写入内容）已在原厂内核（`6.6.89-…-g7e1f3c083cc6`，Android 16）上通过。
