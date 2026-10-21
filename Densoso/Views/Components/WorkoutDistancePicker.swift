import SwiftUI

/// A compact distance control that keeps the plan's target easy to scan and edit.
struct WorkoutDistancePicker: View {
    @Binding var distanceMeters: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isMetersFieldFocused: Bool
    @State private var isEditing = false
    @State private var metersText = ""

    private var normalizedMeters: Int {
        guard distanceMeters.isFinite else { return 1_000 }
        return Int(min(max(distanceMeters, 100), 100_000).rounded())
    }

    private var distanceDescription: String {
        guard normalizedMeters >= 1_000 else { return "\(normalizedMeters) 米" }
        let kilometers = Double(normalizedMeters) / 1_000
        return "\(kilometers.formatted(.number.precision(.fractionLength(0...3)))) 公里"
    }

    private var metersBinding: Binding<String> {
        Binding(
            get: { metersText },
            set: { metersText = String($0.filter(\.isNumber).prefix(6)) }
        )
    }

    var body: some View {
        Group {
            if isEditing {
                editingControl
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            } else {
                summaryControl
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.78), value: isEditing)
        .onChange(of: isEditing) { _, editing in
            isMetersFieldFocused = editing
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityIdentifier("workout-distance-picker")
    }

    private var summaryControl: some View {
        HStack(spacing: 10) {
            Text("目标距离")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Button(action: beginEditing) {
                HStack(spacing: 6) {
                    Text(distanceDescription)
                        .font(.body.weight(.semibold).monospacedDigit())
                    Image(systemName: "pencil")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(OrbitPalette.gold)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑目标距离，当前 \(normalizedMeters) 米")
            .accessibilityIdentifier("workout-distance-edit")
        }
        .padding(.vertical, 4)
    }

    private var editingControl: some View {
        HStack(spacing: 6) {
            TextField("100", text: metersBinding)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 96)
                .focused($isMetersFieldFocused)
                .accessibilityLabel("目标距离米数")
                .accessibilityIdentifier("workout-distance-meters")

            Text("米")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(action: confirmEditing) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(OrbitPalette.gold)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("确认目标距离")
            .accessibilityIdentifier("workout-distance-confirm")

            Button(action: cancelEditing) {
                Image(systemName: "xmark.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("取消编辑目标距离")
            .accessibilityIdentifier("workout-distance-cancel")
        }
        .padding(.vertical, 4)
    }

    private func beginEditing() {
        metersText = String(normalizedMeters)
        isEditing = true
    }

    private func confirmEditing() {
        let parsedMeters = Int(metersText) ?? normalizedMeters
        distanceMeters = Double(min(max(parsedMeters, 100), 100_000))
        finishEditing()
    }

    private func cancelEditing() {
        finishEditing()
    }

    private func finishEditing() {
        isEditing = false
    }
}
