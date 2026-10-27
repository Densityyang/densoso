import XCTest
@testable import DensosoDomain

final class MealPortionPriorTests: XCTestCase {
    func testParsesOnlyExplicitUserUnitAndUnhedgedIngredientGrams() throws {
        let correction = MealPortionPriorCorrection.parse(
            userText: "米饭一碗180克",
            matching: ["米饭"]
        )

        XCTAssertEqual(correction?.unit, "bowl")
        XCTAssertEqual(correction?.unitCount, 1)
        XCTAssertEqual(correction?.gramsPerUnit, 180)
        XCTAssertEqual(
            MealPortionPriorCorrection.correction(from: try XCTUnwrap(correction).evidenceSnapshot),
            correction
        )
    }

    func testParserRejectsMissingOrUncertainRelationsAndMatchesIngredientClause() {
        XCTAssertNil(MealPortionPriorCorrection.parse(userText: "我吃了米饭", matching: ["米饭"]))
        XCTAssertNil(MealPortionPriorCorrection.parse(
            userText: "我吃了一碗米饭，大约180克",
            matching: ["米饭"]
        ))
        XCTAssertNil(MealPortionPriorCorrection.parse(
            userText: "米饭一碗180克以内",
            matching: ["米饭"]
        ))
        XCTAssertNil(MealPortionPriorCorrection.parse(
            userText: "米饭一碗180克以上",
            matching: ["米饭"]
        ))
        let riceCorrection = MealPortionPriorCorrection.parse(
            userText: "1碗米饭180g，2碗面条300g",
            matching: ["米饭"]
        )
        XCTAssertEqual(riceCorrection?.unit, "bowl")
        XCTAssertEqual(riceCorrection?.unitCount, 1)
        XCTAssertEqual(riceCorrection?.totalGrams, 180)
        XCTAssertNil(MealPortionPriorCorrection.parse(
            userText: "1碗，180g米饭",
            matching: ["米饭"]
        ))
        XCTAssertNil(MealPortionPriorCorrection.parse(
            userText: "米饭一份180克",
            matching: ["米饭"]
        ))
        XCTAssertNil(MealPortionPriorCorrection.parse(
            userText: "十一碗米饭180g",
            matching: ["米饭"]
        ))
    }

    func testParserPreservesChineseHalfUnitCounts() throws {
        let correction = try XCTUnwrap(MealPortionPriorCorrection.parse(
            userText: "米饭一碗半180克",
            matching: ["米饭"]
        ))
        XCTAssertEqual(correction.unitCount, 1.5)
        XCTAssertEqual(correction.gramsPerUnit, 120, accuracy: 0.001)
    }

    func testChineseAndEnglishUnitsShareCanonicalAliases() {
        XCTAssertEqual(MealPortionPriorCorrection.normalizeSupportedUnit("碗"), "bowl")
        XCTAssertEqual(MealPortionPriorCorrection.normalizeSupportedUnit("small bowl"), "smallbowl")
        XCTAssertEqual(MealPortionPriorCorrection.normalizeSupportedUnit("large bowls"), "largebowl")
        XCTAssertEqual(MealPortionPriorCorrection.normalizeSupportedUnit("大碗"), "largebowl")
        XCTAssertEqual(MealPortionPriorCorrection.normalizeSupportedUnit("鸡蛋"), "egg")
        XCTAssertEqual(MealPortionPriorCorrection.normalizeSupportedUnit("饺子"), "dumpling")
        XCTAssertEqual(
            MealPortionPriorCorrection.explicitHouseholdQuantity(in: "我吃了2个鸡蛋", matching: ["鸡蛋"])?.unit,
            "egg"
        )
        XCTAssertEqual(
            MealPortionPriorCorrection.explicitHouseholdQuantity(in: "我吃了2个鸡蛋", matching: ["鸡蛋"])?.count,
            2
        )
        XCTAssertEqual(MealPortionPriorCorrection.explicitHouseholdQuantity(in: "2 bowls")?.unit, "bowl")
    }

    func testMealQuantityResolverUsesMatchingPersonalPriorAndKeepsStaticFallback() throws {
        let resolver = MealQuantityEvidenceResolver()
        let evidence = MealQuantityEvidence(kind: .household, value: 1, unit: "碗")
        let personal = HouseholdPortionPrior(
            unit: "bowl",
            p10Grams: 120,
            p50Grams: 200,
            p90Grams: 280,
            version: "personal"
        )

        XCTAssertEqual(
            try resolver.resolve(evidence, personalPrior: personal),
            .household(prior: personal, count: 1)
        )
        XCTAssertEqual(
            try resolver.resolve(
                evidence,
                personalPrior: HouseholdPortionPrior(
                    unit: "cup",
                    p10Grams: 200,
                    p50Grams: 240,
                    p90Grams: 300,
                    version: "personal"
                )
            ),
            .household(
                prior: HouseholdPortionPrior(
                    unit: "bowl",
                    p10Grams: 100,
                    p50Grams: 160,
                    p90Grams: 240,
                    version: PortionEstimator.algorithmVersion
                ),
                count: 1
            )
        )
        XCTAssertThrowsError(try resolver.resolve(
            MealQuantityEvidence(kind: .count, value: 1, unit: "bowl"),
            personalPrior: personal
        ))
    }

    func testPersonalPriorUseSnapshotRetainsAppliedRangeAndVersion() throws {
        let prior = HouseholdPortionPrior(
            unit: "碗",
            p10Grams: 120,
            p50Grams: 200,
            p90Grams: 280,
            version: "personal-meal-portion-prior-v1"
        )
        let usage = try XCTUnwrap(MealPortionPriorUsage(prior: prior, count: 1.5))
        let snapshot = usage.evidenceSnapshot
        let decoded = try JSONDecoder().decode(MealPortionPriorUsage.self, from: Data(snapshot.summary.utf8))

        XCTAssertEqual(MealPortionPriorUsage.usage(from: snapshot), usage)
        XCTAssertEqual(snapshot.grade, .weak)
        XCTAssertEqual(snapshot.sourceID, MealPortionPriorUsage.evidenceSourceID)
        XCTAssertEqual(snapshot.sourceVersion, prior.version)
        XCTAssertEqual(snapshot.confidence, 0.4)
        XCTAssertEqual(decoded.unit, "bowl")
        XCTAssertEqual(decoded.count, 1.5)
        XCTAssertEqual(decoded.p10Grams, 120)
        XCTAssertEqual(decoded.p50Grams, 200)
        XCTAssertEqual(decoded.p90Grams, 280)
    }
}
