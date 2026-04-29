import Testing
import Foundation
@testable import rtr

@Suite("BrowserCatalog.resolve")
struct BrowserCatalogTests {

    private let safari = Browser(
        id: "com.apple.Safari",
        displayName: "Safari",
        bundleID: "com.apple.Safari",
        appURL: URL(fileURLWithPath: "/Applications/Safari.app"),
        kind: .simple
    )

    private let firefox = Browser(
        id: "org.mozilla.firefox",
        displayName: "Firefox",
        bundleID: "org.mozilla.firefox",
        appURL: URL(fileURLWithPath: "/Applications/Firefox.app"),
        kind: .simple
    )

    private let chromeDefault = Browser(
        id: "com.google.Chrome#Default",
        displayName: "Google Chrome — Personal",
        bundleID: "com.google.Chrome",
        appURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
        kind: .chromium(profileDir: "Default", profileName: "Personal")
    )

    private let chromeWork = Browser(
        id: "com.google.Chrome#Profile 2",
        displayName: "Google Chrome — Work",
        bundleID: "com.google.Chrome",
        appURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
        kind: .chromium(profileDir: "Profile 2", profileName: "Work")
    )

    private var all: [Browser] { [safari, firefox, chromeDefault, chromeWork] }

    // MARK: - Exact ID match

    @Test func exactBundleIDMatch() {
        #expect(BrowserCatalog.resolve(id: "com.apple.Safari", in: all)?.id == "com.apple.Safari")
    }

    @Test func exactBundleIDPlusProfileMatch() {
        #expect(BrowserCatalog.resolve(id: "com.google.Chrome#Profile 2", in: all)?.id
                == "com.google.Chrome#Profile 2")
    }

    // MARK: - Friendly alias for Chromium profiles ("chrome:Work")

    @Test func chromiumProfileAlias() {
        #expect(BrowserCatalog.resolve(id: "chrome:Work", in: all)?.id
                == "com.google.Chrome#Profile 2")
    }

    @Test func chromiumProfileAliasIsCaseInsensitiveOnProfileName() {
        #expect(BrowserCatalog.resolve(id: "chrome:WORK", in: all)?.id
                == "com.google.Chrome#Profile 2")
    }

    @Test func chromiumProfileAliasReturnsNilWhenNoMatch() {
        #expect(BrowserCatalog.resolve(id: "chrome:NoSuchProfile", in: all) == nil)
    }

    // MARK: - Friendly fuzzy match on simple browsers

    @Test func friendlyNameSafari() {
        #expect(BrowserCatalog.resolve(id: "safari", in: all)?.id == "com.apple.Safari")
    }

    @Test func friendlyNameFirefox() {
        #expect(BrowserCatalog.resolve(id: "firefox", in: all)?.id == "org.mozilla.firefox")
    }

    @Test func friendlyMatchPrefersExactBundleIDIfPresent() {
        #expect(BrowserCatalog.resolve(id: "com.apple.Safari", in: all)?.id == "com.apple.Safari")
    }

    @Test func friendlyDoesNotMatchChromiumProfiles() {
        // "chrome" without ":Profile" should not pick a Chromium variant via the simple-fuzzy path.
        #expect(BrowserCatalog.resolve(id: "chrome", in: all) == nil)
    }

    @Test func emptyCatalogReturnsNil() {
        #expect(BrowserCatalog.resolve(id: "anything", in: []) == nil)
    }
}
