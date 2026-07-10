// 分类回测：对一行一条的短信文件跑分类器，输出四分类分布 + 每类样本清单。
//
// 用法：
//   swift run backtest <sms_raw.txt>                    # 正则基线（RuleParser.classify）
//   swift run backtest <sms_raw.txt> <模型.mlmodelc>     # CoreML 模型，并打印与正则的分歧
//
// 输出：stdout 打印分布统计；同目录生成 backtest_<分类器>.csv（text,pred）供人工核对。
import Foundation
import NaturalLanguage
import OmnyCore

// 四分类标签：与 MLTraining 训练标签一致（bookmark 并入 other，短信场景无收藏类）
func ruleLabel(_ text: String) -> String {
    switch RuleParser.classify(text) {
    case .package: "package"
    case .trip: "trip"
    case .todo: "todo"
    case .bookmark, nil: "other"
    }
}

guard CommandLine.arguments.count >= 2 else {
    print("用法：swift run backtest <sms_raw.txt> [模型.mlmodelc]")
    exit(1)
}
let lines = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
    .split(separator: "\n").map(String.init).filter { !$0.isEmpty }

var mlModel: NLModel?
if CommandLine.arguments.count >= 3 {
    let url = URL(fileURLWithPath: CommandLine.arguments[2])
    mlModel = try NLModel(contentsOf: url)
}

let name = mlModel == nil ? "rules" : "model"
var counts: [String: Int] = [:]
var samples: [String: [String]] = [:]
var disagreements: [(String, String, String)] = []  // (text, rule, model)
var csv = "text,pred\n"

for text in lines {
    let rule = ruleLabel(text)
    let pred: String
    if let mlModel {
        pred = mlModel.predictedLabel(for: text) ?? "other"
        if pred != rule { disagreements.append((text, rule, pred)) }
    } else {
        pred = rule
    }
    counts[pred, default: 0] += 1
    if samples[pred, default: []].count < 20 { samples[pred, default: []].append(text) }
    csv += "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\",\(pred)\n"
}

print("== 分布（\(name)，共 \(lines.count) 条）==")
for (label, n) in counts.sorted(by: { $0.value > $1.value }) {
    let pct = Double(n) / Double(lines.count) * 100
    print("  \(label.padding(toLength: 8, withPad: " ", startingAt: 0)) \(n)  \(String(format: "%.1f", pct))%")
}
print("\n== 每类样本（前 20 条，人工核对误分）==")
for (label, texts) in samples.sorted(by: { $0.key < $1.key }) {
    print("\n-- \(label) --")
    texts.forEach { print("  \($0.prefix(60))") }
}
if !disagreements.isEmpty {
    print("\n== 模型 vs 正则分歧（共 \(disagreements.count) 条，逐条看谁对）==")
    for (text, rule, model) in disagreements.prefix(50) {
        print("  [正则 \(rule) | 模型 \(model)] \(text.prefix(50))")
    }
}

let outPath = "backtest_\(name).csv"
try csv.write(toFile: outPath, atomically: true, encoding: .utf8)
print("\n完整预测已写入 \(outPath)")
