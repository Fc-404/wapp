#!/usr/bin/env bash
# 一键：构建 → 装机 → 启动 WebAbility
# 前置：手机 USB 连接、已开 USB 调试；首次签名需在 DevEco Studio 里登录账号并勾自动签名。
set -euo pipefail

DEV="${DEV:-/c/Program Files/Huawei/DevEco Studio}"
HDC="$DEV/sdk/default/openharmony/toolchains/hdc.exe"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "== targets =="
"$HDC" list targets

echo "== build =="
scripts/build.sh

HAP="entry/build/default/outputs/default/entry-default-signed.hap"
if [ ! -f "$HAP" ]; then
  echo "!! 没有 signed hap：$HAP"
  echo "   说明工程还没配置签名。在 DevEco Studio 打开本工程 → File → Project Structure →"
  echo "   Signing Configs → 勾选 Automatically generate signature（需登录华为账号、手机已连接），"
  echo "   再重跑本脚本。"
  exit 1
fi

echo "== install =="
"$HDC" install -r "$HAP"

echo "== start =="
"$HDC" shell aa start -a WebAbility -b com.xazh.wapp
