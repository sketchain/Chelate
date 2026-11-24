import SwiftUI
import UIKit

/// Demo mode only (Settings › 数据 › 小组件展示): every widget family at its real size with the
/// demo snapshot, plus the small widget in its offline state.
struct WidgetGalleryView: View {
    @Environment(\.chelateAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    /// Point sizes on 6.1–6.3" iPhones.
    enum Size {
        static let small = CGSize(width: 170, height: 170)
        static let medium = CGSize(width: 364, height: 170)
        static let circular = CGSize(width: 76, height: 76)
        static let rectangular = CGSize(width: 172, height: 76)
    }

    private var now: Date { Date() }

    private var live: NodeWidgetContent {
        NodeWidgetContent(snapshot: .demo(fetchedAt: now.addingTimeInterval(-120)), state: .live)
    }

    private var offline: NodeWidgetContent {
        NodeWidgetContent(snapshot: .demo(fetchedAt: now.addingTimeInterval(-3 * 3600)), state: .offline)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 16) {
                    item("小号") { system(.small, live, size: Size.small) }
                    item("小号 · 离线") { system(.small, offline, size: Size.small) }
                }
                item("中号") { system(.medium, live, size: Size.medium) }
                HStack(alignment: .top, spacing: 16) {
                    item("锁屏圆形") { accessory(.circular, size: Size.circular) }
                    item("锁屏长条") { accessory(.rectangular, size: Size.rectangular) }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("小组件展示")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("widget-gallery")
    }

    private func item<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Home screen widget: system background, 22 pt corners, 16 pt content margins.
    private func system(_ family: NodeWidgetFamily, _ content: NodeWidgetContent, size: CGSize) -> some View {
        NodeWidgetView(content: content, family: family, accent: accent, now: now)
            .padding(16)
            .frame(width: size.width, height: size.height)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.08), radius: 8, y: 2)
    }

    /// Lock screen widget: monochrome on a wallpaper-like dark backdrop.
    private func accessory(_ family: NodeWidgetFamily, size: CGSize) -> some View {
        NodeWidgetView(content: live, family: family, accent: accent, now: now)
            .frame(width: size.width, height: size.height)
            .foregroundStyle(.white)
            .tint(.white)
            .environment(\.colorScheme, .dark)
            .padding(10)
            .background(
                LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.32), Color(red: 0.32, green: 0.22, blue: 0.36)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
    }
}
