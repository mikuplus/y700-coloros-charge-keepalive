#!/usr/bin/env python3
"""打包 KernelSU / Magisk 模块 zip。

用法：
    python3 build.py
    python3 build.py --list      # 只列出已有产物

产物：
    releases/charge_keepalive_fix_<版本>.zip   当前版本，刷这个
    releases/history/...                       每次内容变化前的自动备份
    charge_keepalive_fix.zip                   根目录快捷副本（始终最新）

版本号取自 module.prop 的 version= 行。小改动重复打包会覆盖同名文件，
内容有变化时旧包自动挪进 history/，不会丢。
"""
import datetime
import os
import shutil
import sys
import zipfile

# (文件名, 权限)
FILES = [
    ("module.prop", 0o644),
    ("service.sh", 0o755),
    ("worker.sh", 0o755),
    ("config.prop", 0o644),
    ("webroot/index.html", 0o644),
]

ROOT = os.path.dirname(os.path.abspath(__file__))
OUTDIR = os.path.join(ROOT, "releases")
HISTDIR = os.path.join(OUTDIR, "history")
LATEST = os.path.join(ROOT, "charge_keepalive_fix.zip")


def read_version() -> str:
    with open(os.path.join(ROOT, "module.prop"), encoding="utf-8") as f:
        for line in f:
            if line.startswith("version="):
                return line.split("=", 1)[1].strip() or "dev"
    return "dev"


def safe_name(ver: str) -> str:
    return "charge_keepalive_fix_" + ver.replace("/", "_").replace(" ", "_") + ".zip"


def build_zip(path: str) -> None:
    """把模块文件写进 zip；脚本统一转成 LF。"""
    now = datetime.datetime.now().timetuple()[:6]
    with zipfile.ZipFile(path, "w") as zf:
        for name, mode in FILES:
            with open(os.path.join(ROOT, name), "rb") as f:
                data = f.read()
            # 脚本必须是 LF，否则 Android 上 sh 会报语法错误
            data = data.replace(b"\r\n", b"\n")

            zi = zipfile.ZipInfo(name)
            zi.external_attr = mode << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.date_time = now
            zf.writestr(zi, data)


def main() -> int:
    if "--list" in sys.argv:
        if not os.path.isdir(OUTDIR):
            print("还没有产物")
            return 0
        for name in sorted(os.listdir(OUTDIR)):
            p = os.path.join(OUTDIR, name)
            if os.path.isfile(p):
                print(f"{name}  {os.path.getsize(p):,} bytes")
        return 0

    missing = [n for n, _ in FILES if not os.path.isfile(os.path.join(ROOT, n))]
    if missing:
        print("缺少文件：" + ", ".join(missing), file=sys.stderr)
        return 1

    ver = read_version()
    os.makedirs(HISTDIR, exist_ok=True)

    target = os.path.join(OUTDIR, safe_name(ver))
    tmp = os.path.join(OUTDIR, ".build.tmp")
    build_zip(tmp)

    with open(tmp, "rb") as f:
        new_data = f.read()

    changed = True
    if os.path.isfile(target):
        with open(target, "rb") as f:
            old_data = f.read()
        changed = old_data != new_data
        if changed:
            # 上次同版本的包先存进 history，再被新内容覆盖
            stamp = datetime.datetime.fromtimestamp(
                os.path.getmtime(target)).strftime("%Y%m%d-%H%M%S")
            base = os.path.splitext(safe_name(ver))[0]
            bak = os.path.join(HISTDIR, f"{base}_{stamp}.zip")
            shutil.move(target, bak)
            print(f"旧包已备份 → releases/history/{os.path.basename(bak)}")

    os.replace(tmp, target)
    shutil.copyfile(target, LATEST)

    size = os.path.getsize(target)
    print(f"版本 {ver}  {'已更新' if changed else '无变化'}")
    print(f"releases/{os.path.basename(target)}  {size:,} bytes  ({len(FILES)} files)")
    print(f"charge_keepalive_fix.zip  {os.path.getsize(LATEST):,} bytes（根目录快捷副本）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
