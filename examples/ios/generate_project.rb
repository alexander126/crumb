# frozen_string_literal: true

require "fileutils"
require "xcodeproj"

root = File.expand_path(__dir__)
project_path = File.join(root, "CrumbDemo.xcodeproj")
FileUtils.rm_rf(project_path)

project = Xcodeproj::Project.new(project_path)
target = project.new_target(:application, "CrumbDemo", :ios, "15.0")
test_target = project.new_target(:ui_test_bundle, "CrumbDemoUITests", :ios, "15.0")

source_group = project.main_group.new_group("CrumbDemo", "CrumbDemo")
source_files = %w[AppDelegate.swift DemoCrumbConfiguration.swift MainViewController.swift].map do |name|
  source_group.new_file(name)
end
target.add_file_references(source_files)
source_group.new_file("Info.plist")

test_group = project.main_group.new_group("CrumbDemoUITests", "CrumbDemoUITests")
test_target.add_file_references([test_group.new_file("CrumbDemoUITests.swift")])
test_target.add_dependency(target)

package_reference = project.new(
  Xcodeproj::Project::Object::XCLocalSwiftPackageReference
)
package_reference.relative_path = "../.."
project.root_object.package_references << package_reference

%w[CrumbCore CrumbUI].each do |product_name|
  dependency = project.new(
    Xcodeproj::Project::Object::XCSwiftPackageProductDependency
  )
  dependency.package = package_reference
  dependency.product_name = product_name
  target.package_product_dependencies << dependency

  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dependency
  target.frameworks_build_phase.files << build_file
end

target.build_configurations.each do |configuration|
  configuration.build_settings["CODE_SIGN_STYLE"] = "Automatic"
  configuration.build_settings["CURRENT_PROJECT_VERSION"] = "1"
  configuration.build_settings["DEVELOPMENT_TEAM"] = ""
  configuration.build_settings["GENERATE_INFOPLIST_FILE"] = "NO"
  configuration.build_settings["INFOPLIST_FILE"] = "CrumbDemo/Info.plist"
  configuration.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "15.0"
  configuration.build_settings["MARKETING_VERSION"] = "0.1.0"
  configuration.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "dev.crumb.nativepoc.ios"
  configuration.build_settings["PRODUCT_NAME"] = "CrumbDemo"
  configuration.build_settings["SWIFT_VERSION"] = "6.0"
  configuration.build_settings["TARGETED_DEVICE_FAMILY"] = "1,2"
end

test_target.build_configurations.each do |configuration|
  configuration.build_settings["CODE_SIGN_STYLE"] = "Automatic"
  configuration.build_settings["DEVELOPMENT_TEAM"] = ""
  configuration.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  configuration.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "15.0"
  configuration.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "dev.crumb.nativepoc.ios.uitests"
  configuration.build_settings["SWIFT_VERSION"] = "6.0"
  configuration.build_settings["TARGETED_DEVICE_FAMILY"] = "1,2"
  configuration.build_settings["TEST_TARGET_NAME"] = "CrumbDemo"
end

project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.add_test_target(test_target)
scheme.save_as(project_path, "CrumbDemo", true)
puts "Generated #{project_path}"
