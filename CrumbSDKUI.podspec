version = File.read(File.expand_path("VERSION", __dir__)).strip

Pod::Spec.new do |spec|
  spec.name = "CrumbSDKUI"
  spec.version = version
  spec.summary = "The native, on-demand issue reporter interface for Crumb"
  spec.description = <<-DESC
    Crumb's UIKit reporter, foreground shake lifecycle, screenshot masking, and
    report-time diagnostics. It stays idle until the reporter is invoked.
  DESC
  spec.homepage = "https://github.com/alexander126/crumb"
  spec.license = { type: "Apache-2.0", file: "LICENSE" }
  spec.authors = "Crumb contributors"
  spec.source = {
    git: "https://github.com/alexander126/crumb.git",
    tag: spec.version.to_s
  }

  spec.ios.deployment_target = "15.0"
  spec.swift_version = "6.0"
  spec.module_name = "CrumbUI"
  spec.source_files = "packages/ios/Sources/CrumbUI/**/*.swift"
  spec.resource_bundles = {
    "CrumbUI" => "packages/ios/Sources/CrumbUI/Resources/**/*"
  }
  spec.dependency "CrumbSDKCore", spec.version.to_s
  spec.frameworks = [
    "CoreMotion",
    "CoreTelephony",
    "CryptoKit",
    "Network",
    "OSLog",
    "UIKit"
  ]
  spec.pod_target_xcconfig = {
    "OTHER_SWIFT_FLAGS" => "$(inherited) -package-name Crumb"
  }
end
