// swift-tools-version:6.0
// 回测工具：拿真实短信全量跑分类基线（正则 classify），输出分布与样本清单。
// 模型训出来后加 --model 参数对比 CoreML 模型与正则的分歧。
import PackageDescription

let package = Package(
    name: "Backtest",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../OmnyCore")],
    targets: [
        .executableTarget(name: "backtest",
                          dependencies: [.product(name: "OmnyCore", package: "OmnyCore")]),
    ]
)
