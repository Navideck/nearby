Pod::Spec.new do |s|
  s.name = 'nearby'
  s.version = '0.0.1'
  s.summary = 'Nearby peer sessions and connectionless broadcasting for Flutter.'
  s.homepage = 'https://github.com/Navideck/nearby'
  s.license = { :file => '../LICENSE' }
  s.author = 'Navideck'
  s.source = { :path => '.' }
  s.source_files = 'nearby/Sources/nearby/**/*.swift'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '13.1'
  s.osx.deployment_target = '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.9'
end
