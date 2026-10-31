//
//  OnboardingView.swift
//  Pike
//
//  First-launch welcome screen (Apple "Welcome to" pattern).
//

import SwiftUI

struct OnboardingView: View {
    let onDismiss: () -> Void
    let onTestDrive: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image("AppIcon-Display")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 22))

            Spacer().frame(height: 16)

            Text("Welcome to Pike")
                .font(.system(size: 34, weight: .bold))

            Spacer().frame(height: 40)

            VStack(alignment: .leading, spacing: 24) {
                featureRow(
                    icon: "fuelpump.fill",
                    title: "Every Exit at a Glance",
                    subtitle: "Gas, food, lodging and more - all ahead of you."
                )
                featureRow(
                    icon: "location.fill",
                    title: "No Destination Needed",
                    subtitle: "Pike shows what\u{2019}s coming down the pike based on where you\u{2019}re headed."
                )
                featureRow(
                    icon: "road.lanes",
                    title: "Built for the Road",
                    subtitle: "Perfect for your co-pilot to find the best stop, fast."
                )
            }
            .padding(.horizontal, 8)

            Spacer()

            VStack(spacing: 12) {
                Button(action: onTestDrive) {
                    Label("Take a Test Drive", systemImage: "car.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(.white)
                        .background(.blue, in: RoundedRectangle(cornerRadius: 14))
                }

                Button(action: onDismiss) {
                    Text("Continue")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
    }

    private func featureRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
