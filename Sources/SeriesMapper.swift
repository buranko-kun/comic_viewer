import Foundation

/// Maps a downloaded comic's title to a canonical series/character folder so downloads auto-file
/// into `Batman/`, `X-Men/`, `Spawn/`, … (including spin-offs, e.g. "Sam & Twitch" → Spawn).
/// Matching is whole-word on a normalized title; the first franchise with a hit wins. No match
/// (unknown/indie) → nil, and the comic drops in the library root.
///
/// This is a hand-curated heuristic, not derived from the catalog — extend the `map` as needed.
enum SeriesMapper {
    static func folder(for title: String) -> String? {
        let t = " " + normalize(title) + " "
        for (folder, phrases) in map {
            for p in phrases where t.contains(" " + p + " ") { return folder }
        }
        return nil
    }

    private static func normalize(_ s: String) -> String {
        var n = s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        n = n.replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
        return n.trimmingCharacters(in: .whitespaces)
    }

    /// Ordered franchise → match phrases. Order matters for crossovers (first match wins), and
    /// spin-offs that share a word (Deadpool before X-Men) come first.
    private static let map: [(String, [String])] = [
        // --- Image / other publishers (distinctive; keep before Marvel/DC) ---
        ("Spawn", ["spawn", "sam twitch", "sam and twitch", "curse of the spawn", "hellspawn",
                   "medieval spawn", "gunslinger spawn", "the scorched", "violator"]),
        ("Invincible", ["invincible", "omni man", "atom eve"]),
        ("The Walking Dead", ["walking dead", "negan", "clementine"]),
        ("Savage Dragon", ["savage dragon"]),
        ("Witchblade", ["witchblade", "the darkness", "cyberforce"]),
        ("Hellboy", ["hellboy", "b p r d", "bprd", "abe sapien"]),
        ("Sin City", ["sin city"]),
        ("Teenage Mutant Ninja Turtles", ["teenage mutant ninja turtles", "tmnt"]),

        // --- Marvel solo characters big enough for their own folder (before their franchise) ---
        ("Deadpool", ["deadpool"]),
        ("Cable", ["cable"]),
        ("Wolverine", ["wolverine", "old man logan", "x 23", "laura kinney", "weapon x"]),
        ("She-Hulk", ["she hulk", "sensational she hulk"]),
        ("Venom", ["venom", "carnage", "knull", "lethal protector"]),
        ("Silver Surfer", ["silver surfer"]),
        ("Thanos", ["thanos"]),
        ("Moon Knight", ["moon knight"]),
        ("Ghost Rider", ["ghost rider"]),
        ("Blade", ["blade"]),

        // --- Marvel franchises ---
        ("Spider-Man", ["spider man", "spiderman", "spider gwen", "spider woman", "miles morales",
                        "silk", "spider verse", "scarlet spider", "spider girl", "kraven",
                        "green goblin"]),
        ("X-Men", ["x men", "x force", "x factor", "new mutants", "uncanny", "magneto",
                   "gambit", "mystique", "sabretooth", "excalibur", "marauders", "apocalypse",
                   "dark phoenix", "jean grey", "cyclops", "nightcrawler", "colossus", "storm",
                   "rogue", "psylocke", "juggernaut", "mister sinister"]),
        ("Fantastic Four", ["fantastic four", "human torch", "mister fantastic", "invisible woman",
                            "doctor doom", "galactus", "namor"]),
        ("Iron Man", ["iron man", "tony stark", "war machine", "ironheart"]),
        ("Thor", ["thor", "mighty thor", "loki", "valkyrie", "jane foster", "asgard"]),
        ("Hulk", ["hulk", "bruce banner", "abomination"]),
        ("Captain America", ["captain america", "steve rogers", "winter soldier", "bucky", "u s agent"]),
        ("Daredevil", ["daredevil", "elektra", "kingpin"]),
        ("The Punisher", ["punisher", "frank castle"]),
        ("Doctor Strange", ["doctor strange", "sorcerer supreme"]),
        ("Black Panther", ["black panther", "wakanda", "shuri"]),
        ("Captain Marvel", ["captain marvel", "ms marvel", "kamala khan", "carol danvers"]),
        ("Guardians of the Galaxy", ["guardians of the galaxy", "star lord", "gamora", "drax",
                                     "rocket raccoon", "groot", "nova", "adam warlock"]),
        ("Avengers", ["avengers", "black widow", "hawkeye", "ant man", "the wasp", "vision",
                      "scarlet witch", "quicksilver", "ultron", "kang", "young avengers"]),

        // --- DC solo characters big enough for their own folder (before their franchise) ---
        ("Nightwing", ["nightwing", "dick grayson"]),
        ("Catwoman", ["catwoman", "selina kyle"]),
        ("Harley Quinn", ["harley quinn"]),
        ("Supergirl", ["supergirl"]),

        // --- DC franchises ---
        ("Batman", ["batman", "detective comics", "dark knight", "robin", "batgirl",
                    "batwoman", "batwing", "red hood", "red robin", "joker",
                    "penguin", "riddler", "two face", "bane", "ra s al ghul",
                    "gotham", "birds of prey", "azrael", "huntress", "the batman"]),
        ("Superman", ["superman", "action comics", "superboy", "super sons",
                      "man of steel", "krypton", "bizarro", "lois lane", "jimmy olsen"]),
        ("Wonder Woman", ["wonder woman", "wonder girl", "nubia"]),
        ("The Flash", ["the flash", "flash", "kid flash", "impulse", "reverse flash", "wally west"]),
        ("Green Lantern", ["green lantern", "green lanterns", "sinestro", "hal jordan", "john stewart",
                           "kyle rayner", "guy gardner", "red lanterns"]),
        ("Aquaman", ["aquaman", "aqualad", "mera"]),
        ("Green Arrow", ["green arrow", "arsenal", "red arrow"]),
        ("Teen Titans", ["teen titans", "the titans", "raven", "starfire", "cyborg", "beast boy"]),
        ("Justice League", ["justice league", "jla", "jsa", "justice society"]),
        ("Shazam", ["shazam"]),
        ("Swamp Thing", ["swamp thing"]),
        ("The Sandman", ["the sandman", "sandman"]),
        ("Hellblazer", ["hellblazer", "constantine"]),
        ("Suicide Squad", ["suicide squad", "task force x"]),
    ]
}
