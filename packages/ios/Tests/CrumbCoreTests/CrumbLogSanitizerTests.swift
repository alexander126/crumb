import Foundation
import Testing
@testable import CrumbCore

struct CrumbLogSanitizerTests {
    @Test
    func redactsNestedReactNativeMetadataWithoutLosingSafeFields() {
        let raw = #"Checkout failed metadata={"credentials":{"password":"synthetic-password","api_key":"synthetic-api-key"},"screen":"checkout"}"#
        let expected = #"Checkout failed metadata={"credentials":{"password":"[REDACTED]","api_key":"[REDACTED]"},"screen":"checkout"}"#

        #expect(CrumbLogSanitizer.sanitize(raw) == expected)
        #expect(CrumbLogSanitizer.sanitize(expected) == expected)
    }

    @Test(arguments: [
        #"{"token":{"value":"synthetic-container"},"safe":true}"#,
        "{\"Cookie\":[\n\"synthetic-session\",\n\"synthetic-refresh\"\n],\"safe\":true}"
    ])
    func failsClosedForComplexCredentialValues(raw: String) {
        let sanitized = CrumbLogSanitizer.sanitize(raw)

        #expect(!sanitized.contains("synthetic"))
        #expect(sanitized.contains("[REDACTED]"))
        #expect(CrumbLogSanitizer.sanitize(sanitized) == sanitized)
    }

    @Test(arguments: [
        "access_token", "access-token", "accessToken", "refresh_token", "refresh-token", "refreshToken",
        "id_token", "id-token", "idToken", "authToken", "sessionToken", "client_secret", "client-secret",
        "clientSecret", "api_key", "api-key", "apiKey", "X-API-Key"
    ])
    func redactsCommonCredentialKeySpellings(key: String) {
        let raw = #"{"\#(key)":"synthetic-credential","safe":"retained"}"#
        let expected = #"{"\#(key)":"[REDACTED]","safe":"retained"}"#

        #expect(CrumbLogSanitizer.sanitize(raw) == expected)
        #expect(CrumbLogSanitizer.sanitize(expected) == expected)
    }

