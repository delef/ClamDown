import Testing
import UserNotifications
@testable import ClamDownAppKit

@Suite struct NotificationPermissionTests {
    @Test func mapsSystemStatus() {
        #expect(NotificationPermission(.notDetermined) == .notAsked)
        #expect(NotificationPermission(.denied) == .denied)
        #expect(NotificationPermission(.authorized) == .allowed)
        #expect(NotificationPermission(.provisional) == .allowed)
    }

    @Test func hintOnlyWhenTheSettingIsOnAndMacOSSaysNo() {
        #expect(NotificationPermission.notAsked.hint(settingOn: true) == .allow)
        #expect(NotificationPermission.denied.hint(settingOn: true) == .openSettings)
        #expect(NotificationPermission.allowed.hint(settingOn: true) == .nothing)
        for permission in [NotificationPermission.notAsked, .denied, .allowed] {
            #expect(permission.hint(settingOn: false) == .nothing)
        }
    }
}
