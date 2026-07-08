import SwiftUI

/// 交互稿的暖调配色：米色底、陶土橙点缀
enum Theme {
    static let screen = Color(red: 0.957, green: 0.937, blue: 0.902)      // #f4efe6
    static let card = Color(red: 1.0, green: 0.992, blue: 0.973)          // #fffdf8
    static let cardWarm = Color(red: 0.992, green: 0.973, blue: 0.933)    // #fdf8ee
    static let text = Color(red: 0.149, green: 0.133, blue: 0.11)         // #26221c
    static let sub = Color(red: 0.549, green: 0.514, blue: 0.459)         // #8c8375
    static let accent = Color(red: 0.761, green: 0.255, blue: 0.047)      // #c2410c 陶土橙
    static let green = Color(red: 0.247, green: 0.435, blue: 0.31)        // #3f6f4f
    static let slate = Color(red: 0.357, green: 0.42, blue: 0.62)         // #5b6b9e 行程蓝
    static let red = Color(red: 0.702, green: 0.204, blue: 0.122)         // #b3341f
    static let line = Color(red: 0.36, green: 0.314, blue: 0.235).opacity(0.14)
}

// MARK: 通用组件

struct CardBackground: ViewModifier {
    var warm = false
    func body(content: Content) -> some View {
        content
            .padding(15)
            .background(warm ? Theme.cardWarm : Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.04), radius: 5, y: 2)
    }
}

extension View {
    func cardStyle(warm: Bool = false) -> some View {
        modifier(CardBackground(warm: warm))
    }
}

struct Badge: View {
    let text: String
    var color: Color = Theme.sub

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .heavy))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(color.opacity(0.13))
            .clipShape(Capsule())
    }
}

struct SectionHeader: View {
    let icon: String
    let iconColor: Color
    let title: String
    var count: String? = nil

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 30, height: 30)
                .background(iconColor.opacity(0.13))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(title).font(.system(size: 17, weight: .bold))
            if let count {
                Text(count).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.sub)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}
