#!/bin/bash
# 从 macOS 信息 App 数据库导出收到的短信/iMessage，一行一条、已去重。
# 终端需要「完全磁盘访问权限」（系统设置 → 隐私与安全性 → 完全磁盘访问权限）。
set -euo pipefail

OUT="${1:-sms_raw.txt}"

sqlite3 ~/Library/Messages/chat.db \
  "SELECT DISTINCT replace(replace(text, char(10), ' '), char(13), ' ')
   FROM message
   WHERE is_from_me = 0 AND text IS NOT NULL AND length(text) > 4" \
  | sort -u > "$OUT"

echo "导出完成：$(wc -l < "$OUT") 条 → $OUT"
