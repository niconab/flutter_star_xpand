require 'digest'
require 'fileutils'

# StarIO10 is NOT stored in this repository (Star's licence forbids
# redistribution). It is downloaded from Star's official public GitHub
# repository the first time CocoaPods evaluates this podspec (pod install),
# pinned to a version and verified with SHA-256.
# (A prepare_command would not run, because Flutter plugins are local :path pods.)
STARIO10_VERSION = '2.14.0'
STARIO10_URL     = "https://github.com/star-micronics/StarXpand-SDK-iOS/archive/refs/tags/#{STARIO10_VERSION}.zip"
STARIO10_SHA256  = 'e2fcd1662323170879c6d4605dd959b2ff4714fe878f6ad80d35ac9f90047340'

frameworks_dir = File.join(__dir__, 'flutter_star_prnt_plus', 'Frameworks')
xcframework    = File.join(frameworks_dir, 'StarIO10.xcframework')
stamp          = File.join(frameworks_dir, '.stario10-version')

unless File.directory?(xcframework) && File.exist?(stamp) && File.read(stamp).strip == STARIO10_VERSION
  FileUtils.rm_rf(frameworks_dir)
  FileUtils.mkdir_p(frameworks_dir)
  zip = File.join(frameworks_dir, 'stario10.zip')
  Pod::UI.puts "flutter_star_prnt_plus: downloading StarIO10 #{STARIO10_VERSION} from #{STARIO10_URL}" if defined?(Pod::UI)
  system('curl', '-fsSL', '--retry', '3', '-o', zip, STARIO10_URL) or raise "Failed to download #{STARIO10_URL}"
  actual = Digest::SHA256.file(zip).hexdigest
  raise "StarIO10 checksum mismatch (expected #{STARIO10_SHA256}, got #{actual})" unless actual == STARIO10_SHA256
  system('unzip', '-q', '-o', zip, "StarXpand-SDK-iOS-#{STARIO10_VERSION}/StarIO10.xcframework/*",
         "StarXpand-SDK-iOS-#{STARIO10_VERSION}/LICENSE", '-d', frameworks_dir) or raise 'Failed to unzip StarIO10'
  src = File.join(frameworks_dir, "StarXpand-SDK-iOS-#{STARIO10_VERSION}")
  FileUtils.mv(File.join(src, 'StarIO10.xcframework'), xcframework)
  FileUtils.mv(File.join(src, 'LICENSE'), File.join(frameworks_dir, 'StarIO10-LICENSE.txt'))
  FileUtils.rm_rf([src, zip])
  File.write(stamp, STARIO10_VERSION)
end

Pod::Spec.new do |s|
  s.name             = 'flutter_star_prnt_plus'
  s.version          = '3.0.0'
  s.summary          = 'Star Micronics printers via StarXpand SDK (StarIO10).'
  s.description      = 'Drop-in replacement for flutter_star_prnt_plus built on StarIO10.'
  s.homepage         = 'https://github.com/niconab/flutter_star_xpand'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'niconab' => 'anj@nicon.se' }
  s.source           = { :path => '.' }
  s.source_files     = 'flutter_star_prnt_plus/Sources/flutter_star_prnt_plus/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  # StarIO10 (arm64 device, arm64 + x86_64 simulator; no 32-bit slices).
  s.vendored_frameworks = 'flutter_star_prnt_plus/Frameworks/StarIO10.xcframework'
  s.frameworks       = 'ExternalAccessory', 'CoreBluetooth'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version    = '5.0'
end
