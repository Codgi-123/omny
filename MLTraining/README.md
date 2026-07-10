# 文本分类小模型训练

训练一个跑在手机端的四分类 CoreML 模型，作为解析漏斗的第一级：
分类免费跑在端上，只有 trip / package / todo 才值得花 LLM 抽字段，other 直接落需处理或丢弃。
服务两个入口：短信（快捷指令自动化）与截屏 OCR 文本。

## 标签体系

| label | 定义 | 例子 |
|---|---|---|
| `trip` | 火车/航班行程通知（12306、航司、购票平台） | 「您购买的G101次列车…」 |
| `package` | 快递物流**全流程**：揽收/在途/派送/待取/取件码/签收 | 「凭37-1-6311到保利创智锦城店取…」 |
| `todo` | 明确要求收件人做某件事的事务提醒：还款、缴费、预约确认、会议、截止日期 | 「您的信用卡本期账单…最后还款日7月15日」 |
| `other` | 其余一切：营销推广、验证码、银行动账、工资、运营商提醒、诈骗 | 「【天猫】双11狂欢…回T退订」 |

注意两个类目设计决策：

- **package 覆盖全状态而不只取件码**——在途/签收短信也要认出来，快递合并链路（状态只前进）依赖它们；只训「取件码」会把在途短信推去 other。
- **todo 的正样本大头不在短信**：短信里只有还款/缴费/预约这一小类；聊天记录、会议纪要式的自由文本主要靠截屏 OCR 进来。给 todo 收集样本时要两种文风都覆盖（短信体 + 聊天/纪要体），否则截屏入口的分类会拉胯。

## 数据管线

```sh
# 1. 导出自己的全部历史短信（分布最匹配的数据；终端需要完全磁盘访问权限）
./export_sms.sh sms_raw.txt

# 2.（补充 other/junk 样本量）从 80w 公开垃圾短信数据集抽几千条
#    https://github.com/ysh329/spam-msg-classifier 或天池 https://tianchi.aliyun.com/dataset/6480

# 3. LLM 批量打标（读一行一条的 txt，输出 text,label 两列的 CSV）
export LLM_PROTOCOL=claude LLM_BASE_URL=https://api.anthropic.com \
       LLM_API_KEY=sk-xxx LLM_MODEL=claude-opus-4-8
python3 label_with_llm.py sms_raw.txt labeled.csv

# 4. 人工抽查 5% 标签质量；troubleshoot 后重跑有问题的批次

# 5. 训练（Apple Silicon 上几千条样本约 1~3 分钟）
xcrun swift train_classifier.swift labeled.csv TextKindClassifier.mlmodel
```

## 评估标准（比总准确率重要）

- **盯 trip/package 的召回**：真快递被判成 other 等于漏掉取件码，代价最高；
- other 的精度可以松：误放行的营销短信后面还有 LLM 拒识和需处理兜底；
- 测试集只用自己的真实短信（公开数据集分布和自己手机不一致，评估会虚高）；
- 推理侧要带置信度阈值：分类置信度低于阈值时放行给正则 classify 兜底，不硬判。

## 集成规划（模型训出来后）

- CoreML 模型**只放 `OmnyApp` 层**（CoreML 不跨平台，进 OmnyCore 会挂 Linux CI）；
- `OmnyCore` 定义 `TextKindClassifier` 协议，现有正则 `RuleParser.classify` 是跨平台实现兼降级路径，App 层注入 CoreML 实现——与 `HTTPTransport` 注入范式一致；
- 长期规划见 TODO.md：提取环节先由 LLM 承担并自动积累 (原文, 字段) 标注对，
  攒够后蒸馏成按类型分置的 `MLWordTagger` 抽取小模型，LLM 退居兜底。
