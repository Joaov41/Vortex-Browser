import SwiftUI
import UIKit

/// Shared sizes, radii and colors for Vortex chrome (toolbar pills, sidebars, cards).
enum BrowserDesign {
    enum Radius {
        static let icon: CGFloat = 8
        static let row: CGFloat = 12
        static let card: CGFloat = 20
        static let panel: CGFloat = 24
        static let sheet: CGFloat = 30
    }

    enum Size {
        static let hitTarget: CGFloat = 44
        static let toolbarPillHeight: CGFloat = 44
        static let sidebarIcon: CGFloat = 26
        static let progressBarHeight: CGFloat = 2
    }

    enum Shadow {
        static let controlRadius: CGFloat = 8
        static let cardRadius: CGFloat = 18
        static let panelRadius: CGFloat = 24

        static func color(isDark: Bool) -> Color {
            Color.black.opacity(isDark ? 0.35 : 0.18)
        }
    }

    enum Phone {
        static let panelHorizontalInset: CGFloat = 24
        static let tabsPanelMinHeight: CGFloat = 420
        static let tabsPanelHeightFraction: CGFloat = 0.88
        static let aiPanelMinHeight: CGFloat = 360
        static let aiPanelHeightFraction: CGFloat = 0.52
        static let aiPanelExpandedMinHeight: CGFloat = 520
    }

    enum Tint {
        static let favorite = Color(uiColor: .systemYellow)
        static let incognito = Color(uiColor: .systemPurple)
        static let password = Color(uiColor: .systemYellow)
        static let protectionActive = Color(uiColor: .systemGreen)
        static let warning = Color(uiColor: .systemOrange)
        static let error = Color(uiColor: .systemRed)
    }

    /// Hairline border for glass chrome. White reads on dark glass; a dark
    /// hairline is needed for the border to remain visible in light mode.
    static func chromeBorder(isDark: Bool) -> Color {
        isDark ? Color.white.opacity(0.2) : Color.black.opacity(0.08)
    }
}

private struct GlassEffectCompatModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let material: Material
    let tint: Color?
    let strokeOpacity: Double

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(material)
                    if let tint {
                        shape.fill(tint)
                    }
                }
            }
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(strokeOpacity),
                            Color.white.opacity(strokeOpacity * 0.35)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.6
                )
            )
    }
}

extension View {
    /// Bottom-toolbar background: clear glass, with a frosted layer faded in while
    /// page text sits behind it (busy text showing through competes with the
    /// address). The frost fades rather than swapping views, so identity and focus
    /// are kept.
    func toolbarBackdrop<S: InsettableShape>(in shape: S, frosted: Bool) -> some View {
        background {
            shape.fill(.thickMaterial)
                .opacity(frosted ? 1 : 0)
                .animation(.easeOut(duration: 0.25), value: frosted)
        }
        .glassEffectCompat(in: shape, material: .ultraThinMaterial, strokeOpacity: 0.18)
    }

    @ViewBuilder
    func glassEffectCompat<S: InsettableShape>(
        in shape: S,
        material: Material = .ultraThinMaterial,
        tint: Color? = nil,
        strokeOpacity: Double = 0.25,
        isInteractive: Bool = true
    ) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                if isInteractive {
                    self.glassEffect(.regular.interactive().tint(tint), in: shape)
                } else {
                    self.glassEffect(.regular.tint(tint), in: shape)
                }
            } else {
                if isInteractive {
                    self.glassEffect(.regular.interactive(), in: shape)
                } else {
                    self.glassEffect(.regular, in: shape)
                }
            }
        } else {
            modifier(
                GlassEffectCompatModifier(
                    shape: shape,
                    material: material,
                    tint: tint,
                    strokeOpacity: strokeOpacity
                )
            )
        }
    }

    @ViewBuilder
    func glassEffectContainerCompat(spacing: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                self
            }
        } else {
            self
        }
    }
}
