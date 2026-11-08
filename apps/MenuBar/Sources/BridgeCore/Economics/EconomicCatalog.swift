@_exported import WorkspaceContracts
import Foundation

/// Built-in rates, the effort rubric and the formulas every economic report
/// uses. A person can add their own rate and choose another; nothing here is
/// fetched at run time.
public enum EconomicCatalog {
    public static let defaultRateID = "us-bls-15-1252-2025-05"

    /// US Bureau of Labor Statistics median wages for Software Developers
    /// (SOC 15-1252). Wage benchmarks: not contractor billing rates, loaded
    /// employer costs or any local market.
    public static let rates: [LaborRate] = [
        LaborRate(id: "us-bls-15-1252-2021-05", label: "US software developer median wage, May 2021",
                  hourly: MoneyAmount(amount: ExactDecimal("58.05")!, currency: "USD"), vintage: "May 2021", region: "United States",
                  basis: .medianWage, derivation: nil,
                  source: .init(publisher: "U.S. Bureau of Labor Statistics, OEWS", url: "https://www.bls.gov/oes/2021/may/oes151252.htm", retrieved: "2026-11-06")),
        LaborRate(id: "us-bls-15-1252-2022-05", label: "US software developer median wage, May 2022",
                  hourly: MoneyAmount(amount: ExactDecimal("61.18")!, currency: "USD"), vintage: "May 2022", region: "United States",
                  basis: .medianWage, derivation: nil,
                  source: .init(publisher: "U.S. Bureau of Labor Statistics, OEWS", url: "https://www.bls.gov/oes/2022/may/oes151252.htm", retrieved: "2026-11-06")),
        LaborRate(id: defaultRateID, label: "US software developer median wage, May 2025",
                  hourly: MoneyAmount(amount: ExactDecimal("65.38")!, currency: "USD"), vintage: "May 2025", region: "United States",
                  basis: .medianWage, derivation: "Median annual wage $135,980 ÷ 2,080 hours, rounded to the cent",
                  source: .init(publisher: "U.S. Bureau of Labor Statistics, Occupational Outlook Handbook",
                                url: "https://www.bls.gov/ooh/computer-and-information-technology/software-developers.htm", retrieved: "2026-11-06")),
    ]

    /// Hours are for a competent developer with 2021–2022 tools building a
    /// useful internal tool; the standard and baseline factors scale them.
    public static let rubric = EffortRubric(
        version: "hub-size-rubric/1",
        sizes: [
            .init(id: "xs", title: "Small change", description: "A well-understood change in one place: a fix, a copy or configuration change, a small refactor.",
                  hours: range("1", "2", "4")),
            .init(id: "s", title: "Contained capability", description: "One capability inside a single component, with its tests.",
                  hours: range("4", "8", "16")),
            .init(id: "m", title: "Feature across components", description: "A feature spanning a few components (interface, logic, storage) or one contained integration.",
                  hours: range("16", "28", "48")),
            .init(id: "l", title: "Subsystem or integration", description: "A subsystem or cross-cutting capability: several components, new contracts or data formats, a migration or an external integration.",
                  hours: range("48", "90", "160")),
            .init(id: "xl", title: "Major capability", description: "A major product capability or a new application area with its own architecture.",
                  hours: range("160", "280", "480")),
        ],
        standardFactors: ["prototype": ExactDecimal("0.6")!, "internal_tool": 1, "production": ExactDecimal("1.75")!],
        contemporaryFactors: range("0.5", "0.8", "1.1"),
        notes: [
            "Choose the size from what was delivered and how much it had to integrate, not from lines changed or tokens used.",
            "Production-oriented work adds hardening, documentation, security and operational readiness (×1.75); a prototype skips most of it (×0.6).",
            "For a developer with 2025–2026 assistants the low, base and high hours are scaled by 0.5, 0.8 and 1.1. Measured uplift from assistants is uncertain and can be negative (METR's 2025 study of experienced open-source developers found them 19% slower), so the range is deliberately wide.",
            "Hub defaults are a starting point for calibration, not a measurement. Corrections are kept as new assessments.",
        ])

    public static let formulas = [
        "Equivalent person-days = estimated human hours ÷ hours per day.",
        "Gross labor equivalent = estimated human hours × hourly rate (a wage equivalent, not revenue, market value or cash saved).",
        "Operator cost = the person's hands-on hours × the operator rate.",
        "Tooling cost = each subscription's monthly price × days in the period ÷ (365.2425 ÷ 12), times the scope's share of known tokens when a project is chosen.",
        "Net opportunity benefit = gross labor equivalent − operator cost − tooling cost; the low end uses the most operator time and the high end the least.",
        "Leverage = estimated human hours ÷ hands-on hours.",
        "Money is rounded to cents, halves to even, after each total; inputs keep their exact decimals.",
    ]

    public static func defaultAssumptions(timeZone: TimeZone = ActivityAnalytics.reportingTimeZone) -> EconomicAssumptions {
        EconomicAssumptions(baseline: .historical, rateID: defaultRateID, hoursPerDay: 8, timeZone: timeZone.identifier)
    }

    /// Built-in rates followed by the person's own; a custom rate can't
    /// replace a built-in one.
    public static func allRates(_ assumptions: EconomicAssumptions) -> [LaborRate] {
        rates + assumptions.customRates.filter { custom in !rates.contains { $0.id == custom.id } }
    }

    public static func rate(_ id: String, in assumptions: EconomicAssumptions) -> LaborRate? {
        allRates(assumptions).first { $0.id == id }
    }

    private static func range(_ low: String, _ base: String, _ high: String) -> EstimateRange {
        EstimateRange(low: ExactDecimal(low)!, base: ExactDecimal(base)!, high: ExactDecimal(high)!)
    }
}
