#!/usr/bin/env swift

import Foundation
import ImageIO

struct Config {
    let inputDirectory: URL
    let outputFile: URL
    let distanceMeters: Double
    let reverseGeocodingEnabled: Bool
    let geocodeDelaySeconds: TimeInterval
    let replaceExisting: Bool
}

struct PhotoRecord: Codable {
    var id: String
    let filename: String
    let relativePath: String
    let sourceDirectory: String?
    let importKey: String?
    let dedupeKey: String?
    let capturedAt: String
    let localDate: String
    let latitude: Double?
    let longitude: Double?
    var clusterId: String?
    var locationLabel: String?
}

struct VisitRecord: Codable {
    let id: String
    let latitude: Double
    let longitude: Double
    let locationLabel: String
    let locality: String?
    let region: String?
    let country: String?
    let countryCode: String?
    let visitCount: Int
    let photoCount: Int
    let firstVisitedAt: String
    let lastVisitedAt: String
    let visitDates: [String]
    let photoIds: [String]
}

struct Summary: Codable {
    let totalPhotos: Int
    let geotaggedPhotos: Int
    let unlocatedPhotos: Int
    let visitAreas: Int
    let countries: [String]
    let years: [Int]
}

struct OutputDocument: Codable {
    let generatedAt: String?
    let sourceDirectory: String?
    let sourceDirectories: [String]?
    let settings: Settings
    let summary: Summary
    let photos: [PhotoRecord]
    let visits: [VisitRecord]
}

struct Settings: Codable {
    let distanceMeters: Double
    let reverseGeocodingEnabled: Bool
    let timezone: String
}

struct GeocodeRecord: Codable {
    let locationLabel: String
    let locality: String?
    let region: String?
    let country: String?
    let countryCode: String?
}

struct Cluster {
    var latitude: Double
    var longitude: Double
    var photoIndices: [Int]
}

private struct NominatimResponse: Decodable {
    let displayName: String?
    let address: NominatimAddress?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case address
    }
}

private struct NominatimAddress: Decodable {
    let city: String?
    let town: String?
    let village: String?
    let municipality: String?
    let suburb: String?
    let county: String?
    let state: String?
    let country: String?
    let countryCode: String?

    enum CodingKeys: String, CodingKey {
        case city
        case town
        case village
        case municipality
        case suburb
        case county
        case state
        case country
        case countryCode = "country_code"
    }
}

private let supportedExtensions: Set<String> = [
    "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff"
]

private let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone.current
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let localDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

private let exifDateFormatters: [DateFormatter] = {
    let formats = [
        "yyyy:MM:dd HH:mm:ss",
        "yyyy:MM:dd HH:mm:ss.SSS",
        "yyyy:MM:dd HH:mm:ssXXXXX",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ssXXXXX"
    ]

    return formats.map { format in
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = format
        return formatter
    }
}()

private func printUsage() {
    let usage = """
    Usage:
      swift scripts/build_trip_data.swift --input /path/to/photos [options]

    Options:
      --input <path>             Directory containing iPhone photo files.
      --output <path>            JSON output path. Default: docs/data/trips.json
      --distance-meters <num>    Merge nearby coordinates into one visit area. Default: 250
      --replace                  Ignore existing JSON and rebuild from only this input directory.
      --no-reverse-geocode       Skip online reverse geocoding and keep coordinate labels only.
      --geocode-delay <seconds>  Delay between reverse geocode requests. Default: 1.1
      --help                     Show this message.
    """

    FileHandle.standardError.write(Data((usage + "\n").utf8))
}

