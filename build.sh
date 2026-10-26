#!/data/data/com.termux/files/usr/bin/bash
#
# build.sh —— 用 zig 的 aarch64-linux-musl 工具链，把 liburing 与 ublksrv
# 编成完全静态的 ublk 工具集（不依赖 Termux / bionic / libc++ 动态库）。
#
# 用法:
#   ./build.sh                    # 构建到 ./out
#   ./build.sh --prefix /data/adb/ublk
#   ./build.sh --clean            # 先删 work/ out/
#   ./build.sh --jobs 4
#
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK="$HERE/work"
OUT="$HERE/out"
PREFIX=""
JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)

LIBURING_COMMIT=236c1525ff1b2ea5870ecada04951eb2d053275e
LIBURING_SHA256=6424a1e7e62d340b97f36f7661005f9006390d29013574e43657de3742677096
UBLKSRV_COMMIT=6d0d922614ec18e6f2b5d476af8d540a1d9c1de8
UBLKSRV_SHA256=229ed8eb5e721558206f66833b0f371872fd8aed3776407ee28f50a3757de4bb

TARGETS="ublk ublk.null ublk.loop ublk.nbd"

while [ $# -gt 0 ]; do
	case "$1" in
	--prefix) PREFIX="$2"; shift 2 ;;
	--jobs)   JOBS="$2";   shift 2 ;;
	--clean)  rm -rf "$WORK" "$OUT"; shift ;;
	-h|--help) sed -n '3,12p' "$0"; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

say() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31merror: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 工具链
say "检查工具链"
command -v zig >/dev/null || die "缺少 zig：pkg install zig"
command -v patch >/dev/null || die "缺少 patch"
command -v autoreconf >/dev/null || die "缺少 autoconf/automake：pkg install autoconf automake libtool m4"

mkdir -p "$WORK"
TOOLDIR="$WORK/toolchain"
mkdir -p "$TOOLDIR"
cat > "$TOOLDIR/mcc" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
exec zig cc -target aarch64-linux-musl "$@"
EOF
cat > "$TOOLDIR/mcxx" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
exec zig c++ -target aarch64-linux-musl "$@"
EOF
chmod +x "$TOOLDIR/mcc" "$TOOLDIR/mcxx"
export TMPDIR="${TMPDIR:-$WORK/tmp}"
mkdir -p "$TMPDIR"
echo "zig       : $(zig version)"
echo "target    : aarch64-linux-musl"
echo "TMPDIR    : $TMPDIR"

# ---------------------------------------------------------------- 下载
fetch() { # url sha256 outfile
	local url=$1 sum=$2 out=$3
	if [ -f "$out" ] && [ "$(sha256sum "$out" | cut -d' ' -f1)" = "$sum" ]; then
		echo "已缓存: $(basename "$out")"
		return
	fi
	echo "下载: $url"
	curl -fsSL --retry 3 -o "$out.part" "$url" || die "下载失败: $url"
	echo "$sum  $out.part" | sha256sum -c - >/dev/null || die "校验失败: $(basename "$out")"
	mv "$out.part" "$out"
}

say "获取上游源码（固定版本）"
fetch "https://codeload.github.com/axboe/liburing/tar.gz/$LIBURING_COMMIT" \
      "$LIBURING_SHA256" "$WORK/liburing.tar.gz"
fetch "https://codeload.github.com/ublk-org/ublksrv/tar.gz/$UBLKSRV_COMMIT" \
      "$UBLKSRV_SHA256" "$WORK/ublksrv.tar.gz"

rm -rf "$WORK/liburing-src" "$WORK/ublksrv-src"
mkdir -p "$WORK/liburing-src" "$WORK/ublksrv-src"
tar xzf "$WORK/liburing.tar.gz" -C "$WORK/liburing-src" --strip-components=1
tar xzf "$WORK/ublksrv.tar.gz" -C "$WORK/ublksrv-src" --strip-components=1

