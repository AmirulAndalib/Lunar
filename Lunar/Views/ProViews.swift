import Defaults
import Sparkle
import SwiftUI

// MARK: - UpdateCheckInterval

enum UpdateCheckInterval: Int {
    case daily = 86400
    case everyThreeDays = 259_200
    case weekly = 604_800
    case monthly = 2_592_000
}

import Paddle

// MARK: - LicenseView

public struct LicenseView: View {
    public var body: some View {
        HStack {
            Text("Licence:")
                .font(.system(size: 12, weight: .medium))
            Text(lunarProOnTrial ? "trial" : (lunarProActive ? "active" : "inactive"))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(lunarProOnTrial ? Colors.peach : (lunarProActive ? Colors.lightGreen : Colors.red))
                )
                .foregroundColor(lunarProOnTrial ? .black : (lunarProActive ? .black : .white))

            if lunarProOnTrial, let days = product?.trialDaysRemaining {
                VStack(spacing: -3) {
                    Text("\(days) days")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                    Text("remaining")
                        .font(.system(size: 7, weight: .semibold, design: .rounded))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(days.intValue > 7 ? Colors.lightGreen : (days.intValue > 3 ? Colors.peach : Colors.red))
                )
                .foregroundColor(days.intValue > 7 ? .black : (days.intValue > 3 ? .black : .white))
            }
            Spacer()

            if lunarProOnTrial {
                SwiftUI.Button("Buy") { showCheckout() }
                    .buttonStyle(FlatButton(
                        color: .primary.opacity(0.9),
                        textColor: colors.inverted,
                        horizontalPadding: 6,
                        verticalPadding: 3
                    ))
                    .font(.system(size: 12, weight: .semibold))
            }
            SwiftUI.Button((lunarProActive && !lunarProOnTrial) ? "Manage" : "Activate") { showLicenseActivation() }
                .buttonStyle(FlatButton(color: .primary.opacity(0.9), textColor: colors.inverted, horizontalPadding: 6, verticalPadding: 3))
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .onAppear { product = lunarProProduct }
    }

    @State var product: PADProduct? = lunarProProduct

    @Default(.lunarProActive) var lunarProActive
    @Default(.lunarProOnTrial) var lunarProOnTrial

    @Environment(\.colors) var colors
}

// MARK: - VersionView

public struct VersionView: View {
    public init(updater: SPUUpdater) {
        self.updater = updater
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Version:")
                    .font(.system(size: 12, weight: .medium))
                Text(Bundle.main.version)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))

                Spacer()

                SwiftUI.Button("Check for updates") { updater.checkForUpdates() }
                    .buttonStyle(FlatButton(
                        color: .primary.opacity(0.9),
                        textColor: colors.inverted,
                        horizontalPadding: 6,
                        verticalPadding: 3
                    ))
                    .font(.system(size: 12, weight: .semibold))
            }
            Divider().padding(.vertical, 2).opacity(0.5)
            HStack(spacing: 3) {
                Toggle("Check automatically", isOn: $checkForUpdates)
                    .toggleStyle(CheckboxToggleStyle(style: .circle))
                    .font(.system(size: 12, weight: .medium))

                Spacer()

                SwiftUI.Button("Daily") {
                    checkForUpdates = true
                    updateCheckInterval = UpdateCheckInterval.daily.rawValue
                }
                .buttonStyle(PickerButton(
                    horizontalPadding: 6,
                    verticalPadding: 3,
                    enumValue: $updateCheckInterval,
                    onValue: UpdateCheckInterval.daily.rawValue
                ))
                .font(.system(size: 12, weight: .semibold))
                .disabled(!checkForUpdates)

                SwiftUI.Button("Weekly") {
                    checkForUpdates = true
                    updateCheckInterval = UpdateCheckInterval.weekly.rawValue
                }
                .buttonStyle(PickerButton(
                    horizontalPadding: 6,
                    verticalPadding: 3,
                    enumValue: $updateCheckInterval,
                    onValue: UpdateCheckInterval.weekly.rawValue
                ))
                .font(.system(size: 12, weight: .semibold))
                .disabled(!checkForUpdates)

                SwiftUI.Button("Monthly") {
                    checkForUpdates = true
                    updateCheckInterval = UpdateCheckInterval.monthly.rawValue
                }
                .buttonStyle(PickerButton(
                    horizontalPadding: 6,
                    verticalPadding: 3,
                    enumValue: $updateCheckInterval,
                    onValue: UpdateCheckInterval.monthly.rawValue
                ))
                .font(.system(size: 12, weight: .semibold))
                .disabled(!checkForUpdates)
            }
            Divider().padding(.vertical, 2).opacity(0.5)
            Toggle("Update to beta builds", isOn: beta)
                .toggleStyle(CheckboxToggleStyle(style: .circle))
                .font(.system(size: 12, weight: .medium))
            Toggle("Install updates silently in the background", isOn: $silentUpdate)
                .toggleStyle(CheckboxToggleStyle(style: .circle))
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    var beta: Binding<Bool> = Binding(
        get: { Defaults[.updateChannel] != .release },
        set: { Defaults[.updateChannel] = $0 ? .beta : .release }
    )

    @Default(.checkForUpdate) var checkForUpdates
    @Default(.updateCheckInterval) var updateCheckInterval
    @Default(.updateChannel) var updateChannel
    @Default(.silentUpdate) var silentUpdate

    @ObservedObject var updater: SPUUpdater
    @Environment(\.colors) var colors
}

