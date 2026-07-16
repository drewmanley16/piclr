import SwiftUI
import MapKit

/// Court picker for invites. Reuses `LocationSearchModel`'s MapKit search
/// (same "pickleball court" query as session logging) but, unlike
/// `LocationPickerSheet`, only accepts results that carry a coordinate — an
/// invite needs a real lat/lng to dedupe against `AppStore.findOrCreateCourt`.
private struct CourtPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = LocationSearchModel()
    let onSelect: (LocationSearchModel.Place) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Nearby courts") {
                    if model.isSearching && model.results.isEmpty {
                        HStack { ProgressView().tint(Theme.accent); Text("Finding courts…").foregroundStyle(Theme.textSecondary) }
                    } else if model.results.isEmpty {
                        Text(model.permissionDenied
                             ? "Location is off — search below."
                             : "No courts found nearby.")
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        ForEach(model.results) { place in
                            Button {
                                onSelect(place)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "mappin.circle.fill")
                                        .foregroundStyle(Theme.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(place.name)
                                            .foregroundStyle(Theme.textPrimary)
                                        if !place.subtitle.isEmpty {
                                            Text(place.subtitle)
                                                .font(.caption)
                                                .foregroundStyle(Theme.textSecondary)
                                        }
                                    }
                                    Spacer()
                                    if let d = place.distanceLabel {
                                        Text(d).font(.caption).foregroundStyle(Theme.textTertiary)
                                    }
                                }
                            }
                            .disabled(place.coordinate == nil)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .searchable(text: $model.query, prompt: "Search courts or places")
            .onChange(of: model.query) { _, _ in model.queryChanged() }
            .navigationTitle("Invite at")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { model.start() }
        }
    }
}

