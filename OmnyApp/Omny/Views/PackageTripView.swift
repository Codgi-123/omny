import SwiftUI

/// 包裹·行程合并页（issue #10）：快递、行程两个列表合并进一个 tab，
/// 顶部分段控件（纯文字两段，按 HIG 不混图文）在两者间切换，腾出的 tab 位给记账。
/// 薄容器：标题栏（ScreenHeader + NavActions）与分段控件收在这一层，
/// 列表内容原样复用 ListViews.swift 的 ExpressView / TripView（各自的空态、
/// 复制取件码、拖动排序、下拉刷新等交互不受影响）。
struct PackageTripView: View {
    /// 分段标识：rawValue 持久化进 AppStorage，勿改既有值。
    enum Segment: Int, CaseIterable, Identifiable {
        case express = 0   // 快递
        case trip = 1      // 行程

        var id: Int { rawValue }
        var title: String { self == .express ? "快递" : "行程" }
    }

    /// 分段选择存 AppStorage：既记住用户上次停留的分段，也充当首页「查看详情」的
    /// 跨页传参通道——TodayView 的快递/行程区块先写目标分段再切 tab，本页读同一键
    /// 直接呈现（避免 NotificationCenter 的时序问题）；之后该值即成为「上次分段」。
    @AppStorage("omnyPackageTripSegment") private var segmentRaw = Segment.express.rawValue

    private var segment: Segment { Segment(rawValue: segmentRaw) ?? .express }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("包裹·行程") { NavActions() }

            Picker("类别", selection: $segmentRaw) {
                ForEach(Segment.allCases) { seg in
                    Text(seg.title).tag(seg.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.Space.page)
            .padding(.bottom, 6)

            switch segment {
            case .express: ExpressView()
            case .trip: TripView()
            }
        }
        .background(Theme.screen)
        .toolbar(.hidden, for: .navigationBar)
    }
}