// MARK: - MenuDensityView

public struct MenuDensityView: View {
    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Text("Menu density")
                    .font(.system(size: 12, weight: .medium))
                Spacer()

                SwiftUI.Button("Clean") { menuDensity = .clean }
                    .buttonStyle(PickerButton(horizontalPadding: 6, verticalPadding: 3, enumValue: $menuDensity, onValue: .clean))
                    .font(.system(size: 12, weight: .semibold))

                SwiftUI.Button("Comfortable") { menuDensity = .comfortable }
                    .buttonStyle(PickerButton(horizontalPadding: 6, verticalPadding: 3, enumValue: $menuDensity, onValue: .comfortable))
                    .font(.system(size: 12, weight: .semibold))

                SwiftUI.Button("Dense") { menuDensity = .dense }
                    .buttonStyle(PickerButton(horizontalPadding: 6, verticalPadding: 3, enumValue: $menuDensity, onValue: .dense))
                    .font(.system(size: 12, weight: .semibold))
            }
            HStack(spacing: 3) {
                Text("Click on")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                HStack(spacing: 2) {
                    Image(systemName: "line.horizontal.3.decrease.circle.fill").font(.system(size: 10, weight: .semibold))
                    Text("Options")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.15)))
                Text("at the top for more granular settings")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
            }.opacity(0.7)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .onChange(of: menuDensity) { density in
            let dense = density == .dense
            let comfy = density == .comfortable
            let clean = density == .clean

            withAnimation(.fastSpring) {
                Defaults[.showSliderValues] = dense || comfy
                Defaults[.showVolumeSlider] = dense
                Defaults[.showOrientationInQuickActions] = dense
                Defaults[.showInputInQuickActions] = dense || comfy
                Defaults[.showStandardPresets] = dense || comfy
                Defaults[.showCustomPresets] = dense
                Defaults[.showXDRSelector] = dense || comfy
                Defaults[.showHeaderOnHover] = clean
                Defaults[.showFooterOnHover] = clean
            }
        }
    }

    @Default(.menuDensity) var menuDensity
    @Environment(\.colors) var colors
}

extension Bundle {
    var version: String {
        (infoDictionary?["CFBundleVersion"] as? String) ?? "1.0.0"
    }
}

// MARK: - SPUUpdater + ObservableObject

extension SPUUpdater: ObservableObject {}

// MARK: - DetailToggleStyle

public struct DetailToggleStyle: ToggleStyle {
    public init(style: Style = .circle) {
        self.style = style
    }

    public enum Style {
        case square, circle, empty

        public var sfSymbolName: String {
            switch self {
            case .empty:
                return ""
            case .square:
                return ".square"
            case .circle:
                return ".circle"
            }
        }
    }

    @Environment(\.isEnabled) public var isEnabled
    public let style: Style // custom param

    public func makeBody(configuration: Configuration) -> some View {
        SwiftUI.Button(action: {
            configuration.isOn.toggle() // toggle the state binding
        }, label: {
            HStack(spacing: 3) {
                Image(
                    systemName: configuration
                        .isOn ? "arrowtriangle.up\(style.sfSymbolName).fill" : "arrowtriangle.down\(style.sfSymbolName).fill"
                )
                .imageScale(.medium)
                configuration.label
            }
        })
        .contentShape(Rectangle())
        .buttonStyle(PlainButtonStyle()) // remove any implicit styling from the button
        .disabled(!isEnabled)
    }
}
