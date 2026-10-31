platform :ios, '17.0'
target 'MotoNav' do
  # v1.77：黑屏兜底——换高德 2D 地图 SDK（AMap2DMap，OpenGLES 渲染，绕开 3D Metal 渲染不兼容）
  # 官方 pod 源为 http 老链接(a.amap.com) runner 下载超时；改用本地 podspec(_deps/AMap2DMap.podspec)
  # 下载仓库内预打包(_deps/AMap_iOS_2DMap_Lib_v5.6.0.zip)，绕开 trunk 解析与慢源
  pod 'AMapFoundation'
  pod 'AMap2DMap', :podspec => '_deps/AMap2DMap.podspec'
end