    @Test(arguments: [
        (#"{"password":"synthetic-\"suffix","safe":true}"#, #"{"password":"[REDACTED]","safe":true}"#),
        (#"{"client_secret":"synthetic-\\path","safe":true}"#, #"{"client_secret":"[REDACTED]","safe":true}"#),
        (#"{'password':'synthetic-\'suffix','safe':true}"#, #"{'password':'[REDACTED]','safe':true}"#),
        (#"{"password":"synthetic-unclosed"#, #"{"password":"[REDACTED]""#),
        (#"{"password":"synthetic-trailing\"#, #"{"password":"[REDACTED]""#),
        (#"{'password':'synthetic-unclosed"#, #"{'password':'[REDACTED]'"#),
        (#"{"Authorization":"Basic synthetic-encoded","safe":true}"#, #"{"Authorization":"[REDACTED]","safe":true}"#),
        (#"{"Cookie":"session=synthetic-session; refresh=synthetic-refresh","safe":true}"#, #"{"Cookie":"[REDACTED]","safe":true}"#)
    ])
    func redactsWholeQuotedValuesIncludingEscapesAndTruncation(raw: String, expected: String) {
        #expect(CrumbLogSanitizer.sanitize(raw) == expected)
    }

    @Test
    func redactsWholeAuthorizationAndCookieHeadersIncludingFoldedLines() {
        let raw = "Authorization: Basic c3ludGhldGljOnZhbHVl\r\n"
            + "Proxy-Authorization: Digest username=\"synthetic-user\", response=\"synthetic-response\"\r\n"
            + "Cookie: session=synthetic-session; refresh=synthetic-refresh\r\n"
            + "\tcontinued=synthetic-continuation\r\n"
            + "Set-Cookie: session=synthetic-session; Expires=Wed, 01 Jan 2030 00:00:00 GMT; HttpOnly\r\n"
            + "status=503 screen=checkout"
        let expected = "Authorization: [REDACTED]  Proxy-Authorization: [REDACTED]  "
            + "Cookie: [REDACTED]  Set-Cookie: [REDACTED]  status=503 screen=checkout"

        #expect(CrumbLogSanitizer.sanitize(raw) == expected)
        #expect(CrumbLogSanitizer.sanitize(expected) == expected)
    }

    @Test
    func leavesSafeContextAndSimilarKeyNamesUnchanged() {
        let raw = #"{"tokenCount":2,"passwordHint":"retained","secretary":"retained","screen":"checkout"} status=503 retry_count=2"#

        #expect(CrumbLogSanitizer.sanitize(raw) == raw)
        #expect(CrumbLogSanitizer.sanitize("password=synthetic-password status=503")
            == "password=[REDACTED] status=503")
    }

    @Test(arguments: [
        #"{"password":"synthetic-password","apiKey":"synthetic-api-key","safe":true}"#,
        "Authorization: Basic c3ludGhldGljOnZhbHVl\nCookie: session=synthetic; refresh=synthetic-refresh",
        "email=user@example.invalid password=synthetic-password https://synthetic-user:synthetic-password@example.invalid?a=synthetic-query&b=synthetic-query 4111 1111 1111 1111\nforged-line",
        #"{"password":"synthetic-trailing\"#
    ])
    func redactionIsIdempotent(raw: String) {
        let once = CrumbLogSanitizer.sanitize(raw)

        #expect(CrumbLogSanitizer.sanitize(once) == once)
    }

    @Test(arguments: [
        ("token=[REDACTED]synthetic-tail", "token=[REDACTED]"),
        ("password=[REDACTED]{nested:synthetic-tail}", "password=[REDACTED]")
    ])
    func redactsCredentialSuffixesAfterAnExistingMarker(raw: String, expected: String) {
        #expect(CrumbLogSanitizer.sanitize(raw) == expected)
    }

    @Test(arguments: [
        "token=[REDACTED] status=503",
        #"{"token":[REDACTED],"safe":true}"#,
        "password=[REDACTED]; safe=retained",
        #"{"Cookie":[REDACTED]}"#,
        #"[token=[REDACTED]]"#,
        "Authorization: [REDACTED]",
        "Set-Cookie: [REDACTED] safe=retained"
    ])
    func preservesOnlyStandaloneRedactionMarkers(raw: String) {
        #expect(CrumbLogSanitizer.sanitize(raw) == raw)
    }

    @Test
    func redactsLongEscapedValuesWithoutLeavingASuffix() {
        let raw = #"{"password":""# + String(repeating: #"synthetic-\""#, count: 8_192)
            + #"synthetic-tail","safe":true}"#

        #expect(raw.utf8.count > 65_536)
        #expect(CrumbLogSanitizer.sanitize(raw) == #"{"password":"[REDACTED]","safe":true}"#)
    }

    @Test(arguments: [
        ("password:\nsynthetic-value status=503", "password: [REDACTED] status=503"),
        ("{\"password\":\n\"synthetic-value\",\"safe\":true}", #"{"password": "[REDACTED]","safe":true}"#)
    ])
    func redactsCredentialsSeparatedByLineBreaks(raw: String, expected: String) {
        #expect(CrumbLogSanitizer.sanitize(raw) == expected)
        #expect(CrumbLogSanitizer.sanitize(expected) == expected)
    }

    @Test
    func preservesExistingRedactionCategories() {
        let raw = "email=user@example.invalid password=synthetic-password "
            + "https://synthetic-user:synthetic-password@example.invalid?a=synthetic-query&b=synthetic-query "
            + "4111 1111 1111 1111\nforged-line"
        let sanitized = CrumbLogSanitizer.sanitize(raw)

        #expect(!sanitized.contains("user@example.invalid"))
        #expect(!sanitized.contains("synthetic-password"))
        #expect(!sanitized.contains("synthetic-query"))
        #expect(!sanitized.contains("4111"))
        #expect(!sanitized.contains("\n"))
        #expect(sanitized.contains("[REDACTED_EMAIL]"))
        #expect(sanitized.contains("[REDACTED_NUMBER]"))
        #expect(sanitized.contains("forged-line"))
    }
}
