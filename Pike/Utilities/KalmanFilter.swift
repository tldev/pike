import Foundation
import CoreLocation

/// Simple 1D Kalman filter for smoothing course (heading) values.
/// Handles the circular nature of angles (0/360 wraparound).
final class CourseKalmanFilter {
    private var estimate: Double = 0
    private var errorEstimate: Double = 1
    private var isInitialized = false

    /// Process noise — how much we expect the course to change between updates.
    /// Higher = more responsive to changes, lower = smoother.
    let processNoise: Double = 0.05

    /// Measurement noise — how noisy we expect raw GPS course readings to be.
    let measurementNoise: Double = 0.3

    /// Feed a new raw course value and get the filtered result.
    func update(measurement: CLLocationDirection) -> CLLocationDirection {
        guard isInitialized else {
            estimate = measurement
            isInitialized = true
            return measurement
        }

        // Handle circular wrapping: adjust measurement to be within 180° of estimate
        var adjustedMeasurement = measurement
        let diff = measurement - estimate
        if diff > 180 {
            adjustedMeasurement -= 360
        } else if diff < -180 {
            adjustedMeasurement += 360
        }

        // Kalman prediction step
        let predictedErrorEstimate = errorEstimate + processNoise

        // Kalman update step
        let kalmanGain = predictedErrorEstimate / (predictedErrorEstimate + measurementNoise)
        estimate = estimate + kalmanGain * (adjustedMeasurement - estimate)
        errorEstimate = (1 - kalmanGain) * predictedErrorEstimate

        // Normalize back to 0-360
        estimate = (estimate + 360).truncatingRemainder(dividingBy: 360)

        return estimate
    }
}

