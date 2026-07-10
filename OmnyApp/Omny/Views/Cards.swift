import SwiftUI
import SwiftData
import OmnyCore

// MARK: - 快递卡（取件码大字 + 复制 + 标记已取）
// 卡片本体不带背景——作为 List 单元格时由分组表提供表面；作首页轮播时外层加 .cardStyle()。

struct PackageCard: View {
    @Bindable var item: InboxItem
    @Environment(\.modelContext) private var context
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 头部：图标与标题垂直居中；右侧状态标签
            HStack(spacing: 12) {
                IconChip(symbol: "shippingbox.fill", color: Theme.express)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.carrier ?? "快递")
                        .font(.headline)
                    if let station = item.station {
                        Text(station)
                            .font(.subheadline)
                            .foregroundStyle(Theme.sub)
                            .lineLimit(1)
                    }
                }
                Spacer()
                statusTag
            }

            // 主体：取件码（点按复制）/ 单号，右侧「已取」按钮
            HStack(alignment: .bottom, spacing: 12) {
                if let code = item.pickupCode {
                    Button {
                        UIPasteboard.general.string = code
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(copied ? "已复制取件码" : "取件码 · 点按复制")
                                .font(.caption)
                                .foregroundStyle(copied ? Theme.green : Theme.sub)
                            Text(code)
                                .font(.system(size: 34, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.express)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("复制取件码")
                } else if let number = item.trackingNumber ?? item.trackingTail {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("单号")
                            .font(.caption)
                            .foregroundStyle(Theme.sub)
                        Text(number)
                            .font(.title3)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 8)
                pickupButton
            }

            // 底部：收件时间
            Text(receivedText)
                .font(.caption)
                .foregroundStyle(Theme.sub)
        }
        .contentShape(Rectangle())
        .contextMenu {
            if let code = item.pickupCode {
                Button {
                    UIPasteboard.general.string = code
                } label: {
                    Label("复制取件码", systemImage: "doc.on.doc")
                }
            }
        }
    }

    // 收件时间：不显示年，带星期几，固定按 UTC+8 展示（例：7月10日周五 23:44）
    // locale 锁死简体中文——否则跟随系统语言，英文机上会显示成 "Fri, Jul 10 at ..."
    private var receivedText: String {
        item.createdAt.formatted(
            Date.FormatStyle(locale: Locale(identifier: "zh_CN"),
                             timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
                .month().day().weekday(.abbreviated).hour().minute()
        )
    }

    // 取件按钮：未取时是明确的动作 CTA「确认取件」（实心蓝，避免 ✅ 误解为已完成）；
    // 已取后变成浅绿确认态「已取件」，再点可撤销
    private var pickupButton: some View {
        let done = item.packageStatus == .pickedUp
        return Button {
            item.packageStatus = done ? .awaitingPickup : .pickedUp
            try? context.save()
        } label: {
            Group {
                if done {
                    Label("已取件", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.green)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)          // 高度 ≥44pt 触控目标
                        .background(Theme.green.opacity(0.15), in: Capsule())
                } else {
                    Text("确认取件")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Theme.express, in: Capsule())
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(done ? "撤销取件" : "确认取件")
    }

    private var statusTag: some View {
        switch item.packageStatus {
        // 只有"待取"是需要用户行动的状态 → 用强调色；其余是信息态 → 中性灰
        case .awaitingPickup: StatusTag(text: "待取", color: Theme.express)
        case .outForDelivery: StatusTag(text: "派送中", color: Theme.sub)
        case .inTransit: StatusTag(text: "在途", color: Theme.sub)
        case .pickedUp: StatusTag(text: "已签收", color: Theme.sub)
        }
    }
}

// MARK: - 行程卡（时间路线 + 倒计时）

struct TripCard: View {
    let item: InboxItem

    private var isFlight: Bool { item.tripKindRaw == "flight" }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                IconChip(symbol: isFlight ? "airplane" : "tram.fill", color: Theme.trip, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.tripNumber ?? "行程")
                        .font(.headline)
                    if let seat = item.seat {
                        Text(seat)
                            .font(.caption)
                            .foregroundStyle(Theme.sub)
                    }
                }
                Spacer()
                if let depart = item.departAt {
                    StatusTag(text: countdown(to: depart) + "后", color: Theme.trip)
                }
            }
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.departAt?.formatted(date: .omitted, time: .shortened) ?? "--:--")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                    Text(item.departPlace ?? "出发")
                        .font(.footnote)
                        .foregroundStyle(Theme.sub)
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.footnote)
                    .foregroundStyle(Theme.sub)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(item.arriveAt?.formatted(date: .omitted, time: .shortened) ?? "--:--")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                    Text(item.arrivePlace ?? "到达")
                        .font(.footnote)
                        .foregroundStyle(Theme.sub)
                }
            }
            if let date = item.departAt {
                HStack {
                    Text(date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().weekday()))
                        .font(.caption)
                        .foregroundStyle(Theme.sub)
                    Spacer()
                }
            }
        }
    }

    private func countdown(to date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        if seconds < 3600 { return "\(max(1, Int(seconds / 60))) 分钟" }
        if seconds < 48 * 3600 { return "\(Int(seconds / 3600)) 小时" }
        return "\(Int(seconds / 86400)) 天"
    }
}

