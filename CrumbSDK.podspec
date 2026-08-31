version = File.read(File.expand_path("VERSION", __dir__)).strip

Pod::Spec.new do |spec|
  spec.name = "CrumbSDK"
  spec.version = version
  spec.summary = "The complete Crumb native issue-reporting SDK for iOS"
  spec.description = <<-DESC
    Installs the Crumb core and reporter UI modules together. Crumb captures a
    bounded, privacy-safe diagnostic packet only when a user opens the reporter.
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
  spec.dependency "CrumbSDKCore", spec.version.to_s
  spec.dependency "CrumbSDKUI", spec.version.to_s
end