/// Composer for a new invite: pick a court, a date/time, mutual-follower
/// friends to tag, and an optional note. Submitting creates the invite and
/// tags every selected friend as a recipient.
struct InviteComposerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    @State private var selectedPlace: LocationSearchModel.Place?
    @State private var showCourtPicker = false
    @State private var scheduledAt = Date().addingTimeInterval(3600).roundedUpToNextQuarterHour()
    @State private var selectedFriendIds: Set<UUID> = []
    @State private var note = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Court") {
                    Button {
                        showCourtPicker = true
                    } label: {
                        HStack {
                            Image(systemName: "mappin.circle.fill").foregroundStyle(Theme.accent)
                            Text(selectedPlace?.name ?? "Choose a court")
                                .foregroundStyle(selectedPlace == nil ? Theme.textSecondary : Theme.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }

                Section("When") {
                    DatePicker("Date & time", selection: $scheduledAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                }

                Section("Invite friends") {
                    if store.mutualFriends.isEmpty {
                        Text("You need mutual followers to invite. Follow each other first.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        ForEach(store.mutualFriends) { friend in
                            Button {
                                if selectedFriendIds.contains(friend.userId) {
                                    selectedFriendIds.remove(friend.userId)
                                } else {
                                    selectedFriendIds.insert(friend.userId)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    ProfileAvatar(profile: friend.profile, size: 32)
                                    Text(friend.profile?.displayName ?? "Player")
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    if selectedFriendIds.contains(friend.userId) {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                                    } else {
                                        Image(systemName: "circle").foregroundStyle(Theme.textTertiary)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Note (optional)") {
                    TextField("Need a 4th, casual 3.0–3.5…", text: $note, axis: .vertical)
                        .lineLimit(3)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("New Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { Task { await submit() } }
                        .disabled(selectedPlace?.coordinate == nil || selectedFriendIds.isEmpty || isSubmitting)
                }
            }
            .sheet(isPresented: $showCourtPicker) {
                CourtPickerSheet { place in selectedPlace = place }
            }
            .task { await store.loadFollowLists() }
        }
    }

    private func submit() async {
        guard let place = selectedPlace, let coordinate = place.coordinate else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        guard let court = await store.findOrCreateCourt(
            name: place.name,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        ) else { return }
        let ok = await store.createInvite(
            courtId: court.id,
            scheduledAt: scheduledAt,
            note: note,
            recipientIds: Array(selectedFriendIds)
        )
        if ok { dismiss() }
    }
}

private extension Date {
    func roundedUpToNextQuarterHour() -> Date {
        let interval: TimeInterval = 15 * 60
        return Date(timeIntervalSinceReferenceDate: (timeIntervalSinceReferenceDate / interval).rounded(.up) * interval)
    }
}

struct InviteCard: View {
    @EnvironmentObject private var store: AppStore
    let invite: SessionInvite
    var showsInlineCancel = true

    @State private var showCancelConfirmation = false
    @State private var isCancelling = false

    private var myId: UUID? { store.currentProfile?.id }
    private var isHost: Bool { invite.hostId == myId }
    private var myResponse: RSVPStatus? { myId.flatMap { invite.myResponse(userId: $0) } }

    var body: some View {
        NavigationLink {
            InviteDetailView(inviteId: invite.id, preloaded: invite)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProfileAvatar(participant: invite.host, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(invite.court?.name ?? "Court")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(isHost ? "You" : invite.host?.displayName ?? "Someone") · \(invite.scheduledAtDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if isHost && showsInlineCancel && !invite.isCancelled && !invite.isPast {
                        Button {
                            showCancelConfirmation = true
                        } label: {
                            if isCancelling {
                                ProgressView().controlSize(.small).tint(Theme.loss)
                            } else {
                                Image(systemName: "xmark.circle")
                                    .font(.subheadline)
                            }
                        }
                        .foregroundStyle(Theme.loss)
                        .disabled(isCancelling)
                    }
                }

                if let note = invite.note, !note.isEmpty {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }

                HStack {
                    if invite.isCancelled {
                        Label("Canceled", systemImage: "xmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.loss)
                    } else if invite.isPast {
                        Label("Ended", systemImage: "clock.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textTertiary)
                    } else if invite.yesCount > 0 {
                        Text("\(invite.yesCount) in")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    Spacer()
                    if !isHost && !invite.isCancelled && !invite.isPast {
                        RSVPButtons(invite: invite, current: myResponse)
                    }
                }
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
        .confirmationDialog("Cancel this invite?", isPresented: $showCancelConfirmation, titleVisibility: .visible) {
            Button("Cancel Invite", role: .destructive) {
                Task {
                    isCancelling = true
                    _ = await store.cancelInvite(invite)
                    isCancelling = false
                }
            }
            Button("Keep Invite", role: .cancel) {}
        } message: {
            Text("Everyone invited will be notified that it was canceled.")
        }
    }
}

private struct RSVPButtons: View {
    @EnvironmentObject private var store: AppStore
    let invite: SessionInvite
    let current: RSVPStatus?

    var body: some View {
        HStack(spacing: 8) {
            rsvpButton(.yes, label: "Yes")
            rsvpButton(.maybe, label: "Maybe")
            rsvpButton(.no, label: "No")
        }
    }

    private func rsvpButton(_ status: RSVPStatus, label: String) -> some View {
        let isSelected = current == status
        return Button(label) { Task { await store.respondToInvite(invite, status: status) } }
            .font(.caption.weight(.semibold))
            .foregroundStyle(isSelected ? Theme.background : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Theme.accent : Theme.hairline, in: Capsule())
    }
}

struct InviteDetailView: View {
    @EnvironmentObject private var store: AppStore
    let inviteId: UUID
    var preloaded: SessionInvite?

    @State private var fetchedInvite: SessionInvite?
    @State private var isLoading = true
    @State private var showCancelConfirmation = false
    @State private var isCancelling = false

    private var invite: SessionInvite? {
        fetchedInvite ?? store.activeInvites.first { $0.id == inviteId } ?? preloaded
    }

    private var isHost: Bool { invite?.hostId == store.currentProfile?.id }

    var body: some View {
        ScrollView {
            if let invite {
                VStack(alignment: .leading, spacing: 16) {
                    InviteCard(invite: invite, showsInlineCancel: false)

                    if invite.isCancelled {
                        statusBanner(
                            title: "Invite canceled",
                            message: "The invited players were notified.",
                            systemImage: "xmark.circle.fill",
                            color: Theme.loss
                        )
                    } else if invite.isPast {
                        statusBanner(
                            title: "Session time passed",
                            message: "This invite is no longer shown in Upcoming.",
                            systemImage: "clock.fill",
                            color: Theme.textSecondary
                        )
                    }

                    if let recipients = invite.recipients, !recipients.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Invited").font(.headline).foregroundStyle(Theme.textPrimary)
                            ForEach(recipients) { recipient in
                                HStack(spacing: 10) {
                                    ProfileAvatar(participant: recipient.user, size: 32, linked: true)
                                    Text(recipient.user?.displayName ?? "Player")
                                        .font(.subheadline)
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    Text(RSVPStatus(rawValue: recipient.status)?.label ?? "Pending")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(recipient.status == "yes" ? Theme.accent : Theme.textSecondary)
                                }
                            }
                        }
                    }

                    if isHost && !invite.isCancelled && !invite.isPast {
                        Button(role: .destructive) {
                            showCancelConfirmation = true
                        } label: {
                            HStack {
                                Spacer()
                                if isCancelling {
                                    ProgressView().tint(Theme.loss)
                                } else {
                                    Label("Cancel Invite", systemImage: "xmark.circle")
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.loss)
                        .disabled(isCancelling)
                    }
                }
                .padding(16)
            } else if isLoading {
                ProgressView()
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 100)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "figure.pickleball")
                        .font(.largeTitle)
                        .foregroundStyle(Theme.textTertiary)
                    Text("This invite is no longer available")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 100)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Invite")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: inviteId) {
            if store.activeInvites.first(where: { $0.id == inviteId }) == nil,
               preloaded == nil {
                fetchedInvite = await store.loadInvite(inviteId: inviteId)
            }
            isLoading = false
        }
        .onChange(of: store.activeInvites) { _, invites in
            guard !invites.contains(where: { $0.id == inviteId }),
                  fetchedInvite?.isCancelled != true else { return }
            Task { fetchedInvite = await store.loadInvite(inviteId: inviteId) }
        }
        .confirmationDialog("Cancel this invite?", isPresented: $showCancelConfirmation, titleVisibility: .visible) {
            Button("Cancel Invite", role: .destructive) {
                guard let invite else { return }
                Task {
                    isCancelling = true
                    if await store.cancelInvite(invite) {
                        fetchedInvite = await store.loadInvite(inviteId: inviteId)
                    }
                    isCancelling = false
                }
            }
            Button("Keep Invite", role: .cancel) {}
        } message: {
            Text("Everyone invited will be notified that it was canceled.")
        }
    }

    private func statusBanner(title: String, message: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .cardStyle(padding: 14, fill: Theme.surfaceElevated)
    }
}
