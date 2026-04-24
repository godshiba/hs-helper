import Foundation

public enum Translations {
    private static var languagePrefix: String {
        let code: String
        if let override = UserDefaults.standard.string(forKey: "hs-helper.gameLanguage"),
            !override.isEmpty, override != "System"
        {
            code = override
        } else {
            code = Locale.preferredLanguages.first ?? "en"
        }
        return String(code.prefix(2)).lowercased()
    }

    public static func translate(_ key: String) -> String {
        let lang = languagePrefix
        if lang == "ru" {
            return ru[key] ?? key
        }
        return key
    }

    private static let ru: [String: String] = [
        "Your Deck": "Ваша колода",
        "Deck": "Колода",
        "Opponent": "Противник",
        "Hand": "В руке",
        "Fatigue": "Усталость",
        "Turn": "Ход",
        "Top deck odds": "Шанс топдека",
        "DECK": "КОЛОДА",
        "CARDS PLAYED": "РАЗЫГРАНО",
        "Waiting for game…": "Ожидание игры…",
        "Tracking Power.log": "Чтение Power.log",
        "No plays yet": "Нет действий",
        "No cards played yet": "Нет разыгранных карт",
        "Last:": "Посл.:",
        "Constructed": "Рейтинг",
    ]
}
