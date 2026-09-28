# frozen_string_literal: true

module AydinCreative
  module AiRenderStudio
    # 本地照片级管线（2026-09-28）：Z-Image Turbo + Fun ControlNet Union → SeedVR2 精修放大。
    #
    # 为什么换掉 RealVisXL：SDXL 是 2023-24 年的底模，CLIP 只读 77 token，从 SketchUp 平涂色块出发，
    # denoise 低就是 CG 感、高就改结构，调参数到顶了。2026 年本地开源模型里：
    #   - Z-Image Turbo（阿里通义，6B，8 步出图）是公认照片真实感最好的，16GB 显存能跑；
    #     文本编码器是 Qwen3-4B，能读长描述，不再有 77 token 的问题；
    #   - 官方 Fun ControlNet Union（canny/hed/depth/mlsd/pose）已经是 ComfyUI 原生节点
    #     (ModelPatchLoader + QwenImageDiffsynthControlnet)，能把结构硬锁住；
    #   - SeedVR2（字节，7B int8，一步扩散）也是 ComfyUI 原生节点，放大时补真实微观纹理，
    #     不改几何，还能按原图做 LAB 颜色对齐——替换原来的"RealVisXL 低降噪精修 + ESRGAN"。
    # 节点接法照 ComfyUI 官方模板(workflow_templates 仓库)：
    #   image_z_image_turbo_fun_union_controlnet.json / utility_seedvr2_7b_int8_upscale_image.json
    #
    # 结构锁定靠三样东西叠加，都不是"文字求模型别改"：
    #   1. ControlNet 吃的是 SketchUp 从真实 3D 模型渲出的边线(Capture.lines)，不是从截图猜的；
    #   2. img2img：从 SketchUp 截图的真实像素出发(denoise < 1)，材质颜色/明暗分区都保留；
    #   3. 出图后 GeometryCheck 打分，偏了就换种子重出，留最好的一张。
    module PhotoBuilder
      module_function

      # ---- 模型文件自动识别 ---------------------------------------------------
      # 不写死文件名：去 ComfyUI 的模型目录里按关键字找，找不到就明确告诉用户缺什么、去哪下。
      REQUIRED = {
        unet: ['diffusion_models', /z[-_ ]?image[-_ ]?turbo/i, 'z_image_turbo_bf16.safetensors',
               'https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/diffusion_models/z_image_turbo_bf16.safetensors'],
        clip: ['text_encoders', /qwen[-_ ]?3[-_ ]?4b/i, 'qwen_3_4b.safetensors',
               'https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors'],
        vae: ['vae', /\A(ae|flux[-_]?ae|flux1?[-_]vae|z[-_]?image[-_]?vae)[^\/]*\.safetensors\z/i, 'ae.safetensors',
              'https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/vae/ae.safetensors'],
        control: ['model_patches', /z[-_ ]?image.*control/i, 'Z-Image-Turbo-Fun-Controlnet-Union.safetensors',
                  'https://huggingface.co/alibaba-pai/Z-Image-Turbo-Fun-Controlnet-Union/resolve/main/Z-Image-Turbo-Fun-Controlnet-Union.safetensors']
      }.freeze

      SEEDVR = {
        unet: ['diffusion_models', /seedvr2.*7b/i, /seedvr2.*3b/i, 'seedvr2_7b_int8_convrot.safetensors',
               'https://huggingface.co/Comfy-Org/SeedVR2/resolve/main/diffusion_models/seedvr2_7b_int8_convrot.safetensors'],
        vae: ['vae', /seedvr2.*vae/i, nil, 'seedvr2_ema_vae_fp16.safetensors',
              'https://huggingface.co/Comfy-Org/SeedVR2/resolve/main/vae/seedvr2_ema_vae_fp16.safetensors']
      }.freeze

      ZIMAGE_NODES = %w[ModelPatchLoader QwenImageDiffsynthControlnet ModelSamplingAuraFlow ConditioningZeroOut].freeze
      SEEDVR_NODES = %w[SeedVR2Preprocess SeedVR2Conditioning SeedVR2PostProcessing VAEEncodeTiled VAEDecodeTiled].freeze

      # 同一类里有多个文件时的偏好：新版本 > 旧版本，bf16 > fp8（16GB 显存 bf16 能放下，画质更好）
      def pick(list, rx)
        hits = list.select { |f| File.basename(f.to_s) =~ rx }
        hits.max_by do |f|
          n = f.to_s.downcase
          score = 0
          score += 4 if n =~ /2\.1|v2|union[-_]?2/
          score += 2 if n.include?('bf16')
          score += 1 if n.include?('fp8')
          score -= 3 if n.include?('gguf')
          score
        end
      end

      # 返回 { ok:, models: {...}, missing: [文字说明...], seedvr: {...} 或 nil }
      def resolve(client)
        missing = []
        nodes_missing = ZIMAGE_NODES.reject { |n| client.node?(n) }
        unless nodes_missing.empty?
          missing << "ComfyUI 版本太旧，缺少节点 #{nodes_missing.join(', ')}：请把 ComfyUI Desktop 更新到最新版"
        end

        m = {}
        REQUIRED.each do |key, (folder, rx, default_name, url)|
          f = pick(client.models(folder), rx)
          if f
            m[key] = f
          else
            missing << "#{folder}/#{default_name}  ←  #{url}"
          end
        end

        seed = nil
        if SEEDVR_NODES.all? { |n| client.node?(n) }
          dm = client.models(SEEDVR[:unet][0])
          unet = pick(dm, SEEDVR[:unet][1]) || pick(dm, SEEDVR[:unet][2])
          vae = pick(client.models(SEEDVR[:vae][0]), SEEDVR[:vae][1])
          seed = { unet: unet, vae: vae } if unet && vae
        end

        { ok: missing.empty?, models: m, missing: missing, seedvr: seed }
      end

      def seedvr_hint
        "#{SEEDVR[:unet][0]}/#{SEEDVR[:unet][3]}  ←  #{SEEDVR[:unet][4]}\n#{SEEDVR[:vae][0]}/#{SEEDVR[:vae][3]}  ←  #{SEEDVR[:vae][4]}"
      end

      # ---- 第一阶段：Z-Image Turbo + ControlNet(SketchUp 真实边线) + img2img ---------------
      # ai_strength 0-100 → denoise / ControlNet 强度：
      #   0   : denoise 0.86, cn 1.00 —— 保留截图的颜色分区，边线锁死
      #   100 : denoise 1.00, cn 0.60 —— 只保留大结构
      DIFFUSION_MEGAPIXELS = 1.5 # ControlNet Union 训练分辨率 1328²≈1.76MP，1.5MP 附近最稳

      def build_structure(input_filename:, lines_filename:, models:, prompt:, strength:, seed:, tag:,
                          vlm_model: nil, kind: 'exterior', reference_filename: nil)
        t = strength.to_i.clamp(0, 100) / 100.0
        denoise = (0.86 + 0.14 * t).round(3)
        cn = (1.0 - 0.4 * t).round(3)
        stamp = Time.now.strftime('%Y%m%d_%H%M%S')

        g = {
          'unet' => { 'class_type' => 'UNETLoader', 'inputs' => { 'unet_name' => models[:unet], 'weight_dtype' => 'default' } },
          'clip' => { 'class_type' => 'CLIPLoader', 'inputs' => { 'clip_name' => models[:clip], 'type' => 'lumina2', 'device' => 'default' } },
          'vae' => { 'class_type' => 'VAELoader', 'inputs' => { 'vae_name' => models[:vae] } },
          'patch' => { 'class_type' => 'ModelPatchLoader', 'inputs' => { 'name' => models[:control] } },

          'src' => { 'class_type' => 'LoadImage', 'inputs' => { 'image' => input_filename } },
          # 16 的倍数：Z-Image 的 patch(2) × VAE(8)
          'src_s' => { 'class_type' => 'ImageScaleToTotalPixels', 'inputs' => {
            'image' => ['src', 0], 'upscale_method' => 'lanczos', 'megapixels' => DIFFUSION_MEGAPIXELS, 'resolution_steps' => 16
          } },
          'sz' => { 'class_type' => 'GetImageSize', 'inputs' => { 'image' => ['src_s', 0] } },

          # SketchUp 线稿是"白底/色块 + 黑线"，Canny 之后变成 ControlNet 要的"黑底白线"。
          # 阈值照官方模板(0.1/0.32)。线稿先缩到和扩散图完全一样的尺寸，保证逐像素对齐。
          'lines' => { 'class_type' => 'LoadImage', 'inputs' => { 'image' => lines_filename } },
          'lines_s' => { 'class_type' => 'ImageScale', 'inputs' => {
            'image' => ['lines', 0], 'upscale_method' => 'lanczos', 'width' => ['sz', 0], 'height' => ['sz', 1], 'crop' => 'disabled'
          } },
          'edge' => { 'class_type' => 'Canny', 'inputs' => { 'image' => ['lines_s', 0], 'low_threshold' => 0.1, 'high_threshold' => 0.32 } },
          'cn' => { 'class_type' => 'QwenImageDiffsynthControlnet', 'inputs' => {
            'model' => ['unet', 0], 'model_patch' => ['patch', 0], 'vae' => ['vae', 0], 'image' => ['edge', 0], 'strength' => cn
          } },
          'ms' => { 'class_type' => 'ModelSamplingAuraFlow', 'inputs' => { 'model' => ['cn', 0], 'shift' => 3 } },

          'pos' => { 'class_type' => 'CLIPTextEncode', 'inputs' => { 'clip' => ['clip', 0], 'text' => prompt } },
          # Turbo 是蒸馏模型，cfg=1，不用负面提示词（官方模板就是 ConditioningZeroOut）
          'neg' => { 'class_type' => 'ConditioningZeroOut', 'inputs' => { 'conditioning' => ['pos', 0] } },
          'lat' => { 'class_type' => 'VAEEncode', 'inputs' => { 'pixels' => ['src_s', 0], 'vae' => ['vae', 0] } },
          'ks' => { 'class_type' => 'KSampler', 'inputs' => {
            'model' => ['ms', 0], 'seed' => seed, 'steps' => denoise < 1.0 ? 10 : 8, 'cfg' => 1.0,
            'sampler_name' => 'res_multistep', 'scheduler' => 'simple',
            'positive' => ['pos', 0], 'negative' => ['neg', 0], 'latent_image' => ['lat', 0], 'denoise' => denoise
          } },
          'dec' => { 'class_type' => 'VAEDecode', 'inputs' => { 'samples' => ['ks', 0], 'vae' => ['vae', 0] } },
          'save' => { 'class_type' => 'SaveImage', 'inputs' => { 'images' => ['dec', 0], 'filename_prefix' => "SU_AI_Render/#{stamp}_zimage_#{tag}" } }
        }

        # 看图识物（沿用 SDXL 管线里验证过的 gemma VLM）：构件名是乱码时，靠它告诉扩散模型
        # "这里是床不是沙发"。Qwen3 文本编码器能读长文本，直接拼在描述里，不用 SDXL 那种加权技巧。
        if vlm_model
          g['vclip'] = { 'class_type' => 'CLIPLoader', 'inputs' => { 'clip_name' => vlm_model, 'type' => 'ltxv' } }
          g['vlm'] = { 'class_type' => 'TextGenerate', 'inputs' => {
            'clip' => ['vclip', 0], 'image' => ['src_s', 0], 'prompt' => WorkflowBuilder.vision_checklist_prompt,
            'max_length' => 150, 'sampling_mode' => 'off'
          } }
          g['vlm_txt'] = { 'class_type' => 'StringConcatenate', 'inputs' => {
            'string_a' => prompt, 'string_b' => ['vlm', 0],
            'delimiter' => "\nFurniture and objects visible in this #{kind == 'interior' ? 'room' : 'scene'} (render each as exactly this kind of object, same place, same count): "
          } }
          g['pos']['inputs']['text'] = ['vlm_txt', 0]

          # 参考图：同一个 VLM 把它的材质/色调/光线读成一句话，拼进描述里（只借风格，不借布局）
          if reference_filename
            g['ref'] = { 'class_type' => 'LoadImage', 'inputs' => { 'image' => reference_filename } }
            g['ref_vlm'] = { 'class_type' => 'TextGenerate', 'inputs' => {
              'clip' => ['vclip', 0], 'image' => ['ref', 0], 'prompt' => REFERENCE_PROMPT,
              'max_length' => 120, 'sampling_mode' => 'off'
            } }
            g['ref_txt'] = { 'class_type' => 'StringConcatenate', 'inputs' => {
              'string_a' => ['vlm_txt', 0], 'string_b' => ['ref_vlm', 0],
              'delimiter' => "\nMaterial palette, colour grading and lighting mood: "
            } }
            g['pos']['inputs']['text'] = ['ref_txt', 0]
          end
        end
        g
      end

      REFERENCE_PROMPT = 'Describe ONLY the materials, surface finishes, colour palette and lighting of this photo in ' \
                         'one or two sentences (for example: light oak floor, white lime-plaster walls, brushed brass ' \
                         'details, warm low evening sun). Do not describe the furniture layout, objects or composition. ' \
                         'No lists, no markdown.'

      # ---- 第二阶段：SeedVR2 精修放大到目标分辨率 ------------------------------------
      # 先 lanczos 放到目标尺寸，SeedVR2 一步扩散补真实细节；PostProcessing 用 LAB 把颜色
      # 对齐回第一阶段的图（官方描述："most faithful"），几何也按参考图对齐。
      def build_seedvr(input_filename:, seedvr:, width:, height:, seed:)
        stamp = Time.now.strftime('%Y%m%d_%H%M%S')
        tiled = { 'tile_size' => 512, 'overlap' => 128, 'temporal_size' => 4096, 'temporal_overlap' => 8 }
        {
          'img' => { 'class_type' => 'LoadImage', 'inputs' => { 'image' => input_filename } },
          'rs' => { 'class_type' => 'ImageScale', 'inputs' => {
            'image' => ['img', 0], 'upscale_method' => 'lanczos', 'width' => width, 'height' => height, 'crop' => 'disabled'
          } },
          'pre' => { 'class_type' => 'SeedVR2Preprocess', 'inputs' => { 'resized_images' => ['rs', 0] } },
          'vae' => { 'class_type' => 'VAELoader', 'inputs' => { 'vae_name' => seedvr[:vae] } },
          'unet' => { 'class_type' => 'UNETLoader', 'inputs' => { 'unet_name' => seedvr[:unet], 'weight_dtype' => 'default' } },
          'enc' => { 'class_type' => 'VAEEncodeTiled', 'inputs' => { 'pixels' => ['pre', 0], 'vae' => ['vae', 0] }.merge(tiled) },
          'cond' => { 'class_type' => 'SeedVR2Conditioning', 'inputs' => { 'model' => ['unet', 0], 'vae_conditioning' => ['enc', 0] } },
          'ks' => { 'class_type' => 'KSampler', 'inputs' => {
            'model' => ['unet', 0], 'seed' => seed, 'steps' => 1, 'cfg' => 1.0, 'sampler_name' => 'euler', 'scheduler' => 'simple',
            'positive' => ['cond', 0], 'negative' => ['cond', 1], 'latent_image' => ['enc', 0], 'denoise' => 1.0
          } },
          'dec' => { 'class_type' => 'VAEDecodeTiled', 'inputs' => { 'samples' => ['ks', 0], 'vae' => ['vae', 0] }.merge(tiled) },
          'post' => { 'class_type' => 'SeedVR2PostProcessing', 'inputs' => {
            'images' => ['dec', 0], 'original_resized_images' => ['rs', 0], 'color_correction_method' => 'lab'
          } },
          'save' => { 'class_type' => 'SaveImage', 'inputs' => { 'images' => ['post', 0], 'filename_prefix' => "SU_AI_Render/#{stamp}_final" } }
        }
      end

      # 没装 SeedVR2 时的兜底：ESRGAN(有的话) + lanczos 到目标尺寸，不再过一遍会改画面的扩散
      def build_resize(input_filename:, width:, height:, esrgan: nil)
        stamp = Time.now.strftime('%Y%m%d_%H%M%S')
        g = { 'img' => { 'class_type' => 'LoadImage', 'inputs' => { 'image' => input_filename } } }
        src = ['img', 0]
        if esrgan
          g['um'] = { 'class_type' => 'UpscaleModelLoader', 'inputs' => { 'model_name' => esrgan } }
          g['up'] = { 'class_type' => 'ImageUpscaleWithModel', 'inputs' => { 'upscale_model' => ['um', 0], 'image' => src } }
          src = ['up', 0]
        end
        g['rs'] = { 'class_type' => 'ImageScale', 'inputs' => {
          'image' => src, 'upscale_method' => 'lanczos', 'width' => width, 'height' => height, 'crop' => 'disabled'
        } }
        g['save'] = { 'class_type' => 'SaveImage', 'inputs' => { 'images' => ['rs', 0], 'filename_prefix' => "SU_AI_Render/#{stamp}_final" } }
        g
      end

      # 目标输出尺寸（8 的倍数），跟面板上"输出清晰度"一致
      def output_dims(aspect_ratio, resolution)
        short = WorkflowBuilder::RES_SHORT_EDGE[resolution.to_s] || 1080
        ar = aspect_ratio.to_f
        ar = 16.0 / 9.0 if ar <= 0
        w, h = ar >= 1.0 ? [(short * ar).round, short] : [short, (short / ar).round]
        [w - w % 8, h - h % 8]
      end

      # ---- 提示词：Z-Image 吃"照片描述"，不吃"指令" -------------------------------
      # Qwen3-4B 编码器能读长文本，所以把 SketchUp 里提取的材质(带物理质感)、光照都写成
      # 一段完整的照片描述。不要写"不要改变 xxx"这种指令——扩散模型不理解否定，结构交给 ControlNet。
      def prompt(kind:, ctx:, preset: nil, user_prompt: nil)
        interior = kind.to_s == 'interior'
        parts = []
        parts << (interior ?
          'A real professional interior photograph of this room, shot on a full-frame DSLR with a 24mm wide lens at eye level, straight vertical lines, as published in an architecture and interior design magazine.' :
          'A real professional architectural photograph of this building, shot on a full-frame DSLR with a 24mm wide lens, straight vertical lines, as published in an architecture magazine.')

        mats = material_sentences(ctx)
        parts << "Surfaces and materials: #{mats}." unless mats.empty?

        light =
          if !preset.to_s.strip.empty?
            preset.strip
          elsif (sun = ctx && (ctx[:sun] || ctx['sun'])) && (sun[:available] || sun['available'])
            "Natural sunlight #{sun[:sun_description] || sun['sun_description']}, with matching soft shadows."
          else
            interior ? 'Soft natural daylight from the windows mixed with warm 2700K interior lights.' : 'Soft natural daylight, real sky.'
          end
        parts << "Lighting: #{light}"

        up = user_prompt.to_s.strip.tr("\n", ' ')
        parts << (up =~ /[.。!！]\z/ ? up : "#{up}.") unless up.empty?

        parts << 'Photorealistic, every surface has real physical material texture: visible wood grain, fabric weave, ' \
                 'stone veining, brushed metal, clear glass with reflections. Soft realistic shadows, ambient occlusion ' \
                 'in corners and under furniture, bounce light, natural colour, high dynamic range, crisp detail, ' \
                 'subtle film grain.' + (interior ? '' : ' Real grass, real paving, real trees and real sky.')
        parts.join(' ')
      end

      # "Material12" / "材质3" / "Color_A01" / "<auto>" 这类自动生成的名字不带任何信息，别写进提示词
      PLACEHOLDER_NAME = /\A\s*(<.*>|(material|mat|color|colour|default|材质|颜色)[\s_\-#]*[a-z]?\d*)\s*\z/i

      def material_sentences(ctx)
        return '' unless ctx
        mats = ctx[:visible_materials] || ctx['visible_materials'] || []
        nq = ctx[:naming_quality] || ctx['naming_quality'] || {}
        use_names = %w[good mixed].include?((nq[:verdict] || nq['verdict']).to_s)
        mats.first(8).map do |x|
          name = (x[:name] || x['name']).to_s
          next if name.start_with?('(')
          hint = WorkflowBuilder.material_physics_hint(name, x[:texture_file] || x['texture_file'])
          placeholder = name =~ PLACEHOLDER_NAME
          next nil unless hint || (use_names && !placeholder)
          label = use_names && !placeholder ? name.tr('_', ' ') : nil
          if hint
            kind, desc = hint.split(':', 2)
            label ? "#{label} (#{kind}, #{desc.strip})" : "#{kind} (#{desc.strip})"
          else
            label
          end
        end.compact.join('; ')
      end
    end
  end
end
