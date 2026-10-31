import StoreKit
import SwiftUI

/// App information and settings.
struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var exitService: ExitService
    @AppStorage(ExitCardCategoryVisibility.storageKey)
    private var exitCardCategoryMask: Int = ExitCardCategoryVisibility.defaultMask
    @State private var isUSStorefront = false

    private var exitCardCategoryVisibility: ExitCardCategoryVisibility {
        get { ExitCardCategoryVisibility(mask: exitCardCategoryMask) }
        nonmutating set { exitCardCategoryMask = newValue.mask }
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version?.isEmpty == false ? version : nil, build?.isEmpty == false ? build : nil) {
        case let (v?, b?):
            return "\(v) (\(b))"
        case let (v?, nil):
            return v
        case let (nil, b?):
            return b
        default:
            return "\u{2014}"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                exitCardCategoriesSection

                if isUSStorefront {
                    Section("Support") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("If Pike helped with your road trip, please buy me a coffee!")
                                .font(.subheadline)
                            if let buyMeACoffeeURL = URL(string: "https://buymeacoffee.com/tjohnell") {
                                Link(destination: buyMeACoffeeURL) {
                                    Text("Buy Me a Coffee")
                                        .font(.body.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(versionText)
                            .foregroundStyle(.secondary)
                    }

                    if let packVersionLabel = exitService.packVersionLabel {
                        HStack {
                            Text("Exit Data")
                            Spacer()
                            Text(packVersionLabel)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Data Attribution")
                            .font(.subheadline)
                        Text("Map data \u{00A9} OpenStreetMap contributors")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Licensed under the Open Database License (ODbL)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .task {
                await observeStorefrontForSupportCTA()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func observeStorefrontForSupportCTA() async {
        let currentStorefront = await Storefront.current
        await MainActor.run {
            isUSStorefront = currentStorefront?.countryCode.uppercased() == "USA"
        }

        for await storefront in Storefront.updates {
            await MainActor.run {
                isUSStorefront = storefront.countryCode.uppercased() == "USA"
            }
        }
    }

    // MARK: - Exit Card Categories

    @ViewBuilder
    private var exitCardCategoriesSection: some View {
        Section {
            ForEach(ExitCardServiceCategory.settingsOrder) { category in
                Toggle(isOn: categoryToggleBinding(for: category)) {
                    Label(category.displayName, systemImage: category.systemImage)
                }
                .disabled(isOnlyEnabled(category))
            }

            Button("Show All Categories") {
                var visibility = exitCardCategoryVisibility
                visibility.enableAll()
                exitCardCategoryVisibility = visibility
            }
            .disabled(exitCardCategoryVisibility.isAllEnabled)
        } header: {
            Text("Exit Card Categories")
        } footer: {
            Text("Choose which service types appear on exit cards. At least one category stays enabled.")
        }
    }

    private func categoryToggleBinding(for category: ExitCardServiceCategory) -> Binding<Bool> {
        Binding(
            get: { exitCardCategoryVisibility.isEnabled(category) },
            set: { enabled in
                var visibility = exitCardCategoryVisibility
                visibility.set(category, enabled: enabled)
                exitCardCategoryVisibility = visibility
            }
        )
    }

    private func isOnlyEnabled(_ category: ExitCardServiceCategory) -> Bool {
        let visibility = exitCardCategoryVisibility
        return visibility.enabledCategories.count == 1 && visibility.isEnabled(category)
    }
}
