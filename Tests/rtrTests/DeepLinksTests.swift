import Testing
import Foundation
@testable import rtr

@Suite("DeepLinks rewriting")
struct DeepLinksTests {

    private func handler(named name: String) -> DeepLinkHandler {
        DeepLinks.all.first(where: { $0.name == name })!
    }

    // MARK: - Slack

    @Test func slackChannelMessageRewritesToCustomScheme() throws {
        let url = URL(string: "https://acme.slack.com/archives/C0123ABCD/p1700000000123456")!
        let h = handler(named: "Slack")
        #expect(h.matches(url))

        let out = try #require(h.rewrite(url))
        #expect(out.scheme == "slack")

        let comp = try #require(URLComponents(url: out, resolvingAgainstBaseURL: false))
        #expect(comp.host == "channel")
        let items = Dictionary(uniqueKeysWithValues:
            (comp.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["team"] == "acme")
        #expect(items["id"] == "C0123ABCD")
        #expect(items["message"] == "1700000000.123456")
    }

    @Test func slackUsesResolvedTeamIDNotSubdomain() throws {
        // The slack:// scheme requires the team ID (T…); the subdomain alone doesn't navigate.
        let url = URL(string: "https://heyhalda.slack.com/archives/C03QJUCA4CC/p1779142039159159")!
        let out = try #require(rtr.slackRewrite(url) { sub in
            sub == "heyhalda" ? "T7H6W50RX" : nil
        })
        let items = Dictionary(uniqueKeysWithValues:
            (URLComponents(url: out, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") })
        #expect(items["team"] == "T7H6W50RX")
        #expect(items["id"] == "C03QJUCA4CC")
        #expect(items["message"] == "1779142039.159159")
    }

    @Test func slackFallsBackToSubdomainWhenTeamIDUnresolved() throws {
        let url = URL(string: "https://acme.slack.com/archives/C0123ABCD/p1700000000123456")!
        let out = try #require(rtr.slackRewrite(url) { _ in nil })
        let items = Dictionary(uniqueKeysWithValues:
            (URLComponents(url: out, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") })
        #expect(items["team"] == "acme")
    }

    @Test func slackThreadTimestampPreserved() throws {
        let url = URL(string: "https://acme.slack.com/archives/C0123ABCD/p1700000000123456?thread_ts=1699000000.111111")!
        let out = try #require(handler(named: "Slack").rewrite(url))
        let comp = try #require(URLComponents(url: out, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues:
            (comp.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["thread_ts"] == "1699000000.111111")
    }

    @Test func slackWorkspaceRootFallsBackToOpen() throws {
        let url = URL(string: "https://acme.slack.com/")!
        let out = try #require(handler(named: "Slack").rewrite(url))
        #expect(out.scheme == "slack")
        #expect(out.host == "open")
    }

    @Test func slackDoesNotMatchUnrelatedHosts() {
        let h = handler(named: "Slack")
        #expect(!h.matches(URL(string: "https://example.com")!))
        #expect(!h.matches(URL(string: "https://slack.com/about")!))
    }

    // MARK: - Zoom

    @Test func zoomJoinLinkRewritesWithPwd() throws {
        let url = URL(string: "https://zoom.us/j/1234567890?pwd=secret")!
        let h = handler(named: "Zoom")
        #expect(h.matches(url))

        let out = try #require(h.rewrite(url))
        #expect(out.scheme == "zoommtg")
        #expect(out.host == "zoom.us")
        #expect(out.path == "/join")

        let items = Dictionary(uniqueKeysWithValues:
            (URLComponents(url: out, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") })
        #expect(items["confno"] == "1234567890")
        #expect(items["pwd"] == "secret")
    }

    @Test func zoomMyLinkMatchesButRewriteReturnsNilForNonJoinPath() {
        // /my/* matches the handler's predicate but only /j/<id> rewrites.
        let url = URL(string: "https://zoom.us/my/jonny")!
        let h = handler(named: "Zoom")
        #expect(h.matches(url))
        #expect(h.rewrite(url) == nil)
    }

    @Test func zoomDoesNotMatchUnrelated() {
        let h = handler(named: "Zoom")
        #expect(!h.matches(URL(string: "https://zoom.us/about")!))
        #expect(!h.matches(URL(string: "https://example.com/j/123")!))
    }

    // MARK: - Spotify

    @Test func spotifyTrackRewrite() {
        let url = URL(string: "https://open.spotify.com/track/abc123")!
        let h = handler(named: "Spotify")
        #expect(h.matches(url))
        #expect(h.rewrite(url)?.absoluteString == "spotify:track:abc123")
    }

    @Test func spotifyAlbumRewrite() {
        let url = URL(string: "https://open.spotify.com/album/xyz789")!
        #expect(handler(named: "Spotify").rewrite(url)?.absoluteString == "spotify:album:xyz789")
    }

    @Test func spotifyDoesNotMatchOtherHosts() {
        #expect(!handler(named: "Spotify").matches(URL(string: "https://spotify.com/track/abc")!))
    }

    // MARK: - Discord

    @Test func discordChannelRewrite() {
        let url = URL(string: "https://discord.com/channels/123/456")!
        let h = handler(named: "Discord")
        #expect(h.matches(url))
        #expect(h.rewrite(url)?.absoluteString == "discord://-/channels/123/456")
    }

    @Test func discordDoesNotMatchHomePages() {
        let h = handler(named: "Discord")
        #expect(!h.matches(URL(string: "https://discord.com/")!))
        #expect(!h.matches(URL(string: "https://discord.com/login")!))
    }

    @Test func discordAppLegacyHostMatches() {
        #expect(handler(named: "Discord").matches(URL(string: "https://discordapp.com/channels/1/2")!))
    }
}
