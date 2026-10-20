import SwiftUI

extension Color {
    /// Violeta da marca Sweevi (#6A3DF5).
    static let sweevi = Color(red: 0x6A / 255, green: 0x3D / 255, blue: 0xF5 / 255)
}

/// Símbolo do Sweevi: o play girado para baixo vira a seta de download e cai no cursor
/// de uma barra de progresso. Mesma geometria de `Branding/sweevi-symbol.svg` (canvas 256×256).
struct SweeviLogo: View {
    var color: Color = .sweevi

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 256
            context.translateBy(x: (size.width - 256 * scale) / 2, y: (size.height - 256 * scale) / 2)
            context.scaleBy(x: scale, y: scale)

            // Triângulo equilátero (lado 152) apontando para baixo, cantos com raio 18.
            let a = CGPoint(x: 52, y: 30)
            let b = CGPoint(x: 204, y: 30)
            let c = CGPoint(x: 128, y: 30 + 152 * 3.squareRoot() / 2)
            var play = Path()
            play.move(to: CGPoint(x: 128, y: 30))
            play.addArc(tangent1End: b, tangent2End: c, radius: 18)
            play.addArc(tangent1End: c, tangent2End: a, radius: 18)
            play.addArc(tangent1End: a, tangent2End: b, radius: 18)
            play.closeSubpath()
            context.fill(play, with: .color(color))

            // Barra de progresso: trilho, parte já baixada e o cursor.
            let track = CGRect(x: 128, y: 205, width: 88, height: 10)
            let progress = CGRect(x: 40, y: 200, width: 88, height: 20)
            let playhead = CGRect(x: 106, y: 188, width: 44, height: 44)
            context.fill(Path(roundedRect: track, cornerRadius: 5, style: .circular), with: .color(color.opacity(0.4)))
            context.fill(Path(roundedRect: progress, cornerRadius: 10, style: .circular), with: .color(color))
            context.fill(Path(ellipseIn: playhead), with: .color(color))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Sweevi")
    }
}

