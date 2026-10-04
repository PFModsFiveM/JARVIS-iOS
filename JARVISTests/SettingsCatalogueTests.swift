import XCTest
@testable import JARVIS

/// The settings hierarchy, its search and its links.
///
/// These are the tests that the old Settings page could not have had. It was a `body`, so "is every
/// page reachable", "is every page searchable" and "does every link go somewhere" were not
/// questions anything could ask - they were answered by reading 434 lines and hoping. The hierarchy
/// is data now, so they are three assertions.
final class SettingsCatalogueTests: XCTestCase {

    // MARK: The table itself

    func testEveryDestinationHasExactlyOneEntry() {
        for destination in SettingsDestination.allCases {
            let matching = SettingsCatalogue.entries.filter { $0.destination == destination }
            XCTAssertEqual(matching.count, 1, "\(destination.rawValue) should appear once")
        }
    }

    /// A row in the list that opens nothing, or a page nothing can reach, are the two failures this
    /// structure exists to prevent.
    func testEveryEntryIsInACategoryThatIsShown() {
        let shown = Set(SettingsCatalogue.categories)
        for entry in SettingsCatalogue.entries {
            XCTAssertTrue(shown.contains(entry.category),
                          "\(entry.title) is in \(entry.category.rawValue), which no screen lists")
        }
    }

    func testEverySlugIsUniqueAndUsableInAURL() {
        var seen = Set<String>()
        for destination in SettingsDestination.allCases {
            let slug = destination.rawValue
            XCTAssertFalse(slug.isEmpty)
            XCTAssertTrue(seen.insert(slug).inserted, "two destinations share the slug \(slug)")
            XCTAssertEqual(slug, slug.lowercased(), "\(slug) should be lower case")
            XCTAssertNil(slug.rangeOfCharacter(from: CharacterSet(charactersIn: " /?#")),
                         "\(slug) would need escaping in a URL")
        }
    }

    func testEveryEntryHasSomethingToSearchFor() {
        for entry in SettingsCatalogue.entries {
            XCTAssertFalse(entry.title.isEmpty)
            XCTAssertFalse(entry.subtitle.isEmpty, "\(entry.title) has no subtitle")
            XCTAssertFalse(entry.symbol.isEmpty, "\(entry.title) has no symbol")
            XCTAssertFalse(entry.keywords.isEmpty, "\(entry.title) has no keywords")
        }
    }

    // MARK: Links

    func testEveryDestinationRoundTripsThroughItsLink() {
        for destination in SettingsDestination.allCases {
            let url = SettingsCatalogue.link(to: destination)
            XCTAssertEqual(url.scheme, "jarvis")
            XCTAssertEqual(url.host, "settings")
            XCTAssertEqual(SettingsCatalogue.destination(forPath: url.path), destination,
                           "\(url.absoluteString) did not come back as \(destination.rawValue)")
        }
    }

    func testABareSettingsLinkOpensTheListRatherThanAPage() {
        XCTAssertNil(SettingsCatalogue.destination(forPath: ""))
        XCTAssertNil(SettingsCatalogue.destination(forPath: "/"))
    }

    func testAnUnknownSlugOpensTheListRatherThanTheWrongPage() {
        XCTAssertNil(SettingsCatalogue.destination(forPath: "/wireless-charging"))
        XCTAssertNil(SettingsCatalogue.destination(forPath: "/wake"))
    }

    /// A link that names a group goes to that group's first page. Better than nothing happening,
    /// and it is what somebody writing the obvious URL by hand meant.
    func testALinkNamingAGroupOpensItsFirstPage() {
        XCTAssertEqual(SettingsCatalogue.destination(forPath: "/general"), .connection)
        XCTAssertEqual(SettingsCatalogue.destination(forPath: "/learning"), .learning)
    }

    /// `learning` is the name of a page and of the group it sits in. Read as the page, because a
    /// page is the more specific thing a link can mean.
    func testAPageWinsOverAGroupWithTheSameName() {
        XCTAssertEqual(SettingsCategory.learning.rawValue, SettingsDestination.learning.rawValue,
                       "this test is only meaningful while the two names collide")
        XCTAssertEqual(SettingsCatalogue.destination(forPath: "/learning"), .learning)
    }

