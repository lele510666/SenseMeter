//ContentView.swift
import SwiftUI
import Combine
import CoreMotion
import CoreLocation
import MapKit
import AVFoundation
class MotionManager: ObservableObject {
    private var motionManager = CMMotionManager()
    @Published var gForce: Double = 0.0
    
    func startUpdates(frequency: Double) {
        motionManager.stopAccelerometerUpdates()
        motionManager.accelerometerUpdateInterval = 1.0 / frequency
        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, error in
            guard let data = data, error == nil else { return }
            let ax = data.acceleration.x
            let ay = data.acceleration.y
            let az = data.acceleration.z
            let g = sqrt(ax*ax + ay*ay + az*az)
            DispatchQueue.main.async { self?.gForce = g }
        }
    }
    func stopUpdates() {
        motionManager.stopAccelerometerUpdates()
    }
}
class AltimeterManager: ObservableObject {
    private var altimeter = CMAltimeter()
    @Published var relativeAltitude: Double = 0.0
    @Published var pressure: Double = 0.0
    
    func startUpdates() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            guard let data = data, error == nil else { return }
            DispatchQueue.main.async {
                self?.relativeAltitude = data.relativeAltitude.doubleValue
                self?.pressure = data.pressure.doubleValue * 10.0
            }
        }
    }
    func stopUpdates() {
        altimeter.stopRelativeAltitudeUpdates()
    }
}

// MARK: - GPSManager
class GPSManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    @Published var gpsAltitude: Double = 0.0
    @Published var gpsSpeed: Double = 0.0
    @Published var latitude: Double = 0.0
    @Published var longitude: Double = 0.0
    
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
    }
    func startUpdates() {
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }
    func stopUpdates() {
        locationManager.stopUpdatingLocation()
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        DispatchQueue.main.async {
            self.gpsAltitude = loc.altitude
            self.gpsSpeed = loc.speed >= 0 ? loc.speed : 0
            self.latitude = loc.coordinate.latitude
            self.longitude = loc.coordinate.longitude
        }
    }
    func formatDMS(_ coordinate: Double, isLatitude: Bool) -> String {
        let deg = Int(coordinate)
        let minFloat = abs((coordinate - Double(deg)) * 60)
        let min = Int(minFloat)
        let sec = (minFloat - Double(min)) * 60
        let direction = isLatitude ? (coordinate >= 0 ? "N" : "S") : (coordinate >= 0 ? "E" : "W")
        return String(format: "%d°%02d'%05.2f\"%@", abs(deg), min, sec, direction)
    }
    func formatDecimal(_ coordinate: Double, isLatitude: Bool) -> String {
        let direction = isLatitude ? (coordinate >= 0 ? "N" : "S") : (coordinate >= 0 ? "E" : "W")
        return String(format: "%.5f%@", abs(coordinate), direction)
    }
}

class MagnetometerManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private var motionManager = CMMotionManager()
    private var locationManager = CLLocationManager()
    @Published var magneticField: Double = 0.0   // μT
    @Published var trueHeading: Double = 0.0     
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestWhenInUseAuthorization()
        
        if CLLocationManager.headingAvailable() {
            locationManager.startUpdatingHeading()
        }
        locationManager.startUpdatingLocation()
    }

    func startUpdates(frequency: Double) {
        guard motionManager.isMagnetometerAvailable else { return }
        motionManager.stopMagnetometerUpdates()
        motionManager.magnetometerUpdateInterval = 1.0 / frequency
        motionManager.startMagnetometerUpdates(to: .main) { [weak self] data, error in
            guard let self = self, let data = data, error == nil else { return }
            let x = data.magneticField.x
            let y = data.magneticField.y
            let z = data.magneticField.z
            let magnitude = sqrt(x*x + y*y + z*z)
            let magneticAngle = atan2(y, x) * 180 / .pi
            let magneticHeading = (magneticAngle >= 0 ? magneticAngle : magneticAngle + 360)
            let declination = self.locationManager.heading?.trueHeading ?? 0.0
            var trueHeading = magneticHeading + declination - magneticHeading
            trueHeading = trueHeading >= 0 ? trueHeading : trueHeading + 360
            DispatchQueue.main.async {
                self.magneticField = magnitude
                self.trueHeading = trueHeading
            }
        }
    }
    func stopUpdates() {
        motionManager.stopMagnetometerUpdates()
    }
    // CLLocationManagerDelegate
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        DispatchQueue.main.async {
            self.trueHeading = newHeading.trueHeading
        }
    }
}
class AudioMeterManager: NSObject, ObservableObject {
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    @Published var decibel: Float = 0.0
    func start() {
        AVAudioApplication.requestRecordPermission { granted in
            if granted {
                DispatchQueue.main.async {
                    self.setupSession()
                    self.startRecording()
                }
            }
        }
    }
    private func setupSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord,
                                 mode: .measurement,
                                 options: [.defaultToSpeaker, .mixWithOthers])
        try? session.setActive(true)
    }
    private func startRecording() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sound.caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue
        ]
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.isMeteringEnabled = true
            recorder?.prepareToRecord()
            recorder?.record()
            startTimer()
        } catch {
        }
    }
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            self.recorder?.updateMeters()
            
            let power = self.recorder?.averagePower(forChannel: 0) ?? -160
            self.decibel = self.db(from: power)
        }
    }
    func stop() {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
    }
    private func db(from power: Float) -> Float {
        let minDb: Float = -80
        if power < minDb { return 0 }
        return (power - minDb) * (120 / abs(minDb))
    }
}
struct FeatureItem: Identifiable {
    let id = UUID()
    let icon: String
    let titleKey: String  
}
struct RecordEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let speed: Double
    let altitude: Double
    let latitude: Double
    let longitude: Double
    init(speed: Double, altitude: Double, latitude: Double, longitude: Double) {
        self.id = UUID()
        self.timestamp = Date()
        self.speed = speed
        self.altitude = altitude
        self.latitude = latitude
        self.longitude = longitude
    }
}

struct TripRecord: Identifiable, Codable {
    let id: UUID
    let startTime: Date
    var entries: [RecordEntry]
    var endTime: Date {
        entries.last?.timestamp ?? startTime
    }
    init() {
        self.id = UUID()
        self.startTime = Date()
        self.entries = []
    }
}
struct GForceView: View {
    @StateObject private var motion = MotionManager()
    @AppStorage("threshold") private var threshold: Double = 2.5
    @AppStorage("frequency") private var frequency: Double = 10.0
    @AppStorage("decimalPlaces") private var decimalPlaces: Int = 2
    @AppStorage("showAcceleration") private var showAcceleration: Bool = true
    @State private var showingSettings = false
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(spacing: 20) {
            Text(formattedG(motion.gForce))
                .font(.system(size: decimalPlaces == 4 ? 75 : 90, weight: .bold, design: .rounded))
                .foregroundColor(motion.gForce > threshold ? .red : .blue)
            
            if showAcceleration { 
                Text(String(format: "%.\(decimalPlaces)f m/s²", motion.gForce * 9.80665))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(.green)
            }
        }
            .padding()
            .onAppear { motion.startUpdates(frequency: frequency) }
            .onDisappear { motion.stopUpdates() }
            .onChange(of: frequency) { oldValue, newValue in
                motion.startUpdates(frequency: newValue)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingSettings.toggle() } label: {
                        Image(systemName: "gearshape.fill").font(.title2)
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                VStack(spacing: 30) {
                    Text(
                        String(
                            format: NSLocalizedString("g_threshold_value", comment: ""),
                            threshold
                        )
                    )
                    Slider(value: $threshold, in: 1.01...5.0, step: 0.01)
                    
                    Text(
                        String(
                            format: NSLocalizedString("frequency_value", comment: ""),
                            Int(frequency)
                        )
                    )
                    Slider(value: $frequency, in: 1...60, step: 1)
                    
                    Text(
                        String(
                            format: NSLocalizedString("decimal_places_value", comment: ""),
                            decimalPlaces
                        )
                    )
                    Slider(value: Binding(get: { Double(decimalPlaces) }, set: { decimalPlaces = Int($0) }), in: 0...4, step: 1)
                    Toggle("show_acceleration", isOn: $showAcceleration)
                    Spacer()
                }
                .padding()
            }
    }
    private func formattedG(_ value: Double) -> String {
        String(format: "%.\(decimalPlaces)f G", value)
    }
}

