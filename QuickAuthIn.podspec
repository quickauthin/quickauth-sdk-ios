Pod::Spec.new do |s|
  s.name             = 'QuickAuthIn'
  s.module_name      = 'QuickAuth'
  s.version          = '0.1.0'
  s.summary          = 'QuickAuth iOS SDK — Phone OTP + WhatsApp marketing attribution.'
  s.description      = <<-DESC
QuickAuth iOS SDK provides drop-in phone OTP authentication (SMS or WhatsApp),
SMS auto-fill via the system one-time-code keyboard suggestion, "Login with
WhatsApp" via wa.me Universal Link, and marketing attribution + conversion
tracking. Ships with both headless APIs and pre-built SwiftUI/UIKit components.
                       DESC

  s.homepage         = 'https://quickauth.in'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'QuickAuth' => 'contact@quickauth.in' }
  s.source           = { :git => 'https://github.com/quickauthin/quickauth-sdk-ios.git', :tag => "v#{s.version}" }

  s.ios.deployment_target = '14.0'
  s.swift_version         = '5.9'

  s.source_files = 'Sources/QuickAuth/**/*.swift'
  s.frameworks   = 'Foundation', 'UIKit', 'SwiftUI', 'Combine'
end
