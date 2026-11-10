import SwiftUI

// =============================================================================
// MARK: - SidebarIconTile
// =============================================================================

/// A rounded-square tile with a white SF Symbol on a vertical gradient, as
/// System Settings draws its sidebar icons. Each symbol is fit in a box sized
/// for its shape, so glyphs of different proportions read at the same weight.
struct SidebarIconTile: View {
    /// The two stops of the tile fill, top to bottom. These are fixed colors
    /// and not `Theme.Color` tokens: a tile is a small picture, like an app
    /// icon, and must look the same under every accent color and appearance.
    struct Palette: Equatable {
        let top: Color
        let bottom: Color

        init(_ top: UInt32, _ bottom: UInt32) {
            self.top = Color(rgb: top)
            self.bottom = Color(rgb: bottom)
        }

        static let gray = Palette(0xA1A1A6, 0x6E6E73)
        static let graphite = Palette(0x48484A, 0x1C1C1E)
        static let blue = Palette(0x4DA3FF, 0x0A6CFF)
        static let indigo = Palette(0x8E8CF8, 0x5856D6)
        static let purple = Palette(0xB57BFF, 0x8A3FFC)
        static let magenta = Palette(0xF06BD0, 0xA53BF0)
        static let red = Palette(0xFF6B6B, 0xF02D3A)
        static let orange = Palette(0xFFB443, 0xFF8A00)
        static let green = Palette(0x5EDB7A, 0x28B446)
        static let teal = Palette(0x4FD8E0, 0x12A5B8)
    }

    struct Style: Equatable {
        /// SF Symbol name.
        let symbolName: String
        /// Side of the box the symbol is fit in. Keep it even: an odd size
        /// centers the box on a half point.
        let size: CGFloat
        /// Offset for a symbol whose visual mass is off its box center. Keep
        /// it a multiple of 0.5 (one pixel at 2x); smaller offsets round away.
        let nudge: CGSize
        let palette: Palette

        init(_ symbolName: String, size: CGFloat = 12, nudge: CGSize = .zero, _ palette: Palette) {
            self.symbolName = symbolName
            self.size = size
            self.nudge = nudge
            self.palette = palette
        }
    }

    let style: Style

    private static let side: CGFloat = 20
    private static let cornerRadius: CGFloat = 4.75

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        shape
            .fill(
                LinearGradient(
                    colors: [style.palette.top, style.palette.bottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                // A light inner edge, brighter at the top, gives the tile its lift.
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.28), .white.opacity(0.06)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.5
                )
            }
            .overlay {
                // `resizable()` fits the glyph's own bounds in the box; a
                // font-sized symbol keeps uneven side bearings and the sidebar
                // Label scales it up.
                Image(systemName: style.symbolName)
                    .resizable()
                    .fontWeight(.semibold)
                    .scaledToFit()
                    .frame(width: style.size, height: style.size)
                    .offset(style.nudge)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: 0.5)
                    // Rasterize offscreen so the glyph keeps its fractional
                    // position; drawn in place, a symbol snaps half a pixel
                    // low at 2x.
                    .drawingGroup()
            }
            .frame(width: Self.side, height: Self.side)
            .shadow(color: .black.opacity(0.22), radius: 0.6, y: 0.5)
            .accessibilityHidden(true)
    }
}

extension Color {
    /// A color from `0xRRGGBB` in sRGB.
    fileprivate init(rgb: UInt32) {
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