struct AltimeterView: View {
    @StateObject private var altimeter = AltimeterManager()
    @StateObject private var gps = GPSManager()
    @AppStorage("altimeterDecimalPlaces") private var decimalPlaces: Int = 2
    //@AppStorage("calibratedAltitude") private var calibratedAltitude: Double = 0.0
    @AppStorage("altimeterMode") private var mode: Int = 0
    @AppStorage("altimeterDisplayMode") private var displayMode: Int = 0
    @AppStorage("isEnglish") private var isEnglish: Bool = false
    @State private var showingSettings = false
    private var isCJK: Bool {
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        return ["zh"].contains(lang)
    }
    var body: some View {
        VStack {
            Spacer()
            Text(displayValue())
                .font(.system(size: 65, weight: .bold, design: .rounded))
                .foregroundColor(.blue)
                .onTapGesture { displayMode = (displayMode + 1) % 2 }
            Spacer()
            
            HStack {
                 Button(LocalizedStringKey(modeKey())) { mode = (mode + 1) % 3 }
                    .font(isCJK ? .title2 : .title3)
                    .foregroundColor(.white)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 12)
                    .background(Color.green)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .onAppear { altimeter.startUpdates(); gps.startUpdates() }
        .onDisappear { altimeter.stopUpdates(); gps.stopUpdates() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showingSettings.toggle() } label: { Image(systemName: "gearshape.fill").font(.title2) }
            }
        }
        .sheet(isPresented: $showingSettings) {
            VStack(spacing: 30) {
                Text(
                    String(
                        format: NSLocalizedString("altimeter_decimal_places", comment: ""),
                        decimalPlaces
                    )
                )
                Slider(value: Binding(get: { Double(decimalPlaces) }, set: { decimalPlaces = Int($0) }), in: 0...4, step: 1)
                Spacer()
            }.padding()
        }
    }
    
    private func displayValue() -> String {
        if displayMode == 1 { return String(format: "%.\(decimalPlaces)f hPa", altimeter.pressure) }
        switch mode {
        case 0: return String( format: "%.\(decimalPlaces)f m", (44330 * (1 - pow(altimeter.pressure / 1013.25, 1/5.255))) - gps.gpsAltitude)
        case 1: return String(format: "%.\(decimalPlaces)f m", 44330 * (1 - pow(altimeter.pressure / 1013.25, 1/5.255)))
        case 2: return String(format: "%.\(decimalPlaces)f m", gps.gpsAltitude)
        default: return "--"
        }
    }
    
    private func modeKey() -> String {
        switch mode {
        case 0: return "altimeter_mode_relative"
        case 1: return "altimeter_mode_pressure"
        case 2: return "altimeter_mode_gps"
        default: return ""
        }
    }
}
struct RecordButton: View {
    @Binding var isRecording: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    if isRecording {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.red)
                            .frame(width: 30, height: 30)
                    } else {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 33, height: 33)
                    }
                }
                Text(isRecording
                     ? LocalizedStringKey("recording")
                     : LocalizedStringKey("record")
                )
                .foregroundColor(.black)
                .font(.system(size: 16, weight: .medium))
                .lineLimit(1)                         
                .fixedSize(horizontal: true, vertical: false) 
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.gray.opacity(0.4), lineWidth: 1)
            )
        }
    }
}
struct SpeedView: View {
    @StateObject private var gps = GPSManager()
        @AppStorage("speedDecimalPlaces") private var decimalPlaces: Int = 1
        @AppStorage("speedUnitIndex") private var unitIndex: Int = 0
        @AppStorage("latLonFormatDecimal") private var latLonFormatDecimal: Bool = false
        @AppStorage("showLatLonInTrip") private var showLatLonInTrip: Bool = true
        @AppStorage("isEnglish") private var isEnglish: Bool = false

        @State private var showingSettings = false
        @State private var timer: Timer?
        @State private var isRecording = false
        @State private var currentTrip: TripRecord?
        @State private var tripRecords: [TripRecord] = [] {
            didSet { saveTrips() }
        }

        let tripsKey = "savedTrips"
    
    init() {
        if let data = UserDefaults.standard.data(forKey: "savedTrips"),
           let trips = try? JSONDecoder().decode([TripRecord].self, from: data) {
            _tripRecords = State(initialValue: trips)
        }
    }
    
