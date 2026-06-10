import XCTest
@testable import LinkoKit

final class SurgeRuleImporterTests: XCTestCase {
    private let importer = SurgeRuleImporter()

    // A realistic slice of a Surge profile with multiple sections, comments,
    // inline `//` notes, and rule options.
    private static let profile = """
    [General]
    loglevel = notify
    dns-server = 223.5.5.5

    [Rule]
    # domestic & LAN go direct
    DOMAIN-SUFFIX,cn,DIRECT
    DOMAIN,example.com,Proxy // pin this one
    DOMAIN-KEYWORD,google,Proxy
    IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
    IP-CIDR6,2620:0:2d0:200::7/32,Proxy,no-resolve
    GEOIP,CN,DIRECT,no-resolve
    GEOSITE,category-ads-all,REJECT
    RULE-SET,https://example.com/proxy.list,Proxy
    RULE-SET,LAN,DIRECT
    RULE-SET,SYSTEM,DIRECT
    PROCESS-NAME,Telegram,Proxy
    DEST-PORT,80,Proxy
    DOMAIN-SUFFIX,extended.com,Proxy,extended-matching
    SNELL-THING,foo,Proxy
    FINAL,Proxy

    [Proxy Group]
    Proxy = select, A, B
    """

    func testParsesRuleSectionOnly() {
        let result = importer.importSurgeRules(Self.profile)
        // 14 valid rules (SNELL-THING skipped). General/Proxy Group sections ignored.
        XCTAssertEqual(result.rules.count, 14)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("SNELL-THING"))
    }

    func testMapsCoreTypes() {
        let result = importer.importSurgeRules(Self.profile)
        let byTypeValue = result.rules

        XCTAssertEqual(byTypeValue[0].type, .domainSuffix)
        XCTAssertEqual(byTypeValue[0].value, "cn")
        XCTAssertEqual(byTypeValue[0].target, "DIRECT")

        XCTAssertEqual(byTypeValue[1].type, .domain)
        XCTAssertEqual(byTypeValue[1].value, "example.com")
        XCTAssertEqual(byTypeValue[1].target, "Proxy")

        XCTAssertEqual(byTypeValue[2].type, .domainKeyword)
        XCTAssertEqual(byTypeValue[2].value, "google")

        XCTAssertEqual(byTypeValue[3].type, .ipCIDR)
        XCTAssertEqual(byTypeValue[3].value, "192.168.0.0/16")
        XCTAssertEqual(byTypeValue[3].target, "DIRECT")

        XCTAssertEqual(byTypeValue[4].type, .ipCIDR6)
        XCTAssertEqual(byTypeValue[4].value, "2620:0:2d0:200::7/32")

        XCTAssertEqual(byTypeValue[5].type, .geoip)
        XCTAssertEqual(byTypeValue[5].value, "CN")

        XCTAssertEqual(byTypeValue[6].type, .geosite)
        XCTAssertEqual(byTypeValue[6].value, "category-ads-all")
        XCTAssertEqual(byTypeValue[6].target, "REJECT")
    }

    func testParsesRuleSetVariants() {
        let result = importer.importSurgeRules(Self.profile)
        let ruleSets = result.rules.filter { $0.type == .ruleSet }
        XCTAssertEqual(ruleSets.count, 3)
        XCTAssertEqual(ruleSets[0].value, "https://example.com/proxy.list")
        XCTAssertEqual(ruleSets[0].target, "Proxy")
        XCTAssertEqual(ruleSets[1].value, "LAN")
        XCTAssertEqual(ruleSets[2].value, "SYSTEM")
    }

    func testParsesProcessAndPort() {
        let result = importer.importSurgeRules(Self.profile)
        let process = result.rules.first { $0.type == .processName }
        XCTAssertEqual(process?.value, "Telegram")
        XCTAssertEqual(process?.target, "Proxy")

        let port = result.rules.first { $0.type == .destPort }
        XCTAssertEqual(port?.value, "80")
        XCTAssertEqual(port?.target, "Proxy")
    }

    func testFinalRuleHasNoValue() {
        let result = importer.importSurgeRules(Self.profile)
        let final = result.rules.last
        XCTAssertEqual(final?.type, .final)
        XCTAssertEqual(final?.value, "")
        XCTAssertEqual(final?.target, "Proxy")
    }

    func testStripsInlineCommentWithoutCorruptingPolicy() {
        let result = importer.importSurgeRules(Self.profile)
        let pinned = result.rules.first { $0.value == "example.com" }
        XCTAssertEqual(pinned?.target, "Proxy")
    }

    func testOptionsDoNotLeakIntoPolicy() {
        let result = importer.importSurgeRules(Self.profile)
        let geoip = result.rules.first { $0.type == .geoip }
        XCTAssertEqual(geoip?.target, "DIRECT")
        let extended = result.rules.first { $0.value == "extended.com" }
        XCTAssertEqual(extended?.target, "Proxy")
    }

    func testReferencedPoliciesFirstSeenOrder() {
        let result = importer.importSurgeRules(Self.profile)
        XCTAssertEqual(result.referencedPolicies, ["DIRECT", "Proxy", "REJECT"])
    }

    func testBareRuleListWithoutSectionHeader() {
        let text = """
        DOMAIN-SUFFIX,google.com,Proxy
        FINAL,DIRECT
        """
        let result = importer.importSurgeRules(text)
        XCTAssertEqual(result.rules.count, 2)
        XCTAssertEqual(result.rules[0].type, .domainSuffix)
        XCTAssertEqual(result.rules[1].type, .final)
        XCTAssertEqual(result.rules[1].target, "DIRECT")
    }

    func testSkipsLogicalRules() {
        let text = """
        [Rule]
        AND,((DOMAIN,a.com),(DEST-PORT,443)),Proxy
        DOMAIN,b.com,Proxy
        """
        let result = importer.importSurgeRules(text)
        XCTAssertEqual(result.rules.count, 1)
        XCTAssertEqual(result.rules[0].value, "b.com")
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("logical"))
    }

    func testEmptyInputYieldsEmptyResult() {
        let result = importer.importSurgeRules("")
        XCTAssertTrue(result.rules.isEmpty)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertTrue(result.referencedPolicies.isEmpty)
    }

    func testMissingValueWarns() {
        let result = importer.importSurgeRules("[Rule]\nDOMAIN,,Proxy")
        XCTAssertTrue(result.rules.isEmpty)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("without a value"))
    }

    func testMissingPolicyWarns() {
        let result = importer.importSurgeRules("[Rule]\nDOMAIN,a.com")
        XCTAssertTrue(result.rules.isEmpty)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("without a policy"))
    }
}

