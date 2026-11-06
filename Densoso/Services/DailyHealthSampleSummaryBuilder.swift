import DensosoDomain
import Foundation

enum DailyHealthSampleSummaryBuilder {
    /// Each component's Hungarian solve is O(rows² × (workouts + samples));
    /// neither side may exceed this limit.
    private static let maximumMatchingSide = 128

    static func build(
        samples: [HealthSampleSnapshot],
        dayStart: Date,
        sleepSamples: [HealthSampleSnapshot]? = nil,
        workouts: [WorkoutRecord]
    ) -> DailyHealthSampleSummary {
        let validWorkouts = workouts
            .filter { $0.durationMinutes > 0 }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let validEffortSamples = HealthSampleSnapshot.deduplicated(samples)
            .filter { $0.metric == .workoutEffort && $0.value.map { (1...10).contains($0) } == true }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let assignedSamplesByWorkout = maximumCardinalityThenOverlapMatches(
            samples: validEffortSamples,
            workouts: validWorkouts
        )

        let efforts = validWorkouts.compactMap { workout -> WorkoutEffortDailyAggregate? in
            guard let score = assignedSamplesByWorkout[workout.id]?.value else { return nil }
            return WorkoutEffortDailyAggregate(workoutRecordID: workout.id, score: score)
        }
        return DailyHealthSampleSummary(
            samples: samples,
            dayStart: dayStart,
            sleepSamples: sleepSamples,
            workoutEffort: efforts
        )
    }

    private static func overlap(_ sample: HealthSampleSnapshot, start: Date, end: Date) -> TimeInterval {
        max(min(sample.endDate, end).timeIntervalSince(max(sample.startDate, start)), 0)
    }

    /// Finds a one-to-one assignment with lexicographic objectives:
    /// first maximize matched positive-overlap pairs, then total overlap.
    /// Rows and columns are UUID-sorted, so exact objective ties are stable.
    private static func maximumCardinalityThenOverlapMatches(
        samples: [HealthSampleSnapshot],
        workouts: [WorkoutRecord]
    ) -> [UUID: HealthSampleSnapshot] {
        let rowCount = samples.count
        let workoutCount = workouts.count
        guard rowCount > 0, workoutCount > 0 else { return [:] }

        var components = DisjointSet(count: rowCount + workoutCount)
        for row in 0..<rowCount {
            for column in 0..<workoutCount {
                guard positiveOverlap(samples[row], workouts[column]) != nil else { continue }
                components.union(row, rowCount + column)
            }
        }

        var sampleRowsByComponent: [Int: [Int]] = [:]
        var workoutColumnsByComponent: [Int: [Int]] = [:]
        for row in 0..<rowCount {
            sampleRowsByComponent[components.find(row), default: []].append(row)
        }
        var result: [UUID: HealthSampleSnapshot] = [:]
        for column in 0..<workoutCount {
            workoutColumnsByComponent[components.find(rowCount + column), default: []].append(column)
        }

        let componentRoots = Set(sampleRowsByComponent.keys)
            .intersection(workoutColumnsByComponent.keys)
            .sorted()
        for root in componentRoots {
            guard let rows = sampleRowsByComponent[root],
                  let columns = workoutColumnsByComponent[root],
                  rows.count <= maximumMatchingSide,
                  columns.count <= maximumMatchingSide else {
                // This connected component is too large to match reliably;
                // independent components still get their own bounded solve.
                continue
            }

            // One dummy column per sample permits any sample to remain unmatched.
            // Missing/zero-overlap real edges have zero cost like dummies; only
            // strictly positive real edges are extracted as associations.
            let componentRowCount = rows.count
            let componentWorkoutCount = columns.count
            let componentColumnCount = componentWorkoutCount + componentRowCount
            var costs = Array(
                repeating: Array(repeating: MatchingCost.zero, count: componentColumnCount),
                count: componentRowCount
            )
            var weights = Array(
                repeating: Array<TimeInterval?>(repeating: nil, count: componentWorkoutCount),
                count: componentRowCount
            )
            for localRow in 0..<componentRowCount {
                for localColumn in 0..<componentWorkoutCount {
                    guard let weight = positiveOverlap(samples[rows[localRow]], workouts[columns[localColumn]]) else {
                        continue
                    }
                    weights[localRow][localColumn] = weight
                    costs[localRow][localColumn] = MatchingCost(matchedPairs: -1, negativeOverlap: -weight)
                }
            }

            let assignment = minimumCostAssignment(costs, realColumnCount: componentWorkoutCount)
            for (localRow, localColumn) in assignment
            where localColumn < componentWorkoutCount && weights[localRow][localColumn] != nil {
                result[workouts[columns[localColumn]].id] = samples[rows[localRow]]
            }
        }
        return result
    }

    private static func positiveOverlap(
        _ sample: HealthSampleSnapshot,
        _ workout: WorkoutRecord
    ) -> TimeInterval? {
        let duration = Double(workout.durationMinutes) * 60
        guard duration.isFinite, duration > 0 else { return nil }
        let value = overlap(
            sample,
            start: workout.date,
            end: workout.date.addingTimeInterval(duration)
        )
        return value.isFinite && value > 0 ? value : nil
    }

