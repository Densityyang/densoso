import SwiftUI

/// A compact duration control that keeps the plan's time goal easy to scan and edit.
struct WorkoutDurationPicker: View {
    @Binding var durationMinutes: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedField: Field?
    @State private var isEditing = false
    @State private var hoursText = ""
    @State private var minutesText = ""

    private enum Field: Hashable {
        case hours
        case minutes
    }

    private var normalizedDuration: Int {
        min(max(durationMinutes, 1), 720)
    }

    private var hours: Int { normalizedDuration / 60 }
    private var minutes: Int { normalizedDuration % 60 }

    private var durationDescription: String {
        if hours == 0 { return "\(minutes) 分钟" }
        if minutes == 0 { return "\(hours) 小时" }
        return "\(hours) 小时 \(minutes) 分钟"
    }

    private var hoursBinding: Binding<String> {
        Binding(
            get: { hoursText },
            set: { hoursText = String($0.filter(\.isNumber).prefix(2)) }
        )
    }

    private var minutesBinding: Binding<String> {
        Binding(
            get: { minutesText },
            set: { minutesText = String($0.filter(\.isNumber).prefix(2)) }
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
            focusedField = editing ? .hours : nil
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityIdentifier("workout-duration-picker")
    }

    private var summaryControl: some View {
        HStack(spacing: 10) {
            Text("训练时长")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Button(action: beginEditing) {
                HStack(spacing: 6) {
                    Text(durationDescription)
                        .font(.body.weight(.semibold).monospacedDigit())
                    Image(systemName: "pencil")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(OrbitPalette.gold)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑训练时长，当前 \(durationDescription)")
            .accessibilityIdentifier("workout-duration-edit")
        }
        .padding(.vertical, 4)
    }

    private var editingControl: some View {
        HStack(spacing: 6) {
            TextField("0", text: hoursBinding)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 42)
                .focused($focusedField, equals: .hours)
                .accessibilityLabel("训练时长小时")
                .accessibilityIdentifier("workout-duration-hours")

            Text("小时")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("0", text: minutesBinding)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 42)
                .focused($focusedField, equals: .minutes)
                .accessibilityLabel("训练时长分钟")
                .accessibilityIdentifier("workout-duration-minutes")

            Text("分钟")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(action: confirmEditing) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(OrbitPalette.gold)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("确认训练时长")
            .accessibilityIdentifier("workout-duration-confirm")

            Button(action: cancelEditing) {
                Image(systemName: "xmark.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("取消编辑训练时长")
        }
        .padding(.vertical, 4)
    }

    private func beginEditing() {
        let current = normalizedDuration
        hoursText = String(current / 60)
        minutesText = String(current % 60)
        isEditing = true
    }

    private func confirmEditing() {
        let hours = min(max(Int(hoursText) ?? 0, 0), 12)
        let minutes = min(max(Int(minutesText) ?? 0, 0), 59)
        durationMinutes = min(max(hours * 60 + minutes, 1), 720)
        finishEditing()
    }

    private func cancelEditing() {
        finishEditing()
    }

    private func finishEditing() {
        isEditing = false
    }
}
