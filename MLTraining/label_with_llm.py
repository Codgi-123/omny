#!/usr/bin/env python3
"""LLM 批量打标：一行一条的短信 txt → text,label 两列的 CSV。

标签：trip / package / todo / other（定义见 README.md）。
仅用标准库；协议与 App 内 LLMClient 一致（Claude / OpenAI 兼容二选一）。

用法：
  export LLM_PROTOCOL=claude|openai LLM_BASE_URL=... LLM_API_KEY=... LLM_MODEL=...
  python3 label_with_llm.py sms_raw.txt labeled.csv
"""
import csv
import json
import os
import sys
import time
import urllib.request

LABELS = {"trip", "package", "todo", "other"}
BATCH = 20

SYSTEM = """你给中文短信打分类标签，只能从四个标签中选：
- trip: 火车/航班行程通知（12306、航司、购票平台的车次/航班/乘车提醒）
- package: 快递物流全流程（揽收/在途/派送/待取/取件码/驿站/柜机/签收）
- todo: 明确要求收件人做某件事的事务提醒（还款、缴费、预约确认、会议、截止日期），注意营销诱导点击不算
- other: 其余一切（营销推广、验证码、银行动账、工资、运营商提醒、诈骗）
输入是一个 JSON 数组，每个元素是一条短信。
只输出 JSON 数组，长度与输入一致，每个元素是对应短信的标签字符串，不要任何其他文字。"""


def request_labels(texts: list[str]) -> list[str]:
    protocol = os.environ["LLM_PROTOCOL"]
    base = os.environ["LLM_BASE_URL"].rstrip("/")
    key = os.environ["LLM_API_KEY"]
    model = os.environ["LLM_MODEL"]
    user = json.dumps(texts, ensure_ascii=False)

    if protocol == "claude":
        url = f"{base}/v1/messages"
        headers = {"x-api-key": key, "anthropic-version": "2023-06-01"}
        body = {"model": model, "max_tokens": 1024, "system": SYSTEM,
                "messages": [{"role": "user", "content": user}]}
    else:
        url = f"{base}/v1/chat/completions"
        headers = {"Authorization": f"Bearer {key}"}
        body = {"model": model, "max_tokens": 1024,
                "messages": [{"role": "system", "content": SYSTEM},
                             {"role": "user", "content": user}]}
    headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, json.dumps(body).encode(), headers)
    with urllib.request.urlopen(req, timeout=120) as resp:
        payload = json.load(resp)
    if protocol == "claude":
        content = next(b["text"] for b in payload["content"] if b["type"] == "text")
    else:
        content = payload["choices"][0]["message"]["content"]
    content = content.strip().removeprefix("```json").removeprefix("```").removesuffix("```")

    labels = json.loads(content)
    if len(labels) != len(texts) or not all(l in LABELS for l in labels):
        raise ValueError(f"标签数量或取值不合法：{labels}")
    return labels


def main() -> None:
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, encoding="utf-8") as f:
        texts = [line.strip() for line in f if line.strip()]

    done: dict[str, str] = {}
    if os.path.exists(dst):  # 断点续跑：已标过的行直接跳过
        with open(dst, encoding="utf-8") as f:
            done = {row["text"]: row["label"] for row in csv.DictReader(f)}

    pending = [t for t in texts if t not in done]
    print(f"共 {len(texts)} 条，其中 {len(pending)} 条待标注")

    with open(dst, "a", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        if not done:
            writer.writerow(["text", "label"])
        for i in range(0, len(pending), BATCH):
            batch = pending[i:i + BATCH]
            try:
                labels = request_labels(batch)
            except Exception as e:  # 失败批次跳过并记录，跑完后重跑本脚本即可续标
                print(f"[跳过] 第 {i}-{i + len(batch)} 条：{e}", file=sys.stderr)
                continue
            writer.writerows(zip(batch, labels))
            f.flush()
            print(f"{min(i + BATCH, len(pending))}/{len(pending)}")
            time.sleep(0.3)


if __name__ == "__main__":
    main()
