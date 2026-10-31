platform :ios, '17.0'
target 'MotoNav' do
  # v1.77：黑屏兜底——换高德 2D 地图 SDK（AMap2DMap，OpenGLES 渲染，绕开 3D Metal 渲染不兼容）
  # AMap2DMap 官方 pod 源为 http 老链接(a.amap.com)，GitHub runner 下载不稳定超时；改为仓库内预下载包
  pod 'AMapFoundation'
  pod 'AMap2DMap', :http => 'https://raw.githubusercontent.com/kongpeipei/MotoNav-iOS/main/_deps/AMap_iOS_2DMap_Lib_v5.6.0.zip'
end