final class ClashRuleImporterTests: XCTestCase {
    private let importer = ClashRuleImporter()

    private static let fullDocument = """
    port: 7890
    mode: rule
    rules:
      - DOMAIN-SUFFIX,google.com,Proxy
      - DOMAIN-KEYWORD,github,Proxy
      - DOMAIN,ad.example.com,REJECT
      - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
      - IP-CIDR6,fe80::/10,DIRECT,no-resolve
      - GEOIP,CN,DIRECT
      - RULE-SET,https://example.com/rules.yaml,Proxy
      - PROCESS-NAME,curl,DIRECT
      - DST-PORT,443,Proxy
      - MATCH,Proxy
    """

    func testParsesFullClashDocument() {
        let result = importer.importClashRules(Self.fullDocument)
        XCTAssertEqual(result.rules.count, 10)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testMatchMapsToFinal() {
        let result = importer.importClashRules(Self.fullDocument)
        let last = result.rules.last
        XCTAssertEqual(last?.type, .final)
        XCTAssertEqual(last?.value, "")
        XCTAssertEqual(last?.target, "Proxy")
    }

    func testMapsTypesAndPolicies() {
        let result = importer.importClashRules(Self.fullDocument)
        XCTAssertEqual(result.rules[0].type, .domainSuffix)
        XCTAssertEqual(result.rules[0].value, "google.com")
        XCTAssertEqual(result.rules[0].target, "Proxy")

        XCTAssertEqual(result.rules[2].type, .domain)
        XCTAssertEqual(result.rules[2].target, "REJECT")

        XCTAssertEqual(result.rules[3].type, .ipCIDR)
        XCTAssertEqual(result.rules[3].target, "DIRECT")

        XCTAssertEqual(result.rules[4].type, .ipCIDR6)

        let ruleSet = result.rules.first { $0.type == .ruleSet }
        XCTAssertEqual(ruleSet?.value, "https://example.com/rules.yaml")

        let port = result.rules.first { $0.type == .destPort }
        XCTAssertEqual(port?.value, "443")
    }

    func testReferencedPolicies() {
        let result = importer.importClashRules(Self.fullDocument)
        XCTAssertEqual(result.referencedPolicies, ["Proxy", "REJECT", "DIRECT"])
    }

    func testBareYAMLList() {
        let text = """
        - DOMAIN-SUFFIX,example.com,Proxy
        - MATCH,DIRECT
        """
        let result = importer.importClashRules(text)
        XCTAssertEqual(result.rules.count, 2)
        XCTAssertEqual(result.rules[0].value, "example.com")
        XCTAssertEqual(result.rules[1].type, .final)
        XCTAssertEqual(result.rules[1].target, "DIRECT")
    }

    func testQuotedValues() {
        let text = """
        rules:
          - "DOMAIN-SUFFIX,quoted.com,Proxy"
          - 'DOMAIN,single.com,DIRECT'
        """
        let result = importer.importClashRules(text)
        XCTAssertEqual(result.rules.count, 2)
        XCTAssertEqual(result.rules[0].value, "quoted.com")
        XCTAssertEqual(result.rules[0].target, "Proxy")
        XCTAssertEqual(result.rules[1].value, "single.com")
    }

    func testSkipsUnsupportedTypeWithWarning() {
        let text = """
        rules:
          - SCRIPT,my-script,Proxy
          - DOMAIN,ok.com,Proxy
        """
        let result = importer.importClashRules(text)
        XCTAssertEqual(result.rules.count, 1)
        XCTAssertEqual(result.rules[0].value, "ok.com")
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("SCRIPT"))
    }

    func testEmptyRulesSection() {
        let result = importer.importClashRules("port: 7890\nmode: rule")
        XCTAssertTrue(result.rules.isEmpty)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testLineFallbackForLooseSnippet() {
        // Not valid as a single YAML mapping/list but a recognizable rule line.
        let text = "DOMAIN-SUFFIX,loose.com,Proxy"
        let result = importer.importClashRules(text)
        XCTAssertEqual(result.rules.count, 1)
        XCTAssertEqual(result.rules[0].value, "loose.com")
    }

    func testCrossDelegation() {
        // Surge importer can take Clash text and vice versa.
        let clashText = "rules:\n  - DOMAIN,x.com,Proxy"
        let viaSurge = SurgeRuleImporter().importClashRules(clashText)
        XCTAssertEqual(viaSurge.rules.count, 1)

        let surgeText = "[Rule]\nDOMAIN,y.com,Proxy"
        let viaClash = ClashRuleImporter().importSurgeRules(surgeText)
        XCTAssertEqual(viaClash.rules.count, 1)
        XCTAssertEqual(viaClash.rules[0].value, "y.com")
    }
}
