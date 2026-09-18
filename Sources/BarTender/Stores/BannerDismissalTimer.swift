import Foundation

/// Time source for `BannerDismissalTimer`. `now` is elapsed time since an
/// arbitrary origin; `schedule` runs an action after a delay and returns a
/// closure that cancels it. Tests swap in a manually advanced clock.
struct BannerClock {
    var now: @MainActor () -> Duration
    var schedule: @MainActor (Duration, @escaping @MainActor () -> Void) -> @MainActor () -> Void

    static var live: BannerClock {
        let origin = ContinuousClock.now
        return BannerClock(
            now: { ContinuousClock.now - origin },
            schedule: { delay, action in
                let task = Task { @MainActor in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    action()
                }
                return { task.cancel() }
            }
        )
    }
}

/// One shared countdown for the current banner, however many windows render it.
///
/// Each `BannerView` reports, under a unique token, whether it is actually on
/// screen and whether it is hovered. The countdown only runs while at least one
/// view is visible and none is hovered, and it resumes with the time left rather
/// than restarting. Hiding or removing a view drops its hover too, so a view torn
/// down mid-hover cannot pause the banner forever.
///
/// An info banner that no view shows for `staleAfter` in a row is dropped, so a
/// message posted while every window was closed doesn't surface hours later.
@MainActor
final class BannerDismissalTimer {
    var onExpire: () -> Void = {}

    private let delay: Duration
    private let staleAfter: Duration
    private let clock: BannerClock

    private var autoDismisses = false
    private var remaining: Duration
    private var countingSince: Duration?
    private var cancelScheduled: (() -> Void)?
    private var cancelStale: (() -> Void)?
    private var visibleViews: Set<UUID> = []
    private var hoveredViews: Set<UUID> = []

    init(delay: Duration, staleAfter: Duration, clock: BannerClock) {
        self.delay = delay
        self.staleAfter = staleAfter
        self.clock = clock
        self.remaining = delay
    }

    /// Starts a fresh countdown for a newly shown banner (or stops it for `nil`
    /// or error banners). View tokens are kept: views that stay on screen
    /// across a replacement keep rendering the new banner.
    func reset(autoDismisses: Bool) {
        stopCounting(accumulate: false)
        stopStaleWatch()
        self.autoDismisses = autoDismisses
        remaining = delay
        update()
    }

    /// Records a view's current state. A view that isn't visible can't be hovered.
    func setView(_ token: UUID, visible: Bool, hovered: Bool) {
        if visible {
            visibleViews.insert(token)
        } else {
            visibleViews.remove(token)
        }
        if visible, hovered {
            hoveredViews.insert(token)
        } else {
            hoveredViews.remove(token)
        }
        update()
    }

    func removeView(_ token: UUID) {
        setView(token, visible: false, hovered: false)
    }

    private func update() {
        let shouldCount = autoDismisses && !visibleViews.isEmpty && hoveredViews.isEmpty
        if shouldCount, countingSince == nil {
            countingSince = clock.now()
            cancelScheduled = clock.schedule(remaining) { [weak self] in self?.expire() }
        } else if !shouldCount {
            stopCounting(accumulate: true)
        }

        let unseen = autoDismisses && visibleViews.isEmpty
        if unseen, cancelStale == nil {
            cancelStale = clock.schedule(staleAfter) { [weak self] in self?.expire() }
        } else if !unseen {
            stopStaleWatch()
        }
    }

    private func stopStaleWatch() {
        cancelStale?()
        cancelStale = nil
    }

    private func stopCounting(accumulate: Bool) {
        if accumulate, let countingSince {
            remaining = max(.zero, remaining - (clock.now() - countingSince))
        }
        countingSince = nil
        cancelScheduled?()
        cancelScheduled = nil
    }

    private func expire() {
        stopCounting(accumulate: false)
        stopStaleWatch()
        autoDismisses = false
        onExpire()
    }
}