private func parseArguments() -> Config? {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.contains("--help") || arguments.contains("-h") {
        printUsage()
        exit(0)
    }

    var inputPath: String?
    var outputPath = "docs/data/trips.json"
    var distanceMeters = 250.0
    var reverseGeocodingEnabled = true
    var geocodeDelaySeconds = 1.1
    var replaceExisting = false

    var index = 0
    while index < arguments.count {
        let argument = arguments[index]

        switch argument {
        case "--input":
            index += 1
            guard index < arguments.count else {
                print("--input requires a value")
                return nil
            }
            inputPath = arguments[index]
        case "--output":
            index += 1
            guard index < arguments.count else {
                print("--output requires a value")
                return nil
            }
            outputPath = arguments[index]
        case "--distance-meters":
            index += 1
            guard index < arguments.count, let value = Double(arguments[index]) else {
                print("--distance-meters requires a numeric value")
                return nil
            }
            distanceMeters = value
        case "--replace":
            replaceExisting = true
        case "--geocode-delay":
            index += 1
            guard index < arguments.count, let value = Double(arguments[index]) else {
                print("--geocode-delay requires a numeric value")
                return nil
            }
            geocodeDelaySeconds = value
        case "--no-reverse-geocode":
            reverseGeocodingEnabled = false
        default:
            print("Unknown argument: \(argument)")
            return nil
        }

        index += 1
    }

    guard let inputPath else {
        printUsage()
        return nil
    }

    let inputDirectory = URL(fileURLWithPath: inputPath, isDirectory: true).standardizedFileURL
    let outputFile = URL(fileURLWithPath: outputPath).standardizedFileURL

    return Config(
        inputDirectory: inputDirectory,
        outputFile: outputFile,
        distanceMeters: distanceMeters,
        reverseGeocodingEnabled: reverseGeocodingEnabled,
        geocodeDelaySeconds: geocodeDelaySeconds,
        replaceExisting: replaceExisting
    )
}

private func stableId(for text: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash &*= 0x100000001b3
    }
    return String(hash, radix: 16)
}

private func roundedCoordinateComponent(_ value: Double?) -> String {
    guard let value else {
        return "na"
    }

    return String(format: "%.5f", value)
}

private func buildImportKey(sourceDirectory: String, relativePath: String) -> String {
    stableId(for: "\(sourceDirectory)::\(relativePath)")
}

private func buildDedupeKey(filename: String, capturedAt: String, latitude: Double?, longitude: Double?) -> String {
    stableId(
        for: [
            filename.lowercased(),
            capturedAt,
            roundedCoordinateComponent(latitude),
            roundedCoordinateComponent(longitude)
        ].joined(separator: "::")
    )
}

private func buildPhotoId(importKey: String, dedupeKey: String) -> String {
    "photo-\(String(stableId(for: "\(importKey)::\(dedupeKey)").prefix(16)))"
}

private func discoverImageFiles(in directory: URL) -> [URL] {
    let fileManager = FileManager.default
    guard let enumerator = fileManager.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
        return []
    }

    var files: [URL] = []
    for case let url as URL in enumerator {
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
            continue
        }

        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        if values?.isRegularFile == true {
            files.append(url)
        }
    }

    return files.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
}

private func parseExifDate(_ rawValue: Any?) -> Date? {
    guard let value = rawValue else {
        return nil
    }

    if let date = value as? Date {
        return date
    }

    let stringValue: String
    if let string = value as? String {
        stringValue = string
    } else {
        stringValue = String(describing: value)
    }

    for formatter in exifDateFormatters {
        if let date = formatter.date(from: stringValue) {
            return date
        }
    }

    return isoFormatter.date(from: stringValue)
}

private func parseCoordinate(value: Any?, ref: Any?) -> Double? {
    guard let value else {
        return nil
    }

    let baseValue: Double?
    if let number = value as? NSNumber {
        baseValue = number.doubleValue
    } else if let string = value as? String {
        baseValue = Double(string)
    } else {
        baseValue = Double(String(describing: value))
    }

    guard var coordinate = baseValue else {
        return nil
    }

    if let direction = ref as? String {
        let upper = direction.uppercased()
        if upper == "S" || upper == "W" {
            coordinate *= -1
        }
    }

    return coordinate
}

private func relativePath(for fileURL: URL, baseDirectory: URL) -> String {
    let path = fileURL.path
    let basePath = baseDirectory.path

    if path == basePath {
        return fileURL.lastPathComponent
    }

    if path.hasPrefix(basePath + "/") {
        return String(path.dropFirst(basePath.count + 1))
    }

    return fileURL.lastPathComponent
}

private func fallbackFileDate(for fileURL: URL) -> Date? {
    let fileManager = FileManager.default
    guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path) else {
        return nil
    }

    return (attributes[.creationDate] as? Date) ?? (attributes[.modificationDate] as? Date)
}

