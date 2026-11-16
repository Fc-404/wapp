#!/usr/bin/env python3
"""把本地签名块（.signing/signing.json5，不进版本库）合入 build-profile.json5。

用法: python scripts/signing_merge.py [build-profile.json5] [.signing/signing.json5]

- 本地签名文件不存在时什么都不做（仓库里的 build-profile.json5 保持 signingConfigs: []）。
- 只覆盖 app.signingConfigs 一个键，其余内容原样保留。
"""
import json
import os
import sys


def main() -> int:
    profile = sys.argv[1] if len(sys.argv) > 1 else 'build-profile.json5'
    signing_file = sys.argv[2] if len(sys.argv) > 2 else '.signing/signing.json5'

    if not os.path.exists(profile) or not os.path.exists(signing_file):
        return 0

    with open(profile, encoding='utf-8') as f:
        data = json.load(f)
    with open(signing_file, encoding='utf-8') as f:
        signing = json.load(f).get('signingConfigs', [])

    app = data.get('app', {})
    if app.get('signingConfigs') == signing:
        return 0
    app['signingConfigs'] = signing
    data['app'] = app
    with open(profile, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write('\n')
    print('signing merged: %d config(s)' % len(signing))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
