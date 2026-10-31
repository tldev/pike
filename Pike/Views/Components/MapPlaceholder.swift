import SwiftUI

/// Shimmer skeleton shown while the Map view is loading.
struct MapPlaceholder: View {
    @State private var shimmerOffset: CGFloat = -1

    private let baseColor = Color(.systemGray5)
    private let highlightColor = Color(.systemGray4)

    var body: some View {
        baseColor
            .overlay {
                GeometryReader { geo in
                    let width = geo.size.width
                    LinearGradient(
                        colors: [.clear, highlightColor.opacity(0.4), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: width * 0.6)
                    .offset(x: shimmerOffset * width)
                    .onAppear {
                        shimmerOffset = -1
                        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                            shimmerOffset = 1.5
                        }
                    }
                }
                .clipped()
            }
            .overlay {
                Image(systemName: "map")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.quaternary)
            }
    }
}
