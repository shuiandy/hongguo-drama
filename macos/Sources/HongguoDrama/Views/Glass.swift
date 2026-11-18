import SwiftUI

// Liquid Glass building blocks.
//
// On macOS 26 these map straight onto `glassEffect`, `GlassEffectContainer` and
// `backgroundExtensionEffect`. On macOS 14/15 (or when built with an SDK older than
// Xcode 26) they fall back to an ultra-thin material with a hairline highlight, so
// every screen keeps the same layout and hierarchy.

extension Color {
    /// Brand accent, #FF5C6C.
    static let hongguoRed = Color(red: 1.0, green: 0.361, blue: 0.424)
    /// Pressed / deep accent, #E22640.
    static let hongguoRedDeep = Color(red: 0.886, green: 0.149, blue: 0.251)
    /// Rating and "not public on the web" marker, #FFC94D.
    static let hongguoGold = Color(red: 1.0, green: 0.788, blue: 0.302)
}

enum GlassVariant {
    /// Default glass: frosted, adapts to what is behind it.
    case regular
    /// More transparent glass for small controls over rich media.
    case clear
}

extension View {
    /// Puts the view on a glass surface of the given shape.
    @ViewBuilder
    func glassSurface<S: Shape>(_ variant: GlassVariant = .regular, in shape: S,
                                tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(Self.makeGlass(variant, tint: tint, interactive: interactive), in: shape)
        } else {
            fallbackGlass(variant, in: shape, tint: tint)
        }
        #else
        fallbackGlass(variant, in: shape, tint: tint)
        #endif
    }

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    private static func makeGlass(_ variant: GlassVariant, tint: Color?, interactive: Bool) -> Glass {
        var glass: Glass = variant == .clear ? .clear : .regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
    #endif

    private func fallbackGlass<S: Shape>(_ variant: GlassVariant, in shape: S, tint: Color?) -> some View {
        self
            .background {
                ZStack {
                    if let tint {
                        shape.fill(LinearGradient(colors: [tint, tint.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                    } else {
                        shape.fill(variant == .clear ? AnyShapeStyle(.ultraThinMaterial.opacity(0.7)) : AnyShapeStyle(.ultraThinMaterial))
                    }
                }
            }
            .overlay {
                shape.stroke(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom),
                             lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    /// Lets glass shapes inside one `GlassGroup` morph into each other (for example a moving selection).
    @ViewBuilder
    func glassID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Mirrors and blurs this view under the floating sidebar and toolbar (macOS 26).
    @ViewBuilder
    func extendsUnderChrome() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.backgroundExtensionEffect()
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// Groups nearby glass shapes so they render as one sheet and blend when they touch.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

// MARK: Buttons

/// Capsule glass button. `prominent` tints it with the brand red for the primary action.
struct GlassButtonStyle: ButtonStyle {
    var prominent = false
    var size: ControlSize = .regular

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: height)
            .contentShape(Capsule())
            .glassSurface(in: Capsule(), tint: prominent ? .hongguoRed : nil, interactive: true)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }

    private var height: CGFloat {
        switch size {
        case .mini, .small: return 30
        case .large, .extraLarge: return 44
        default: return 36
        }
    }

    private var horizontalPadding: CGFloat { size == .large || size == .extraLarge ? 20 : 14 }

    private var font: Font {
        switch size {
        case .mini, .small: return .system(size: 12, weight: prominent ? .semibold : .medium)
        case .large, .extraLarge: return .system(size: 15, weight: prominent ? .semibold : .medium)
        default: return .system(size: 13, weight: prominent ? .semibold : .medium)
        }
    }
}

/// Round glass icon button.
struct GlassIconButtonStyle: ButtonStyle {
    var diameter: CGFloat = 36
    var variant: GlassVariant = .regular

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: diameter * 0.4, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .glassSurface(variant, in: Circle(), interactive: true)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Bare icon inside a larger glass bar (the bar provides the glass).
struct BarIconButtonStyle: ButtonStyle {
    var size: CGFloat = 32
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(active ? AnyShapeStyle(Color.hongguoRed) : AnyShapeStyle(.primary))
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: Segmented selector

/// A row of options in one glass capsule; the selected option is a bright pill that slides between items.
struct GlassOption<Value: Hashable & Sendable>: Identifiable {
    let label: String
    let value: Value
    var id: Value { value }
}

struct GlassSegments<Value: Hashable & Sendable>: View {
    let options: [GlassOption<Value>]
    @Binding var selection: Value
    var compact = false
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let selected = option.value == selection
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(.system(size: compact ? 12 : 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? AnyShapeStyle(Color.black) : AnyShapeStyle(.primary))
                        .padding(.horizontal, compact ? 11 : 14)
                        .frame(height: compact ? 26 : 30)
                        .background {
                            if selected {
                                Capsule().fill(.white.opacity(0.92))
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .glassSurface(in: Capsule())
    }
}

// MARK: Ambient backdrop

/// The cover, heavily blurred, used as a coloured light source behind glass.
struct AmbientBackdrop: View {
    let url: String
    var blur: CGFloat = 70
    var opacity: Double = 0.7

    var body: some View {
        CoverImage(url: url, cornerRadius: 0)
            .scaleEffect(1.3)
            .blur(radius: blur, opaque: true)
            .saturation(1.4)
            .opacity(opacity)
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Small glass capsule label.
struct GlassTag: View {
    let text: String
    var systemImage: String?
    var iconColor: Color?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).foregroundStyle(iconColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary)) }
            Text(text)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .glassSurface(.clear, in: Capsule())
    }
}
