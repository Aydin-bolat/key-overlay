# frozen_string_literal: true

# 材质工坊 (Material Painter) — SketchUp 材质贴图工具
# 注册入口。真正的实现在 material_painter/main.rb
#
# 作者: Aydin Creative AI

require 'sketchup.rb'
require 'extensions.rb'

module AydinCreative
  module MaterialPainter
    PLUGIN_NAME    = '材质工坊'
    PLUGIN_ID      = 'material_painter'
    PLUGIN_VERSION = '1.0.0'

    PATH_ROOT = File.dirname(__FILE__)
    PATH      = File.join(PATH_ROOT, PLUGIN_ID)
    PATH_HTML = File.join(PATH, 'html')

    unless defined?(@extension_registered) && @extension_registered
      loader = File.join(PATH, 'main')
      ext = SketchupExtension.new(PLUGIN_NAME, loader)
      ext.description = '材质贴图工具：导入贴图、旋转/缩放/XY 方向移动、弯曲多面物体共享平面投影贴图、' \
                         '直接在贴图上画笔涂改（可调颜色/透明度），改完立即更新到模型上。'
      ext.version     = PLUGIN_VERSION
      ext.copyright   = "Aydin Creative AI #{Time.now.year}"
      ext.creator     = 'Aydin Creative AI'
      Sketchup.register_extension(ext, true)
      @extension_registered = true
    end
  end
end
