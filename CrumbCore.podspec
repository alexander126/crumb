version = File.read(File.expand_path("VERSION", __dir__)).strip

Pod::Spec.new do |spec|
  spec.name = "CrumbCore"
  spec.version = version
  spec.summary = "Configuration, reports, queues, and upload transport for Crumb"
  spec.description = <<-DESC
    The non-visual Crumb SDK module: configuration, privacy-bounded report
    envelopes, durable local queueing, and reliable report upload.
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
  spec.module_name = "CrumbCore"
  spec.source_files = "packages/ios/Sources/CrumbCore/**/*.swift"
  spec.frameworks = ["CryptoKit"]
  spec.pod_target_xcconfig = {
    "OTHER_SWIFT_FLAGS" => "$(inherited) -package-name Crumb"
  }
end