    func testALinkIsReadWhateverItsCaseOrSlashes() {
        XCTAssertEqual(SettingsCatalogue.destination(forPath: "/WAKING"), .waking)
        XCTAssertEqual(SettingsCatalogue.destination(forPath: "waking/"), .waking)
    }

    // MARK: Search

    func testSearchFindsAPageByItsTitle() {
        XCTAssertEqual(SettingsCatalogue.search("voice").first?.destination, .voice)
        XCTAssertEqual(SettingsCatalogue.search("display").first?.destination, .appearance)
    }

    /// The point of keywords: the words somebody will type are often not on the page. Nothing in
    /// "Reaching the PC from away" says Tailscale, and Tailscale is the answer.
    func testSearchFindsAPageByAWordThatIsNotOnIt() {
        XCTAssertEqual(SettingsCatalogue.search("tailscale").first?.destination, .reaching)
        XCTAssertEqual(SettingsCatalogue.search("wol").first?.destination, .waking)
        XCTAssertEqual(SettingsCatalogue.search("ntfy").first?.destination, .alerts)
        XCTAssertEqual(SettingsCatalogue.search("unpair").first?.destination, .forget)
        XCTAssertEqual(SettingsCatalogue.search("cloudflare").first?.destination, .footageStore)
    }

    func testSearchIgnoresCaseAndSurroundingSpace() {
        XCTAssertEqual(SettingsCatalogue.search("  TAILSCALE ").first?.destination, .reaching)
    }

    /// Every word has to match something. "pc battery" is two requirements, not two chances.
    func testEveryWordOfTheQueryHasToMatch() {
        XCTAssertFalse(SettingsCatalogue.search("wake lan").isEmpty)
        XCTAssertTrue(SettingsCatalogue.search("wake aubergine").isEmpty,
                      "a word that matches nothing should not be ignored")
    }

    func testAnEmptyQueryFindsNothingRatherThanEverything() {
        XCTAssertTrue(SettingsCatalogue.search("").isEmpty)
        XCTAssertTrue(SettingsCatalogue.search("   ").isEmpty)
    }

    func testNonsenseFindsNothing() {
        XCTAssertTrue(SettingsCatalogue.search("qzxjv").isEmpty)
    }

    /// A page whose title is the word beats a page that merely mentions it, so the first result is
    /// the one somebody meant.
    func testATitleMatchOutranksAKeywordMatch() {
        let found = SettingsCatalogue.search("lights")
        XCTAssertEqual(found.first?.destination, .smartHome,
                       "\"Lights and devices\" should come before the pages that mention lights")
        XCTAssertTrue(found.contains { $0.destination == .standbyLights })
    }

    /// A word inside the title, not only at its start. Somebody scanning for "diagnostics" expects
    /// "Connection diagnostics".
    func testSearchMatchesAWordInsideATitle() {
        XCTAssertEqual(SettingsCatalogue.search("diagnostics").first?.destination, .diagnostics)
    }

    func testSearchIsStableForTheSameQuery() {
        let once = SettingsCatalogue.search("pc").map(\.destination)
        let twice = SettingsCatalogue.search("pc").map(\.destination)
        XCTAssertEqual(once, twice)
    }

    func testSearchNeverReturnsAPageTwice() {
        let found = SettingsCatalogue.search("pc").map(\.destination)
        XCTAssertEqual(found.count, Set(found).count)
    }

    // MARK: Status
    //
    // §21's distinction, which the old page did not make: set up and set up *and working now* are
    // different facts, and a screen that shows them the same way is lying about one of them.

    func testConfiguredAndLiveDoNotLookTheSame() {
        XCTAssertNotEqual(SettingsStatus.live("x").colour, SettingsStatus.configured("x").colour)
        XCTAssertTrue(SettingsStatus.live("x").filled)
        XCTAssertFalse(SettingsStatus.configured("x").filled,
                       "a hollow dot is what says \"set up, not answering\"")
    }

    func testSomethingNotSetUpIsNotShownAsAFault() {
        XCTAssertNotEqual(SettingsStatus.off("None").colour, SettingsStatus.fault("None").colour)
    }

    func testEveryStatusCarriesItsOwnWords() {
        let all: [SettingsStatus] = [.live("a"), .ready("b"), .configured("c"),
                                     .off("d"), .attention("e"), .fault("f")]
        XCTAssertEqual(all.map(\.text), ["a", "b", "c", "d", "e", "f"])
    }
}
