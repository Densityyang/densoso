import DensosoDomain
import XCTest
@testable import Densoso

final class Gate05EvaluationTests: XCTestCase {
    func testFrozenFoodResolutionSetMeetsGateThresholds() throws {
        let catalog = try JSONDecoder().decode(
            [FoodCatalogEntry].self,
            from: Gate03FixtureLoader.data("food-catalog")
        )
        let fixture = try JSONDecoder().decode(
            ResolutionFixture.self,
            from: Gate03FixtureLoader.data("food-resolution")
        )
        let resolver = FoodResolver(catalog: catalog)
        var total = 0
        var top1Hits = 0
        var top3Hits = 0
        var aliasTotal = 0
        var aliasHits = 0
        var rawCookedTotal = 0
        var rawCookedHits = 0

        for group in fixture.groups {
            for query in group.queries {
                let result = resolver.resolve(
                    FoodResolutionQuery(
                        label: query,
                        preparation: group.preparation,
                        categoryHint: group.categoryHint,
                        sourceQuality: 1
                    )
                )
                total += 1
                let top1 = result.candidates.first?.id == group.expectedFoodID
                let top3 = result.candidates.contains { $0.id == group.expectedFoodID }
                if top1 { top1Hits += 1 }
                if top3 { top3Hits += 1 }
                if group.subset == "alias" {
                    aliasTotal += 1
                    if top1 { aliasHits += 1 }
                }
                if group.subset == "rawCooked" {
                    rawCookedTotal += 1
                    if top1 { rawCookedHits += 1 }
                }
            }
        }

        XCTAssertEqual(total, 100)
        XCTAssertEqual(Double(aliasHits) / Double(aliasTotal), 1, accuracy: 0.0001)
        XCTAssertEqual(Double(rawCookedHits) / Double(rawCookedTotal), 1, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(Double(top1Hits) / Double(total), 0.80)
        XCTAssertGreaterThanOrEqual(Double(top3Hits) / Double(total), 0.90)
        attachReport(
            name: "gate05-food-resolution.json",
            payload: FoodResolutionReport(
                caseCount: total,
                aliasCaseCount: aliasTotal,
                aliasAccuracy: Double(aliasHits) / Double(aliasTotal),
                rawCookedCaseCount: rawCookedTotal,
                rawCookedAccuracy: Double(rawCookedHits) / Double(rawCookedTotal),
                top1Accuracy: Double(top1Hits) / Double(total),
                top3Accuracy: Double(top3Hits) / Double(total)
            )
        )
    }

    func testFrozenPortionReferencesMeetCoverageGate() throws {
        let fixture = try JSONDecoder().decode(
            PortionFixture.self,
            from: Gate03FixtureLoader.data("portion-reference")
        )
        let estimator = PortionEstimator()
        var total = 0
        var covered = 0

        for group in fixture.groups {
            for sample in group.samples {
                let evidence: PortionEvidence
                switch group.kind {
                case "approximateGrams":
                    evidence = .approximateGrams(grams: sample.likely!)
                case "photoNoScale":
                    evidence = .photo(
                        likelyGrams: sample.likely!, hasScale: false,
                        isMixedDish: false, isOccluded: false, unknownContainer: false
                    )
                case "photoMixedOccluded":
                    evidence = .photo(
                        likelyGrams: sample.likely!, hasScale: false,
                        isMixedDish: true, isOccluded: true, unknownContainer: true
                    )
                case "packageServing":
                    evidence = .packageServing(
                        gramsPerServing: sample.serving!, count: sample.count!
                    )
                case "householdPrior":
                    evidence = .household(prior: group.prior!, count: sample.count!)
                default:
                    return XCTFail("Unknown fixture kind \(group.kind)")
                }
                let estimate = try estimator.estimate(evidence: [evidence], food: nil)
                total += 1
                if estimate.lowGrams <= sample.reference,
                   sample.reference <= estimate.highGrams {
                    covered += 1
                }
            }
        }

        let coverage = Double(covered) / Double(total)
        let outsideRate = Double(total - covered) / Double(total)
        XCTAssertEqual(total, 50)
        XCTAssertGreaterThanOrEqual(coverage, 0.80)
        XCTAssertLessThanOrEqual(outsideRate, 0.20)
        attachReport(
            name: "gate05-portion-reference.json",
            payload: PortionCoverageReport(
                referenceCount: total,
                coveredCount: covered,
                coverage: coverage,
                outsideRate: outsideRate,
                sourceBoundary: "synthetic calibration fixture; not field measurement"
            )
        )
    }

    private func attachReport<Payload: Encodable>(name: String, payload: Payload) {
        guard let data = try? JSONEncoder().encode(payload) else {
            XCTFail("Could not encode evaluation report \(name)")
            return
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct FoodResolutionReport: Encodable {
    let caseCount: Int
    let aliasCaseCount: Int
    let aliasAccuracy: Double
    let rawCookedCaseCount: Int
    let rawCookedAccuracy: Double
    let top1Accuracy: Double
    let top3Accuracy: Double
}

private struct PortionCoverageReport: Encodable {
    let referenceCount: Int
    let coveredCount: Int
    let coverage: Double
    let outsideRate: Double
    let sourceBoundary: String
}

private struct ResolutionFixture: Decodable {
    struct Group: Decodable {
        let expectedFoodID: String
        let preparation: FoodPreparation
        let categoryHint: String
        let subset: String
        let queries: [String]
    }
    let version: String
    let source: String
    let groups: [Group]
}

private struct PortionFixture: Decodable {
    struct Group: Decodable {
        struct Sample: Decodable {
            let id: String
            let likely: Double?
            let serving: Double?
            let count: Double?
            let reference: Double
        }
        let kind: String
        let prior: HouseholdPortionPrior?
        let samples: [Sample]
    }
    let version: String
    let source: String
    let groups: [Group]
}
