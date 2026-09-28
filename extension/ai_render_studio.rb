# frozen_string_literal: true

# AI 渲染工作室 (AI Render Studio) — SketchUp 超写实 AI 渲染插件
# 注册入口。真正的实现在 ai_render_studio/main.rb
#
# 作者: Aydin Creative AI
# 后端: 本地 ComfyUI —— Z-Image Turbo + Fun ControlNet Union（SketchUp 真实边线锁结构）+ SeedVR2 精修放大；
#       旧的 RealVisXL + 深度/边线 ControlNet 管线保留为备选引擎

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
      ext.description = 'SketchUp 一键 AI 照片级渲染（全本地 ComfyUI）：Z-Image Turbo + ControlNet 锁结构 + SeedVR2 精修放大，出图后自动做结构吻合度检查。'
      ext.version     = PLUGIN_VERSION
      ext.copyright   = "Aydin Creative AI #{Time.now.year}"
      ext.creator     = 'Aydin Creative AI'
      Sketchup.register_extension(ext, true)
      @extension_registered = true
    end
  end
end
