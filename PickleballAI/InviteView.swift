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
                             ? "Location is off. Search below."
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
        ProfileNavigationStack {
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
                                Haptics.tap()
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
        if ok {
            Haptics.success()
            dismiss()
        }
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
    /// Set false when this card is already the content of `InviteDetailView` —
    /// otherwise tapping it would push another (identical) detail screen on
    /// top of itself.
    var isNavigable = true

    @State private var showCancelConfirmation = false
    @State private var isCancelling = false

    private var myId: UUID? { store.currentProfile?.id }
    private var isHost: Bool { invite.hostId == myId }
    private var myResponse: RSVPStatus? { myId.flatMap { invite.myResponse(userId: $0) } }

    var body: some View {
        Group {
            if isNavigable {
                NavigationLink {
                    InviteDetailView(inviteId: invite.id, preloaded: invite)
                } label: {
                    cardContent
                }
                .buttonStyle(.plain)
            } else {
                cardContent
            }
        }
        .confirmationDialog("Cancel this invite?", isPresented: $showCancelConfirmation, titleVisibility: .visible) {
            Button("Cancel Invite", role: .destructive) {
                Haptics.tap()
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

    private var cardContent: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Theme.accentSoft)
                        Image(systemName: "figure.pickleball")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(invite.court?.name ?? "Court")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(isHost ? "Hosted by you" : "Hosted by \(invite.host?.displayName ?? "Someone")")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 6) {
                        statusPill
                        if isNavigable {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }

                if let note = invite.note, !note.isEmpty {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }

                Divider().overlay(Theme.hairline)

                HStack {
                    Label(
                        invite.scheduledAtDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()),
                        systemImage: "clock"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)

                    Spacer()

                    if isHost && showsInlineCancel && !invite.isCancelled && !invite.isPast {
                        Button {
                            showCancelConfirmation = true
                        } label: {
                            if isCancelling {
                                ProgressView().controlSize(.small).tint(Theme.loss)
                            } else {
                                Label("Cancel", systemImage: "xmark.circle")
                                    .font(.caption.weight(.semibold))
                            }
                        }
                        .foregroundStyle(Theme.loss)
                        .disabled(isCancelling)
                    } else if !isHost && !invite.isCancelled && !invite.isPast {
                        RSVPButtons(invite: invite, current: myResponse)
                    }
                }
            }
            .cardStyle()
    }

    @ViewBuilder
    private var statusPill: some View {
        if invite.isCancelled {
            pill("Canceled", color: Theme.loss)
        } else if invite.isPast {
            pill("Ended", color: Theme.textTertiary)
        } else if !isHost, let myResponse, myResponse != .pending {
            pill(myResponse.label, color: rsvpColor(myResponse))
        } else if invite.yesCount > 0 {
            pill("\(invite.yesCount) in", color: Theme.accent)
        }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }
}

func rsvpColor(_ status: RSVPStatus) -> Color {
    switch status {
    case .yes: return Theme.accent
    case .no: return Theme.loss
    case .maybe: return Theme.textSecondary
    case .pending: return Theme.textTertiary
    }
}

private struct RSVPButtons: View {
    @EnvironmentObject private var store: AppStore
    let invite: SessionInvite
    let current: RSVPStatus?

    var body: some View {
        HStack(spacing: 8) {
            rsvpButton(.no, icon: "xmark")
            rsvpButton(.maybe, icon: "questionmark")
            rsvpButton(.yes, icon: "checkmark")
        }
    }

    private func rsvpButton(_ status: RSVPStatus, icon: String) -> some View {
        let isSelected = current == status
        return Button {
            Haptics.tap()
            Task { await store.respondToInvite(invite, status: status) }
        } label: {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(isSelected ? Theme.background : Theme.textSecondary)
                .frame(width: 30, height: 30)
                .background(isSelected ? rsvpColor(status) : Theme.surfaceElevated, in: Circle())
        }
        .buttonStyle(.plain)
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
        // Prefer the store's copy: after any action (RSVP, cancel) the store is
        // refreshed, while `fetchedInvite` is a snapshot from the deep-link load
        // and would otherwise keep rendering the pre-action state.
        store.activeInvites.first { $0.id == inviteId } ?? fetchedInvite ?? preloaded
    }

    private var isHost: Bool { invite?.hostId == store.currentProfile?.id }

    var body: some View {
        ScrollView {
            if let invite {
                VStack(alignment: .leading, spacing: 16) {
                    InviteCard(invite: invite, showsInlineCancel: false, isNavigable: false)

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
                            Text("Invited (\(recipients.count))")
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)

                            VStack(spacing: 0) {
                                ForEach(recipients) { recipient in
                                    if recipient.id != recipients.first?.id {
                                        Divider().overlay(Theme.hairline).padding(.leading, 52)
                                    }
                                    IdentityRow(
                                        avatarURL: recipient.user?.avatarURL,
                                        initials: recipient.user?.initials ?? "?",
                                        avatarSize: 36,
                                        name: recipient.user?.displayName ?? "Player",
                                        userId: recipient.user?.id
                                    ) {
                                        let status = RSVPStatus(rawValue: recipient.status) ?? .pending
                                        Text(status.label)
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(rsvpColor(status))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(rsvpColor(status).opacity(0.14), in: Capsule())
                                    }
                                    .padding(.vertical, 8)
                                }
                            }
                            .cardStyle()
                        }
                    }

                    if isHost && !invite.isCancelled && !invite.isPast {
                        Button {
                            showCancelConfirmation = true
                        } label: {
                            HStack {
                                Spacer()
                                if isCancelling {
                                    ProgressView().tint(Theme.loss)
                                } else {
                                    Label("Cancel Invite", systemImage: "xmark.circle")
                                        .font(.subheadline.weight(.semibold))
                                }
                                Spacer()
                            }
                            .foregroundStyle(Theme.loss)
                            .padding(.vertical, 12)
                            .background(Theme.loss.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
                        }
                        .buttonStyle(.plain)
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
                Haptics.tap()
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
