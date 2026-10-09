import AIMonitorCore
import SwiftUI

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var model: MonitorModel
    @StateObject private var attention = Attention()

    private var colorScheme: ColorScheme? {
        switch model.appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// Weekday + month + day, honoring the app's own language setting rather
    /// than the raw system locale — so "zh" stays "zh" even when the user's
    /// chosen app language differs from the OS language, and vice versa.
    static func headerDate(_ lang: Language) -> String {
        let fmt = DateFormatter()
        fmt.locale = lang.resolved == .zh ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US")
        fmt.dateFormat = lang.resolved == .zh ? "M月d日 EEE" : "EEE, MMM d"
        return fmt.string(from: Date())
    }

    var body: some View {
        RootContent()
            .environment(\.appAnimations, model.animationsEnabled)
            .environment(\.isAttended, attention.attended)
            .environment(\.lowPowerMode, attention.lowPower)
            // A new skin repaints everything: colours are read at draw time,
            // and a fresh identity is the one way to make every view draw.
            .id(model.skin)
            .preferredColorScheme(model.skin.forcedScheme ?? colorScheme)
    }
}

/// Split from `RootView` so the motion budget read here already includes the
/// app's own Animations switch injected above.
private struct RootContent: View {
    @EnvironmentObject var model: MonitorModel
    @Environment(\.motionBudget) private var motion

    private var page: Page { model.page }

    var body: some View {
        VStack(spacing: 0) {
            // Header: the skin's mark and a serif wordmark, then the tabs.
            HStack(alignment: .center, spacing: 8) {
                BrandMark()
                    .frame(width: 17, height: 17)
                    .accessibilityHidden(true)
                Text(L10n.text(.appTitle, model.language))
                    .font(Theme.serif(19, weight: .medium))
                    .foregroundStyle(Theme.text)
                Spacer()
                if model.skin == .nocturne {
                    MoonPhaseBadge(lang: model.language)
                }
                Text(RootView.headerDate(model.language))
                    .font(.system(size: 11, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 22).padding(.top, 24).padding(.bottom, 12)
            .frame(maxWidth: Theme.readingWidth)
            .frame(maxWidth: .infinity)

            TabStrip(page: page, lang: model.language) { p in
                withAnimation(motion.animation(Motion.turn)) { model.setPage(p) }
            }
            .padding(.horizontal, 22).padding(.bottom, 10)
            .frame(maxWidth: Theme.readingWidth)
            .frame(maxWidth: .infinity)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            Group {
                switch page {
                case .dashboard: DashboardView()
                case .timeline: TimelineView()
                case .models: ModelsView()
                case .receipt: ReceiptView()
                case .settings: SettingsView()
                }
            }
            // `id(page)` makes each page a distinct view so the transition can
            // tell them apart: the new page rises in, the old one fades.
            .id(page)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: motion.allowsTravel ? 8 : 0)),
                removal: .opacity
            ))
        }
        // The skin's ground: Claude's ivory printed as a manga manuscript
        // sheet, or a night sky.
        .background(SkinSheet())
    }
}

/// Claude-style segmented control: a sunken well with a pill that slides to
/// the selected page. The pill has the skin's mark on top — ears, or an ahoge.
private struct TabStrip: View {
    let page: Page
    let lang: Language
    let select: (Page) -> Void
    @Namespace private var pill
    @Environment(\.motionBudget) private var motion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Page.allCases, id: \.self) { p in
                Button { select(p) } label: {
                    Text(p.label(lang))
                        .font(.system(size: 12, weight: page == p ? .semibold : .medium))
                        .foregroundStyle(page == p ? Theme.text : Theme.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background {
                            if page == p {
                                SkinPill(trigger: Page.allCases.firstIndex(of: page) ?? 0)
                                    .matchedGeometryEffect(id: "tab-pill", in: pill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Not merely "don't draw the ring" — don't take focus at all.
                // AppKit was handing first responder to the leading tab on
                // launch and firing its action, which silently reset the
                // remembered tab before the window was ever seen.
                .focusable(false)
            }
        }
        .padding(3)
        .background(Theme.sunken, in: Capsule(style: .continuous))
        .animation(motion.animation(Motion.press), value: page)
        .focusEffectDisabled()
    }
}
