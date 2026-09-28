# frozen_string_literal: true

# AI 渲染工作室 (AI Render Studio) — SketchUp 超写实 AI 渲染插件
# 注册入口。真正的实现在 ai_render_studio/main.rb
#
# 作者: Aydin Creative AI
# 后端: 本地 ComfyUI —— Flux.2 Klein 9B 图像编辑；渲染前从 SketchUp 提取视角里每个物体的
#       形状/位置/尺寸/颜色/材质 + 真实 3D 深度图/法线图一起交给模型，防止变形

require 'sketchup.rb'
require 'extensions.rb'

module AydinCreative
  module AiRenderStudio
    PLUGIN_NAME    = 'AI 渲染工作室'
    PLUGIN_ID      = 'ai_render_studio'
    PLUGIN_VERSION = '0.2.0'

    PATH_ROOT = File.dirname(__FILE__)
    PATH      = File.join(PATH_ROOT, PLUGIN_ID)
    PATH_HTML = File.join(PATH, 'html')

    unless defined?(@extension_registered) && @extension_registered
      loader = File.join(PATH, 'main')
      ext = SketchupExtension.new(PLUGIN_NAME, loader)
      ext.description = 'SketchUp 一键 AI 照片级渲染（本地 ComfyUI · Flux.2 Klein 9B）：提取模型物体/材质/尺寸信息 + 深度/法线参考图防止变形，出图后自动做结构吻合度检查。'
      ext.version     = PLUGIN_VERSION
      ext.copyright   = "Aydin Creative AI #{Time.now.year}"
      ext.creator     = 'Aydin Creative AI'
      Sketchup.register_extension(ext, true)
      @extension_registered = true
    end
  end
end
