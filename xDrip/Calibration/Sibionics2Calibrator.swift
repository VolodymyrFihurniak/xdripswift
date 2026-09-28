import CoreData
import Foundation

/// xDrip+'s existing weighted calibration curve applied to the factory-corrected
/// Sibionics value (mg/dL), which is already the value delivered by the stock core.
final class Sibionics2XDripCalibrator: Calibrator {
    let rawValueDivider = 1.0
    let ageAdjustMentNeeded = false
    let sParams = SlopeParameters(
        LOW_SLOPE_1: 1, LOW_SLOPE_2: 1, HIGH_SLOPE_1: 1, HIGH_SLOPE_2: 1,
        DEFAULT_LOW_SLOPE_LOW: 1, DEFAULT_LOW_SLOPE_HIGH: 1, DEFAULT_SLOPE: 1,
        DEFAULT_HIGH_SLOPE_HIGH: 1, DEFAUL_HIGH_SLOPE_LOW: 1
    )

    func description() -> String { "Sibionics2XDripCalibrator" }
}

/// JugglucoNG's default calibration profile: single-point offset, then fresh
/// weighted OLS with a bounded slope and a small local anchor blend.
final class Sibionics2JugglucoCalibrator: Calibrator {
    let rawValueDivider = 1.0
    let ageAdjustMentNeeded = false
    let sParams = SlopeParameters(
        LOW_SLOPE_1: 1, LOW_SLOPE_2: 1, HIGH_SLOPE_1: 1, HIGH_SLOPE_2: 1,
        DEFAULT_LOW_SLOPE_LOW: 1, DEFAULT_LOW_SLOPE_HIGH: 1, DEFAULT_SLOPE: 1,
        DEFAULT_HIGH_SLOPE_HIGH: 1, DEFAUL_HIGH_SLOPE_LOW: 1
    )

    func description() -> String { "Sibionics2JugglucoNGCalibrator" }

    func createNewBgReading(
        rawData: Double,
        timeStamp: Date?,
        sensor: Sensor?,
        last3Readings: inout [BgReading],
        lastCalibrationsForActiveSensorInLastXDays: inout [Calibration],
        firstCalibration: Calibration?,
        lastCalibration: Calibration?,
        deviceName: String?,
        nsManagedObjectContext: NSManagedObjectContext
    ) -> BgReading {
        let reading = NoCalibrator().createNewBgReading(
            rawData: rawData,
            timeStamp: timeStamp,
            sensor: sensor,
            last3Readings: &last3Readings,
            lastCalibrationsForActiveSensorInLastXDays: &lastCalibrationsForActiveSensorInLastXDays,
            firstCalibration: firstCalibration,
            lastCalibration: lastCalibration,
            deviceName: deviceName,
            nsManagedObjectContext: nsManagedObjectContext
        )

        var calibrations = lastCalibrationsForActiveSensorInLastXDays
        if let firstCalibration,
           !calibrations.contains(where: { $0.objectID == firstCalibration.objectID }) {
            calibrations.append(firstCalibration)
        }
        let anchors = calibrations.map { calibration in
            Sibionics2CalibrationAnchor(
                sensorMgDl: calibration.estimateRawAtTimeOfCalibration > 0
                    ? calibration.estimateRawAtTimeOfCalibration
                    : calibration.adjustedRawValue,
                fingerstickMgDl: calibration.bg,
                timeStamp: calibration.timeStamp
            )
        }
        let corrected = Sibionics2JugglucoCalibrationMath.calibratedValue(
            rawData,
            at: timeStamp ?? Date(),
            anchors: anchors
        )
        reading.calculatedValue = min(
            ConstantsCalibrationAlgorithms.maximumBgReadingCalculatedValue,
            max(ConstantsCalibrationAlgorithms.minimumBgReadingCalculatedValue, corrected)
        )
        findSlope(for: reading, last2Readings: &last3Readings)
        return reading
    }

    func initialCalibration(
        firstCalibrationBgValue: Double,
        firstCalibrationTimeStamp: Date,
        secondCalibrationBgValue: Double,
        sensor: Sensor,
        lastBgReadingsWithCalculatedValue0AndForSensor: inout [BgReading],
        deviceName: String?,
        nsManagedObjectContext: NSManagedObjectContext
    ) -> (firstCalibration: Calibration?, secondCalibration: Calibration?) {
        let result = Sibionics2XDripCalibrator().initialCalibration(
            firstCalibrationBgValue: firstCalibrationBgValue,
            firstCalibrationTimeStamp: firstCalibrationTimeStamp,
            secondCalibrationBgValue: secondCalibrationBgValue,
            sensor: sensor,
            lastBgReadingsWithCalculatedValue0AndForSensor: &lastBgReadingsWithCalculatedValue0AndForSensor,
            deviceName: deviceName,
            nsManagedObjectContext: nsManagedObjectContext
        )
        let anchors = [result.firstCalibration, result.secondCalibration].compactMap { $0 }.map { Self.anchor($0) }
        for index in lastBgReadingsWithCalculatedValue0AndForSensor.indices {
            let reading = lastBgReadingsWithCalculatedValue0AndForSensor[index]
            reading.calculatedValue = Self.clampedValue(
                Sibionics2JugglucoCalibrationMath.calibratedValue(
                    reading.ageAdjustedRawValue,
                    at: max(reading.timeStamp, result.secondCalibration?.timeStamp ?? firstCalibrationTimeStamp),
                    anchors: anchors
                )
            )
            var olderReadings = Array(lastBgReadingsWithCalculatedValue0AndForSensor.dropFirst(index + 1).prefix(3))
            findSlope(for: reading, last2Readings: &olderReadings)
        }
        return result
    }

    func createNewCalibration(
        bgValue: Double,
        lastBgReading: BgReading?,
        sensor: Sensor,
        lastCalibrationsForActiveSensorInLastXDays: inout [Calibration],
        firstCalibration: Calibration,
        deviceName: String?,
        nsManagedObjectContext: NSManagedObjectContext
    ) -> Calibration? {
        guard let lastBgReading,
              let calibration = Sibionics2XDripCalibrator().createNewCalibration(
                bgValue: bgValue,
                lastBgReading: lastBgReading,
                sensor: sensor,
                lastCalibrationsForActiveSensorInLastXDays: &lastCalibrationsForActiveSensorInLastXDays,
                firstCalibration: firstCalibration,
                deviceName: deviceName,
                nsManagedObjectContext: nsManagedObjectContext
              ) else { return nil }

        var anchors = lastCalibrationsForActiveSensorInLastXDays.map { Self.anchor($0) }
        anchors.append(Self.anchor(calibration))
        lastBgReading.calculatedValue = Self.clampedValue(
            Sibionics2JugglucoCalibrationMath.calibratedValue(
                lastBgReading.ageAdjustedRawValue,
                at: max(lastBgReading.timeStamp, calibration.timeStamp),
                anchors: anchors
            )
        )
        return calibration
    }

    private static func anchor(_ calibration: Calibration) -> Sibionics2CalibrationAnchor {
        Sibionics2CalibrationAnchor(
            sensorMgDl: calibration.estimateRawAtTimeOfCalibration > 0
                ? calibration.estimateRawAtTimeOfCalibration
                : calibration.adjustedRawValue,
            fingerstickMgDl: calibration.bg,
            timeStamp: calibration.timeStamp
        )
    }

    private static func clampedValue(_ value: Double) -> Double {
        min(
            ConstantsCalibrationAlgorithms.maximumBgReadingCalculatedValue,
            max(ConstantsCalibrationAlgorithms.minimumBgReadingCalculatedValue, value)
        )
    }
}
