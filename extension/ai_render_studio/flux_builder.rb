# frozen_string_literal: true

module AydinCreative
  module AiRenderStudio
    # 渲染引擎：Flux.2 Klein 9B（KV）图像编辑 —— 2026-09-28 回到最初的 Flux 管线。
    #
    # 中间试过 RealVisXL+ControlNet 和 Z-Image Turbo+ControlNet，实测都不如最初的 Flux：前者像线稿上色，
    # 后者直接画成了另一个房间。所以回到 Flux.2 Klein，并恢复当时的做法——
    #   1. ModelExtractor 从 SketchUp 相机视角里提取参与渲染的每个物体：名称、屏幕位置、真实尺寸、
    #      主色/副色、距离，以及每种材质(带物理质感描述)、相机、太阳 —— 写成 GROUND TRUTH 喂给模型，
    #      防止它变形、改物体、丢物体；
    #   2. 看图识物(gemma VLM)补上物体类别（构件名是乱码时，床会被认成沙发）；
    #   3. 参考图：Image 1 = SketchUp 截图，Image 2/3 = 从真实 3D 模型射线采样的深度图 / 法线图
    #      (空间线索)，Image 4 = 用户给的风格参考图(可选)；
    #   4. "CHANGE BUDGET" 文字指令控制改动幅度。
    # 节点接法照 ComfyUI 官方模板 image_flux2_klein_9b_kv_image_edit.json：每张参考图 VAEEncode →
    # ReferenceLatent(正/负条件都接)，FluxKVCache，CFGGuider cfg 1，euler，Flux2Scheduler 4 步。
    # 提示词各段（ground_truth_block / strength_directive / photo_contract / 材质质感字典 / 看图识物）
    # 是当初写给 Flux 的原文，直接恢复。
    module FluxBuilder
      module_function

      VISION_CLIP = 'gemma4_e4b_it_fp8_scaled.safetensors'

      RES_SHORT_EDGE = {
        '240p' => 240, '360p' => 360, '480p' => 480, '720p' => 720,
        '1080p' => 1080, '1440p' => 1440, '2160p' => 2160, '4k' => 2160, '4K' => 2160
      }.freeze

      # ---- 模型文件自动识别 / 一键下载 -----------------------------------------------
      REQUIRED = {
        unet: ['diffusion_models', /flux[-_.]?2.*klein.*9b|klein.*9b/i, 'flux-2-klein-9b-kv-fp8.safetensors',
               'https://huggingface.co/black-forest-labs/FLUX.2-klein-9b-kv-fp8/resolve/main/flux-2-klein-9b-kv-fp8.safetensors'],
        clip: ['text_encoders', /qwen[-_ ]?3[-_ .]?8b/i, 'qwen_3_8b_fp8mixed.safetensors',
               'https://huggingface.co/Comfy-Org/flux2-klein-9B/resolve/main/split_files/text_encoders/qwen_3_8b_fp8mixed.safetensors'],
        vae: ['vae', /flux[-_.]?2.*vae|flux2[-_]?ae/i, 'flux2-vae.safetensors',
              'https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/vae/flux2-vae.safetensors']
      }.freeze
      EXCLUDE = { unet: /lora|vae|control/i }.freeze
      SIZE_GB = { unet: 9.4, clip: 8.7, vae: 0.3 }.freeze
      SEARCH_FOLDERS = %w[diffusion_models unet_gguf checkpoints text_encoders clip_gguf vae loras].freeze
      # 结构 LoRA（RefControl，Flux.2 Klein 9B 线稿版）：让 Klein 把线稿当"必须照着画的结构"，
      # 而不只是软参考——解决墙板线条/拱形/柜子造型被 Flux 自己重新设计的问题。
      # 用法（作者 README）：图 1 = 控制图（线稿），图 2 = 参考图（材质/颜色/物体从这里取），
      # 提示词带触发词 "refcontrol"，LoRA 权重 0.8-1.0。在 Klein Base 上训练，作者说蒸馏 4 步版也能用。
      # HF 仓库里的文件名没法事先确定，下载时由脚本问 HF API 找 .safetensors，存成固定文件名。
      STRUCT_LORA = {
        folder: 'loras', rx: /refcontrol.*line\s*art|refcontrol.*lineart|line\s*art.*refcontrol/i,
        name: 'refcontrol-flux2-klein-9b-lineart.safetensors',
        repo: 'thedeoxen/refcontrol-FLUX.2-klein-9B-reference-lineart-lora'
      }.freeze
      STRUCT_LORA_STRENGTH = 0.9
      # 线稿颜色约定：SketchUp 消隐线截图是"白底黑线"，而 RefControl 作者给的 Klein 9B 线稿示例
      # (github.com/thedeoxen/refcontrol assets/klein-9b/lineart-01.png) 控制图是"黑底白线"，所以反相。
      LINEART_INVERT = true

      FLUX_NODES = %w[ReferenceLatent CFGGuider SamplerCustomAdvanced KSamplerSelect RandomNoise
                      Flux2Scheduler EmptyFlux2LatentImage ConditioningZeroOut].freeze

      # 同一类里有多个文件时的偏好：新版本 > 旧版本，bf16 > fp8（16GB 显存 bf16 能放下，画质更好）
      def pick(list, rx, exclude = nil)
        hits = list.select { |f| (b = base(f)) =~ rx && !(exclude && b =~ exclude) }
        hits.max_by do |f|
          n = f.to_s.downcase
          score = 0
          score += 4 if n =~ /2\.1|v2|union[-_]?2/
          score += 2 if n.include?('bf16')
          score += 1 if n.include?('fp8')
          score += 1 if n =~ /\Aae\./
          score
        end
      end

      # ComfyUI 在 Windows 上返回的相对路径用反斜杠
      def base(f)
        f.to_s.split(%r{[\\/]}).last.to_s
      end

      # 在别的文件夹里找同名/同类文件 → "在 X/ 里找到了 Y"
      def found_elsewhere(client, rx, right_folder, exclude = nil)
        SEARCH_FOLDERS.reject { |f| f == right_folder }.flat_map do |folder|
          client.models(folder).select { |f| (b = base(f)) =~ rx && !(exclude && b =~ exclude) }.first(2).map { |f| "#{folder}/#{f}" }
        end
      end

      def missing_line(client, key)
        folder, rx, name, url = REQUIRED[key]
        label = { unet: 'Flux.2 Klein 9B 主模型', clip: '文本编码器 Qwen3-8B', vae: 'Flux2 VAE' }[key]
        elsewhere = found_elsewhere(client, rx, folder, EXCLUDE[key])
        gguf = elsewhere.select { |e| e.start_with?('unet_gguf/', 'clip_gguf/') }
        if !gguf.empty? && elsewhere.size == gguf.size
          "✗ #{label}：找到了 GGUF 版（#{gguf.map { |e| e.split('/', 2).last }.join('、')}），但 ComfyUI 里没装 ComfyUI-GGUF 插件。" \
            "装上它（ComfyUI Manager 搜 GGUF），或者改下 safetensors 版：\n    #{url}"
        elsif elsewhere.empty?
          "✗ #{label}：没找到。下载放到 models/#{folder}/#{name}\n    #{url}"
        else
          "✗ #{label}：在 #{elsewhere.join('、')} 找到了，但它必须放在 models/#{folder}/ 里（移动过去后重启 ComfyUI）"
        end
      end

      def model_ref(models)
        models[:loader] == :ckpt ? ['ckpt', 0] : ['unet', 0]
      end

      def clip_ref(models)
        models[:loader] == :ckpt ? ['ckpt', 1] : ['clip', 0]
      end

      def vae_ref(models)
        models[:loader] == :ckpt ? ['ckpt', 2] : ['vae', 0]
      end

      # 返回 { ok:, models: {...}, missing: [...], downloads: [...], found: {...} }
      def resolve(client)
        missing = []
        nodes_missing = FLUX_NODES.reject { |n| client.node?(n) }
        missing << "ComfyUI 版本太旧，缺少节点 #{nodes_missing.join(', ')}：请把 ComfyUI Desktop 更新到最新版" unless nodes_missing.empty?

        m = {}
        folder, rx, = REQUIRED[:unet]
        if (f = pick(client.models(folder), rx, EXCLUDE[:unet]))
          m[:unet] = f
          m[:loader] = :unet
        elsif client.node?('UnetLoaderGGUF') && (f = pick(client.models('unet_gguf'), rx, EXCLUDE[:unet]))
          m[:unet] = f
          m[:loader] = :gguf
        else
          missing << missing_line(client, :unet)
        end
        # KV 版才能用 FluxKVCache（官方模板里就是 KV 版）
        m[:kv] = m[:unet].to_s =~ /kv/i && client.node?('FluxKVCache') ? true : false

        folder, rx, = REQUIRED[:clip]
        if (f = pick(client.models(folder), rx))
          m[:clip] = f
          m[:clip_loader] = :clip
        elsif client.node?('CLIPLoaderGGUF') && (f = pick(client.models('clip_gguf'), rx))
          m[:clip] = f
          m[:clip_loader] = :gguf
        else
          missing << missing_line(client, :clip)
        end

        folder, rx, = REQUIRED[:vae]
        if (f = pick(client.models(folder), rx))
          m[:vae] = f
        else
          missing << missing_line(client, :vae)
        end

        downloads = []
        { unet: !m[:unet], clip: !m[:clip], vae: !m[:vae] }.each do |key, need|
          next unless need
          folder, rx, name, url = REQUIRED[key]
          next unless found_elsewhere(client, rx, folder, EXCLUDE[key]).empty?
          downloads << { folder: folder, name: name, url: url, gb: SIZE_GB[key] }
        end

        # 结构 LoRA（可选）
        lora_ok = client.node?('LoraLoaderModelOnly')
        m[:struct_lora] = lora_ok ? pick(client.models(STRUCT_LORA[:folder]), STRUCT_LORA[:rx]) : nil
        lora_downloads = []
        if lora_ok && m[:struct_lora].nil?
          lora_downloads << { folder: STRUCT_LORA[:folder], name: STRUCT_LORA[:name], repo: STRUCT_LORA[:repo] }
        end

        found = {}
        SEARCH_FOLDERS.each { |fd| found[fd] = client.models(fd) }
        { ok: missing.empty?, models: m, missing: missing, downloads: downloads, lora_downloads: lora_downloads,
          found: found }
      end

      def loader_nodes(models)
        {
          'unet' => (models[:loader] == :gguf ?
            { 'class_type' => 'UnetLoaderGGUF', 'inputs' => { 'unet_name' => models[:unet] } } :
            { 'class_type' => 'UNETLoader', 'inputs' => { 'unet_name' => models[:unet], 'weight_dtype' => 'default' } }),
          'clip' => (models[:clip_loader] == :gguf ?
            { 'class_type' => 'CLIPLoaderGGUF', 'inputs' => { 'clip_name' => models[:clip], 'type' => 'flux2' } } :
            { 'class_type' => 'CLIPLoader', 'inputs' => { 'clip_name' => models[:clip], 'type' => 'flux2', 'device' => 'default' } }),
          'vae' => { 'class_type' => 'VAELoader', 'inputs' => { 'vae_name' => models[:vae] } }
        }
      end

      # ---- 出图：Flux.2 Klein 图像编辑（官方模板结构）------------------------------------
      # images: [文件名, ...]，第一张决定输出尺寸（缩到约 1MP 再生成，跟官方模板一致）。
      # prompt_text: 纯文字；vlm: 看图识物的模型文件名（有就把识别结果拼到提示词最前面）。
      STEPS = 4

      # final_size: [w, h] 时在同一张图里直接放大到这个尺寸（结果窗口的调色/增强用；渲染管线是
      # 先出几张 1MP 择优，再单独 build_upscale）
      # lora: 结构 LoRA 文件名（有就挂在主模型上，权重 STRUCT_LORA_STRENGTH）
      # invert: 需要反相的图片下标（线稿颜色约定，见 LINEART_INVERT）
      # vlm_image: 看图识物看哪张图（结构 LoRA 模式下图 1 是线稿，要看图 2 的 SketchUp 截图）
      def build_edit(images:, models:, prompt_text:, seed:, tag:, vlm: nil, vlm_lead: nil, final_size: nil, esrgan: nil,
                     lora: nil, invert: [], vlm_image: 0)
        stamp = Time.now.strftime('%Y%m%d_%H%M%S')
        g = loader_nodes(models)
        model = ['unet', 0]
        if lora
          g['lora'] = { 'class_type' => 'LoraLoaderModelOnly', 'inputs' => {
            'model' => model, 'lora_name' => lora, 'strength_model' => STRUCT_LORA_STRENGTH
          } }
          model = ['lora', 0]
        end
        if models[:kv]
          g['kv'] = { 'class_type' => 'FluxKVCache', 'inputs' => { 'model' => model } }
          model = ['kv', 0]
        end

        images.each_with_index do |name, i|
          g["img#{i}"] = { 'class_type' => 'LoadImage', 'inputs' => { 'image' => name } }
          src = ["img#{i}", 0]
          if invert.include?(i)
            g["img#{i}_inv"] = { 'class_type' => 'ImageInvert', 'inputs' => { 'image' => src } }
            src = ["img#{i}_inv", 0]
          end
          g["img#{i}_s"] = { 'class_type' => 'ImageScaleToTotalPixels', 'inputs' => {
            'image' => src, 'upscale_method' => 'lanczos', 'megapixels' => 1.0, 'resolution_steps' => 16
          } }
        end
        g['sz'] = { 'class_type' => 'GetImageSize', 'inputs' => { 'image' => ['img0_s', 0] } }

        text = prompt_text
        if vlm
          g['vclip'] = { 'class_type' => 'CLIPLoader', 'inputs' => { 'clip_name' => vlm, 'type' => 'ltxv' } }
          g['vlm'] = { 'class_type' => 'TextGenerate', 'inputs' => {
            'clip' => ['vclip', 0], 'image' => ["img#{vlm_image}_s", 0], 'prompt' => vision_checklist_prompt,
            'max_length' => 150, 'sampling_mode' => 'off'
          } }
          g['vlm_a'] = { 'class_type' => 'StringConcatenate', 'inputs' => {
            'string_a' => vlm_lead.to_s, 'string_b' => ['vlm', 0], 'delimiter' => ' '
          } }
          g['vlm_b'] = { 'class_type' => 'StringConcatenate', 'inputs' => {
            'string_a' => ['vlm_a', 0], 'string_b' => prompt_text, 'delimiter' => "\n\n"
          } }
          text = ['vlm_b', 0]
        end
        g['pos'] = { 'class_type' => 'CLIPTextEncode', 'inputs' => { 'clip' => ['clip', 0], 'text' => text } }
        g['neg'] = { 'class_type' => 'ConditioningZeroOut', 'inputs' => { 'conditioning' => ['pos', 0] } }

        pos = ['pos', 0]
        neg = ['neg', 0]
        images.each_index do |i|
          g["ref#{i}_lat"] = { 'class_type' => 'VAEEncode', 'inputs' => { 'pixels' => ["img#{i}_s", 0], 'vae' => ['vae', 0] } }
          g["ref#{i}_pos"] = { 'class_type' => 'ReferenceLatent', 'inputs' => { 'conditioning' => pos, 'latent' => ["ref#{i}_lat", 0] } }
          g["ref#{i}_neg"] = { 'class_type' => 'ReferenceLatent', 'inputs' => { 'conditioning' => neg, 'latent' => ["ref#{i}_lat", 0] } }
          pos = ["ref#{i}_pos", 0]
          neg = ["ref#{i}_neg", 0]
        end

        g['guider'] = { 'class_type' => 'CFGGuider', 'inputs' => { 'model' => model, 'positive' => pos, 'negative' => neg, 'cfg' => 1.0 } }
        g['sampler'] = { 'class_type' => 'KSamplerSelect', 'inputs' => { 'sampler_name' => 'euler' } }
        g['noise'] = { 'class_type' => 'RandomNoise', 'inputs' => { 'noise_seed' => seed } }
        g['sigmas'] = { 'class_type' => 'Flux2Scheduler', 'inputs' => { 'steps' => STEPS, 'width' => ['sz', 0], 'height' => ['sz', 1] } }
        g['latent'] = { 'class_type' => 'EmptyFlux2LatentImage', 'inputs' => { 'width' => ['sz', 0], 'height' => ['sz', 1], 'batch_size' => 1 } }
        g['sample'] = { 'class_type' => 'SamplerCustomAdvanced', 'inputs' => {
          'noise' => ['noise', 0], 'guider' => ['guider', 0], 'sampler' => ['sampler', 0], 'sigmas' => ['sigmas', 0], 'latent_image' => ['latent', 0]
        } }
        g['dec'] = { 'class_type' => 'VAEDecode', 'inputs' => { 'samples' => ['sample', 0], 'vae' => ['vae', 0] } }
        out = ['dec', 0]
        if final_size
          w, h = final_size
          if esrgan && [w, h].max > 1600
            g['um'] = { 'class_type' => 'UpscaleModelLoader', 'inputs' => { 'model_name' => esrgan } }
            g['up'] = { 'class_type' => 'ImageUpscaleWithModel', 'inputs' => { 'upscale_model' => ['um', 0], 'image' => out } }
            out = ['up', 0]
          end
          g['rs'] = { 'class_type' => 'ImageScale', 'inputs' => {
            'image' => out, 'upscale_method' => 'lanczos', 'width' => w, 'height' => h, 'crop' => 'disabled'
          } }
          out = ['rs', 0]
        end
        g['save'] = { 'class_type' => 'SaveImage', 'inputs' => { 'images' => out, 'filename_prefix' => "SU_AI_Render/#{stamp}_#{tag}" } }
        g
      end

      # 放大到目标分辨率：长边 >1600 先 ESRGAN 4x，再 lanczos 精确缩放（当初 Flux 管线的做法）
      def build_upscale(input_filename:, width:, height:, esrgan: nil)
        stamp = Time.now.strftime('%Y%m%d_%H%M%S')
        g = { 'img' => { 'class_type' => 'LoadImage', 'inputs' => { 'image' => input_filename } } }
        src = ['img', 0]
        if esrgan && [width, height].max > 1600
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

      def output_dims(aspect_ratio, resolution)
        short = RES_SHORT_EDGE[resolution.to_s] || 1080
        ar = aspect_ratio.to_f
        ar = 16.0 / 9.0 if ar <= 0
        w, h = ar >= 1.0 ? [(short * ar).round, short] : [short, (short / ar).round]
        [w - w % 8, h - h % 8]
      end

      # ---- 提示词 ------------------------------------------------------------------
      def vision_lead_in(kind, image_no = 1)
        kind_label = kind.to_s == 'interior' ? 'interior' : 'exterior'
        "This is an architectural #{kind_label} photograph. FURNITURE AND OBJECTS ACTUALLY PRESENT, identified by " \
        "directly looking at Image #{image_no} - this is ground truth from real observation, not a guess. Render exactly " \
        'these items as exactly these categories, nothing more, nothing fewer:'
      end

      # refcontrol: 结构 LoRA 模式——图 1 = 线稿(控制图)，图 2 = SketchUp 截图(参考图)，触发词放最前面
      def render_prompt(kind:, ctx:, strength:, preset: nil, user_prompt: nil, has_depth: false, has_normal: false,
                        reference_index: nil, refcontrol: false)
        parts = []
        if refcontrol
          parts << 'refcontrol. Image 1 is a line drawing of the exact 3D model from this camera: every line is a real ' \
                   'edge - walls, wall panel mouldings, arches, cornices, ceiling ornaments, furniture outlines and ' \
                   'details. Follow its structure, proportions and every line exactly. Image 2 is the SketchUp view of ' \
                   'the same scene: take every object, its colours and its materials from Image 2, and turn it into a ' \
                   'real photograph.'
        else
          parts << image_roles(has_depth, has_normal)
        end
        append_prompt_body(parts, kind: kind, ctx: ctx, strength: strength, preset: preset, user_prompt: user_prompt,
                                  reference_index: reference_index)
      end

      def image_roles(has_depth, has_normal)
        idx = 2
        refs = ['Image 1 is the SketchUp 3D-model view to turn into a real photograph.']
        if has_depth
          refs << "Image #{idx} is a depth map of exactly the same view rendered from the real 3D model (near = white, far = black)."
          idx += 1
        end
        if has_normal
          refs << "Image #{idx} is a surface-normal map of the same view from the real 3D model."
          idx += 1
        end
        refs << 'Use the depth/normal maps only as spatial guides for the exact shape, size and position of every object - never copy their colours.' if has_depth || has_normal
        refs.join(' ')
      end

      def append_prompt_body(parts, kind:, ctx:, strength:, preset:, user_prompt:, reference_index:)
        parts << ground_truth_block(ctx)
        parts << strength_directive(strength)
        if reference_index
          parts << "Image #{reference_index} is a reference photo. " + reference_directive(strength)
        elsif !preset.to_s.strip.empty?
          parts << "Lighting and weather mood: #{preset.strip}"
        end
        kind_label = kind.to_s == 'interior' ? 'interior' : 'exterior'
        parts << "Additional art direction from the designer (follow this): #{user_prompt.to_s.strip.tr("\n", ' ')}" unless user_prompt.to_s.strip.empty?
        parts << photo_contract(kind_label)
        parts.join("\n\n")
      end

      def grade_prompt(instruction)
        instr = instruction.to_s.strip
        instr = 'subtle professional color grade' if instr.empty?
        "Professional photographic color grading applied to Image 1: #{instr}. Keep the composition, geometry, " \
        'objects and details EXACTLY the same - only adjust colour, white balance, tone curve, contrast, saturation ' \
        'and overall mood. Result must still look like a real photograph, natural and believable.'
      end

      def enhance_prompt(strength)
        s = strength.to_i.clamp(0, 100)
        amount = s <= 35 ? 'Subtly' : (s <= 70 ? 'Clearly' : 'Strongly')
        "#{amount} enhance Image 1 into an authentic real photograph: physically-accurate materials with fine " \
        'microtexture (wood grain, fabric weave, stone veining, metal reflections as appropriate to each surface), ' \
        'realistic soft shadows and ambient occlusion, believable reflections, natural lighting falloff, balanced ' \
        'colour grading, crisp but natural focus. Do NOT change the composition, camera angle, perspective, layout, ' \
        'objects, furniture, colours or the count/position of anything in the scene.'
      end

      # ---- 以下提示词段落是当初写给 Flux 的原文（从最初的 workflow_builder.rb 恢复）----
      def vision_checklist_prompt
        'Look at this flat-shaded 3D model preview image and identify every distinct piece of furniture or major ' \
        'object actually visible. Answer with ONLY a short comma-separated list - no numbering, no markdown, no ' \
        'extra sentences before or after. For each item write its exact real-world category (bed, sofa, armchair, ' \
        'dining chair, desk, table, nightstand, wardrobe, bookshelf, floor lamp, table lamp, pendant light, wall ' \
        'light, plant, rug, mirror, artwork, or other) followed by its rough position in parentheses, in exactly ' \
        'this format: bed (centre background), nightstand (left of bed), wardrobe (right background). Judge the ' \
        'category strictly from silhouette and proportions alone, ignoring colour - a bed is never a sofa, an ' \
        'armchair is never a dining chair. Do not invent anything not actually visible.'
      end

      def reference_directive(strength)
        if strength <= 35
          'Use it for MATERIALS AND LIGHTING MOOD ONLY - lean the colour ' \
          'palette, surface finishes and lighting quality in that general direction. Do NOT change any furniture, ' \
          'object, layout or architectural feature to match it - the geometry constraints above are absolute.'
        else
          'Use it as a style cue: lean the materials, lighting mood and overall aesthetic ' \
          'toward it, while the geometry constraints above remain the structural basis of the render.'
        end
      end

      def photo_contract(kind_label)
        common =
          'Render as a single frame of high-end professional architectural and hospitality photography, shot on a ' \
          'full-frame DSLR with a wide 24-35mm lens. Physically-accurate materials with fine microtexture, clear ' \
          'glass with believable reflections, soft realistic shadows, balanced high-dynamic-range exposure, subtle ' \
          'film grain, colour graded. People, if any, correctly human-scaled - about as tall as a standard door - ' \
          'never tiny distant specks; at most a few. It MUST read as an authentic on-site photograph, not CGI, not ' \
          'a clay or 3D render, not CAD, not an illustration, no black outlines or sketch strokes anywhere. No ' \
          'text, logos, watermark, warped geometry, floating objects or duplicated structures.'

        specific =
          if kind_label == 'interior'
            'This is an INDOOR scene: the floor is a real interior floor finish (wood, tile, stone or carpet as ' \
            'shown) - it is NOT outdoors, there is no grass, gravel, garden, landscaping, sky or exterior ground of ' \
            'any kind anywhere in frame, and nothing is visible through or beneath any counter, floor or surface. ' \
            'Warm 2700K interior lighting, furnished rooms glowing softly, real fabric/wood/stone textures on ' \
            'furniture and surfaces.'
          else
            'Real stacked-stone and timber cladding, weathered slate or cedar-shingle roofs, real wood decking ' \
            'with plank joints, and where interiors are visible through windows, warm 2700K lighting glowing ' \
            'softly. Ground is real: grass and wildflower meadow with natural colour variation, gravel and stone ' \
            'paving, boardwalks - never a flat colour fill. Lit path bollards and lanterns actually emitting light ' \
            'where present. Atmospheric depth, gentle haze on distant hills, natural sky gradient.'
          end

        "#{common} #{specific}"
      end

      def strength_directive(s)
        base = "CHANGE BUDGET is #{s} out of 100. "
        body =
          if s <= 10
            'FIXED INVENTORY. You SHOULD and MUST fully photorealize every surface and light this scene like a ' \
            'professional interior/architectural photograph - rich real materials, natural light, warm interior ' \
            'lighting, soft shadows, believable reflections, atmosphere. BUT the objects, furniture and fixtures ' \
            'visible in Image 1 are the COMPLETE and ONLY inventory: keep every one of them in its exact position, ' \
            'shape, size, style and count, and do NOT introduce any furniture, fireplace, chandelier, shelving, ' \
            'artwork, plant or architectural feature that is not already present in Image 1. Keep the same pendant ' \
            'light, the same wall sconces, the same wardrobe, the same bed - just make them look real and beautifully lit.'
          elsif s <= 30
            'Photorealize and light the scene fully like a professional photograph. Keep every building, room, piece ' \
            'of furniture and fixture in its exact position, shape and count. You may add small context elements that ' \
            'do not touch the structure (trees, shrubs, grass, sky, a couple of people), but do NOT add or replace ' \
            'any interior furniture or fixtures.'
          elsif s <= 55
            'Keep the overall room/building massing, the camera, and the main furniture layout. You may enrich the ' \
            'scene and refine minor detailing, add planting and context, and adjust small architectural details.'
          elsif s <= 80
            'Use the image as a strong compositional guide. You may restyle surfaces and facades, adjust proportions ' \
            'and detailing, and add or remove secondary elements.'
          else
            'Use the image only as loose guidance for camera and general layout. Reinterpret architecture, materials, ' \
            'furniture and surroundings freely for the most striking result.'
          end
        base + body
      end

      MATERIAL_PHYSICS = [
        [/glass|玻璃|window\s*pane|幕墙/, 'glass: perfectly smooth, hard, highly specular and transparent/translucent, sharp reflections and slight refraction, no visible surface texture'],
        [/mirror|镜/, 'mirror-polished: perfectly smooth and hard with sharp, undistorted reflections'],
        [/chrome|不锈钢|stainless|polished\s*metal|铬|抛光金属/, 'polished metal: very smooth and hard, strong anisotropic specular highlights, cool-toned mirror-like reflections'],
        [/metal|steel|iron|aluminu?m|brass|copper|bronze|金属|钢|铁|铝|黄铜|铜|青铜/, 'metal: hard and smooth to satin, moderate-to-strong specular highlight, subtle reflections, minimal surface roughness'],
        [/leather|皮革|真皮/, 'leather: semi-gloss with fine natural grain texture, visible creases and stitching, warm soft specular highlights, moderately soft to the touch'],
        [/velvet|丝绒|天鹅绒/, 'velvet: very soft directional nap that changes shade with viewing angle, deep matte shadows between fibers, subtle fuzzy rim highlights'],
        [/carpet|rug|\bfur\b|plush|地毯|毛毯|絨|绒毛|羊毛毯/, 'carpet/fur: deep soft pile with visible directional nap/fur catching rim light, matte and non-reflective, soft shadowed crevices between fibers'],
        [/fabric|textile|upholst|linen|cotton|wool|silk|cushion|pillow|sofa|布艺|布料|棉|麻|羊毛|丝绸|沙发布|靠垫|窗帘|curtain/, 'fabric: soft matte surface with visible woven texture, gentle diffuse shadowing, slight softness/give at seams and folds'],
        [/wood|oak|walnut|pine|plywood|timber|木|橡木|胡桃木|松木|夹板|木地板|木纹/, 'wood: satin to semi-gloss finish, visible grain direction and natural colour variation, warm mid-strength specular highlight, hard but with organic surface variation'],
        [/marble|granite|travertine|大理石|花岗岩/, 'polished stone: hard, satin-to-glossy with natural veining/speckling, moderate reflectivity, subtle micro-roughness'],
        [/concrete|cement|混凝土|水泥/, 'concrete: hard, matte to low-satin, fine uniform micro-roughness, subtle pores and colour variation, minimal specular highlight'],
        [/stone|rock|石材|石头|岩/, 'natural stone: hard, matte to satin, irregular texture and colour variation, low specular highlight'],
        [/brick|砖/, 'brick: hard, rough matte masonry texture, visible mortar joints, uneven natural colour variation'],
        [/tile|ceramic|porcelain|瓷砖|陶瓷/, 'ceramic tile: hard, smooth semi-gloss to glossy, uniform reflections, crisp grout lines'],
        [/plastic|acrylic|塑料|亚克力/, 'plastic: smooth, hard, moderate uniform specular highlight, slightly artificial sheen unless matte-finished'],
        [/plant|leaf|leaves|foliage|grass|tree|植物|叶|草坪|树/, 'foliage: organic irregular matte surface with a subtle waxy sheen on leaves, natural colour variation, soft directional highlights'],
        [/water|pool|pond|水|泳池|水池/, 'water: reflective liquid surface with gentle ripples, mirror-like reflections and slight refraction'],
        [/wallpaper|壁纸/, 'wallpaper: matte, slightly soft texture, very low specular highlight']
      ].freeze

      def material_physics_hint(name, texture_file)
        text = "#{name} #{texture_file}".to_s.downcase
        hit = MATERIAL_PHYSICS.find { |rx, _| rx.match?(text) }
        hit && hit[1]
      end

      def ground_truth_block(ctx)
        return 'GROUND TRUTH: (no 3D model data available for this view.)' if ctx.nil?

        lines = []
        lines << 'GROUND TRUTH extracted from the actual 3D model for THIS exact camera view.'
        lines << 'Trust this over your visual guess wherever they conflict. Keep the geometry, proportions and camera framing exactly as in Image 1.'

        m = ctx[:model] || ctx['model']
        if m
          bb = m[:bbox_m] || m['bbox_m'] || {}
          lines << format('- Building bounding box: %sm (W) x %sm (D) x %sm (H); approx %s storey(s).',
                          bb[:x] || bb['x'], bb[:y] || bb['y'], bb[:z] || bb['z'],
                          m[:approx_storeys] || m['approx_storeys'])
        end

        cam = ctx[:camera] || ctx['camera']
        if cam
          fl = cam[:focal_length_mm] || cam['focal_length_mm']
          eh = cam[:eye_height_m] || cam['eye_height_m']
          lines << format('- Camera: %s view, %s eye height %.1fm, looking toward %s.',
                          (cam[:perspective] || cam['perspective']) ? 'perspective' : 'parallel',
                          fl ? "~#{fl}mm equiv," : '',
                          (eh || 0).to_f, cam[:looking_direction] || cam['looking_direction'])
        end

        sun = ctx[:sun] || ctx['sun']
        if sun && (sun[:available] || sun['available'])
          lines << format('- Real sun position from the model: %s. Local date/time %s%s. Match the lighting direction and shadows to this unless a specific lighting mood is given below.',
                          sun[:sun_description] || sun['sun_description'],
                          sun[:date_time] || sun['date_time'],
                          (sun[:city] || sun['city']).to_s.empty? ? '' : ", #{sun[:city] || sun['city']}")
        end

        mats = ctx[:visible_materials] || ctx['visible_materials'] || []
        named = mats.reject { |x| (x[:name] || x['name']).to_s.start_with?('(') }
        unless named.empty?
          listed = named.first(12).map do |x|
            name = x[:name] || x['name']
            frac = ((x[:screen_fraction] || x['screen_fraction']).to_f * 100).round
            tex = x[:texture_file] || x['texture_file']
            base = tex ? "#{name} (~#{frac}% of view, textured '#{tex}')" : "#{name} (~#{frac}% of view)"
            hint = material_physics_hint(name, tex)
            hint ? "#{base} — #{hint}" : base
          end
          lines << "- Materials the model author assigned, most prominent first: #{listed.join('; ')}."
        end

        comps = ctx[:visible_components] || ctx['visible_components'] || []
        named_c = comps.map { |x| x[:name] || x['name'] }.reject { |n| n.to_s.strip.empty? }
        lines << "- Named objects visible in frame: #{named_c.first(15).join(', ')}." unless named_c.empty?

        objs = ctx[:visible_objects] || ctx['visible_objects'] || []
        unless objs.empty?
          lines << ''
          lines << 'DISTINCT OBJECTS in this exact view, one line per real, separate object actually detected in the ' \
                    '3D model (not a guess) — position on screen, approximate size, distance from camera. Treat EACH ' \
                    'as a genuinely separate object at exactly that position: do not merge two of them into one, do ' \
                    'not omit a small/distant one, do not invent extra ones, and do not change how many there are.'
          objs.each_with_index do |o, i|
            name = o[:name] || o['name']
            zone = o[:screen_zone] || o['screen_zone']
            frac = ((o[:screen_fraction] || o['screen_fraction']).to_f * 100).round
            near = o[:nearest_m] || o['nearest_m']
            far = o[:farthest_m] || o['farthest_m']
            size_hint = frac >= 15 ? 'large / close, render in full detail' : (frac <= 3 ? 'small / distant — keep it small and correctly shaped, do not lose or distort it' : 'medium')
            label = name.to_s.strip.empty? ? '(unnamed object)' : name

            sz = o[:size_m] || o['size_m']
            size_str = ''
            if sz
              w = (sz[:w] || sz['w']).to_f * 100
              d = (sz[:d] || sz['d']).to_f * 100
              h = (sz[:h] || sz['h']).to_f * 100
              size_str = format(', real-world size approx %dx%dx%dcm (W x D x H)', w.round, d.round, h.round)
            end
            color_name = o[:color_name] || o['color_name']
            color_hex = o[:color_hex] || o['color_hex']
            color_str = color_name ? ", dominant colour #{color_name} (#{color_hex})" : ''
            secondary = o[:secondary_color_name] || o['secondary_color_name']
            color_str += " — also contains a distinct #{secondary} part/item worth rendering explicitly, not just the dominant colour" if secondary

            unnamed_note = label == '(unnamed object)' ? ' — NOT explicitly named in the model: identify what real-world object this most likely is from its shape, size and colour below, and render it as that specific real object (not a vague blob).' : ''

            lines << format('%d. "%s" — %s of frame, ~%d%% of the frame, ~%sm away%s%s (%s).%s',
                            i + 1, label, zone, frac, near || far, size_str, color_str, size_hint, unnamed_note)
          end
        end

        nq = ctx[:naming_quality] || ctx['naming_quality'] || {}
        verdict = nq[:verdict] || nq['verdict']
        case verdict
        when 'good'
          lines << 'Naming quality: GOOD — use the exact material and object names above when assigning real-world materials.'
        when 'mixed'
          lines << 'Naming quality: MIXED — use the meaningful names above; for placeholder-looking names, choose materials from your visual reading.'
        when 'poor'
          lines << 'Naming quality: POOR — the names are mostly auto-generated placeholders. Assign materials from your visual reading, but DO honour the geometry, dimensions, camera and sun data above.'
        else
          lines << 'Naming quality: UNKNOWN — rely on your visual reading for materials; honour the geometry, camera and sun data above.'
        end

        lines << ''
        lines << 'HOW TO READ THIS SKETCHUP IMAGE (critical):'
        lines << 'Flat, uniform, unshaded colour fills in the image are placeholders that encode FUNCTION, not final appearance. ' \
                 'Bright yellow / orange flat areas = paved pedestrian paths, walkways or roads — render them as realistic paving ' \
                 '(stone, concrete pavers, gravel or asphalt as fits the scene), NEVER leave them yellow. ' \
                 'Flat saturated green = lawn / grass / planted ground — render as real grass and groundcover with natural colour variation. ' \
                 'Flat blue = water — render as realistic water with reflections and depth. ' \
                 'Any remaining flat single-colour surface is a placeholder: replace it with a believable real material for what it represents. ' \
                 'The SketchUp model has NO edge lines in this image; do not draw black outlines, cartoon contours or sketch strokes on anything. ' \
                 'The final image must look like a real photograph taken on site, not a 3D model, not a clay render, not an illustration.'

        lines.join("\n")
      end
    end
  end
end
