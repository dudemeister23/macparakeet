import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

/// Sheet for managing enrolled speaker voice profiles: list, enroll (record a
/// short mic sample), rename, and delete. Presented from the Meetings settings
/// tab. Recognized names then appear in meeting transcripts in place of the
/// anonymous "Others 1/2" labels.
struct SpeakerProfilesView: View {
    @Bindable var viewModel: SpeakerProfilesViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            enrolledList

            Divider()

            addSpeakerSection

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .parakeetAction(.primaryProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .task { viewModel.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Known speakers")
                .font(.headline)
            Text("Enroll people you meet with so their names appear in meeting transcripts instead of \"Others 1/2\". Voice samples stay on this Mac and are matched only on-device. Requires Speaker detection to be on.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var enrolledList: some View {
        if viewModel.profiles.isEmpty {
            Text("No speakers enrolled yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(viewModel.profiles) { profile in
                        profileRow(profile)
                        if profile.id != viewModel.profiles.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
        }
    }

    @ViewBuilder
    private func profileRow(_ profile: SpeakerProfile) -> some View {
        HStack(spacing: 8) {
            if viewModel.editingProfileID == profile.id {
                TextField("Name", text: $viewModel.editName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { viewModel.commitRename() }
                Button("Save") { viewModel.commitRename() }
                    .parakeetAction(.secondary)
                Button("Cancel") { viewModel.cancelRename() }
                    .parakeetAction(.subtle)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.name)
                        .font(.body)
                    Text(String(format: "%.0fs enrolled", profile.enrolledSeconds))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { viewModel.beginRename(profile) } label: {
                    Image(systemName: "pencil")
                }
                .parakeetAction(.subtle)
                .help("Rename")
                Button(role: .destructive) { viewModel.delete(profile) } label: {
                    Image(systemName: "trash")
                }
                .parakeetAction(.subtle)
                .help("Delete")
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var addSpeakerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a speaker")
                .font(.subheadline.weight(.semibold))

            switch viewModel.phase {
            case .idle:
                HStack(spacing: 8) {
                    TextField("Name (e.g. Sara)", text: $viewModel.enrollmentName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { viewModel.startEnrollment() }
                    Button { viewModel.startEnrollment() } label: {
                        Label("Record", systemImage: "mic.fill")
                    }
                    .parakeetAction(.primary)
                    .disabled(!viewModel.canStartEnrollment)
                }
                Text("Records about \(Int(viewModel.targetSeconds))s of this person speaking naturally. The clearer and longer the sample, the better recognition works.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            case .recording:
                recordingControls

            case .processing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Saving voice profile…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .foregroundStyle(.red)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                Text(String(format: "Recording %@ — %.0fs", viewModel.trimmedEnrollmentName, viewModel.recordedSeconds))
                    .font(.subheadline)
                Spacer()
            }
            ProgressView(
                value: min(viewModel.recordedSeconds, viewModel.targetSeconds),
                total: viewModel.targetSeconds
            )
            HStack(spacing: 8) {
                Button("Save") { Task { await viewModel.saveEnrollment() } }
                    .parakeetAction(.primaryProminent)
                    .disabled(!viewModel.canSaveEnrollment)
                Button("Cancel") { Task { await viewModel.cancelEnrollment() } }
                    .parakeetAction(.secondary)
                Spacer()
                if !viewModel.canSaveEnrollment {
                    Text("Record at least \(Int(viewModel.minSeconds))s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
