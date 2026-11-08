# Crumb's wrapper for the upstream PLCrashReporter 1.12.0 release binary, raising
# only its declared iOS minimum to Crumb's supported floor.
#
# Upstream declares ios.deployment_target 12.0. Xcode 27 rejects any target
# below 15.0 (Xcode 26.6 still accepts 12.0), so a CocoaPods consumer of
# CrumbSDKCore building with Xcode 27 cannot build the generated
# PLCrashReporter targets. CocoaPods applies a pod's own declared
# minimum even when the Podfile asks for a higher platform, so the floor has to
# be corrected on the dependency itself.
#
# This wrapper keeps the pod name PLCrashReporter so it replaces the upstream pod
# rather than installing a second copy of CrashReporter.xcframework. It fetches
# the same official release archive, pinned by SHA-256, and changes nothing else.
#
# Select it from a Podfile, pinned to the Crumb release tag:
#
#   pod 'PLCrashReporter', :podspec =>
#     'https://raw.githubusercontent.com/alexander126/crumb/<tag>/distribution/cocoapods/PLCrashReporter.podspec'
#
# LICENSE.txt beside this file is PLCrashReporter's own MIT license, copied
# verbatim from the pinned release archive. `pod lib lint` resolves a local
# podspec's license file from the podspec's directory rather than from the
# downloaded source, so the copy has to be here as well as in the archive.
#
# The React Native package ships its own wrapper at
# packages/react-native/scripts/PLCrashReporter.podspec, which reads an
# npm-bundled copy of the framework instead of downloading it. Keep the version
# and SHA-256 identical in both; scripts/verify-native-distribution.mjs enforces
# that against the packaging pin.
Pod::Spec.new do |spec|
  spec.cocoapods_version = '>= 1.10'
  spec.name = 'PLCrashReporter'
  spec.version = '1.12.0'
  spec.summary = 'Reliable, open-source crash reporting for iOS, macOS and tvOS.'
  spec.description = 'Upstream PLCrashReporter release binary, wrapped by Crumb with its supported iOS minimum.'
  spec.homepage = 'https://github.com/microsoft/plcrashreporter'
  spec.license = { :type => 'MIT', :file => 'LICENSE.txt' }
  spec.authors = { 'Microsoft' => 'appcentersdk@microsoft.com' }
  spec.source = {
    :http => 'https://github.com/microsoft/plcrashreporter/releases/download/1.12.0/PLCrashReporter-Static-1.12.0.xcframework.zip',
    :sha256 => '9e7124d63316a5e354fdeec631a3d669b1eaa533d3767a0089a05ab0eedc02b5',
    :flatten => true
  }
  spec.resource_bundle = { 'PLCrashReporter' => 'CrashReporter.xcframework/PrivacyInfo.xcprivacy' }
  spec.ios.deployment_target = '15.0'
  spec.osx.deployment_target = '11.5'
  spec.tvos.deployment_target = '12.0'
  spec.vendored_frameworks = 'CrashReporter.xcframework'
  spec.libraries = 'c++'
  spec.pod_target_xcconfig = { 'OTHER_LDFLAGS' => '-lc++' }
end
