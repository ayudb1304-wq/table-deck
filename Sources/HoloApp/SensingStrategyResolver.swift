import HoloCore

/// Resolves which sensing strategy the audio engine should run, in priority
/// order: an active benchmark step, then the calibration draft, then the
/// selected profile, then the latest applicable approach comparison.
enum SensingStrategyResolver {
    static func resolve(
        benchmark: SensingStrategy?,
        calibration: SensingStrategy?,
        profile: SensingStrategy?,
        comparison: SensingStrategy?
    ) -> SensingStrategy {
        benchmark ?? calibration ?? profile ?? comparison ?? .passive
    }
}
