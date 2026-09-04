# The SDK version is declared once, in Swift, at Config.currentSDKVersion — the
# same constant the SDK reports in its X-QuickAuth-SDK header. Read it from
# there instead of keeping a second copy here that has to be remembered on every
# release, and fail loudly rather than publishing a pod with no version.
version_source = File.join(File.dirname(__FILE__), 'Sources', 'QuickAuth', 'Core', 'Config.swift')
sdk_version = File.read(version_source)[/currentSDKVersion\s*=\s*"([^"]+)"/, 1]
raise "#{File.basename(__FILE__)}: could not read currentSDKVersion from #{version_source}" if sdk_version.nil?

Pod::Spec.new do |s|
  # Pod name only. The Swift module stays `QuickAuth` (see s.module_name below)
  # so existing integrations keep compiling against `import QuickAuth` — the
  # Podfile line is the only thing that changes for consumers.
  s.name             = 'QuickAuthSDK'
  s.module_name      = 'QuickAuth'
  s.version          = sdk_version
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

  # App Store review requires a privacy manifest from third-party SDKs. It must
  # ship inside a resource bundle so it survives into the integrating app.
  s.resource_bundles = {
    'QuickAuth' => ['Sources/QuickAuth/PrivacyInfo.xcprivacy']
  }

  # CocoaPods addresses a spec by filename: `pod trunk push`, `pod spec lint`
  # and the Specs repo all expect `<s.name>.podspec`. A file whose name has
  # drifted from s.name fails late and confusingly — the Flutter SDK shipped
  # five releases with that mismatch. Fail here instead, at parse time.
  expected_filename = "#{s.name}.podspec"
  actual_filename   = File.basename(__FILE__)
  unless actual_filename == expected_filename
    raise "podspec filename mismatch: s.name is '#{s.name}', so this file must " \
          "be named '#{expected_filename}' (it is '#{actual_filename}'). Rename " \
          "the file or change s.name — CocoaPods resolves the spec by filename."
  end
end
