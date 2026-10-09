import AIMonitorCore
import SwiftUI

/// The shareable image of today's usage: the dashboard's hero as a poster.
/// Ivory ground, a serif greeting, the day's number in heavy rounded
/// lettering, the kitten as a sticker in her spotlight, provider split and
/// quota rings underneath. Rendered off-screen by `ImageRenderer` at 2× and
/// saved as PNG — always in the light theme, the way a printed card would be.
struct ShareCardView: View {
    let d: StoreReport.Dashboard
    let lang: Language

    private var zh: Bool { lang.resolved == .zh }

    var body: some View {
        ZStack {
            Theme.window
            // The spotlight, once more: behind the kitten on the right.
            Circle()
                .fill(RadialGradient(colors: [Theme.accent.opacity(0.28), Theme.accent.opacity(0)],
                                     center: .center, startRadius: 0, endRadius: 210))
                .frame(width: 420, height: 420)
                .position(x: 700, y: 190)

            switch Skin.current {
            case .observatory: EmptyView()
            case .aubade: DayHeroBackdrop()
            case .nocturne: NightHeroBackdrop()
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 10) {
                    BrandMark().frame(width: 22, height: 22)
                    Text("AI Monitor")
                        .font(Theme.serif(24, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Text(Self.headerDate(lang))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                }
                .padding(.bottom, 26)

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(zh ? "今日 token" : "Tokens today")
                            .font(Theme.serif(20))
                            .foregroundStyle(Theme.textSecondary)
                        Text(CardReport.compact(d.todayTokens, lang: lang))
                            .font(Theme.figure(88))
                            .tracking(-1)
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        HStack(spacing: 8) {
                            StatChip(symbol: "arrow.up.arrow.down", value: "\(d.todayRequests)",
                                     label: zh ? "次请求" : "requests")
                            StatChip(symbol: "clock", value: StoreReport.duration(minutes: d.todayActiveMinutes),
                                     label: zh ? "活跃时长" : "active")
                            StatChip(symbol: "dollarsign",
                                     value: d.todayCostUSD.map { String(format: "%.2f", $0) } ?? "n/a",
                                     label: zh ? "折合费用" : "cost equiv.")
                        }
                    }
                    Spacer()
                    // A still image, so the kitten holds a single cel. At night
                    // she is in the moon mirror and by day in a photograph, as
                    // on the dashboard.
                    let mood: MascotState.Mood = d.todayTokens == 0 ? .butterfly : .happy
                    switch Skin.current {
                    case .nocturne:
                        MoonMirror {
                            Mascot(mood: mood, width: 220, tilt: 0, flexible: true, mirror: true, animated: false)
                        }
                        .frame(width: 220, height: 220)
                    case .aubade:
                        InstantPhoto(caption: nil) {
                            Mascot(mood: mood, width: 200, tilt: 0, flexible: true, animated: false)
                        }
                        .frame(width: 214)
                    case .observatory:
                        Mascot(mood: mood, width: 230, tilt: 2, animated: false)
                    }
                }
                .padding(.bottom, 26)

                HStack(alignment: .top, spacing: 18) {
                    // Provider split — the dashboard's storage bar.
                    if !d.usageShares.isEmpty {
                        UsageBreakdown(shares: Array(d.usageShares.prefix(4)), lang: lang, animateIn: false)
                            .padding(18)
                            .frame(maxWidth: .infinity)
                            .card()
                    }
                    ForEach(Array(d.quotas.prefix(3)), id: \.window.id) { q in
                        let left = max(0, 100 - q.window.usedPercent)
                        VStack(spacing: 8) {
                            ZStack {
                                QuotaRing(fraction: left / 100,
                                          color: left < 10 ? Theme.danger : Theme.color(forProvider: q.provider),
                                          lineWidth: 8, animateIn: false)
                                Text("\(Int(left.rounded()))%")
                                    .font(Theme.figure(20))
                                    .foregroundStyle(Theme.text)
                            }
                            .frame(width: 78, height: 78)
                            Text("\(AppDelegate.shortProvider(q.provider)) · \(q.window.label)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.textMuted)
                                .lineLimit(1)
                        }
                        .padding(14)
                        .card()
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(40)
        }
        .frame(width: 880, height: 560)
        // The observatory prints on paper; the morning is always light and
        // the night always dark.
        .environment(\.colorScheme, Skin.current.forcedScheme ?? .light)
        // A still image: nothing in it should be mid-animation when captured.
        .environment(\.appAnimations, false)
    }

    /// Matches RootView.headerDate — honors the app's own language setting
    /// rather than the raw system locale.
    private static func headerDate(_ lang: Language) -> String {
        let fmt = DateFormatter()
        fmt.locale = lang.resolved == .zh ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US")
        fmt.dateFormat = lang.resolved == .zh ? "yyyy年M月d日" : "MMM d, yyyy"
        return fmt.string(from: Date())
    }
}
