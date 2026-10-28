import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case status
    case activity
    case persona
    case settings
    case help

    var id: Self { self }

    var title: String {
        rawValue.capitalized
    }
}

struct PopoverRootView: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 14) {
                AppTabBar(model: model)

                Group {
                    switch model.selectedTab {
                    case .status:
                        StatusView(model: model)
                    case .activity:
                        ActivityView(model: model)
                    case .persona:
                        PersonaView(model: model)
                    case .settings:
                        SettingsView(model: model)
                    case .help:
                        HelpView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(versionLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(CoffeeTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("app-version")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 16)
            .frame(width: 406)

            if model.isQuitReceiptPresented {
                QuitReceiptView(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .zIndex(1)
            }
        }
        // AppKit can propose more height than a tab's intrinsic content needs.
        // Fill that proposal and keep the tabs at the top instead of centring
        // the shorter Settings content between transparent bands.
        .frame(maxHeight: .infinity, alignment: .top)
        .background(CoffeeTheme.surface)
        .tint(CoffeeTheme.caramel)
        .preferredColorScheme(.dark)
        .animation(
            .easeOut(duration: 0.14),
            value: model.isQuitReceiptPresented
        )
        .onAppear {
            model.popoverDidAppear()
        }
    }

    /// Read the running bundle so the displayed release always follows the installed app.
    private var versionLabel: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        else { return "Development build" }
        return "Version \(version) · Build \(build)"
    }
}

private struct AppTabBar: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                let isActive = model.selectedTab == tab
                Button {
                    model.selectTab(tab)
                } label: {
                    VStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Text(tab.title)
                            if tab == .activity, model.hasUnreadActivity {
                                Circle()
                                    .fill(CoffeeTheme.unreadBadge)
                                    .frame(width: 5, height: 5)
                                    .accessibilityHidden(true)
                            }
                        }
                        .font(
                            .system(
                                size: 12,
                                weight: isActive ? .semibold : .regular
                            )
                        )
                        .foregroundStyle(
                            isActive
                                ? CoffeeTheme.primaryText
                                : CoffeeTheme.muted
                        )

                        Rectangle()
                            .fill(isActive ? CoffeeTheme.caramel : .clear)
                            .frame(height: 2)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    tab == .activity && model.hasUnreadActivity
                        ? "Activity, new events"
                        : tab.title
                )
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
        }
        .background(alignment: .bottom) {
            Rectangle()
                .fill(CoffeeTheme.divider)
                .frame(height: 1)
        }
    }
}
