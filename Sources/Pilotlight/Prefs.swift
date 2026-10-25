import Foundation
import Combine

@MainActor final class Prefs: ObservableObject {
    static let shared = Prefs()

    enum Place: String { case menubar, floating }
    enum Style: String { case lights, single }
    enum Sound: String { case off, soft, distinct }

    private static let d = UserDefaults.standard
    private static func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }

    @Published var notifyPermission = Prefs.bool("notifyPermission", true) { didSet { Prefs.d.set(notifyPermission, forKey: "notifyPermission") } }
    @Published var notifyQuestion = Prefs.bool("notifyQuestion", true) { didSet { Prefs.d.set(notifyQuestion, forKey: "notifyQuestion") } }
    @Published var notifyDone = Prefs.bool("notifyDone", true) { didSet { Prefs.d.set(notifyDone, forKey: "notifyDone") } }
    @Published var notifyError = Prefs.bool("notifyError", true) { didSet { Prefs.d.set(notifyError, forKey: "notifyError") } }
    @Published var quietFocused = Prefs.bool("quietFocused", true) { didSet { Prefs.d.set(quietFocused, forKey: "quietFocused") } }
    @Published var dimFloating = Prefs.bool("dimFloating", true) { didSet { Prefs.d.set(dimFloating, forKey: "dimFloating") } }

    @Published var place = Place(rawValue: Prefs.d.string(forKey: "place") ?? "") ?? .menubar { didSet { Prefs.d.set(place.rawValue, forKey: "place") } }
    @Published var style = Style(rawValue: Prefs.d.string(forKey: "style") ?? "") ?? .lights { didSet { Prefs.d.set(style.rawValue, forKey: "style") } }
    @Published var sound = Sound(rawValue: Prefs.d.string(forKey: "sound") ?? "") ?? .soft { didSet { Prefs.d.set(sound.rawValue, forKey: "sound") } }

    /// how long a permission ask waits in Pilotlight before VS Code shows its own prompt
    @Published var askTimeout: Double = Prefs.d.double(forKey: "askTimeout") > 0 ? Prefs.d.double(forKey: "askTimeout") : 30 {
        didSet { Prefs.d.set(askTimeout, forKey: "askTimeout") }
    }

    func wants(_ kind: AlertKind) -> Bool {
        switch kind {
        case .permission: return notifyPermission
        case .question: return notifyQuestion
        case .done: return notifyDone
        case .error: return notifyError
        }
    }
}
