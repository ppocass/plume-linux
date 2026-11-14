// swift-tools-version: 6.0
import PackageDescription

// Plume pour Linux — la dictee de Plume portee sous Linux.
//
// Les sources de sources/ viennent du depot Plume (macOS). Elles ne sont pas
// recopiees a la main : portage/linux_port.py documente chaque retouche, et
// portage/README.md dit d'ou vient chaque fichier.
//
// Le mode Swift 5 est celui du Plume d'origine : l'app melange fil audio
// temps reel, tap clavier et concurrence ; le mode strict de Swift 6
// n'apporterait que du bruit ici.
let package = Package(
    name: "PlumeLinux",
    products: [.executable(name: "plume", targets: ["PlumeLinux"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "PlumeLinux",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")],
            path: "sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
