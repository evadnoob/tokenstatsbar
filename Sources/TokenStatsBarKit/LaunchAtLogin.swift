import ServiceManagement
import SwiftUI

/// Registers the app as a login item with SMAppService (macOS 13 and later). macOS owns the setting, so the state
/// is read back from the system after every change and whenever the dropdown opens. The user can also change it
/// in System Settings, General, Login Items.
@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var errorText: String?

    init() {
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorText = nil
        } catch {
            errorText = "Launch at login: \(error.localizedDescription)"
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// The "Launch at login" entries of the footer menu. A Toggle in a menu shows as an item with a checkmark.
struct LaunchAtLoginMenuItems: View {
    @ObservedObject var controller: LaunchAtLoginController

    var body: some View {
        Toggle("Launch at login", isOn: Binding(get: { controller.isEnabled }, set: { controller.setEnabled($0) }))
        if controller.requiresApproval {
            Button("Allow in Login Items settings...") { controller.openLoginItemsSettings() }
        }
        if let errorText = controller.errorText {
            Text(errorText)
        }
    }
}
