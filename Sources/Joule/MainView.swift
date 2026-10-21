import JouleCore
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case now, history, apps, battery, alerts
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .now: "Jetzt"
        case .history: "Verlauf"
        case .apps: "Apps"
        case .battery: "Akku"
        case .alerts: "Hinweise"
        }
    }
}

struct MainView: View {
    @EnvironmentObject private var monitor: Monitor
    @AppStorage("page") private var page = Page.now.rawValue

    private var current: Page { Page(rawValue: page) ?? .now }

    var body: some View {
        ZStack {
            WindowGlass().ignoresSafeArea()
            Group {
                switch current {
                case .now: NowView()
                case .history: HistoryView()
                case .apps: AppsView()
                case .battery: BatteryView()
                case .alerts: AlertsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                NavBar(selection: Binding(get: { current }, set: { page = $0.rawValue }), unread: monitor.unreadAlerts)
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink { Image(systemName: "gearshape") }.help("Einstellungen")
            }
        }
        .navigationTitle("Joule")
        .liveSampling(monitor)
        .tint(Theme.accent)
    }
}

/// The five sections as a segmented bar in the middle of the toolbar.
struct NavBar: View {
    @Binding var selection: Page
    var unread: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Page.allCases) { item in
                let selected = item == selection
                Button { selection = item } label: {
                    HStack(spacing: 5) {
                        Text(item.title)
                        if item == .alerts && unread > 0 {
                            Text("\(unread)")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Theme.accent))
                        }
                    }
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 5)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .shadow(color: .black.opacity(0.14), radius: 1.5, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
        .fixedSize()
        .animation(.snappy(duration: 0.2), value: selection)
    }
}

/// Shared page frame: scrolls, centred, comfortable reading width.
struct PageScroll<Content: View>: View {
    var maxWidth: CGFloat = 1080
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) { content }
                .padding(.horizontal, 36)
                .padding(.top, 28)
                .padding(.bottom, 40)
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
        }
    }
}
