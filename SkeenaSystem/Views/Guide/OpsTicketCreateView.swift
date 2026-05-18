//
//  OpsTicketCreateView.swift
//  SkeenaSystem
//
//  Form for creating a new operational ticket.
//  Pre-selects stage "todo". Loads owners for the assignment picker.
//

import SwiftUI

struct OpsTicketCreateView: View {
    var onCreated: ((OpsTicket) -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var taskName: String = ""
    @State private var descriptionText: String = ""
    @State private var selectedOwnerId: String = ""
    @State private var dueDate: Date = Date()
    @State private var hasDueDate: Bool = false
    @State private var notes: String = ""

    // Owners
    @State private var owners: [TicketOwner] = []

    // Save state
    @State private var isSaving = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Task name", text: $taskName)
                        .foregroundColor(.brandTextPrimary)

                    TextField("Description", text: $descriptionText, axis: .vertical)
                        .foregroundColor(.brandTextPrimary)
                        .lineLimit(3...6)
                } header: {
                    Text("Details").foregroundColor(.brandTextPrimary)
                }
                .listRowBackground(Color.brandStrokeSubtle)

                Section {
                    Picker("Owner", selection: $selectedOwnerId) {
                        Text("Unassigned").tag("")
                        ForEach(owners) { owner in
                            Text(owner.name).tag(owner.userId)
                        }
                    }
                    .foregroundColor(.brandTextPrimary)
                } header: {
                    Text("Assignment").foregroundColor(.brandTextPrimary)
                }
                .listRowBackground(Color.brandStrokeSubtle)

                Section {
                    Toggle("Has due date", isOn: $hasDueDate)
                        .foregroundColor(.brandTextPrimary)

                    if hasDueDate {
                        DatePicker("Due date", selection: $dueDate, displayedComponents: .date)
                            .foregroundColor(.brandTextPrimary)
                    }
                } header: {
                    Text("Schedule").foregroundColor(.brandTextPrimary)
                }
                .listRowBackground(Color.brandStrokeSubtle)

                Section {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .foregroundColor(.brandTextPrimary)
                        .lineLimit(3...8)
                } header: {
                    Text("Notes").foregroundColor(.brandTextPrimary)
                }
                .listRowBackground(Color.brandStrokeSubtle)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.brandBackground.ignoresSafeArea())
            .navigationTitle("New Ticket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.brandTextPrimary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView().tint(.white)
                        } else {
                            Text("Save")
                                .foregroundColor(taskName.isEmpty ? .brandTextSecondary : .brandAccent)
                        }
                    }
                    .disabled(taskName.isEmpty || isSaving)
                }
            }
            .alert("Error", isPresented: .constant(errorText != nil)) {
                Button("OK") { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
            .task { await loadOwners() }
        }
    }

    // MARK: - Load owners

    private func loadOwners() async {
        do {
            let fetched = try await OpsTicketsAPI.getOwners()
            await MainActor.run { owners = fetched }
        } catch {
            AppLogging.log("[OpsTicketCreate] Failed to load owners: \(error)", level: .warn, category: .auth)
        }
    }

    // MARK: - Save

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        let dueDateString = hasDueDate ? DateFormatting.ymd.string(from: dueDate) : nil

        do {
            let created = try await OpsTicketsAPI.createTicket(
                taskName: taskName,
                description: descriptionText.isEmpty ? nil : descriptionText,
                ownerUserId: selectedOwnerId.isEmpty ? nil : selectedOwnerId,
                dueDate: dueDateString,
                notes: notes.isEmpty ? nil : notes
            )
            await MainActor.run {
                onCreated?(created)
                dismiss()
            }
        } catch {
            await MainActor.run {
                errorText = error.localizedDescription
            }
        }
    }
}
