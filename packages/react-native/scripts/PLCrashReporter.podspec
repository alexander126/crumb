# Mirrors the upstream 1.12.0 binary podspec. The checked release is bundled in
# npm at packaging time; CocoaPods reads it locally and never downloads it.
Pod::Spec.new do |spec|
  spec.cocoapods_version = '>= 1.10'
  spec.name = 'PLCrashReporter'
  spec.version = '1.12.0'
  spec.summary = 'Reliable, open-source crash reporting for iOS, macOS and tvOS.'
  spec.homepage = 'https://github.com/microsoft/plcrashreporter'
  spec.license = { :type => 'MIT', :file => 'LICENSE.txt' }
  spec.authors = { 'Microsoft' => 'appcentersdk@microsoft.com' }
  spec.source = { :http => 'https://github.com/microsoft/plcrashreporter/releases/download/1.12.0/PLCrashReporter-Static-1.12.0.xcframework.zip', :sha256 => '9e7124d63316a5e354fdeec631a3d669b1eaa533d3767a0089a05ab0eedc02b5' }
  spec.resource_bundle = { 'PLCrashReporter' => 'CrashReporter.xcframework/PrivacyInfo.xcprivacy' }
  spec.ios.deployment_target = '12.0'
  spec.osx.deployment_target = '11.5'
  spec.tvos.deployment_target = '12.0'
  spec.vendored_frameworks = 'CrashReporter.xcframework'
  spec.libraries = 'c++'
  spec.pod_target_xcconfig = { 'OTHER_LDFLAGS' => '-lc++' }
end
