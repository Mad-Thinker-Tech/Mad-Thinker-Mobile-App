//
//  OpsTicketsListView.swift
//  SkeenaSystem
//
//  Displays operational tickets for the active community, grouped by stage.
//  Supports pull-to-refresh, navigation to detail/edit, and creating new tickets.
//

import SwiftUI

struct OpsTicketsListView: View {
    @State private var tickets: [OpsTicket] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var showCreate = false

    var body: some View {
        ZStack {
            Color.brandBackground.ignoresSafeArea()

            if isLoading && tickets.isEmpty {
                ProgressView()
                    .tint(.white)
            } else if tickets.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "ticket")
                        .font(.brandLargeTitle)
                        .foregroundColor(.brandTextSecondary)
                    Text("No tickets yet")
                        .font(.brandHeadline)
                        .foregroundColor(.brandTextPrimary)
                    Text("Tap + to create your first ticket.")
                        .font(.brandSubheadline)
                        .foregroundColor(.brandTextSecondary)
                }
            } else {
                ticketList
            }
        }
        .navigationTitle("Tickets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showCreate = true } label: {
                    Image(systemName: "plus")
                        .foregroundColor(.brandTextPrimary)
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            OpsTicketCreateView { _ in
                Task { await fetchTickets() }
            }
            .preferredColorScheme(.dark)
        }
        .alert("Error", isPresented: .constant(errorText != nil)) {
            Button("OK") { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .task { await fetchTickets() }
        .refreshable { await fetchTickets() }
    }

    // MARK: - Ticket list grouped by stage

    private var ticketList: some View {
        List {
            ForEach(stageOrder, id: \.self) { stage in
                let stageTickets = tickets.filter { $0.stage == stage }
                if !stageTickets.isEmpty {
                    Section {
                        ForEach(stageTickets) { ticket in
                            NavigationLink {
                                OpsTicketDetailView(ticket: ticket) {
                                    Task { await fetchTickets() }
                                }
                            } label: {
                                ticketRow(ticket)
                            }
                            .listRowBackground(Color.brandBackground)
                        }
                    } header: {
                        stageBadge(stage)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private let stageOrder = ["todo", "doing", "done"]

    private func stageLabel(_ stage: String) -> String {
        switch stage {
        case "todo": return "To Do"
        case "doing": return "In Progress"
        case "done": return "Done"
        default: return stage.capitalized
        }
    }

    // MARK: - Row

    private func ticketRow(_ ticket: OpsTicket) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ticket.taskName)
                .font(.brandSubheadline.weight(.semibold))
                .foregroundColor(.brandTextPrimary)

            HStack(spacing: 12) {
                if let owner = ticket.ownerName, !owner.isEmpty {
                    Label(owner, systemImage: "person")
                        .font(.brandCaption)
                        .foregroundColor(.brandTextSecondary)
                }
                if let due = ticket.dueDate, !due.isEmpty {
                    Label(due, systemImage: "calendar")
                        .font(.brandCaption)
                        .foregroundColor(.brandTextSecondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func stageBadge(_ stage: String) -> some View {
        Text(stageLabel(stage))
            .font(.brandCaption2.weight(.medium))
            .foregroundColor(.brandTextOnLight)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(stageColor(stage), in: Capsule())
    }

    private func stageColor(_ stage: String) -> Color {
        switch stage {
        case "todo": return .gray
        case "doing": return .orange
        case "done": return .brandSuccess
        default: return .gray
        }
    }

    // MARK: - Fetch

    private func fetchTickets() async {
        do {
            let fetched = try await OpsTicketsAPI.listTickets()
            await MainActor.run {
                tickets = fetched
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorText = error.localizedDescription
                isLoading = false
            }
        }
    }
}
