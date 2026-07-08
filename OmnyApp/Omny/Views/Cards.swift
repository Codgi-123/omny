import SwiftUI
import SwiftData
import OmnyCore

// MARK: - 快递卡（取件码大字 + 复制 + 标记已取）

struct PackageCard: View {
    @Bindable var item: InboxItem
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(item.carrier ?? "快递")
                    .font(.system(size: 16, weight: .bold))
                if let station = item.station {
                    Text("· \(station)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.sub)
                        .lineLimit(1)
                }
                Spacer()
                statusBadge
            }

            if let code = item.pickupCode {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("取件码")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.sub)
                            .kerning(1)
                        Text(code)
                            .font(.system(size: 28, weight: .black, design: .rounded))
                            .monospacedDigit()
                            .kerning(1)
                    }
                    Spacer()
                    Button {
                        item.packageStatus = .pickedUp
                    } label: {
                        Image(systemName: "checkmark.circle")
                            .frame(width: 38, height: 38)
                            .background(Theme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
                    }
                    .buttonStyle(.plain)
                    Button {
                        UIPasteboard.general.string = code
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
                .padding(11)
                .background(Theme.card.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            } else if let number = item.trackingNumber ?? item.trackingTail {
                Text("单号 \(number)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.sub)
            }

            Text("来自\(item.source.rawValue) · \(item.createdAt.formatted(.relative(presentation: .named)))")
                .font(.system(size: 12))
                .foregroundStyle(Theme.sub)
        }
        .cardStyle()
    }

    private var statusBadge: some View {
        switch item.packageStatus {
        case .awaitingPickup: Badge(text: "待取", color: Theme.accent)
        case .pickedUp: Badge(text: "已签收", color: Theme.sub)
        case .outForDelivery: Badge(text: "派送中", color: Theme.slate)
        case .inTransit: Badge(text: "在途", color: Theme.slate)
        }
    }
}

// MARK: - 行程卡（时间路线 + 倒计时）

struct TripCard: View {
    let item: InboxItem

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(item.tripNumber ?? "行程")
                    .font(.system(size: 16, weight: .bold))
                if let seat = item.seat {
                    Text("· \(seat)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.sub)
                }
                Spacer()
                if let depart = item.departAt {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(countdown(to: depart))
                            .font(.system(size: 19, weight: .black))
                            .foregroundStyle(Theme.accent)
                        Text("后出发")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(Theme.sub)
                    }
                }
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.departAt?.formatted(date: .omitted, time: .shortened) ?? "--:--")
                        .font(.system(size: 30, weight: .bold))
                        .monospacedDigit()
                    Text(item.departPlace ?? "出发")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.sub)
                }
                Spacer()
                Image(systemName: item.tripKindRaw == "flight" ? "airplane" : "tram")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.slate)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.screen))
                    .overlay(Circle().strokeBorder(Theme.slate.opacity(0.3), lineWidth: 1.5))
                    .padding(.top, 8)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(item.arriveAt?.formatted(date: .omitted, time: .shortened) ?? "--:--")
                        .font(.system(size: 30, weight: .bold))
                        .monospacedDigit()
                    Text(item.arrivePlace ?? "到达")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.sub)
                }
            }
            if let date = item.departAt {
                HStack {
                    Text(date.formatted(.dateTime.month().day().weekday()))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.sub)
                    Spacer()
                }
            }
        }
        .cardStyle(warm: true)
    }

    private func countdown(to date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        if seconds < 3600 { return "\(max(1, Int(seconds / 60)))min" }
        if seconds < 48 * 3600 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))天"
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
        HStack(spacing: 11) {
            Button {
                item.todoCompleted.toggle()
                // 滴答待办：完成/取消完成要标脏并回写滴答；本地待办纯本地，只存不同步
                if item.isDidaSynced { item.needsPush = true }
                try? context.save()
                if item.isDidaSynced { Task { await dida.syncNow(context: context) } }
            } label: {
                Image(systemName: item.todoCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.green)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.todoTitle ?? item.rawText)
                        .font(.system(size: 15, weight: .semibold))
                        .strikethrough(item.todoCompleted)
                        .foregroundStyle(item.todoCompleted ? Theme.sub : Theme.text)
                    Badge(text: isLocal ? "本地" : "滴答",
                          color: isLocal ? Theme.slate : Theme.accent)
                }
                Text(syncMeta)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.sub)
            }
            Spacer()
            if let due = item.todoDue {
                Text(dueLabel(due))
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(isToday(due) ? Theme.accent : Theme.sub)
            }
        }
        .cardStyle()
        // 本地待办：点按编辑、长按删除；滴答待办只读（仅完成勾选可用）
        .contentShape(Rectangle())
        .onTapGesture { if isLocal { editing = true } }
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
