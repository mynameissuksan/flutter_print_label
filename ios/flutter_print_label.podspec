#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_print_label.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_print_label'
  s.version          = '0.1.0'
  s.summary          = 'Bluetooth label printer (TSPL) plugin for Android and iOS.'
  s.description      = <<-DESC
Bluetooth label printer (TSPL) plugin for Android and iOS. Supports budget
Chinese label printers that advertise BLE without a device name.
                       DESC
  s.homepage         = 'https://github.com/adsshortcut/flutter_print_label'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Adsshortcut' => 'adsshortcut.ai@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.frameworks       = 'CoreBluetooth'
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
end