    var body: some View {
        ZStack {
                mainContent
                VStack {
                    Spacer() 
                    HStack {
                        Spacer().frame(width: UIScreen.main.bounds.width / 5) 
                        Button("show_map") {
                            showMap = true
                        }
                        .padding()
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .fixedSize() 
                        Spacer() 
                        recordButton
                        Spacer().frame(width: UIScreen.main.bounds.width / 5) 
                    }
                }
            }
            .onAppear {
                gps.startUpdates()
                startTimer()
            }
            .onDisappear {
                gps.stopUpdates()
                timer?.invalidate()
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingSettings.toggle() } label: {
                        Image(systemName: "gearshape.fill").font(.title2)
                    }
                }
            }
            .sheet(isPresented: $showingSettings) { settingsView }
            .background(
                NavigationLink(
                    destination: MapView(gps: gps),
                    isActive: $showMap 
                ) {
                    EmptyView() 
                }
            )
        }

    @State private var showMap: Bool = false
    private var mainContent: some View {
        VStack(spacing: 15) {
            Spacer()
            Text(displaySpeed())
                .font(.system(size: 78, weight: .bold, design: .rounded))
                .foregroundColor(.blue)
                .onTapGesture { unitIndex = (unitIndex + 1) % 4 }

            VStack(spacing: 10) {
                Text(
                    String(
                        format: NSLocalizedString("unit_altitude_value", comment: ""),
                        gps.gpsAltitude
                    )
                )
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundColor(.blue)

                Text(displayLatLon())
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(.blue)
                    .onTapGesture { latLonFormatDecimal.toggle() }
            }
            Spacer()
        }
    }
    private var recordButton: some View {
        RecordButton(
            isRecording: $isRecording,
            action: {
                toggleRecording()
            }
        )
    }
    
    private var settingsView: some View {
        NavigationView {
            List {
                Section("settings_title") {
                    Text(
                        String(
                            format: NSLocalizedString("decimal_places_value", comment: ""),
                            decimalPlaces
                        )
                    )
                    Slider(value: Binding(get: { Double(decimalPlaces) },
                                          set: { decimalPlaces = Int($0) }),
                           in: 0...4, step: 1)
                }
                Section("trips_title") {
                    if tripRecords.isEmpty {
                        Text("trip_empty")
                    } else {
                        ForEach(tripRecords) { trip in
                            NavigationLink(
                                destination: TripDetailView(
                                    trip: trip,
                                    showLatLon: showLatLonInTrip,
                                    latLonDecimal: latLonFormatDecimal,
                                    onDelete: { deleteTrip(trip) }
                                )
                            ) {
                                VStack(alignment: .leading) {
                                    Text(
                                        String(
                                            format: NSLocalizedString("trip_start", comment: ""),
                                            trip.startTime.formatted(date: .numeric, time: .standard)
                                        )
                                    )
                                    
                                    Text(
                                        String(
                                            format: NSLocalizedString("trip_end", comment: ""),
                                            trip.endTime.formatted(date: .numeric, time: .standard)
                                        )
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("close") { showingSettings = false }
                }
            }
        }
    }
    
    private func displaySpeed() -> String {
        let speedMS = gps.gpsSpeed
        var value: Double
        var unit: String
        switch unitIndex {
            case 0: value = speedMS * 3.6; unit = "km/h"
            case 1: value = speedMS * 2.23694; unit = "mph"
            case 2: value = speedMS; unit = "m/s"
            case 3:
                value = speedMS * 1.94384
                unit = NSLocalizedString("unit_knots", comment: "")
            default: value = speedMS * 3.6; unit = "km/h"
        }
        return String(format: "%.\(decimalPlaces)f %@", value, unit)
    }
    
    private func displayLatLon() -> String {
        if latLonFormatDecimal {
            return "\(gps.formatDecimal(gps.latitude, isLatitude: true)), \(gps.formatDecimal(gps.longitude, isLatitude: false))"
        } else {
            return "\(gps.formatDMS(gps.latitude, isLatitude: true)), \(gps.formatDMS(gps.longitude, isLatitude: false))"
        }
    }
    
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            guard isRecording else { return }
            let entry = RecordEntry(
                speed: gps.gpsSpeed,
                altitude: gps.gpsAltitude,
                latitude: gps.latitude,
                longitude: gps.longitude
            )
            currentTrip?.entries.append(entry)
        }
    }
    private func toggleRecording() {
        if isRecording {
            if let trip = currentTrip, !trip.entries.isEmpty {
                tripRecords.append(trip)
            }
            currentTrip = nil
            isRecording = false
        } else {
            currentTrip = TripRecord()
            isRecording = true
        }
    }
    private func deleteTrip(_ trip: TripRecord) {
        if let index = tripRecords.firstIndex(where: { $0.id == trip.id }) {
            tripRecords.remove(at: index)
        }
    }
    private func saveTrips() {
        if let data = try? JSONEncoder().encode(tripRecords) {
            UserDefaults.standard.set(data, forKey: tripsKey)
        }
    }
}
struct TripDetailView: View {
    let trip: TripRecord
    let showLatLon: Bool
    let latLonDecimal: Bool
    let onDelete: () -> Void
    @AppStorage("isEnglish") private var isEnglish: Bool = false
    var body: some View {
        List {
            ForEach(trip.entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                    if showLatLon {
                        Text("\(String(format: "%.2f", entry.speed*3.6)) \("km/h"), \(String(format: "%.1f", entry.altitude)) \("m"), \(latLonString(lat: entry.latitude, lon: entry.longitude))")
                    } else {
                        Text("\(String(format: "%.2f", entry.speed*3.6)) \("km/h"), \(String(format: "%.1f", entry.altitude)) \("m")")
                    }
                }
                .padding(4)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("clear") { onDelete() }
            }
        }
    }
    
    private func latLonString(lat: Double, lon: Double) -> String {
        if latLonDecimal {
            let latStr = String(format: "%.5f%@", abs(lat), lat>=0 ? ("N"):("S"))
            let lonStr = String(format: "%.5f%@", abs(lon), lon>=0 ? ("E"):("W"))
            return "\(latStr) \(lonStr)"
        } else {
            let latDeg = Int(lat)
            let latMinFloat = abs((lat - Double(latDeg)) * 60)
            let latMin = Int(latMinFloat)
            let latSec = (latMinFloat - Double(latMin)) * 60
            
            let lonDeg = Int(lon)
            let lonMinFloat = abs((lon - Double(lonDeg)) * 60)
            let lonMin = Int(lonMinFloat)
            let lonSec = (lonMinFloat - Double(lonMin)) * 60
            
            let latStr = String(format: "%d°%02d'%05.2f\"%@", abs(latDeg), latMin, latSec, lat>=0 ? ("N"):("S"))
            let lonStr = String(format: "%d°%02d'%05.2f\"%@", abs(lonDeg), lonMin, lonSec, lon>=0 ? ("E"):("W"))
            return "\(latStr) \(lonStr)"
        }
    }
}
struct MapView: View {
    @ObservedObject var gps: GPSManager
    @State private var region: MKCoordinateRegion
    init(gps: GPSManager) {
        self.gps = gps

        _region = State(initialValue: MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: gps.latitude, longitude: gps.longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        ))
    }
    var body: some View {
        Map(coordinateRegion: $region, showsUserLocation: true)
    }
}
class StepManager: ObservableObject {
    private let pedometer = CMPedometer()
    @Published var steps: Int = 0
    @Published var isAvailable = CMPedometer.isStepCountingAvailable()
    private var startDate: Date = Date()
    init() {
        startCounting()
    }
    func startCounting() {
        guard isAvailable else { return }
        startDate = Date()
        pedometer.startUpdates(from: startDate) { [weak self] data, error in
            DispatchQueue.main.async {
                if let stepCount = data?.numberOfSteps.intValue {
                    self?.steps = stepCount
                }
            }
        }
    }
    func resetSteps() {
        pedometer.stopUpdates()
        steps = 0
        startCounting()
    }
}
struct StepView: View {
    @StateObject private var stepManager = StepManager()
    @AppStorage("isEnglish") private var isEnglish: Bool = false
    var body: some View {
        VStack {
            Spacer()   
            if stepManager.isAvailable {
                VStack(spacing: 40) {
                    Text("\(stepManager.steps)")
                        .font(.system(size: 90, weight: .bold))
                        .foregroundColor(.blue)

                    Button(action: {
                        stepManager.resetSteps()
                    }) {
                        Text("step_reset_button")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding()
                            .frame(width: 200)
                            .background(Color.red)
                            .cornerRadius(12)
                    }
                }
            } else {
                Text("step_not_available")
                    .foregroundColor(.gray)
            }
            Spacer()  
        }
        .padding(.horizontal)
    }
}
struct MagnetometerView: View {
    @StateObject private var magnet = MagnetometerManager()
    @AppStorage("magnetDecimalPlaces") private var decimalPlaces: Int = 0
    @AppStorage("magnetFrequency") private var frequency: Double = 10.0

