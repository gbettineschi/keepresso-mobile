import Foundation
import Testing
import KeepressoCore
@testable import CompanionCore

struct TelemetryTests {
    private final class Sensors:ThermalSensorReading {
        var values:[String:Double]=["Tp01":58,"Te05":62,"Tg01":95,"TB0T":33]
        var failed=false
        func discoverSensors()->[ThermalSensor]{values.keys.map{ThermalSensor(id:$0,name:$0)}}
        func readCelsius(ids:[String])->[String:Double]?{failed ? nil:values.filter{ids.contains($0.key)}}
    }
    @Test func cpuReadingDoesNotConfuseGpuOrBatteryWithCpu(){
        let sensors=Sensors();let monitor=CompanionTemperatureMonitor(sensors:sensors)
        XCTAssertEqual(monitor.reading()?.celsius,62)
        XCTAssertEqual(monitor.reading()?.sensor,"CPU (hottest sensor)")
    }
    @Test func failedOrImplausibleReadCannotReuseOldTemperatureAsCurrent(){
        let sensors=Sensors();var clock=0.0
        let monitor=CompanionTemperatureMonitor(sensors:sensors,monotonic:{clock})
        XCTAssertEqual(monitor.reading()?.celsius,62)
        clock=2;sensors.failed=true;XCTAssertNil(monitor.reading())
        clock=4;sensors.failed=false;sensors.values=["Tp01":Double.nan,"Te05":0,"Tg01":95]
        XCTAssertNil(monitor.reading())
    }
    @Test func intelUsesCpuTemperatureKeysAndNoOtherSensorFallback(){
        let sensors=Sensors();sensors.values=["TC0P":53,"TB0T":34]
        XCTAssertEqual(CompanionTemperatureMonitor(sensors:sensors).reading()?.celsius,53)
        sensors.values=["Tg01":80,"TB0T":34]
        XCTAssertNil(CompanionTemperatureMonitor(sensors:sensors).reading())
    }
    @Test func observerBudgetAllowsStartupMarginWhileRemainingBounded()async throws{
        let data=try await BoundedWorker.run(executable:URL(fileURLWithPath:"/usr/bin/printf"),arguments:["ready"],timeout:8)
        XCTAssertEqual(String(data:data,encoding:.utf8),"ready")
    }
    @Test func failedRefreshKeepsPriorTimeAndRowsWithoutBecomingAStaleSuccess(){
        var old=TriggerPreview();old.state="ready";old.checkedAt=Date(timeIntervalSince1970:100);old.combined=true
        old.rules=[.init(id:"0",label:"Agent working",satisfied:true,inGrace:false,graceRemaining:nil,details:[])]
        var failed=TriggerPreview();failed.state="error"
        failed.retainPriorAssessment(old)
        XCTAssertEqual(failed.state,"error");XCTAssertEqual(failed.checkedAt,Date(timeIntervalSince1970:100))
        XCTAssertEqual(failed.rules.first?.label,"Agent working");XCTAssertNil(failed.combined)
    }
}
