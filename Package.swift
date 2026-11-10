// swift-tools-version: 6.0

import Foundation
import PackageDescription

extension Dictionary where Key == String, Value == String {
    func nonEmptyValue(_ key: String) -> String? {
        guard let value = self[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }

        return value
    }
}

func appendingPath(_ component: String, to directory: String) -> String {
    URL(fileURLWithPath: directory).appendingPathComponent(component).path
}

func splitConfigurationList(_ value: String) -> [String] {
    value
        .split { character in
            character == "," || character == ";" || character.isWhitespace
        }
        .map(String.init)
}

func staticLibraryFileName(for library: String) -> String {
    if library.hasSuffix(".a") {
        return library
    }

    if library.hasPrefix("lib") {
        return "\(library).a"
    }

    return "lib\(library).a"
}

struct FFmpegConfiguration {
    private static let defaultLibraries = [
        "avformat",
        "avcodec",
        "swresample",
        "avutil"
    ]

    private static let defaultStaticLinkerFlags = [
        "-lz",
        "-lbz2",
        "-liconv",
        "-framework", "AudioToolbox",
        "-framework", "CoreFoundation",
        "-framework", "CoreMedia",
        "-framework", "CoreVideo",
        "-framework", "Security",
        "-framework", "VideoToolbox"
    ]

    let rootDirectory: String?
    let includeDirectory: String?
    let libraryDirectory: String?
    let libraries: [String]
    let extraLinkerFlags: [String]

    init(environment: [String: String]) {
        rootDirectory = environment.nonEmptyValue("FENGLU_FFMPEG_DIR")

        includeDirectory = environment.nonEmptyValue("FENGLU_FFMPEG_INCLUDE_DIR")
            ?? rootDirectory.map { appendingPath("include", to: $0) }

        libraryDirectory = environment.nonEmptyValue("FENGLU_FFMPEG_LIB_DIR")
            ?? rootDirectory.map { appendingPath("lib", to: $0) }

        let configuredLibraries = environment.nonEmptyValue("FENGLU_FFMPEG_LIBS")
            .map(splitConfigurationList)
            ?? []
        libraries = configuredLibraries.isEmpty ? Self.defaultLibraries : configuredLibraries

        extraLinkerFlags = environment.nonEmptyValue("FENGLU_FFMPEG_EXTRA_LINKER_FLAGS")
            .map { $0.split(separator: ";").map(String.init) }
            ?? []
    }

    var usesStaticFFmpeg: Bool {
        libraryDirectory != nil
    }

    var cSettings: [CSetting] {
        guard let includeDirectory else {
            return []
        }

        return [
            .unsafeFlags(["-I", includeDirectory])
        ]
    }

    var linkerSettings: [LinkerSetting] {
        guard let libraryDirectory else {
            return []
        }

        let staticLibraryPaths = libraries.map { library in
            appendingPath(staticLibraryFileName(for: library), to: libraryDirectory)
        }

        return [
            .unsafeFlags(staticLibraryPaths + extraLinkerFlags + Self.defaultStaticLinkerFlags)
        ]
    }

    var cFFmpegTarget: Target {
        if usesStaticFFmpeg {
            return .target(
                name: "CFFmpeg",
                path: "Sources/CFFmpegStatic",
                publicHeadersPath: "include",
                cSettings: cSettings,
                linkerSettings: linkerSettings
            )
        }

        return .systemLibrary(
            name: "CFFmpeg",
            pkgConfig: "libavformat",
            providers: [
                .brew(["ffmpeg"]),
                .apt([
                    "libavformat-dev",
                    "libavcodec-dev",
                    "libavutil-dev",
                    "libswresample-dev"
                ])
            ]
        )
    }
}

let ffmpegConfiguration = FFmpegConfiguration(environment: ProcessInfo.processInfo.environment)

let package = Package(
    name: "FengluPlayer",
    platforms: [
        // Keep in sync with MIN_SYSTEM_VERSION in script/build_and_run.sh.
        .macOS("15.7")
    ],
    products: [
        .executable(name: "FengluPlayer", targets: ["FengluPlayer"])
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.14.3")
    ],
    targets: [
        ffmpegConfiguration.cFFmpegTarget,
        .target(
            name: "FengluFFmpeg",
            dependencies: ["CFFmpeg"],
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-Wno-deprecated-declarations"])
            ] + ffmpegConfiguration.cSettings
        ),
        .executableTarget(
            name: "FengluPlayer",
            dependencies: ["FengluFFmpeg", "SwiftSoup"]
        ),
        .testTarget(
            name: "FengluPlayerTests",
            dependencies: ["FengluPlayer"],
            resources: [.copy("Fixtures")]
        )
    ]
)
