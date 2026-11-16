#!/usr/bin/env python3
"""把 build-profile.json5 里的签名块清空（用于清理历史提交，避免签名信息进公开仓库）。"""
import json
import sys

path = sys.argv[1] if len(sys.argv) > 1 else 'build-profile.json5'
with open(path, encoding='utf-8') as f:
    data = json.load(f)
data.setdefault('app', {})['signingConfigs'] = []
with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write('\n')
