import Testing
@testable import CrumbUI

struct CrumbLocalizationTests {
    @Test
    func loadsThePackagedEnglishReporterCatalog() {
        #expect(crumbLocalized("Report a problem") == "Report a problem")
        #expect(crumbLocalized("Send report") == "Send report")
    }
}
