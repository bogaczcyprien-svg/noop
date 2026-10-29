import XCTest
@testable import StrandAnalytics

/// Optional personal baselines obey the same eligibility contract as resting HR.
/// Kotlin twin: RecoveryOptionalBaselineUsableTest.
final class RecoveryOptionalBaselineUsableTests: XCTestCase {
    private func optionalBaselineFixture(_ mean: Double, _ spread: Double,
                                         _ status: BaselineStatus = .trusted) -> BaselineState {
        BaselineState(baseline: mean, spread: spread,
                      nValid: status == .calibrating ? 0 : (status == .provisional ? 6 : 14),
                      nightsSinceUpdate: status == .stale ? 20 : 0, status: status)
    }

    private var hrv: BaselineState { optionalBaselineFixture(50, 8) }
    private var rhr: BaselineState { optionalBaselineFixture(60, 4) }
    private let statuses: [BaselineStatus] = [.calibrating, .provisional, .trusted, .stale]
    private let respiratoryValues: [Double?] = [nil, 10, 14, 18, 22]
    private let effortValues: [Double?] = [nil, 0, 30, 60, 100]

    private func optionalChargeFixture(respBase: BaselineState?, effortBase: BaselineState? = nil,
                                       resp: Double? = 14, effort: Double? = 60) -> Double? {
        RecoveryScorer.recovery(hrv: 55, rhr: 58, resp: resp,
                                hrvBaseline: hrv, rhrBaseline: rhr, respBaseline: respBase,
                                sleepPerf: 0.85, skinTempDev: 0.2, recoveryIndexSlope: -0.5,
                                effortBaseline: effortBase, priorDayEffort: effort)
    }

    func testUnusableRespirationScoresExactlyLikeAbsent() {
        let states = [Baselines.foldHistory([], cfg: Baselines.respCfg),
                      Baselines.foldHistory([0, 100], cfg: Baselines.respCfg),
                      optionalBaselineFixture(16, 2, .stale)]
        for base in states {
            XCTAssertFalse(base.usable)
            for value in respiratoryValues {
                XCTAssertEqual(optionalChargeFixture(respBase: base, resp: value)?.bitPattern,
                               optionalChargeFixture(respBase: nil, resp: value)?.bitPattern)
            }
        }
    }

    func testUnusableEffortScoresExactlyLikeAbsent() {
        let states = [Baselines.foldHistory([], cfg: Baselines.strainCfg),
                      Baselines.foldHistory([-1, 101], cfg: Baselines.strainCfg),
                      optionalBaselineFixture(45, 10, .stale)]
        for base in states {
            XCTAssertFalse(base.usable)
            for value in effortValues {
                XCTAssertEqual(optionalChargeFixture(respBase: nil, effortBase: base, effort: value)?.bitPattern,
                               optionalChargeFixture(respBase: nil, effort: value)?.bitPattern)
            }
        }
    }

    func testAllOptionalStateAndValuePairsMatchEligibleDriverContract() {
        let respStates: [BaselineState?] = [nil] + statuses.map { optionalBaselineFixture(16, 2, $0) }
        let effortStates: [BaselineState?] = [nil] + statuses.map { optionalBaselineFixture(45, 10, $0) }
        var cases = 0
        var oracleLines: [String] = []
        for respBase in respStates {
            for effortBase in effortStates {
                for resp in respiratoryValues {
                    for effort in effortValues {
                        // The status-free API is the original math, with only eligible personal states supplied.
                        let expected = RecoveryScorer.recovery(
                            hrv: 55, rhr: 58, resp: resp,
                            hrvBaseline: RecoveryScorer.DriverBaseline(hrv),
                            rhrBaseline: RecoveryScorer.DriverBaseline(rhr),
                            respBaseline: respBase.flatMap { $0.usable ? RecoveryScorer.DriverBaseline($0) : nil },
                            sleepPerf: 0.85, skinTempDev: 0.2, recoveryIndexSlope: -0.5,
                            effortBaseline: effortBase.flatMap { $0.usable ? RecoveryScorer.DriverBaseline($0) : nil },
                            priorDayEffort: effort)
                        let actual = optionalChargeFixture(respBase: respBase, effortBase: effortBase,
                                                           resp: resp, effort: effort)
                        XCTAssertEqual(actual?.bitPattern, expected?.bitPattern)
                        if resp == 14, effort == 60 {
                            let bits = actual.map { String($0.bitPattern, radix: 16) } ?? "nil"
                            oracleLines.append("\(respBase?.status.rawValue ?? "nil")/\(effortBase?.status.rawValue ?? "nil")|\(bits)")
                        }
                        cases += 1
                    }
                }
            }
        }
        XCTAssertEqual(cases, 625)
        // FORK: these are the fork's own weights (wHRV 0.30 + wNightMeanHR 0.25, logisticK 1.7, iOS-only), taken
        // from the CI run of this exact test; the Kotlin twin keeps upstream's values because Android is untuned.
        // The relational checks above (each state scores as its eligible baseline) are unchanged.
        XCTAssertEqual(oracleLines.joined(separator: "\n"), """
        nil/nil|405198b5cedd7477
        nil/calibrating|405198b5cedd7477
        nil/provisional|4050bc7a873c8c84
        nil/trusted|4050bc7a873c8c84
        nil/stale|405198b5cedd7477
        calibrating/nil|405198b5cedd7477
        calibrating/calibrating|405198b5cedd7477
        calibrating/provisional|4050bc7a873c8c84
        calibrating/trusted|4050bc7a873c8c84
        calibrating/stale|405198b5cedd7477
        provisional/nil|4051dd410a9f631c
        provisional/calibrating|4051dd410a9f631c
        provisional/provisional|40510e35cc1a6351
        provisional/trusted|40510e35cc1a6351
        provisional/stale|4051dd410a9f631c
        trusted/nil|4051dd410a9f631c
        trusted/calibrating|4051dd410a9f631c
        trusted/provisional|40510e35cc1a6351
        trusted/trusted|40510e35cc1a6351
        trusted/stale|4051dd410a9f631c
        stale/nil|405198b5cedd7477
        stale/calibrating|405198b5cedd7477
        stale/provisional|4050bc7a873c8c84
        stale/trusted|4050bc7a873c8c84
        stale/stale|405198b5cedd7477
        """)
        XCTAssertNotEqual(optionalChargeFixture(respBase: nil)?.bitPattern,
                          optionalChargeFixture(respBase: optionalBaselineFixture(16, 2))?.bitPattern)
        XCTAssertNotEqual(optionalChargeFixture(respBase: nil)?.bitPattern,
                          optionalChargeFixture(respBase: nil, effortBase: optionalBaselineFixture(45, 10))?.bitPattern)
    }

