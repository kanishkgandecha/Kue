//
//  SupabaseSyncSmokeTests.swift
//  KueMacTests
//
//  Kue 3.0 Phase 5 correction (requirement 8 — the disclosed gap the original Phase 5 report
//  never closed): a spot check that `Shared/Services/Sync/` runs correctly reached from the
//  `KueMac` module, not a second copy of `KueTests/Sync/`'s own exhaustive coverage of the same
//  pure types. One representative case per area — `FakeSyncTransport`/`FakeSyncStateStore`/
//  `FakeAccountProvider` only, never real networking, matching `AccountSharedServiceSmokeTests
//  .swift`'s own precedent exactly.
//

import Testing
import Foundation
import SwiftData
@testable import KueMac

// Part of the single `KueMacAllTests` suite — see `MacModelContainerFactoryTests.swift`'s
// header for why all `KueMacTests` files share one `@Suite(.serialized)` type.
extension KueMacAllTests {
    private func makeSignedInAccount() async -> AccountCoordinator {
        let account = AccountCoordinator(provider: FakeAccountProvider(), secureStore: FakeSecureStore())
        await account.signIn(email: FakeAccountProvider.fixtureEmail, password: FakeAccountProvider.fixturePassword)
        return account
    }

    private func makeDecidedStore() -> FakeSyncStateStore {
        let store = FakeSyncStateStore()
        var state = store.load()
        state.hasCompletedInitialSyncDecision = true
        store.save(state)
        return store
    }

    @Test func syncCoordinatorReachesSignedInSyncedStateOnKueMac() async {
        SyncPreference.setEnabled(true)
        defer { SyncPreference.setEnabled(false) }
        let context = ModelContext(ModelContainerFactory.makeInMemory())
        let coordinator = SyncCoordinator(stateStore: makeDecidedStore(), transport: FakeSyncTransport())
        let account = await makeSignedInAccount()
        let status = await coordinator.sync(context: context, account: account)
        #expect(status == .upToDate)
    }

    @Test func syncCoordinatorReportsLocalOnlyWhenSignedOutOnKueMac() async {
        SyncPreference.setEnabled(true)
        defer { SyncPreference.setEnabled(false) }
        let context = ModelContext(ModelContainerFactory.makeInMemory())
        let coordinator = SyncCoordinator(stateStore: makeDecidedStore(), transport: FakeSyncTransport())
        let signedOut = AccountCoordinator(provider: FakeAccountProvider(), secureStore: FakeSecureStore())
        let status = await coordinator.sync(context: context, account: signedOut)
        #expect(status == .localOnly)
    }

    @Test func syncCoordinatorUploadsALocallyCreatedEventOnKueMac() async {
        SyncPreference.setEnabled(true)
        defer { SyncPreference.setEnabled(false) }
        let context = ModelContext(ModelContainerFactory.makeInMemory())
        let store = makeDecidedStore()
        let now = Date.now
        let event = KueEvent(title: "Mac Interview", eventType: .interview, startDate: now.addingTimeInterval(86_400), estimatedDurationMinutes: 60, source: .manual, createdAt: now, updatedAt: now)
        context.insert(event)
        try? context.save()
        SyncOutbox.markEventDirty(event.id, store: store)
        let transport = FakeSyncTransport()
        let coordinator = SyncCoordinator(stateStore: store, transport: transport)
        let account = await makeSignedInAccount()
        _ = await coordinator.sync(context: context, account: account)
        #expect(transport.eventsInSeqOrder.contains { $0.id == event.id })
    }
}
