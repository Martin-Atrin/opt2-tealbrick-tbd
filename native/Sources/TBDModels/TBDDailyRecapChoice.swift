import Foundation

/// Which model Daily uses for its recap, decided from what the person chose and what TBD has set up.
/// Pure rule (C137): the Companion reads the stored values, calls `resolve`, and maps the answer.
///
/// - A provider the person picked in the Daily picker stays, including an explicit "none".
/// - A stored value that is not "none" counts as chosen even without the marker (earlier installs).
/// - No choice (nothing stored, or "none" without the marker): TBD's agent model when it is ready,
///   else the person must choose. Daily is never silently off.
public enum TBDDailyRecapChoice {
    /// Raw value of the recap provider that uses TBD's "agent" model route.
    public static let agentRawValue = "agent"
    /// Raw value of the explicit "no provider" choice.
    public static let noneRawValue = "none"

    public enum Result: Equatable, Sendable {
        /// Use this provider (raw value).
        case provider(String)
        /// Nothing usable is chosen or set up: Daily asks the person to choose a model.
        case needsChoice
    }

    /// - Parameters:
    ///   - storedRaw: the stored provider raw value, nil when none is stored or it is not a known provider.
    ///   - chosen: true when the person picked a provider in the Daily picker (the marker is set).
    ///   - agentRouteReady: true when `TBDAgentModelSetup.resolve` succeeds. Read only when needed.
    public static func resolve(storedRaw: String?, chosen: Bool, agentRouteReady: @autoclosure () -> Bool) -> Result {
        if let raw = storedRaw, !raw.isEmpty {
            if raw != noneRawValue || chosen { return .provider(raw) }
        }
        return agentRouteReady() ? .provider(agentRawValue) : .needsChoice
    }
}