# ---------------------------------------------------------------- 打补丁
apply_patches() { # dir patchdir
	local dir=$1 pdir=$2 p n=0
	for p in "$pdir"/*.patch; do
		[ -e "$p" ] || continue
		( cd "$dir" && patch -p1 --no-backup-if-mismatch -s < "$p" ) \
			|| die "补丁失败: $(basename "$p")"
		n=$((n + 1))
	done
	echo "已应用 $n 个补丁（$(basename "$pdir")）"
}

say "给 liburing 打补丁"
apply_patches "$WORK/liburing-src" "$HERE/patches/liburing"
say "给 ublksrv 打补丁"
apply_patches "$WORK/ublksrv-src" "$HERE/patches/ublksrv"

# ---------------------------------------------------------------- liburing
if [ -n "$PREFIX" ]; then
	mkdir -p "$PREFIX"
	LIPREFIX=$(realpath -s "$PREFIX")
else
	LIPREFIX=$(realpath -s "$OUT/liburing")
	mkdir -p "$LIPREFIX"
fi

say "编译 liburing（静态，--use-libc）"
cd "$WORK/liburing-src"
./configure --cc="$TOOLDIR/mcc" --cxx="$TOOLDIR/mcxx" \
	--use-libc --prefix="$LIPREFIX" > "$WORK/liburing-configure.log" 2>&1 \
	|| { tail -20 "$WORK/liburing-configure.log"; die "liburing configure 失败"; }
make -j"$JOBS" -C src ENABLE_SHARED=0 liburing.a liburing-ffi.a >> "$WORK/liburing-build.log" 2>&1 \
	|| { tail -30 "$WORK/liburing-build.log"; die "liburing 编译失败"; }
make -C src ENABLE_SHARED=0 install >> "$WORK/liburing-build.log" 2>&1 \
	|| { tail -30 "$WORK/liburing-build.log"; die "liburing install 失败"; }
[ -f "$LIPREFIX/lib/liburing.a" ] || die "liburing.a 未生成"
[ -f "$LIPREFIX/include/liburing.h" ] || die "liburing.h 未安装"
echo "liburing.a: $(du -h "$LIPREFIX/lib/liburing.a" | cut -f1)"

# ---------------------------------------------------------------- ublksrv
say "编译 ublksrv（静态）"
cd "$WORK/ublksrv-src"
autoreconf -i > "$WORK/ublksrv-autoreconf.log" 2>&1 \
	|| { tail -20 "$WORK/ublksrv-autoreconf.log"; die "autoreconf 失败"; }

./configure --prefix="$OUT/root" \
	CC="$TOOLDIR/mcc" CXX="$TOOLDIR/mcxx" \
	LDFLAGS="-static" \
	CPPFLAGS="-I$LIPREFIX/include" \
	LIBURING_CFLAGS="-I$LIPREFIX/include" \
	LIBURING_LIBS="$LIPREFIX/lib/liburing.a" \
	> "$WORK/ublksrv-configure.log" 2>&1 \
	|| { tail -30 "$WORK/ublksrv-configure.log"; die "ublksrv configure 失败"; }

make -j"$JOBS" -C lib LDFLAGS="-all-static" > "$WORK/ublksrv-build.log" 2>&1 \
	|| { tail -40 "$WORK/ublksrv-build.log"; die "libublksrv 编译失败"; }
make -j"$JOBS" LDFLAGS="-all-static" $TARGETS >> "$WORK/ublksrv-build.log" 2>&1 \
	|| { tail -40 "$WORK/ublksrv-build.log"; die "ublksrv 编译失败"; }

# ---------------------------------------------------------------- 收集
say "收集产物"
BINDIR="$OUT/bin"
rm -rf "$BINDIR"; mkdir -p "$BINDIR"
for t in $TARGETS; do
	[ -x "$t" ] || die "缺少产物: $t"
	cp "$t" "$BINDIR/$t"
	strip --strip-all "$BINDIR/$t" 2>/dev/null || true
	readelf -d "$BINDIR/$t" 2>/dev/null | grep -q NEEDED \
		&& die "$t 不是静态链接"
done
chmod 755 "$BINDIR"/*

# ---------------------------------------------------------------- 可选安装
if [ -n "$PREFIX" ]; then
	say "安装到 $PREFIX"
	mkdir -p "$PREFIX/bin"
	cp "$BINDIR"/* "$PREFIX/bin/"
	chmod 755 "$PREFIX/bin"/*
fi

say "完成"
printf '%-16s %s\n' "产物目录" "$BINDIR"
ls -la "$BINDIR" | sed '1d'
echo
echo "静态性:"
for t in $TARGETS; do
	printf '  %-12s %s\n' "$t" "$(readelf -l "$BINDIR/$t" 2>/dev/null | grep -c INTERP | sed 's/^0$/无解释器(D) 静态/;s/^1$/有解释器 动态!/')"
done
echo
echo "下一步: 用 root 跑 $BINDIR/ublk features 验证 ioctl 通路"
