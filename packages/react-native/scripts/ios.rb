require 'json'

# Call once inside each application target, before use_react_native!.
def crumb_native_pods!
  package_root = File.expand_path('..', __dir__)
  native_root = File.join(package_root, 'native', 'ios')
  package = JSON.parse(File.read(File.join(package_root, 'package.json')))
  required = [
    'VERSION', 'CrumbSDKCore.podspec', 'CrumbSDKUI.podspec',
    'packages/ios/Sources/CrumbCore/CrumbConfiguration.swift',
    'PLCrashReporter/PLCrashReporter.podspec',
    'PLCrashReporter/CrashReporter.xcframework/Info.plist'
  ]
  unless required.all? { |file| File.file?(File.join(native_root, file)) }
    raise 'Crumb bundled iOS files are missing. Reinstall @crumbsdk/react-native; SDK contributors must run yarn prepare:ios before building.'
  end
  unless File.read(File.join(native_root, 'VERSION')).strip == package.fetch('crumbNativeVersion')
    raise 'Crumb bundled iOS version does not match this npm package. Reinstall @crumbsdk/react-native.'
  end
  pod 'CrumbSDKCore', :path => native_root
  pod 'CrumbSDKUI', :path => native_root
  pod 'PLCrashReporter', :path => File.join(native_root, 'PLCrashReporter')
end