private func readPhotoRecord(from fileURL: URL, baseDirectory: URL) -> PhotoRecord? {
    guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
        return nil
    }

    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
    let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]

    let capturedDate =
        parseExifDate(exif?[kCGImagePropertyExifDateTimeOriginal]) ??
        parseExifDate(exif?[kCGImagePropertyExifDateTimeDigitized]) ??
        parseExifDate(tiff?[kCGImagePropertyTIFFDateTime]) ??
        fallbackFileDate(for: fileURL) ??
        Date()

    let latitude = parseCoordinate(
        value: gps?[kCGImagePropertyGPSLatitude],
        ref: gps?[kCGImagePropertyGPSLatitudeRef]
    )
    let longitude = parseCoordinate(
        value: gps?[kCGImagePropertyGPSLongitude],
        ref: gps?[kCGImagePropertyGPSLongitudeRef]
    )

    let relative = relativePath(for: fileURL, baseDirectory: baseDirectory)
    let sourceDirectory = baseDirectory.path
    let importKey = buildImportKey(sourceDirectory: sourceDirectory, relativePath: relative)
    let dedupeKey = buildDedupeKey(
        filename: fileURL.lastPathComponent,
        capturedAt: isoFormatter.string(from: capturedDate),
        latitude: latitude,
        longitude: longitude
    )

    return PhotoRecord(
        id: buildPhotoId(importKey: importKey, dedupeKey: dedupeKey),
        filename: fileURL.lastPathComponent,
        relativePath: relative,
        sourceDirectory: sourceDirectory,
        importKey: importKey,
        dedupeKey: dedupeKey,
        capturedAt: isoFormatter.string(from: capturedDate),
        localDate: localDateFormatter.string(from: capturedDate),
        latitude: latitude,
        longitude: longitude,
        clusterId: nil,
        locationLabel: nil
    )
}

private func degreesToRadians(_ value: Double) -> Double {
    value * .pi / 180
}

private func haversineDistanceMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
    let earthRadius = 6_371_000.0
    let deltaLat = degreesToRadians(lat2 - lat1)
    let deltaLon = degreesToRadians(lon2 - lon1)
    let a =
        pow(sin(deltaLat / 2), 2) +
        cos(degreesToRadians(lat1)) *
        cos(degreesToRadians(lat2)) *
        pow(sin(deltaLon / 2), 2)

    let c = 2 * atan2(sqrt(a), sqrt(1 - a))
    return earthRadius * c
}

private func formatCoordinateLabel(latitude: Double, longitude: Double) -> String {
    String(format: "%.4f, %.4f", latitude, longitude)
}

private func cacheKey(latitude: Double, longitude: Double) -> String {
    String(format: "%.4f,%.4f", latitude, longitude)
}

private func parseCacheKey(_ key: String) -> (latitude: Double, longitude: Double)? {
    let parts = key.split(separator: ",", maxSplits: 1).map(String.init)
    guard parts.count == 2,
          let latitude = Double(parts[0]),
          let longitude = Double(parts[1]) else {
        return nil
    }

    return (latitude, longitude)
}

private func loadGeocodeCache(from path: URL) -> [String: GeocodeRecord] {
    guard let data = try? Data(contentsOf: path) else {
        return [:]
    }

    return (try? JSONDecoder().decode([String: GeocodeRecord].self, from: data)) ?? [:]
}

private func writeGeocodeCache(_ cache: [String: GeocodeRecord], to path: URL) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    guard let data = try? encoder.encode(cache) else {
        return
    }

    try? data.write(to: path, options: .atomic)
}

private func mergeVisitCache(from document: OutputDocument?, into cache: inout [String: GeocodeRecord]) {
    guard let document else {
        return
    }

    for visit in document.visits {
        let key = cacheKey(latitude: visit.latitude, longitude: visit.longitude)
        if cache[key] != nil {
            continue
        }

        cache[key] = GeocodeRecord(
            locationLabel: visit.locationLabel,
            locality: visit.locality,
            region: visit.region,
            country: visit.country,
            countryCode: visit.countryCode
        )
    }
}

private func cachedGeocode(
    latitude: Double,
    longitude: Double,
    distanceMeters: Double,
    cache: [String: GeocodeRecord]
) -> GeocodeRecord? {
    let exactKey = cacheKey(latitude: latitude, longitude: longitude)
    if let exact = cache[exactKey] {
        return exact
    }

    var bestMatch: GeocodeRecord?
    var bestDistance = Double.greatestFiniteMagnitude

    for (key, record) in cache {
        guard let coordinates = parseCacheKey(key) else {
            continue
        }

        let distance = haversineDistanceMeters(
            lat1: latitude,
            lon1: longitude,
            lat2: coordinates.latitude,
            lon2: coordinates.longitude
        )

        if distance <= distanceMeters && distance < bestDistance {
            bestDistance = distance
            bestMatch = record
        }
    }

    return bestMatch
}

