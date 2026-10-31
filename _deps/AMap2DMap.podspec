# v1.77：高德 2D 地图 SDK 本地 podspec
# 官方 pod 源为 http 老链接(a.amap.com)，GitHub runner 下载超时；
# 改为仓库内预下载包(_deps/AMap_iOS_2DMap_Lib_v5.6.0.zip) + 本地 podspec，绕开 trunk 解析与慢源。
Pod::Spec.new do |s|
  s.name         = 'AMap2DMap'
  s.version      = '5.6.1'
  s.summary      = 'AMap 2D Map SDK for iOS (v1.77 兜底: OpenGLES 渲染, 绕开 3D Metal 不兼容)'
  s.description  = '高德 2D 地图 SDK 5.6.1，MAMapKit.framework（静态），配合 MAMapView 使用。'
  s.homepage     = 'https://lbs.amap.com'
  s.license      = { :type => 'Copyright', :text => 'Copyright AMap' }
  s.author       = { 'AMap' => 'support@amap.com' }
  s.platform     = :ios, '7.0'
  s.source       = { :http => 'https://raw.githubusercontent.com/kongpeipei/MotoNav-iOS/main/_deps/AMap_iOS_2DMap_Lib_v5.6.0.zip' }
  s.vendored_frameworks = 'MAMapKit.framework'
  s.frameworks = ['CoreTelephony', 'SystemConfiguration', 'CoreLocation', 'Security', 'GLKit', 'OpenGLES', 'CoreText', 'QuartzCore', 'CoreGraphics']
  s.libraries   = ['z', 'c++']
  s.dependency 'AMapFoundation'
end
