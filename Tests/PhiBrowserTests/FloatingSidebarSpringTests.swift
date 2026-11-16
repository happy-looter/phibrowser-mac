// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// The floating panel springs into place when it slides in from the window
/// edge: it overshoots a few points and settles, instead of stopping dead.
/// With Reduce Motion on it slides in without the overshoot.
@MainActor
final class FloatingSidebarSpringTests: XCTestCase {
    private var store: LocalStore!
    private var directory: URL!
    private var accountDirectory: URL!
    private var previousLayout: Any?
    private var previousSidebarPosition: Any?
    private var slots: [SpaceWindowSlot] = []
    private let manager = SpaceManager(observeAccountChanges: false)
    private var nextWindowId = 223468789
    /// Held here: a wrapper's `nativeView` is weak.
    private var webViews: [NSView] = []

    private typealias Host = FloatingSidebarHostViewController

    override func setUp() async throws {
        previousLayout = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        previousSidebarPosition = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.sidebarPositionKey)
        PhiPreferences.GeneralSettings.saveSidebarPosition(.left)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account = Account(userID: "floating-sidebar-spring-test-\(UUID().uuidString)")
        accountDirectory = account.userDataStorage
        store = LocalStore(account: account, storeDirectoryURL: directory, presentsCompatibilityAlerts: false)
        account.localStorage = store
        let context = try XCTUnwrap(store.getMainContext())
        context.insert(ProfileModel(profileId: LocalStore.defaultProfileId))
        context.insert(SpaceModel(spaceId: "first", profileId: LocalStore.defaultProfileId,
            name: "first", colorHex: "#AAAAAA", iconName: "target", sortOrder: 0))
        try context.save()
        manager.bind(to: store.account)
        await drainMainQueue()
    }

    override func tearDown() async throws {
        manager.discardSpacePrewarm()
        for slot in slots { slot.closeShellIfPresent() }
        slots.removeAll()
        webViews.removeAll()
        await drainMainQueue()
        try await store.closeForAccountDirectoryRemoval()
        store = nil
        for url in [directory, accountDirectory].compactMap({ $0 })
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        UserDefaults.standard.set(previousLayout, forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        UserDefaults.standard.set(previousSidebarPosition, forKey: PhiPreferences.GeneralSettings.sidebarPositionKey)
        try await super.tearDown()
    }

    func testTheSlideInSpringsIntoPlace() throws {
        let slot = try makeSlot()
        let split = try XCTUnwrap(slot.shell?.split)
        let host = split.floatingSidebarHost
        try collapse(in: slot)
        host.prefersReducedMotion = { false }

        host.showFloatingSidebar()

        let panel = try XCTUnwrap(host.floatingSidebarContainerView)
        let spring = try XCTUnwrap(panel.layer?.animation(forKey: Host.floatingSidebarSlideInAnimationKey) as? CASpringAnimation)
        XCTAssertEqual(spring.stiffness, Host.floatingSidebarSpringStiffness)
        XCTAssertEqual(spring.mass, Host.floatingSidebarSpringMass)
        XCTAssertEqual(spring.damping, Host.floatingSidebarSpringDamping(travel: panel.frame.width), accuracy: 0.001,
                       "damped for this panel's travel")
        XCTAssertEqual(spring.keyPath, "transform.translation.x")
        XCTAssertEqual((spring.fromValue as? CGFloat) ?? .nan, -panel.frame.width, accuracy: 0.5,
                       "starts one panel width off the left edge")
        XCTAssertEqual((spring.toValue as? CGFloat) ?? .nan, 0)
        XCTAssertEqual(panel.frame.minX, 0, accuracy: 0.5,
                       "the model frame is already at rest, so hit-testing works at once")
    }

    func testOnTheRightTheSlideInSpringsFromTheRightEdge() throws {
        PhiPreferences.GeneralSettings.saveSidebarPosition(.right)
        let slot = try makeSlot()
        let split = try XCTUnwrap(slot.shell?.split)
        let host = split.floatingSidebarHost
        try collapse(in: slot)
        host.prefersReducedMotion = { false }

        host.showFloatingSidebar()

        let panel = try XCTUnwrap(host.floatingSidebarContainerView)
        let spring = try XCTUnwrap(panel.layer?.animation(forKey: Host.floatingSidebarSlideInAnimationKey) as? CASpringAnimation)
        XCTAssertEqual((spring.fromValue as? CGFloat) ?? .nan, panel.frame.width, accuracy: 0.5,
                       "starts one panel width off the right edge")
        XCTAssertEqual((spring.toValue as? CGFloat) ?? .nan, 0)
        XCTAssertEqual(panel.frame.maxX, host.view.bounds.maxX, accuracy: 0.5)
    }

    func testReduceMotionSlidesInWithoutTheSpring() throws {
        let slot = try makeSlot()
        let split = try XCTUnwrap(slot.shell?.split)
        let host = split.floatingSidebarHost
        try collapse(in: slot)
        host.prefersReducedMotion = { true }

        host.showFloatingSidebar()

        let panel = try XCTUnwrap(host.floatingSidebarContainerView)
        XCTAssertNil(panel.layer?.animation(forKey: Host.floatingSidebarSlideInAnimationKey))
        XCTAssertTrue(host.isVisible)
    }

    func testHidingDuringTheSpringDropsIt() throws {
        let slot = try makeSlot()
        let split = try XCTUnwrap(slot.shell?.split)
        let host = split.floatingSidebarHost
        try collapse(in: slot)
        host.prefersReducedMotion = { false }
        host.showFloatingSidebar()
        let panel = try XCTUnwrap(host.floatingSidebarContainerView)
        XCTAssertNotNil(panel.layer?.animation(forKey: Host.floatingSidebarSlideInAnimationKey),
                        "precondition: the spring runs")

        host.hideFloatingSidebar(animated: true)

        XCTAssertNil(panel.layer?.animation(forKey: Host.floatingSidebarSlideInAnimationKey))
    }

    func testTheBounceIsTheSameAtEveryWidth() {
        for travel: CGFloat in [198, 350, 505] {
            let damping = Host.floatingSidebarSpringDamping(travel: travel)
            XCTAssertEqual(Self.overshoot(damping: damping) * travel, Host.floatingSidebarSpringOvershoot, accuracy: 0.05,
                           "\(travel) pt slide lands \(Host.floatingSidebarSpringOvershoot) pt past rest")
        }
    }

    func testASlideShorterThanTheBounceDoesNotOvershoot() {
        let critical = 2 * (Host.floatingSidebarSpringStiffness * Host.floatingSidebarSpringMass).squareRoot()
        XCTAssertGreaterThanOrEqual(Host.floatingSidebarSpringDamping(travel: 4), critical)
        XCTAssertGreaterThanOrEqual(Host.floatingSidebarSpringDamping(travel: 0), critical)
    }

    func testTheSpringSettlesWithinAQuarterSecond() {
        for travel: CGFloat in [198, 350, 505] {
            let spring = CASpringAnimation()
            spring.stiffness = Host.floatingSidebarSpringStiffness
            spring.mass = Host.floatingSidebarSpringMass
            spring.damping = Host.floatingSidebarSpringDamping(travel: travel)
            XCTAssertLessThanOrEqual(spring.settlingDuration, 0.25, "\(travel) pt slide")
        }
    }

    /// The share of the travel an underdamped spring overshoots by, from its
    /// damping with the host's stiffness and mass.
    private static func overshoot(damping: CGFloat) -> CGFloat {
        let ratio = damping / (2 * (Host.floatingSidebarSpringStiffness * Host.floatingSidebarSpringMass).squareRoot())
        guard ratio < 1 else { return 0 }
        return exp(-ratio * .pi / (1 - ratio * ratio).squareRoot())
    }

    // MARK: - Harness

    /// Collapses the column without showing the panel.
    private func collapse(in slot: SpaceWindowSlot,
                          file: StaticString = #filePath,
                          line: UInt = #line) throws {
        let split = try XCTUnwrap(slot.shell?.split, file: file, line: line)
        split.setSidebarCollapsed(true, animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        split.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(split.floatingSidebarHost.isVisible, "precondition: the panel is hidden", file: file, line: line)
    }

    /// A shell presenting one Space with one focused, mounted tab.
    private func makeSlot() throws -> SpaceWindowSlot {
        let slot = SpaceWindowSlot(manager: manager, initialSpaceId: "first")
        slot.ensureShell(initialFrame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        slots.append(slot)
        nextWindowId += 1
        let state = UnseededBrowserState(windowId: nextWindowId, localStore: store,
            profileId: LocalStore.defaultProfileId, spaceId: "first", isIncognito: false)
        let webView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        webViews.append(webView)
        let wrapper = PageColorTestWebContentWrapper(urlString: "https://first.example/")
        wrapper.nativeView = webView
        let tab = Tab(guid: nextWindowId, url: wrapper.urlString, isActive: true,
            index: 0, webContentView: wrapper)
        state.tabs = [tab]
        state.updateNormalTabs()
        state.focusingTab = tab
        let session = SpaceSessionController(window: slot.shell!.window, windowId: state.windowId,
            profileId: state.profileId, spaceId: "first", account: store.account,
            slot: slot, browserState: state, dormant: true)
        slot.registerWindow(session, for: "first")
        XCTAssertTrue(session.isPresented, "precondition: the Space is presented")
        slot.shell?.window.orderFront(nil)
        let deadline = Date().addingTimeInterval(2)
        while webView.window == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNotNil(webView.window, "precondition: the page is mounted")
        return slot
    }

    private func drainMainQueue() async {
        let drained = expectation(description: "Main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }
}

/// These Browsers have their tab already, and must never seed one.
private final class UnseededBrowserState: BrowserState {
    override func createQuickLookupTab(customGuid: String? = nil) {}
}