private func firstNonEmpty(_ values: [String?]) -> String? {
    values.first { value in
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !trimmed.isEmpty
    } ?? nil
}

private func geocodeLocationLabel(from response: NominatimResponse) -> GeocodeRecord? {
    let locality = firstNonEmpty([
        response.address?.city,
        response.address?.town,
        response.address?.village,
        response.address?.municipality,
        response.address?.suburb,
        response.address?.county
    ])

    let region = response.address?.state
    let country = response.address?.country

    var parts: [String] = []
    for value in [locality, region, country] {
        guard let value else { continue }
        if !parts.contains(value) {
            parts.append(value)
        }
    }

    let label = parts.isEmpty ? response.displayName : parts.joined(separator: ", ")
    guard let locationLabel = label, !locationLabel.isEmpty else {
        return nil
    }

    return GeocodeRecord(
        locationLabel: locationLabel,
        locality: locality,
        region: region,
        country: country,
        countryCode: response.address?.countryCode
    )
}

private func reverseGeocode(latitude: Double, longitude: Double) -> GeocodeRecord? {
    var components = URLComponents(string: "https://nominatim.openstreetmap.org/reverse")
    components?.queryItems = [
        URLQueryItem(name: "format", value: "jsonv2"),
        URLQueryItem(name: "lat", value: String(latitude)),
        URLQueryItem(name: "lon", value: String(longitude)),
        URLQueryItem(name: "zoom", value: "10"),
        URLQueryItem(name: "addressdetails", value: "1")
    ]

    guard let url = components?.url else {
        return nil
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 20
    request.setValue("whereIhaveBeen/1.0 (personal travel map)", forHTTPHeaderField: "User-Agent")

    let semaphore = DispatchSemaphore(value: 0)
    var geocode: GeocodeRecord?

    let task = URLSession.shared.dataTask(with: request) { data, _, _ in
        defer { semaphore.signal() }

        guard let data,
              let response = try? JSONDecoder().decode(NominatimResponse.self, from: data) else {
            return
        }

        geocode = geocodeLocationLabel(from: response)
    }

    task.resume()
    _ = semaphore.wait(timeout: .now() + 25)
    return geocode
}

private func buildClusters(from photos: [PhotoRecord], distanceMeters: Double) -> [Cluster] {
    var clusters: [Cluster] = []

    for (index, photo) in photos.enumerated() {
        guard let latitude = photo.latitude, let longitude = photo.longitude else {
            continue
        }

        var bestClusterIndex: Int?
        var bestDistance = Double.greatestFiniteMagnitude

        for (clusterIndex, cluster) in clusters.enumerated() {
            let distance = haversineDistanceMeters(
                lat1: latitude,
                lon1: longitude,
                lat2: cluster.latitude,
                lon2: cluster.longitude
            )

            if distance <= distanceMeters && distance < bestDistance {
                bestDistance = distance
                bestClusterIndex = clusterIndex
            }
        }

        if let clusterIndex = bestClusterIndex {
            let memberCount = Double(clusters[clusterIndex].photoIndices.count)
            clusters[clusterIndex].latitude = ((clusters[clusterIndex].latitude * memberCount) + latitude) / (memberCount + 1)
            clusters[clusterIndex].longitude = ((clusters[clusterIndex].longitude * memberCount) + longitude) / (memberCount + 1)
            clusters[clusterIndex].photoIndices.append(index)
        } else {
            clusters.append(Cluster(latitude: latitude, longitude: longitude, photoIndices: [index]))
        }
    }

    return clusters
}

private func visitId(for memberPhotoIds: [String]) -> String {
    let hash = stableId(for: memberPhotoIds.sorted().joined(separator: "|"))
    return "visit-\(String(hash.prefix(10)))"
}

private func ensureParentDirectory(for fileURL: URL) {
    let directory = fileURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}

private func loadExistingOutput(from path: URL) -> OutputDocument? {
    guard let data = try? Data(contentsOf: path), !data.isEmpty else {
        return nil
    }

    return try? JSONDecoder().decode(OutputDocument.self, from: data)
}

private func normalisedExistingPhoto(_ photo: PhotoRecord, document: OutputDocument) -> PhotoRecord {
    let sourceDirectory = photo.sourceDirectory ?? document.sourceDirectory
    let importKey = photo.importKey ?? sourceDirectory.map {
        buildImportKey(sourceDirectory: $0, relativePath: photo.relativePath)
    }
    let dedupeKey = photo.dedupeKey ?? buildDedupeKey(
        filename: photo.filename,
        capturedAt: photo.capturedAt,
        latitude: photo.latitude,
        longitude: photo.longitude
    )

    return PhotoRecord(
        id: photo.id.isEmpty
            ? buildPhotoId(importKey: importKey ?? stableId(for: photo.relativePath), dedupeKey: dedupeKey)
            : photo.id,
        filename: photo.filename,
        relativePath: photo.relativePath,
        sourceDirectory: sourceDirectory,
        importKey: importKey,
        dedupeKey: dedupeKey,
        capturedAt: photo.capturedAt,
        localDate: photo.localDate,
        latitude: photo.latitude,
        longitude: photo.longitude,
        clusterId: nil,
        locationLabel: nil
    )
}

private func clearComputedFields(from photos: [PhotoRecord]) -> [PhotoRecord] {
    photos.map { photo in
        var cleaned = photo
        cleaned.clusterId = nil
        cleaned.locationLabel = nil
        return cleaned
    }
}

private func mergePhotos(existing: [PhotoRecord], incoming: [PhotoRecord]) -> (photos: [PhotoRecord], inserted: Int, updated: Int) {
    var photosById: [String: PhotoRecord] = [:]
    var orderedIds: [String] = []
    var orderedIdSet: Set<String> = []
    var importIndex: [String: String] = [:]
    var dedupeIndex: [String: String] = [:]

    func register(_ photo: PhotoRecord) {
        photosById[photo.id] = photo
        if !orderedIdSet.contains(photo.id) {
            orderedIds.append(photo.id)
            orderedIdSet.insert(photo.id)
        }
        if let importKey = photo.importKey {
            importIndex[importKey] = photo.id
        }
        if let dedupeKey = photo.dedupeKey {
            dedupeIndex[dedupeKey] = photo.id
        }
    }

    for photo in existing {
        register(photo)
    }

    var inserted = 0
    var updated = 0

    for incomingPhoto in incoming {
        let matchedId =
            incomingPhoto.importKey.flatMap { importIndex[$0] } ??
            incomingPhoto.dedupeKey.flatMap { dedupeIndex[$0] }

        if let matchedId {
            var replacement = incomingPhoto
            replacement.id = matchedId
            photosById[matchedId] = replacement
            if let importKey = replacement.importKey {
                importIndex[importKey] = matchedId
            }
            if let dedupeKey = replacement.dedupeKey {
                dedupeIndex[dedupeKey] = matchedId
            }
            updated += 1
        } else {
            register(incomingPhoto)
            inserted += 1
        }
    }

    let merged = orderedIds.compactMap { photosById[$0] }
    return (merged, inserted, updated)
}

guard let config = parseArguments() else {
    exit(1)
}

var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: config.inputDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
    FileHandle.standardError.write(Data("Input directory not found: \(config.inputDirectory.path)\n".utf8))
    exit(1)
}

