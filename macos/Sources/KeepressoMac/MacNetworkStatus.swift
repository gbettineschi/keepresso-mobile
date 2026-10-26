import Foundation
import Network
import CoreWLAN
import CoreLocation
import AppKit
import CompanionCore

/// Read-only, demand-driven telemetry. No timer, network scan or sleep assertion.
@MainActor final class MacNetworkStatus {
    private var monitor:NWPathMonitor?
    private var task:Task<Void,Never>?
    private var evidence=InternetEvidence()
    private var networkType="unknown"
    private var interfaceName:String?
    private var pathIdentity=""
    private var wifiName:String?
    private var hasPath=false
    private let wifi=CWWiFiClient.shared()
    private let probe=HTTPSInternetProbe()
    func start(){
        guard monitor==nil else{return}
        let monitor=NWPathMonitor();self.monitor=monitor
        monitor.pathUpdateHandler={ [weak self,weak monitor] path in
            Task{@MainActor in
                guard let self,let monitor,self.monitor === monitor else{return}
                self.hasPath=true
                self.evidence.reset();self.task?.cancel();self.task=nil
                self.networkType=path.usesInterfaceType(.wifi) ? "wifi":path.usesInterfaceType(.wiredEthernet) ? "ethernet":path.usesInterfaceType(.cellular) ? "cellular":path.status == .satisfied ? "other":"none"
                self.interfaceName=path.availableInterfaces.first(where:{$0.type == .wifi})?.name ?? self.wifi.interface()?.interfaceName
                self.pathIdentity=path.availableInterfaces.filter{path.usesInterfaceType($0.type)}.map{$0.name}.sorted().joined(separator:",")+"|"+path.gateways.map{String(describing:$0)}.sorted().joined(separator:",")
                self.update(available:path.status == .satisfied)
            }
        }
        monitor.start(queue:DispatchQueue(label:"keepresso.internet",qos:.utility))
    }
    func stop(){monitor?.cancel();monitor=nil;task?.cancel();task=nil;evidence.reset();networkType="unknown";interfaceName=nil;wifiName=nil;pathIdentity="";hasPath=false}
    func reset(){stop();start()}
    private func update(available:Bool){
        // Only the current associated network; never saved networks or a scan.
        wifiName=interfaceName.flatMap{wifi.interface(withName:$0)?.ssid()}
        let identity=pathIdentity+"|"+(wifiName ?? "")
        if evidence.updatePath(available:available,identity:identity,now:Date()){task?.cancel();task=nil}
        checkIfDue()
    }
    private func checkIfDue(){
        guard let token=evidence.beginCheck(now:Date()) else{return}
        let probe=probe
        task=Task{ [weak self] in
            let success=await probe.check()
            guard !Task.isCancelled,let self else{return}
            self.evidence.complete(token,success:success,now:Date());self.task=nil
        }
    }
    func snapshot()->[String:Any]{
        if hasPath,let monitor{update(available:monitor.currentPath.status == .satisfied)}
        return ["internet":evidence.status(at:Date()),"internetCheckedAt":evidence.checkedAt.map(WireJSON.iso) as Any? ?? NSNull(),"networkType":networkType == "none" && wifiName != nil ? "wifi":networkType,"wifiName":wifiName as Any? ?? NSNull()]
    }
}

/// Permission is requested only by the settings button; no location updates run.
@MainActor final class WifiNameAccess:NSObject,ObservableObject,CLLocationManagerDelegate {
    private let manager=CLLocationManager()
    @Published private(set) var status:CLAuthorizationStatus = .notDetermined
    override init(){super.init();manager.delegate=self;status=manager.authorizationStatus}
    var allowed:Bool{status == .authorizedAlways}
    var needsSettings:Bool{status == .denied || status == .restricted}
    func request(){
        if needsSettings{NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)}
        else if status == .notDetermined{manager.requestWhenInUseAuthorization()}
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager:CLLocationManager){Task{@MainActor [weak self] in guard let self else{return};self.status=self.manager.authorizationStatus}}
}
