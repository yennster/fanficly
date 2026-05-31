import SwiftUI

private struct AO3ClientKey: EnvironmentKey {
    static let defaultValue: any AO3ClientProtocol = MockAO3Client()
}

extension EnvironmentValues {
    var ao3Client: any AO3ClientProtocol {
        get { self[AO3ClientKey.self] }
        set { self[AO3ClientKey.self] = newValue }
    }
}
