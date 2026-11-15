require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))
native_version = package.fetch("crumbNativeVersion")

Pod::Spec.new do |spec|
  spec.name = "CrumbReactNative"
  spec.version = package.fetch("version")
  spec.summary = package.fetch("description")
  spec.description = <<-DESC
    A thin React Native Nitro Module over Crumb's native iOS SDK. Reporter UI,
    screenshot masking, diagnostics, storage, and upload remain native.
  DESC
  spec.homepage = package.fetch("homepage")
  spec.license = { type: "Apache-2.0", file: "LICENSE" }
  spec.authors = package.fetch("author")
  spec.source = {
    git: "https://github.com/alexander126/crumb.git",
    tag: spec.version.to_s
  }

  spec.ios.deployment_target = "15.1"
  spec.swift_version = "6.0"
  # The adapter links PLCrashReporter's statically linked binary, which CocoaPods
  # refuses to place beneath a dynamic framework, so `use_frameworks!` must not
  # make this pod dynamic. It has no effect on a static-library application.
  spec.static_framework = true
  spec.module_name = "CrumbReactNative"
  spec.source_files = [
    "ios/**/*.{swift,m,mm}",
    "cpp/**/*.{hpp,cpp}"
  ]
  spec.dependency "CrumbSDKCore", native_version
  spec.dependency "CrumbSDKUI", native_version
  # Thread stacks for an opted-in JavaScript failure, in ios/CrumbNativeStackCapture.swift.
  # crumb_native_pods! resolves this to the copy bundled in the npm package.
  spec.dependency "PLCrashReporter", "1.12.0"
  spec.dependency "React-jsi"
  spec.dependency "React-callinvoker"

  load "nitrogen/generated/ios/CrumbReactNative+autolinking.rb"
  add_nitrogen_files(spec)

  install_modules_dependencies(spec)
end
