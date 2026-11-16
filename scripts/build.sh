#!/usr/bin/env bash
# 统一构建入口：固定 DevEco 环境变量，避免每次手敲。
# 用法: scripts/build.sh [hvigor 任务...]   默认 assembleHap
set -euo pipefail

DEV="${DEV:-/c/Program Files/Huawei/DevEco Studio}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# hvigor 读这个环境变量找 SDK（不设会 00303217）
export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-C:\\Program Files\\Huawei\\DevEco Studio\\sdk}"

# 签名/打包阶段 spawn 的是 Windows 进程，PATH 里的 /c/... 形式它认不出，
# 必须塞 Windows 形式的 jbr 路径 + JAVA_HOME，否则 PackageHap 报 "spawn java ENOENT"。
JBR_WIN="$(cygpath -w "$DEV/jbr")"
export JAVA_HOME="$JBR_WIN"
export PATH="$JBR_WIN\\bin;$PATH"

if [ $# -eq 0 ]; then
  set -- assembleHap --mode module -p product=default -p buildMode=debug
fi

# 签名信息不放进版本库：本地 .signing/signing.json5 存在时临时合入，构建完还原
PROFILE="$ROOT/build-profile.json5"
BACKUP="$(mktemp)"
cp "$PROFILE" "$BACKUP"
restore() {
  cp "$BACKUP" "$PROFILE"
  rm -f "$BACKUP"
}
trap restore EXIT INT TERM

PythonBin=$(command -v python || command -v python3 || true)
if [ -n "$PythonBin" ]; then
  "$PythonBin" "$ROOT/scripts/signing_merge.py" "$PROFILE" "$ROOT/.signing/signing.json5" || true
fi

"$DEV/tools/node/node.exe" "$DEV/tools/hvigor/bin/hvigorw.js" "$@" --no-daemon