    @State private var showingSettings = false

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 20) {
                Text(String(format: "%.\(decimalPlaces)f µT", magnet.magneticField))
                    .font(.system(size: 70, weight: .bold, design: .rounded))
                    .foregroundColor(.blue)
            }
            .frame(maxWidth: .infinity)   
            .multilineTextAlignment(.center)
            
            Spacer()
        }
        .onAppear { magnet.startUpdates(frequency: frequency) }
        .onDisappear { magnet.stopUpdates() }
        .onChange(of: frequency) { oldValue, newValue in
            magnet.startUpdates(frequency: newValue)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showingSettings.toggle() } label: {
                    Image(systemName: "gearshape.fill").font(.title2)
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            VStack(spacing: 30) {
                Text(String(format: NSLocalizedString("magnetometer_decimal_places", comment: ""), decimalPlaces))
                Slider(
                    value: Binding(get: { Double(decimalPlaces) },
                                   set: { decimalPlaces = Int($0) }),
                    in: 0...4,
                    step: 1
                )
                Text(String(format: NSLocalizedString("magnetometer_frequency", comment: ""), Int(frequency)))
                Slider(value: $frequency, in: 1...60, step: 1)

                Spacer()
            }
            .padding()
        }
    }
}
struct DecibelView: View {
    @StateObject private var audioManager = AudioMeterManager()
    @AppStorage("decibelDecimalPlaces") private var decimalPlaces: Int = 0  // 0~4位
    @State private var showingSettings = false
    var body: some View {
        VStack {
            Spacer()
            Text("\(String(format: "%.\(decimalPlaces)f", audioManager.decibel)) dB")
                .font(.system(size: 82, weight: .bold))
                .foregroundColor(color(for: audioManager.decibel))
                .padding(.top, 9)
            Spacer()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showingSettings.toggle() } label: { Image(systemName: "gearshape.fill").font(.title2) }
            }
        }
        .sheet(isPresented: $showingSettings) {
            VStack(spacing: 30) {
                Text(String(format: NSLocalizedString("decibel_decimal_places", comment: ""), decimalPlaces))
                Slider(
                    value: Binding(get: { Double(decimalPlaces) },
                                   set: { decimalPlaces = Int($0) }),
                    in: 0...4,
                    step: 1
                )
                Spacer()
            }
            .padding()
        }
        .onAppear { audioManager.start() }
        .onDisappear { audioManager.stop() }
    }
    func color(for dB: Float) -> Color {
        switch dB {
        case ..<80: return .green
        case 80..<90: return .yellow
        default: return .red
        }
    }
}
class CompassHeading: NSObject, ObservableObject, CLLocationManagerDelegate {
    var objectWillChange = PassthroughSubject<Void, Never>()
    var degrees: Double = .zero {
        didSet {
            objectWillChange.send()
        }
    }
    private let locationManager: CLLocationManager
    override init() {
        self.locationManager = CLLocationManager()
        super.init()
        self.locationManager.delegate = self
        self.setup()
    }
    private func setup() {
        self.locationManager.requestWhenInUseAuthorization()
        
        if CLLocationManager.headingAvailable() {
            self.locationManager.startUpdatingLocation()
            self.locationManager.startUpdatingHeading()
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        self.degrees = -1 * newHeading.magneticHeading
    }
}

struct Marker: Hashable {
    let degrees: Double
    let label: String
    init(degrees: Double, label: String = "") {
        self.degrees = degrees
        self.label = label
    }
    func degreeText() -> String {
        return String(format: "%.0f", degrees)
    }
    static func markers() -> [Marker] {
        return [
            Marker(degrees: 0, label: "N"),
            Marker(degrees: 30),
            Marker(degrees: 60),
            Marker(degrees: 90, label: "E"),
            Marker(degrees: 120),
            Marker(degrees: 150),
            Marker(degrees: 180, label: "S"),
            Marker(degrees: 210),
            Marker(degrees: 240),
            Marker(degrees: 270, label: "W"),
            Marker(degrees: 300),
            Marker(degrees: 330)
        ]
    }
}

struct CompassMarkerView: View {
    let marker: Marker
    let compassDegrees: Double