let files = discoverImageFiles(in: config.inputDirectory)
let scannedPhotos = files.compactMap { readPhotoRecord(from: $0, baseDirectory: config.inputDirectory) }
let existingOutput = config.replaceExisting ? nil : loadExistingOutput(from: config.outputFile)
let existingPhotos = clearComputedFields(
    from: (existingOutput?.photos ?? []).map { photo in
        guard let existingOutput else {
            return photo
        }
        return normalisedExistingPhoto(photo, document: existingOutput)
    }
)
let mergeResult = mergePhotos(existing: existingPhotos, incoming: scannedPhotos)
var photos = clearComputedFields(from: mergeResult.photos)
photos.sort {
    if $0.capturedAt == $1.capturedAt {
        return $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending
    }
    return $0.capturedAt < $1.capturedAt
}

let clusters = buildClusters(from: photos, distanceMeters: config.distanceMeters)
let geocodeCachePath = config.outputFile.deletingLastPathComponent().appendingPathComponent("geocode-cache.json")
var geocodeCache = loadGeocodeCache(from: geocodeCachePath)
mergeVisitCache(from: existingOutput, into: &geocodeCache)
var visits: [VisitRecord] = []

for cluster in clusters {
    let memberIndices = cluster.photoIndices.sorted {
        photos[$0].capturedAt < photos[$1].capturedAt
    }
    let memberPhotoIds = memberIndices.map { photos[$0].id }
    let id = visitId(for: memberPhotoIds)

    let geocodeKey = cacheKey(latitude: cluster.latitude, longitude: cluster.longitude)
    var geocode = cachedGeocode(
        latitude: cluster.latitude,
        longitude: cluster.longitude,
        distanceMeters: config.distanceMeters,
        cache: geocodeCache
    )
    if let geocode, geocodeCache[geocodeKey] == nil {
        geocodeCache[geocodeKey] = geocode
    }

    if geocode == nil && config.reverseGeocodingEnabled {
        geocode = reverseGeocode(latitude: cluster.latitude, longitude: cluster.longitude)
        if let geocode {
            geocodeCache[geocodeKey] = geocode
        }
        Thread.sleep(forTimeInterval: config.geocodeDelaySeconds)
    }

    let locationLabel = geocode?.locationLabel ?? formatCoordinateLabel(latitude: cluster.latitude, longitude: cluster.longitude)

    for index in memberIndices {
        photos[index].clusterId = id
        photos[index].locationLabel = locationLabel
    }

    let visitDates = Array(Set(memberIndices.map { photos[$0].localDate })).sorted()
    guard let firstIndex = memberIndices.first, let lastIndex = memberIndices.last else {
        continue
    }

    visits.append(
        VisitRecord(
            id: id,
            latitude: cluster.latitude,
            longitude: cluster.longitude,
            locationLabel: locationLabel,
            locality: geocode?.locality,
            region: geocode?.region,
            country: geocode?.country,
            countryCode: geocode?.countryCode,
            visitCount: visitDates.count,
            photoCount: memberIndices.count,
            firstVisitedAt: photos[firstIndex].capturedAt,
            lastVisitedAt: photos[lastIndex].capturedAt,
            visitDates: visitDates,
            photoIds: memberPhotoIds
        )
    )
}

