enum PlaybackRoutePolicy: Equatable, Sendable {
    case automatic
    case cueAutoAdvance

    var debugDescription: String {
        switch self {
        case .automatic:
            "automatic"
        case .cueAutoAdvance:
            "cueAutoAdvance"
        }
    }
}