    /// Hungarian assignment with lexicographic additive costs. A valid edge
    /// costs (-1 match, -overlap), so no amount of overlap can outweigh an
    /// additional match. Zero-cost dummy columns represent unmatched samples.
    private static func minimumCostAssignment(
        _ costs: [[MatchingCost]],
        realColumnCount: Int
    ) -> [Int: Int] {
        let rowCount = costs.count
        guard rowCount > 0 else { return [:] }
        let columnCount = costs[0].count
        guard columnCount >= rowCount else { return [:] }

        var rowPotential = Array(repeating: MatchingCost.zero, count: rowCount + 1)
        var columnPotential = Array(repeating: MatchingCost.zero, count: columnCount + 1)
        var rowByColumn = Array(repeating: 0, count: columnCount + 1)
        var previousColumn = Array(repeating: 0, count: columnCount + 1)

        for row in 1...rowCount {
            rowByColumn[0] = row
            var currentColumn = 0
            var minimumReducedCost = Array<MatchingCost?>(repeating: nil, count: columnCount + 1)
            var usedColumns = Array(repeating: false, count: columnCount + 1)

            repeat {
                usedColumns[currentColumn] = true
                let currentRow = rowByColumn[currentColumn]
                var delta: MatchingCost?
                var nextColumn = 0

                for column in 1...columnCount where !usedColumns[column] {
                    let reducedCost = costs[currentRow - 1][column - 1]
                        - rowPotential[currentRow]
                        - columnPotential[column]
                    if minimumReducedCost[column].map({ reducedCost < $0 }) ?? true {
                        minimumReducedCost[column] = reducedCost
                        previousColumn[column] = currentColumn
                    }
                    if let candidate = minimumReducedCost[column] {
                        let isLowerCost = delta.map { candidate < $0 } ?? true
                        let isStableTie = delta == candidate
                            && prefersStableColumn(
                                column,
                                over: nextColumn,
                                realColumnCount: realColumnCount,
                                rowByColumn: rowByColumn
                            )
                        if isLowerCost || isStableTie {
                            delta = candidate
                            nextColumn = column
                        }
                    }
                }

                guard let delta else { return [:] }
                for column in 0...columnCount {
                    if usedColumns[column] {
                        rowPotential[rowByColumn[column]] = rowPotential[rowByColumn[column]] + delta
                        columnPotential[column] = columnPotential[column] - delta
                    } else if let reducedCost = minimumReducedCost[column] {
                        minimumReducedCost[column] = reducedCost - delta
                    }
                }
                currentColumn = nextColumn
            } while rowByColumn[currentColumn] != 0

            repeat {
                let predecessor = previousColumn[currentColumn]
                rowByColumn[currentColumn] = rowByColumn[predecessor]
                currentColumn = predecessor
            } while currentColumn != 0
        }

        var result: [Int: Int] = [:]
        for column in 1...columnCount {
            let row = rowByColumn[column]
            guard row > 0 else { continue }
            result[row - 1] = column - 1
        }
        return result
    }

    private static func prefersStableColumn(
        _ candidate: Int,
        over current: Int,
        realColumnCount: Int,
        rowByColumn: [Int]
    ) -> Bool {
        guard current > 0 else { return true }
        let candidateIsReal = candidate <= realColumnCount
        let currentIsReal = current <= realColumnCount
        if candidateIsReal != currentIsReal { return candidateIsReal }
        let candidateIsFree = rowByColumn[candidate] == 0
        let currentIsFree = rowByColumn[current] == 0
        if candidateIsFree != currentIsFree { return candidateIsFree }
        return candidate < current
    }

    private struct MatchingCost: Comparable {
        let matchedPairs: Int
        let negativeOverlap: TimeInterval

        static let zero = MatchingCost(matchedPairs: 0, negativeOverlap: 0)

        static func < (lhs: MatchingCost, rhs: MatchingCost) -> Bool {
            if lhs.matchedPairs != rhs.matchedPairs {
                return lhs.matchedPairs < rhs.matchedPairs
            }
            return lhs.negativeOverlap < rhs.negativeOverlap
        }

        static func + (lhs: MatchingCost, rhs: MatchingCost) -> MatchingCost {
            MatchingCost(
                matchedPairs: lhs.matchedPairs + rhs.matchedPairs,
                negativeOverlap: lhs.negativeOverlap + rhs.negativeOverlap
            )
        }

        static func - (lhs: MatchingCost, rhs: MatchingCost) -> MatchingCost {
            MatchingCost(
                matchedPairs: lhs.matchedPairs - rhs.matchedPairs,
                negativeOverlap: lhs.negativeOverlap - rhs.negativeOverlap
            )
        }
    }

    private struct DisjointSet {
        private var parents: [Int]
        private var ranks: [Int]

        init(count: Int) {
            parents = Array(0..<count)
            ranks = Array(repeating: 0, count: count)
        }

        mutating func find(_ value: Int) -> Int {
            if parents[value] != value {
                parents[value] = find(parents[value])
            }
            return parents[value]
        }

        mutating func union(_ lhs: Int, _ rhs: Int) {
            let leftRoot = find(lhs)
            let rightRoot = find(rhs)
            guard leftRoot != rightRoot else { return }
            if ranks[leftRoot] < ranks[rightRoot] {
                parents[leftRoot] = rightRoot
            } else if ranks[leftRoot] > ranks[rightRoot] {
                parents[rightRoot] = leftRoot
            } else {
                parents[rightRoot] = leftRoot
                ranks[leftRoot] += 1
            }
        }
    }
}