visits.sort {
    if $0.lastVisitedAt == $1.lastVisitedAt {
        return $0.locationLabel.localizedCaseInsensitiveCompare($1.locationLabel) == .orderedAscending
    }
    return $0.lastVisitedAt > $1.lastVisitedAt
}

let years = Array(
    Set(
        photos.compactMap { photo in
            Int(photo.localDate.prefix(4))
        }
    )
).sorted()

let countries = Array(
    Set(
        visits.compactMap(\.country).filter { !$0.isEmpty }
    )
).sorted()

let geotaggedPhotos = photos.filter { $0.latitude != nil && $0.longitude != nil }.count

let output = OutputDocument(
    generatedAt: isoFormatter.string(from: Date()),
    sourceDirectory: config.inputDirectory.path,
    sourceDirectories: Array(
        Set(
            photos.compactMap(\.sourceDirectory).filter { !$0.isEmpty }
        )
    ).sorted(),
    settings: Settings(
        distanceMeters: config.distanceMeters,
        reverseGeocodingEnabled: config.reverseGeocodingEnabled,
        timezone: TimeZone.current.identifier
    ),
    summary: Summary(
        totalPhotos: photos.count,
        geotaggedPhotos: geotaggedPhotos,
        unlocatedPhotos: photos.count - geotaggedPhotos,
        visitAreas: visits.count,
        countries: countries,
        years: years
    ),
    photos: photos,
    visits: visits
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
guard let outputData = try? encoder.encode(output) else {
    FileHandle.standardError.write(Data("Failed to encode JSON output.\n".utf8))
    exit(1)
}

ensureParentDirectory(for: config.outputFile)
do {
    try outputData.write(to: config.outputFile, options: .atomic)
    writeGeocodeCache(geocodeCache, to: geocodeCachePath)
    let mode = config.replaceExisting ? "replace" : "upsert"
    print(
        "Wrote \(photos.count) photos and \(visits.count) visit areas to \(config.outputFile.path) " +
        "[mode: \(mode), scanned: \(scannedPhotos.count), inserted: \(mergeResult.inserted), updated: \(mergeResult.updated)]"
    )
} catch {
    FileHandle.standardError.write(Data("Failed to write output: \(error.localizedDescription)\n".utf8))
    exit(1)
}