    var body: some View {
        VStack {
            Text(marker.degreeText())
                .fontWeight(.light)
                .rotationEffect(textAngle())
            
            Capsule()
                .frame(width: capsuleWidth(),
                       height: capsuleHeight())
                .foregroundColor(capsuleColor())
            
            Text(marker.label)
                .fontWeight(.bold)
                .rotationEffect(textAngle())
                .padding(.bottom, 205)
        }
        .rotationEffect(Angle(degrees: marker.degrees))
    }
    private func capsuleWidth() -> CGFloat {
        marker.degrees == 0 ? 7 : 3
    }
    private func capsuleHeight() -> CGFloat {
        marker.degrees == 0 ? 45 : 30
    }
    private func capsuleColor() -> Color {
        marker.degrees == 0 ? .red : .gray
    }
    private func textAngle() -> Angle {
        Angle(degrees: -compassDegrees - marker.degrees)
    }
}
struct CompassView: View {
    @StateObject private var compassHeading = CompassHeading()

    var body: some View {
        VStack(spacing: 40) {
            Text("\(Int(-compassHeading.degrees))°")
                .font(.system(size: 90, weight: .bold))
                .foregroundColor(.blue)  
                .padding(.top, 70)

            ZStack {
                ForEach(Marker.markers(), id: \.self) { marker in
                    CompassMarkerView(marker: marker, compassDegrees: compassHeading.degrees)
                }
            }
            .frame(width: 340, height: 340)
            .rotationEffect(.degrees(compassHeading.degrees))
            Spacer()
        }
    }
}

struct BottomBarScrollable: View {
    @Binding var selected: Int
    let items: [(String, String)] = [
        ("waveform.path.ecg", "加速度"),
        ("barometer", "气压"),
        ("speedometer", "速度"),
        ("figure.walk", "步数"),
        ("bolt.circle", "磁力计"),
        ("ear", "噪音"),
        ("location.north.fill", "指南针"),
        ("settings", "设置")
    ]
    let features: [FeatureItem]    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 28) {
                ForEach(Array(features.enumerated()), id: \.1.id) { index, item in
                    let title = LocalizedStringKey(item.titleKey)
                    VStack(spacing: 4) {
                        Image(systemName: item.icon)
                            .font(.system(size: 22))
                            .foregroundColor(selected == index ? .blue : .gray)

                        Text(title)
                            .font(.system(size: 13))
                            .foregroundColor(selected == index ? .blue : .gray)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(selected == index ? Color.blue.opacity(0.12) : Color.clear)
                    .cornerRadius(10)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation {
                            selected = index
                        }
                    }
                }
               
                VStack(spacing: 4) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 22))
                        .foregroundColor(selected == features.count ? .blue : .gray)

                    Text(LocalizedStringKey("feature_settings"))
                        .font(.system(size: 13))
                        .foregroundColor(selected == features.count ? .blue : .gray)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(selected == features.count ? Color.blue.opacity(0.12) : Color.clear)
                .cornerRadius(10)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation {
                        selected = features.count   
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 70)
        .background(Color(UIColor.systemBackground))
    }
}
struct SettingsView: View {
    @Binding var features: [FeatureItem]
    var saveOrder: () -> Void
    
    
    enum AppLanguage: String, CaseIterable, Identifiable {
        case system ,  english, french, spanish, german, japanese, chinese
        var id: String { self.rawValue }
        var displayName: LocalizedStringKey {
            switch self {
            case .system:   return LocalizedStringKey("language_system")
            case .english:  return LocalizedStringKey("language_english")
            case .french:   return LocalizedStringKey("language_french")
            case .spanish:  return LocalizedStringKey("language_spanish")
            case .german:   return LocalizedStringKey("language_german")
            case .japanese: return LocalizedStringKey("language_japanese")
            case .chinese:  return LocalizedStringKey("language_chinese")
            }
        }
    }
    enum AppTheme: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }

        var displayName: LocalizedStringKey {
            switch self {
            case .system: return LocalizedStringKey("theme_system")
            case .light:  return LocalizedStringKey("theme_light")
            case .dark:   return LocalizedStringKey("theme_dark")
            }
        }
    }
    @AppStorage("appTheme")
    private var appTheme: String = "system"
    
    @AppStorage("appLanguage")
    private var selectedLanguageRaw: String = AppLanguage.system.rawValue
    private var selectedLanguage: AppLanguage {
        get { AppLanguage(rawValue: selectedLanguageRaw) ?? .english }
        set { selectedLanguageRaw = newValue.rawValue }
    }
    var body: some View {
        List {
            Section(header: Text(LocalizedStringKey("feature_sort_title"))) {
                ForEach(features) { item in
                    HStack {
                        Image(systemName: item.icon)
                            .foregroundColor(.blue)
                        Text(LocalizedStringKey(item.titleKey))
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                .onMove { from, to in
                    features.move(fromOffsets: from, toOffset: to)
                    saveOrder()
                }
            }
            Section(header: Text(LocalizedStringKey("feature_language_title"))) {
                Picker(selection: Binding(
                    get: { selectedLanguageRaw },
                    set: { selectedLanguageRaw = $0 }
                ), label: Text(LocalizedStringKey("feature_select_language"))) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName)
                            .tag(lang.rawValue)
                    }
                }
                .pickerStyle(MenuPickerStyle())
            }
            Section(header: Text(LocalizedStringKey("theme_title"))) {
                Picker(
                    selection: $appTheme,
                    label: Text(LocalizedStringKey("theme_select"))
                ) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.displayName)
                            .tag(theme.rawValue)
                    }
                }
                .pickerStyle(MenuPickerStyle())
            }
        }
        .environment(\.editMode, .constant(.active))
    }
}

