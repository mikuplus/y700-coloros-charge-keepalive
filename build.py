#!/usr/bin/env python3
"""打包 KernelSU / Magisk 模块 zip。

用法：
    python3 build.py

产物：charge_keepalive_fix.zip（只含模块运行所需文件，
README / LICENSE / build.py 不会被打进去）
"""
import datetime
import os
import sys
import zipfile

# (文件名, 权限)
FILES = [
    ("module.prop", 0o644),
    ("service.sh", 0o755),
    ("worker.sh", 0o755),
    ("config.prop", 0o644),
]

OUT = "charge_keepalive_fix.zip"


def main() -> int:
    missing = [n for n, _ in FILES if not os.path.isfile(n)]
    if missing:
        print("缺少文件：" + ", ".join(missing), file=sys.stderr)
        return 1

    now = datetime.datetime.now().timetuple()[:6]

    with zipfile.ZipFile(OUT, "w") as zf:
        for name, mode in FILES:
            with open(name, "rb") as f:
                data = f.read()
            # 脚本必须是 LF，否则 Android 上 sh 会报语法错误
            data = data.replace(b"\r\n", b"\n")

            zi = zipfile.ZipInfo(name)
            zi.external_attr = mode << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.date_time = now
            zf.writestr(zi, data)

    size = os.path.getsize(OUT)
    print(f"{OUT}  {size:,} bytes  ({len(FILES)} files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
