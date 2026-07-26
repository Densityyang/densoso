import Foundation

/// A synthetic, privacy-safe sample for evaluating a speech-to-text path.
///
/// The transcript and slots are supplied by a benchmark harness; this type does
/// not retain microphone audio or user health records.
struct SpeechBenchmarkSample: Sendable, Equatable {
    let id: String
    let referenceTranscript: String
    let hypothesisTranscript: String
    let expectedSlots: [String: String]
    let observedSlots: [String: String]
    let endToEndLatencyMilliseconds: Int?
}

struct SpeechBenchmarkReport: Sendable, Equatable {
    let sampleCount: Int
    let transcriptErrorRate: Double
    let slotAccuracy: Double
    let medianLatencyMilliseconds: Int?
    let p95LatencyMilliseconds: Int?
}

/// Computes deterministic speech quality metrics for Chinese and Latin text.
/// Chinese Han characters are evaluated as individual tokens; contiguous Latin
/// letters and digits are kept as one token. This avoids requiring a third-party
/// segmenter merely to make the benchmark reproducible in CI.
struct SpeechBenchmarkEvaluator: Sendable {
    func evaluate(_ samples: [SpeechBenchmarkSample]) -> SpeechBenchmarkReport {
        let transcriptTotals = samples.reduce(into: (distance: 0, referenceTokens: 0)) { totals, sample in
            let reference = tokens(in: sample.referenceTranscript)
            let hypothesis = tokens(in: sample.hypothesisTranscript)
            totals.distance += editDistance(reference, hypothesis)
            totals.referenceTokens += reference.count
        }

        let expectedSlotCount = samples.reduce(0) { $0 + $1.expectedSlots.count }
        let correctSlotCount = samples.reduce(0) { total, sample in
            total + sample.expectedSlots.reduce(0) { matches, expected in
                let observed = sample.observedSlots[expected.key]
                return matches + (normalizeSlot(observed) == normalizeSlot(expected.value) ? 1 : 0)
            }
        }

        let latencies = samples.compactMap(\.endToEndLatencyMilliseconds).sorted()
        return SpeechBenchmarkReport(
            sampleCount: samples.count,
            transcriptErrorRate: rate(numerator: transcriptTotals.distance, denominator: transcriptTotals.referenceTokens),
            slotAccuracy: rate(numerator: correctSlotCount, denominator: expectedSlotCount),
            medianLatencyMilliseconds: percentile(0.5, in: latencies),
            p95LatencyMilliseconds: percentile(0.95, in: latencies)
        )
    }

    private func rate(numerator: Int, denominator: Int) -> Double {
        guard denominator > 0 else { return numerator == 0 ? 0 : 1 }
        return Double(numerator) / Double(denominator)
    }

    private func percentile(_ percentile: Double, in sortedValues: [Int]) -> Int? {
        guard !sortedValues.isEmpty else { return nil }
        let index = max(0, Int(ceil(percentile * Double(sortedValues.count))) - 1)
        return sortedValues[index]
    }

    private func normalizeSlot(_ value: String?) -> String? {
        value?
            .precomposedStringWithCompatibilityMapping
            .lowercased()
            .unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0) }
            .map(String.init)
            .joined()
    }

    private func tokens(in text: String) -> [String] {
        let normalized = text.precomposedStringWithCompatibilityMapping.lowercased()
        var result: [String] = []
        var latinToken = ""

        func flushLatinToken() {
            guard !latinToken.isEmpty else { return }
            result.append(latinToken)
            latinToken = ""
        }

        for scalar in normalized.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.punctuationCharacters.contains(scalar) {
                flushLatinToken()
            } else if isHan(scalar) {
                flushLatinToken()
                result.append(String(scalar))
            } else {
                latinToken.unicodeScalars.append(scalar)
            }
        }
        flushLatinToken()
        return result
    }

    private func isHan(_ scalar: UnicodeScalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value)
            || (0x3400...0x4DBF).contains(scalar.value)
            || (0xF900...0xFAFF).contains(scalar.value)
    }

    private func editDistance(_ left: [String], _ right: [String]) -> Int {
        var previous = Array(0...right.count)
        for (leftIndex, leftToken) in left.enumerated() {
            var current = [leftIndex + 1]
            for (rightIndex, rightToken) in right.enumerated() {
                let substitution = previous[rightIndex] + (leftToken == rightToken ? 0 : 1)
                let insertion = current[rightIndex] + 1
                let deletion = previous[rightIndex + 1] + 1
                current.append(min(substitution, insertion, deletion))
            }
            previous = current
        }
        return previous[right.count]
    }
}