struct ContentView: View {
    //@State private var selected: Int = 0
    @AppStorage("appLanguage") private var appLanguage: String = "chinese"
    @AppStorage("lastSelectedTab") private var selected: Int = 0

    @State private var features: [FeatureItem] = [
        FeatureItem(icon: "waveform.path.ecg", titleKey: "feature_gforce"),
        FeatureItem(icon: "barometer", titleKey: "feature_altitude"),
        FeatureItem(icon: "speedometer", titleKey: "feature_speed"),
        FeatureItem(icon: "figure.walk", titleKey: "feature_steps"),
        FeatureItem(icon: "bolt.circle", titleKey: "feature_magnet"),
        FeatureItem(icon: "ear", titleKey: "feature_decibel"),
        FeatureItem(icon: "location.north.fill", titleKey: "feature_compass"),
        //FeatureItem(icon: "gearshape", titleKey: "feature_settings")
    ]

    @AppStorage("featureOrder") private var featureOrderData: Data = Data()
    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selected) {
                ForEach(Array(features.enumerated()), id: \.element.id) { index, item in
                    NavigationView {
                        page(for: item.titleKey)
                    }
                    .tag(index)
                }

                NavigationView {
                    SettingsView(features: $features, saveOrder: { saveOrder() })
                }
                .tag(features.count)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            BottomBarScrollable(selected: $selected, features: features)
        }
        .onAppear {
            loadOrder()
        }
    }

    private func loadOrder() {
        guard let savedKeys = try? JSONDecoder().decode([String].self, from: featureOrderData),
              !savedKeys.isEmpty else { return }
        let dict = Dictionary(uniqueKeysWithValues: features.map { ($0.titleKey, $0) })
        var reordered = savedKeys.compactMap { dict[$0] }
        let remaining = features.filter { item in
            !reordered.contains(where: { $0.titleKey == item.titleKey })
        }
        reordered.append(contentsOf: remaining)
        features = reordered
        if selected >= features.count {
            selected = 0
        }
    }

    private func saveOrder() {
        let keys = features.map { $0.titleKey }
        if let data = try? JSONEncoder().encode(keys) {
            featureOrderData = data
        }
    }

    @ViewBuilder
    func page(for key: String) -> some View {
        switch key {
        case "feature_gforce": GForceView()
        case "feature_altitude": AltimeterView()
        case "feature_speed": SpeedView()
        case "feature_steps": StepView()
        case "feature_magnet": MagnetometerView()
        case "feature_decibel": DecibelView()
        case "feature_compass": CompassView()
        case "feature_settings": SettingsView(features: $features, saveOrder: saveOrder)
        default: Text("?")
        }
    }
}