    func testRespirationRowsUseExactlyTheEligibleBaseline() {
        for status in statuses {
            let base = optionalBaselineFixture(16, 2, status)
            for value in respiratoryValues {
                let actual = RecoveryScorer.chargeDrivers(hrv: 55, rhr: 58, resp: value,
                    hrvBaseline: hrv, rhrBaseline: rhr, respBaseline: base,
                    sleepPerf: 0.85, skinTempDev: 0.2)
                let expected = RecoveryScorer.chargeDrivers(hrv: 55, rhr: 58, resp: value,
                    hrvBaseline: hrv, rhrBaseline: rhr, respBaseline: base.usable ? base : nil,
                    sleepPerf: 0.85, skinTempDev: 0.2)
                XCTAssertEqual(actual, expected)
                XCTAssertEqual(actual.contains { $0.label == "Respiratory rate" }, base.usable && value != nil)
                XCTAssertTrue(actual.contains { $0.label == "Heart rate variability" })
            }
        }
    }

    func testRespirationTraceUsesExactlyTheScoredTerms() {
        for status in statuses {
            let base = optionalBaselineFixture(16, 2, status)
            for value in respiratoryValues {
                let actual = RecoveryScorer.recoveryTrace(hrv: 55, rhr: 58, resp: value,
                    hrvBaseline: hrv, rhrBaseline: rhr, respBaseline: base,
                    sleepPerf: 0.85, skinTempDev: 0.2)
                let expected = RecoveryScorer.recoveryTrace(hrv: 55, rhr: 58, resp: value,
                    hrvBaseline: hrv, rhrBaseline: rhr, respBaseline: base.usable ? base : nil,
                    sleepPerf: 0.85, skinTempDev: 0.2)
                XCTAssertEqual(actual.score?.bitPattern, expected.score?.bitPattern)
                XCTAssertEqual(actual.trace, expected.trace)
                XCTAssertEqual(actual.trace.contains { $0.hasPrefix("charge term resp ") }, base.usable && value != nil)
                XCTAssertEqual(actual.trace.contains { $0.hasPrefix("charge baseline resp ") }, base.usable)
                XCTAssertEqual(actual.trace.contains { $0.hasPrefix("charge nilTerm dropped=") && $0.contains("resp") },
                               !base.usable || value == nil)
            }
        }
    }

    func testDominantHrvColdStartStillRefusesEveryOptionalState() {
        for status in [BaselineStatus.calibrating, .stale] {
            let coldHrv = optionalBaselineFixture(50, 8, status)
            for optionalStatus in statuses {
                let base = optionalBaselineFixture(16, 2, optionalStatus)
                XCTAssertNil(RecoveryScorer.recovery(hrv: 55, rhr: 58, resp: 14,
                    hrvBaseline: coldHrv, rhrBaseline: rhr, respBaseline: base, sleepPerf: 0.85,
                    effortBaseline: optionalBaselineFixture(45, 10, optionalStatus), priorDayEffort: 60))
                XCTAssertTrue(RecoveryScorer.chargeDrivers(hrv: 55, rhr: 58, resp: 14,
                    hrvBaseline: coldHrv, rhrBaseline: rhr, respBaseline: base, sleepPerf: 0.85).isEmpty)
                let trace = RecoveryScorer.recoveryTrace(hrv: 55, rhr: 58, resp: 14,
                    hrvBaseline: coldHrv, rhrBaseline: rhr, respBaseline: base, sleepPerf: 0.85)
                XCTAssertNil(trace.score)
                XCTAssertEqual(trace.trace.count, 1)
                XCTAssertTrue(trace.trace.first?.contains("hrvBaselineNotUsable") ?? false)
            }
        }
    }
}
