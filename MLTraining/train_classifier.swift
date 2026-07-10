// 训练四分类文本模型（trip/package/todo/other）并输出 CoreML 模型。
// 用法：xcrun swift train_classifier.swift labeled.csv TextKindClassifier.mlmodel
// CSV 需含 text,label 两列。BERT 迁移学习要求 macOS 14+ 训练、iOS 17+ 运行。
// 注意：ModelParameters 的参数名随 Xcode 版本略有差异，编译报错时按提示微调。
import CreateML
import Foundation
import NaturalLanguage

guard CommandLine.arguments.count == 3 else {
    print("用法：xcrun swift train_classifier.swift <labeled.csv> <输出.mlmodel>")
    exit(1)
}
let dataURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outURL = URL(fileURLWithPath: CommandLine.arguments[2])

let table = try MLDataTable(contentsOf: dataURL)
let (train, test) = table.randomSplit(by: 0.85, seed: 42)

let model = try MLTextClassifier(
    trainingData: train, textColumn: "text", labelColumn: "label",
    parameters: MLTextClassifier.ModelParameters(
        algorithm: .transferLearning(.bertEmbedding, revision: 1),
        language: .simplifiedChinese))

let metrics = model.evaluation(on: test, textColumn: "text", labelColumn: "label")
print("测试集误分类率：\(metrics.classificationError)")
print("各类精度/召回（重点盯 trip/package 的召回）：")
print(metrics.precisionRecall)

try model.write(to: outURL, metadata: MLModelMetadata(
    author: "Omny",
    shortDescription: "短信/OCR 文本四分类：trip/package/todo/other",
    version: "0.1"))
print("已输出：\(outURL.path)")
