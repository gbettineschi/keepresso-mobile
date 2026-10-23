import Foundation

public struct CompanionTemperature:Equatable,Sendable {
    public let celsius:Double
    public let sensor:String
}

/// Companion-only read adapter; the pinned upstream SMC implementation is unchanged.
/// Never writes a key, changes fan control, or substitutes a battery/GPU reading.
public final class CompanionTemperatureMonitor {
    private let sensors:ThermalSensorReading
    private let monotonic:()->TimeInterval
    private var ids:[String]?
    private var nextSample = -Double.greatestFiniteMagnitude
    private var cached:CompanionTemperature?
    public init(sensors:ThermalSensorReading=SMCThermalSensors(),monotonic:@escaping()->TimeInterval={ProcessInfo.processInfo.systemUptime}){
        self.sensors=sensors;self.monotonic=monotonic
    }
    public func reading()->CompanionTemperature?{
        let now=monotonic()
        if now<nextSample{return cached}
        nextSample=now+1
        if ids==nil{ids=sensors.discoverSensors().map(\.id).filter{$0.hasPrefix("Tp") || $0.hasPrefix("Te") || $0.hasPrefix("TC")}}
        cached=nil
        guard let ids,!ids.isEmpty,let values=sensors.readCelsius(ids:ids),let maximum=values.filter({ids.contains($0.key)}).values.filter({$0.isFinite && SMCThermalSensors.isPlausibleCelsius($0)}).max() else{return nil}
        cached=CompanionTemperature(celsius:maximum,sensor:"CPU (hottest sensor)")
        return cached
    }
}