// MARK: - 待办行（勾选 + 同步状态）

struct TodoRow: View {
    @Bindable var item: InboxItem
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var dida: DidaService
    @State private var editing = false

    private var isLocal: Bool { item.canEditLocally }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                item.todoCompleted.toggle()
                // 滴答待办：完成/取消完成要标脏并回写滴答；本地待办纯本地，只存不同步
                if item.isDidaSynced { item.needsPush = true }
                try? context.save()
                if item.isDidaSynced { Task { await dida.syncNow(context: context) } }
            } label: {
                Image(systemName: item.todoCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(item.todoCompleted ? Theme.green : Theme.sub)
                    .frame(width: 44, height: 44)          // ≥44pt 触控目标
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.todoCompleted ? "标记为未完成" : "标记为完成")

            VStack(alignment: .leading, spacing: 2) {
                Text(item.todoTitle ?? item.rawText)
                    .font(.body)
                    .strikethrough(item.todoCompleted)
                    .foregroundStyle(item.todoCompleted ? Theme.sub : Theme.text)
                Text(syncMeta)
                    .font(.caption)
                    .foregroundStyle(Theme.sub)
            }
            Spacer()
            if let due = item.todoDue {
                Text(dueLabel(due))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(isToday(due) ? Theme.accent : Theme.sub)
            }
        }
        // 本地待办：点按编辑、左滑删除/编辑；滴答待办只读（仅完成勾选可用）
        .contentShape(Rectangle())
        .onTapGesture { if isLocal { editing = true } }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if isLocal {
                Button(role: .destructive) { delete() } label: { Label("删除", systemImage: "trash") }
                Button { editing = true } label: { Label("编辑", systemImage: "pencil") }
                    .tint(Theme.slate)
            }
        }
        .contextMenu {
            if isLocal {
                Button { editing = true } label: { Label("编辑", systemImage: "pencil") }
                Button(role: .destructive) { delete() } label: { Label("删除", systemImage: "trash") }
            }
        }
        .sheet(isPresented: $editing) { TodoEditSheet(item: item, onDelete: delete) }
    }

    private func delete() {
        // 本地待办不涉及同步，直接删除
        context.delete(item)
        try? context.save()
    }

    private var syncMeta: String {
        guard item.isDidaSynced else { return "仅本地" }
        return item.needsPush ? "待同步" : "已同步滴答"
    }

    private func dueLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "今天 " + date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month().day())
    }

    private func isToday(_ date: Date) -> Bool {
        Calendar.current.isDateInToday(date)
    }
}

// MARK: - 本地待办编辑弹窗（改标题/截止时间 + 删除）。仅用于本地来源待办。

struct TodoEditSheet: View {
    @Bindable var item: InboxItem
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var title: String
    @State private var hasDue: Bool
    @State private var due: Date

    init(item: InboxItem, onDelete: @escaping () -> Void) {
        self.item = item
        self.onDelete = onDelete
        _title = State(initialValue: item.todoTitle ?? item.rawText)
        _hasDue = State(initialValue: item.todoDue != nil)
        _due = State(initialValue: item.todoDue ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("内容") {
                    TextField("标题", text: $title)
                }
                Section("截止时间") {
                    Toggle("设置截止时间", isOn: $hasDue.animation())
                    if hasDue {
                        DatePicker("截止", selection: $due)
                    }
                }
                Section {
                    Button("删除待办", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
            }
            .navigationTitle("编辑待办")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        let trimmed = title.trimmingCharacters(in: .whitespaces)
                        item.todoTitle = trimmed.isEmpty ? item.rawText : trimmed
                        item.todoDue = hasDue ? due : nil
                        try? context.save()
                        dismiss()
                    }
                }
            }
        }
    }
}
