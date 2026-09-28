# frozen_string_literal: true

# AI 渲染工作室 (AI Render Studio) — SketchUp 超写实 AI 渲染插件
# 注册入口。真正的实现在 ai_render_studio/main.rb
#
# 作者: Aydin Creative AI
# 后端: 本地 ComfyUI (Qwen Image Edit 2511 + RealVisXL 精修)

require 'sketchup.rb'
require 'extensions.rb'

module AydinCreative
  module AiRenderStudio
    PLUGIN_NAME    = 'AI 渲染工作室'
    PLUGIN_ID      = 'ai_render_studio'
    PLUGIN_VERSION = '0.1.0'

    PATH_ROOT = File.dirname(__FILE__)
    PATH      = File.join(PATH_ROOT, PLUGIN_ID)
    PATH_HTML = File.join(PATH, 'html')

    unless defined?(@extension_registered) && @extension_registered
      loader = File.join(PATH, 'main')
      ext = SketchupExtension.new(PLUGIN_NAME, loader)
      ext.description = 'SketchUp 一键 AI 超写实渲染：提取模型材质/构件信息 + 相机取景 + 本地 ComfyUI 出图。'
      ext.version     = PLUGIN_VERSION
      ext.copyright   = "Aydin Creative AI #{Time.now.year}"
      ext.creator     = 'Aydin Creative AI'
      Sketchup.register_extension(ext, true)
      @extension_registered = true
    end
  end
end
