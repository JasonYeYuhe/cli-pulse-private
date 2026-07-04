import XCTest
@testable import SensorKit

final class SMCDecoderTests: XCTestCase {
    func testFourCCRoundTrip() {
        XCTAssertEqual(SMC.keyString(SMC.fourCC("F0Ac")), "F0Ac")
        XCTAssertEqual(SMC.keyString(SMC.fourCC("#KEY")), "#KEY")
        // Known FourCC value: "F0Ac" = 0x46304163
        XCTAssertEqual(SMC.fourCC("F0Ac"), 0x4630_4163)
    }

    func testDecodeFlt() {
        // 1650.37 RPM as little-endian IEEE-754 float bytes.
        let bits = Float(1650.37).bitPattern
        let b = [UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff), UInt8((bits >> 16) & 0xff), UInt8((bits >> 24) & 0xff)]
        let v = SMC.decode(type: "flt", bytes: b)
        XCTAssertNotNil(v)
        XCTAssertEqual(v!, 1650.37, accuracy: 0.01)
    }

    func testDecodeUIntLittleEndian() {
        XCTAssertEqual(SMC.decode(type: "ui8", bytes: [2]), 2)
        XCTAssertEqual(SMC.decode(type: "ui16", bytes: [0x10, 0x27]), 10000)   // 0x2710 LE
        XCTAssertEqual(SMC.decode(type: "ui32", bytes: [0x40, 0x42, 0x0f, 0x00]), 1_000_000)
    }

    func testDecodeFixedPointIntel() {
        // sp78: byte0 int part, byte1/256 frac. 0x2b40 -> 43.25
        XCTAssertEqual(SMC.decode(type: "sp78", bytes: [0x2b, 0x40])!, 43.25, accuracy: 0.001)
    }

    func testDecodeUnknownTypeNil() {
        XCTAssertNil(SMC.decode(type: "xxxx", bytes: [1, 2, 3, 4]))
        XCTAssertNil(SMC.decode(type: "flt", bytes: [1, 2]))  // too short
    }
}

final class IOReportMathTests: XCTestCase {
    func testEnergyUnits() {
        XCTAssertEqual(IOReportPower.joules(fromEnergy: 5000, unit: "mJ")!, 5.0, accuracy: 1e-9)
        XCTAssertEqual(IOReportPower.joules(fromEnergy: 5_000_000, unit: "uJ")!, 5.0, accuracy: 1e-9)
        XCTAssertEqual(IOReportPower.joules(fromEnergy: 5_000_000_000, unit: "nJ")!, 5.0, accuracy: 1e-9)
        XCTAssertNil(IOReportPower.joules(fromEnergy: 100, unit: "W"))   // not an energy unit -> skip
    }
}

final class SensorMathTests: XCTestCase {
    func testTempClassification() {
        XCTAssertTrue(SensorMath.isCPUTempKey("Tp01"))
        XCTAssertTrue(SensorMath.isCPUTempKey("Te05"))
        XCTAssertTrue(SensorMath.isGPUTempKey("Tg0D"))
        XCTAssertFalse(SensorMath.isGPUTempKey("Tp01"))
        XCTAssertFalse(SensorMath.isCPUTempKey("Tg05"))
    }

    func testAverageTempDropsAbsurd() {
        XCTAssertEqual(SensorMath.averageTemp([70.0, 66.0, 68.0])!, 68.0, accuracy: 0.01)
        XCTAssertEqual(SensorMath.averageTemp([70.0, -999, 200, 66.0])!, 68.0, accuracy: 0.01)
        XCTAssertNil(SensorMath.averageTemp([]))
        XCTAssertNil(SensorMath.averageTemp([-1, 999]))
    }

    func testCpuGpuTempFromSMC() {
        let smc = ["Tp01": 70.0, "Tp09": 66.0, "Tg05": 64.0, "Tg0D": 65.0, "Ts0P": 39.0]
        XCTAssertEqual(SensorMath.cpuTemp(smc: smc, hid: [])!, 68.0, accuracy: 0.01)
        XCTAssertEqual(SensorMath.gpuTemp(smc: smc)!, 64.5, accuracy: 0.01)
    }

    func testCpuTempHidFallback() {
        XCTAssertEqual(SensorMath.cpuTemp(smc: [:], hid: [50.0, 60.0])!, 55.0, accuracy: 0.01)
    }

    func testDieTempBandRejectsNonPhysical() {
        // Regression: a power-gated GPU rail intermittently reports ~9 °C; the
        // die-temp band must reject it (< 20 °C) so gpu_temp doesn't go garbage.
        XCTAssertEqual(SensorMath.dieTempFloorC, 20.0)
        XCTAssertEqual(SensorMath.dieTempCeilC, 115.0)
        XCTAssertLessThan(9.2, SensorMath.dieTempFloorC)   // 9.2 artifact is below the floor
        XCTAssertGreaterThan(56.0, SensorMath.dieTempFloorC)
        XCTAssertLessThan(72.0, SensorMath.dieTempCeilC)
    }

    func testCandidateTempKeysCoverKnownDieSensors() {
        let keys = Set(SensorMath.candidateTempKeys())
        // The die-temp keys observed live on this M1 Pro must be in the scan set.
        for k in ["Tp01", "Tp09", "Tp0D", "Tg05", "Tg0D"] {
            XCTAssertTrue(keys.contains(k), "candidate set missing \(k)")
        }
        // 4 clusters * 2 hi * 16 lo = 128, all unique.
        XCTAssertEqual(SensorMath.candidateTempKeys().count, 128)
        XCTAssertEqual(keys.count, 128)
    }

    func testPowerMapping() {
        let ch = ["CPU Energy": 5.253, "GPU Energy": 1.301, "ANE0": 0.0, "DRAM0": 1.28, "Noise": 9.9]
        let p = SensorMath.power(from: ch)
        XCTAssertEqual(p.cpu!, 5.253, accuracy: 0.001)
        XCTAssertEqual(p.gpu!, 1.301, accuracy: 0.001)
        XCTAssertEqual(p.ane!, 0.0, accuracy: 0.001)
        // system = cpu + gpu + ane + dram (Noise is not a known rail)
        XCTAssertEqual(p.system!, 5.253 + 1.301 + 0.0 + 1.28, accuracy: 0.001)
    }

    func testPowerMappingEmpty() {
        let p = SensorMath.power(from: [:])
        XCTAssertNil(p.cpu)
        XCTAssertNil(p.system)
    }
}
