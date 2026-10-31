import SwiftUI

struct AppLoadingView: View {
    @State private var isAnimatingIndicator = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color("LaunchBackground"),
                    Color("LaunchBackground").opacity(0.82),
                    Color.black.opacity(0.88)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(.white.opacity(0.18))
                .frame(width: 220, height: 220)
                .blur(radius: 36)
                .offset(y: -130)

            VStack(spacing: 18) {
                Image("AppIcon-Display")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .shadow(color: .black.opacity(0.25), radius: 20, y: 10)

                Text("Loading nearby exits")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.78))

                Capsule()
                    .fill(.white.opacity(0.22))
                    .frame(width: 126, height: 5)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(.white)
                            .frame(width: isAnimatingIndicator ? 126 : 42, height: 5)
                    }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                isAnimatingIndicator = true
            }
        }
    }
}
