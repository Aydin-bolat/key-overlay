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

      # 看图识物用的小型 VLM（gemma）：ControlNet 锁得住"这里有个这个形状的东西"，锁不住"它到底是床还是沙发"。
      # 构件名是乱码时（比如 VRay 导入的"建E_model7723"），靠它看图告诉扩散模型物体类别。
      VISION_CLIP = 'gemma4_e4b_it_fp8_scaled.safetensors'

      RES_SHORT_EDGE = {
        '240p' => 240, '360p' => 360, '480p' => 480, '720p' => 720,
        '1080p' => 1080, '1440p' => 1440, '2160p' => 2160, '4k' => 2160, '4K' => 2160
      }.freeze

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

      # ---- 材质物理质感字典 -------------------------------------------------
      # Ayden 要的"认知材质挑选光滑/硬度/毛发"：不需要另接一个 PBR 贴图生成模型
      # (Ubisoft CHORD / TRELLIS2 这类是给"造贴图数据"用的，跟咱们直接出一张成品
      # 照片的模式接不上)，纯粹是提示词工程——SketchUp 材质名/贴图文件名本身就是
      # 很强的关键词信号(比如"Fabric_Sofa"/"木地板")，按关键词分类后每类补一句该
      # 材质该有的物理质感(粗糙度/反光/绒毛方向)，比通用的"photorealistic materials"
      # 精确得多。中英文关键词都配，顺序即优先级，第一个命中的算数。
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

      # ---- 模型文件自动识别 ---------------------------------------------------
      # 不写死文件名：去 ComfyUI 的模型目录里按关键字找。实际装机时常见的几种"其实有、但没被找到"：
      #   - Z-Image 的 ControlNet 放进了 controlnet/（它是 model patch，必须在 model_patches/）
      #   - 用的是 GGUF 量化版（ComfyUI-GGUF 把它们列在 unet_gguf / clip_gguf 下，不在 diffusion_models）
      #   - 用的是整合包 checkpoint（模型 + 文本编码器 + VAE 一个文件，在 checkpoints/）
      #   - VAE 文件名不是 ae.safetensors
      # 前三种直接支持；放错文件夹的，报错时明确说"在 X 里找到了，请移到 Y"。
      ZIMAGE_RX = /z[-_ ]?image/i
      REQUIRED = {
        unet: ['diffusion_models', /z[-_ ]?image[-_ ]?turbo|z[-_ ]?image(?!.*(control|vae|patch))/i, 'z_image_turbo_bf16.safetensors',
               'https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/diffusion_models/z_image_turbo_bf16.safetensors'],
        clip: ['text_encoders', /qwen[-_ ]?3[-_ .]?4b/i, 'qwen_3_4b.safetensors',
               'https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors'],
        vae: ['vae', /\Aae[._\-]|flux|z[-_ ]?image|ultra[-_]?flux/i, 'ae.safetensors',
              'https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/vae/ae.safetensors'],
        control: ['model_patches', /z[-_ ]?image.*control|control.*z[-_ ]?image/i, 'Z-Image-Turbo-Fun-Controlnet-Union.safetensors',
                  'https://huggingface.co/alibaba-pai/Z-Image-Turbo-Fun-Controlnet-Union/resolve/main/Z-Image-Turbo-Fun-Controlnet-Union.safetensors']
      }.freeze
      # 这些 VAE 名字里可能带 flux 等字样但跟 Z-Image 不兼容
      VAE_EXCLUDE = /seedvr|sdxl|sd15|sd_?1|sd3|wan|qwen|hunyuan|ltx|cosmos|mochi|flux2|flux[-_.]?2/i
      # "Z-Image-Turbo-Fun-Controlnet..." 也含 z-image-turbo 字样，找主模型时必须排除掉
      EXCLUDE = { unet: /control|union|patch|vae|lora/i, vae: VAE_EXCLUDE }.freeze

      # 按文件名找不到时，再去这些文件夹里看看是不是放错了地方
      SEARCH_FOLDERS = %w[diffusion_models unet_gguf checkpoints text_encoders clip_gguf vae controlnet model_patches loras].freeze

      SEEDVR = {
        unet: ['diffusion_models', /seedvr2.*7b/i, /seedvr2.*3b/i, 'seedvr2_7b_int8_convrot.safetensors',
               'https://huggingface.co/Comfy-Org/SeedVR2/resolve/main/diffusion_models/seedvr2_7b_int8_convrot.safetensors'],
        vae: ['vae', /seedvr2.*vae/i, nil, 'seedvr2_ema_vae_fp16.safetensors',
              'https://huggingface.co/Comfy-Org/SeedVR2/resolve/main/vae/seedvr2_ema_vae_fp16.safetensors']
      }.freeze

      ZIMAGE_NODES = %w[ModelPatchLoader QwenImageDiffsynthControlnet ModelSamplingAuraFlow ConditioningZeroOut].freeze
      SEEDVR_NODES = %w[SeedVR2Preprocess SeedVR2Conditioning SeedVR2PostProcessing VAEEncodeTiled VAEDecodeTiled].freeze

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

      # 返回 { ok:, models: {...}, missing: [文字说明...], seedvr: {...} 或 nil, found: {folder => [files]} }
      # models 里 :loader 表示主模型怎么加载：:unet（标准）| :gguf | :ckpt（整合包，clip/vae 也从它来）
      def resolve(client)
        missing = []
        nodes_missing = ZIMAGE_NODES.reject { |n| client.node?(n) }
        unless nodes_missing.empty?
          missing << "ComfyUI 版本太旧，缺少节点 #{nodes_missing.join(', ')}：请把 ComfyUI Desktop 更新到最新版"
        end

        m = {}
        # 主模型：标准 safetensors → GGUF → 整合包 checkpoint
        folder, rx, name, url = REQUIRED[:unet]
        ex = EXCLUDE[:unet]
        if (f = pick(client.models(folder), rx, ex))
          m[:unet] = f
          m[:loader] = :unet
        elsif client.node?('UnetLoaderGGUF') && (f = pick(client.models('unet_gguf'), rx, ex))
          m[:unet] = f
          m[:loader] = :gguf
        elsif (f = pick(client.models('checkpoints'), rx, ex))
          m[:ckpt] = f
          m[:loader] = :ckpt
        else
          missing << missing_line(client, :unet)
        end

        # 文本编码器 + VAE：整合包自带，不用单独找
        unless m[:loader] == :ckpt
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
          if (f = pick(client.models(folder), rx, EXCLUDE[:vae]))
            m[:vae] = f
          else
            missing << missing_line(client, :vae)
          end
        end

        folder, rx, = REQUIRED[:control]
        if (f = pick(client.models(folder), rx))
          m[:control] = f
        else
          missing << missing_line(client, :control)
        end

        seed = nil
        if SEEDVR_NODES.all? { |n| client.node?(n) }
          dm = client.models(SEEDVR[:unet][0])
          unet = pick(dm, SEEDVR[:unet][1]) || pick(dm, SEEDVR[:unet][2])
          vae = pick(client.models(SEEDVR[:vae][0]), SEEDVR[:vae][1])
          seed = { unet: unet, vae: vae } if unet && vae
        end

        found = {}
        SEARCH_FOLDERS.each { |fd| found[fd] = client.models(fd) }

        # 能一键下载的：只有"哪里都没找到"的那几个（放错文件夹的让用户自己挪，不重复下几 GB）
        downloads = []
        { unet: !m[:unet] && !m[:ckpt], clip: m[:loader] != :ckpt && !m[:clip],
          vae: m[:loader] != :ckpt && !m[:vae], control: !m[:control] }.each do |key, need|
          next unless need
          folder, rx, name, url = REQUIRED[key]
          next unless found_elsewhere(client, rx, folder, EXCLUDE[key]).empty?
          downloads << { folder: folder, name: name, url: url, gb: SIZE_GB[key] }
        end
        seedvr_dl = []
        if seed.nil? && SEEDVR_NODES.all? { |n| client.node?(n) }
          seedvr_dl << { folder: SEEDVR[:unet][0], name: SEEDVR[:unet][3], url: SEEDVR[:unet][4], gb: 8.3 } unless pick(client.models('diffusion_models'), /seedvr2/i)
          seedvr_dl << { folder: SEEDVR[:vae][0], name: SEEDVR[:vae][3], url: SEEDVR[:vae][4], gb: 0.5 } unless pick(client.models('vae'), SEEDVR[:vae][1])
        end

        { ok: missing.empty?, models: m, missing: missing, seedvr: seed, found: found,
          downloads: downloads, seedvr_downloads: seedvr_dl }
      end

      # 大概体积（GB），只用来在按钮上提示
      SIZE_GB = { unet: 12.3, clip: 8.0, vae: 0.3, control: 3.1 }.freeze

      def missing_line(client, key)
        folder, rx, name, url = REQUIRED[key]
        label = { unet: 'Z-Image Turbo 主模型', clip: '文本编码器 Qwen3-4B', vae: 'VAE', control: 'Z-Image ControlNet' }[key]
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

      def seedvr_hint
        "#{SEEDVR[:unet][0]}/#{SEEDVR[:unet][3]}  ←  #{SEEDVR[:unet][4]}\n#{SEEDVR[:vae][0]}/#{SEEDVR[:vae][3]}  ←  #{SEEDVR[:vae][4]}"
      end

      # ---- 第一阶段：Z-Image Turbo + ControlNet(SketchUp 真实边线) + img2img ---------------
      # ai_strength 0-100 → denoise / ControlNet 强度：
      #   0   : denoise 0.92, cn 0.75 —— 结构锁住，截图只提供大致的颜色分区
      #   100 : denoise 1.00, cn 0.50 —— 只保留大结构
      # 9-28 第二轮实测：cn 1.0 时成品每条棱边都被画成黑色描边、明暗平涂，像线稿上色的插画。
      # Z-Image Fun ControlNet 推荐的控制强度是 0.65-0.80，1.0 会把边线当成"要画出来的线"。
      # 9-28 实测：denoise 0.86 时成品整体灰暗发闷——img2img 把 SketchUp 截图的暗灰明暗关系
      # 原样继承了，AI 没有空间重新打光。结构靠 ControlNet(真实边线)锁，不靠低 denoise，
      # 所以把下限提到 0.90，同时截图改成"调亮、无阴影"(Capture.textured bright:)。
      DIFFUSION_MEGAPIXELS = 1.5 # ControlNet Union 训练分辨率 1328²≈1.76MP，1.5MP 附近最稳

      # lines_clean: 线稿是 SketchUp 消隐线模式出的"白底黑细线"(Capture.lines clean:) →
      # 直接反相成"黑底白线"喂 ControlNet；否则(色块+黑线的旧线稿)才用 Canny 提边。
      def build_structure(input_filename:, lines_filename:, models:, prompt:, strength:, seed:, tag:,
                          vlm_model: nil, kind: 'exterior', reference_filename: nil, lines_clean: false)
        t = strength.to_i.clamp(0, 100) / 100.0
        denoise = (0.92 + 0.08 * t).round(3)
        cn = (0.75 - 0.25 * t).round(3)
        stamp = Time.now.strftime('%Y%m%d_%H%M%S')

        g = loader_nodes(models).merge(
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
          'edge' => (lines_clean ?
            { 'class_type' => 'ImageInvert', 'inputs' => { 'image' => ['lines_s', 0] } } :
            { 'class_type' => 'Canny', 'inputs' => { 'image' => ['lines_s', 0], 'low_threshold' => 0.1, 'high_threshold' => 0.32 } }),
          'cn' => { 'class_type' => 'QwenImageDiffsynthControlnet', 'inputs' => {
            'model' => model_ref(models), 'model_patch' => ['patch', 0], 'vae' => vae_ref(models), 'image' => ['edge', 0], 'strength' => cn
          } },
          'ms' => { 'class_type' => 'ModelSamplingAuraFlow', 'inputs' => { 'model' => ['cn', 0], 'shift' => 3 } },

          'pos' => { 'class_type' => 'CLIPTextEncode', 'inputs' => { 'clip' => clip_ref(models), 'text' => prompt } },
          # Turbo 是蒸馏模型，cfg=1，不用负面提示词（官方模板就是 ConditioningZeroOut）
          'neg' => { 'class_type' => 'ConditioningZeroOut', 'inputs' => { 'conditioning' => ['pos', 0] } },
          'lat' => { 'class_type' => 'VAEEncode', 'inputs' => { 'pixels' => ['src_s', 0], 'vae' => vae_ref(models) } },
          'ks' => { 'class_type' => 'KSampler', 'inputs' => {
            'model' => ['ms', 0], 'seed' => seed, 'steps' => denoise < 1.0 ? 10 : 8, 'cfg' => 1.0,
            'sampler_name' => 'res_multistep', 'scheduler' => 'simple',
            'positive' => ['pos', 0], 'negative' => ['neg', 0], 'latent_image' => ['lat', 0], 'denoise' => denoise
          } },
          'dec' => { 'class_type' => 'VAEDecode', 'inputs' => { 'samples' => ['ks', 0], 'vae' => vae_ref(models) } },
          'save' => { 'class_type' => 'SaveImage', 'inputs' => { 'images' => ['dec', 0], 'filename_prefix' => "SU_AI_Render/#{stamp}_zimage_#{tag}" } }
        )

        # 看图识物（沿用 SDXL 管线里验证过的 gemma VLM）：构件名是乱码时，靠它告诉扩散模型
        # "这里是床不是沙发"。Qwen3 文本编码器能读长文本，直接拼在描述里，不用 SDXL 那种加权技巧。
        if vlm_model
          g['vclip'] = { 'class_type' => 'CLIPLoader', 'inputs' => { 'clip_name' => vlm_model, 'type' => 'ltxv' } }
          g['vlm'] = { 'class_type' => 'TextGenerate', 'inputs' => {
            'clip' => ['vclip', 0], 'image' => ['src_s', 0], 'prompt' => vision_checklist_prompt,
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

      # 主模型 / 文本编码器 / VAE 的加载节点（标准、GGUF、整合包三种）
      def loader_nodes(models)
        g = {}
        if models[:loader] == :ckpt
          g['ckpt'] = { 'class_type' => 'CheckpointLoaderSimple', 'inputs' => { 'ckpt_name' => models[:ckpt] } }
          return g
        end
        g['unet'] =
          if models[:loader] == :gguf
            { 'class_type' => 'UnetLoaderGGUF', 'inputs' => { 'unet_name' => models[:unet] } }
          else
            { 'class_type' => 'UNETLoader', 'inputs' => { 'unet_name' => models[:unet], 'weight_dtype' => 'default' } }
          end
        g['clip'] =
          if models[:clip_loader] == :gguf
            { 'class_type' => 'CLIPLoaderGGUF', 'inputs' => { 'clip_name' => models[:clip], 'type' => 'lumina2' } }
          else
            { 'class_type' => 'CLIPLoader', 'inputs' => { 'clip_name' => models[:clip], 'type' => 'lumina2', 'device' => 'default' } }
          end
        g['vae'] = { 'class_type' => 'VAELoader', 'inputs' => { 'vae_name' => models[:vae] } }
        g
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

      # ---- 第二阶段：高分辨率细化 → SeedVR2 精修放大 -----------------------------------
      # 9-28 实测：1.5MP 出图直接交给 SeedVR2，纹理细节不够"照片"。中间加一遍 Z-Image 高分辨率
      # 低降噪细化——参数照 ComfyUI 官方 "Z-Image-Turbo 2K Upscaler" 模板：先放大，再 5 步
      # dpmpp_2m_sde/beta、cfg 1、denoise 0.33（模板注明 0.25-0.35 是安全区，>0.35 会出瑕疵），
      # 配详细描述。这一遍在高分辨率上重画微观细节(木纹、织物、反光)，但低 denoise 不动结构。
      # 然后 SeedVR2 放到目标分辨率：一步扩散补真实纹理，LAB 颜色对齐回细化后的图。
      REFINE_DENOISE = 0.33
      REFINE_MIN_LONG = 1920
      REFINE_MAX_LONG = 2560 # 16GB 显存上 Z-Image 细化的舒适上限；再大交给 SeedVR2

      def refine_dims(width, height)
        long = [width, height].max
        target = long.clamp(REFINE_MIN_LONG, REFINE_MAX_LONG).to_f
        k = target / long
        [((width * k) / 16).round * 16, ((height * k) / 16).round * 16]
      end

      # denoise：渲染管线用 REFINE_DENOISE；结果窗口的"AI 调色 / 增强真实感"也走这张图，传自己的值
      def build_finish(input_filename:, models:, prompt:, width:, height:, seed:, seedvr: nil, esrgan: nil, refine: true,
                       denoise: REFINE_DENOISE, tag: 'final')
        stamp = Time.now.strftime('%Y%m%d_%H%M%S')
        g = { 'img' => { 'class_type' => 'LoadImage', 'inputs' => { 'image' => input_filename } } }
        src = ['img', 0]

        if refine
          rw, rh = refine_dims(width, height)
          if esrgan
            g['um'] = { 'class_type' => 'UpscaleModelLoader', 'inputs' => { 'model_name' => esrgan } }
            g['up'] = { 'class_type' => 'ImageUpscaleWithModel', 'inputs' => { 'upscale_model' => ['um', 0], 'image' => src } }
            src = ['up', 0]
          end
          g['r_in'] = { 'class_type' => 'ImageScale', 'inputs' => {
            'image' => src, 'upscale_method' => 'lanczos', 'width' => rw, 'height' => rh, 'crop' => 'disabled'
          } }
          g.merge!(loader_nodes(models))
          g['r_ms'] = { 'class_type' => 'ModelSamplingAuraFlow', 'inputs' => { 'model' => model_ref(models), 'shift' => 3 } }
          g['r_pos'] = { 'class_type' => 'CLIPTextEncode', 'inputs' => { 'clip' => clip_ref(models), 'text' => prompt } }
          g['r_neg'] = { 'class_type' => 'ConditioningZeroOut', 'inputs' => { 'conditioning' => ['r_pos', 0] } }
          g['r_lat'] = { 'class_type' => 'VAEEncode', 'inputs' => { 'pixels' => ['r_in', 0], 'vae' => vae_ref(models) } }
          g['r_ks'] = { 'class_type' => 'KSampler', 'inputs' => {
            'model' => ['r_ms', 0], 'seed' => seed, 'steps' => 5, 'cfg' => 1.0, 'sampler_name' => 'dpmpp_2m_sde', 'scheduler' => 'beta',
            'positive' => ['r_pos', 0], 'negative' => ['r_neg', 0], 'latent_image' => ['r_lat', 0], 'denoise' => denoise
          } }
          g['r_dec'] = { 'class_type' => 'VAEDecode', 'inputs' => { 'samples' => ['r_ks', 0], 'vae' => vae_ref(models) } }
          src = ['r_dec', 0]
        end

        g['rs'] = { 'class_type' => 'ImageScale', 'inputs' => {
          'image' => src, 'upscale_method' => 'lanczos', 'width' => width, 'height' => height, 'crop' => 'disabled'
        } }
        out = ['rs', 0]
        if seedvr
          tiled = { 'tile_size' => 512, 'overlap' => 128, 'temporal_size' => 4096, 'temporal_overlap' => 8 }
          g['sv_pre'] = { 'class_type' => 'SeedVR2Preprocess', 'inputs' => { 'resized_images' => ['rs', 0] } }
          g['sv_vae'] = { 'class_type' => 'VAELoader', 'inputs' => { 'vae_name' => seedvr[:vae] } }
          g['sv_unet'] = { 'class_type' => 'UNETLoader', 'inputs' => { 'unet_name' => seedvr[:unet], 'weight_dtype' => 'default' } }
          g['sv_enc'] = { 'class_type' => 'VAEEncodeTiled', 'inputs' => { 'pixels' => ['sv_pre', 0], 'vae' => ['sv_vae', 0] }.merge(tiled) }
          g['sv_cond'] = { 'class_type' => 'SeedVR2Conditioning', 'inputs' => { 'model' => ['sv_unet', 0], 'vae_conditioning' => ['sv_enc', 0] } }
          g['sv_ks'] = { 'class_type' => 'KSampler', 'inputs' => {
            'model' => ['sv_unet', 0], 'seed' => seed, 'steps' => 1, 'cfg' => 1.0, 'sampler_name' => 'euler', 'scheduler' => 'simple',
            'positive' => ['sv_cond', 0], 'negative' => ['sv_cond', 1], 'latent_image' => ['sv_enc', 0], 'denoise' => 1.0
          } }
          g['sv_dec'] = { 'class_type' => 'VAEDecodeTiled', 'inputs' => { 'samples' => ['sv_ks', 0], 'vae' => ['sv_vae', 0] }.merge(tiled) }
          g['sv_post'] = { 'class_type' => 'SeedVR2PostProcessing', 'inputs' => {
            'images' => ['sv_dec', 0], 'original_resized_images' => ['rs', 0], 'color_correction_method' => 'lab'
          } }
          out = ['sv_post', 0]
        end
        g['save'] = { 'class_type' => 'SaveImage', 'inputs' => { 'images' => out, 'filename_prefix' => "SU_AI_Render/#{stamp}_#{tag}" } }
        g
      end

      # ---- 结果窗口：AI 调色 / 上传图片增强真实感（都用 Z-Image 低降噪 img2img）------------
      GRADE_DENOISE = 0.28

      def grade_prompt(instruction)
        instr = instruction.to_s.strip
        instr = 'a subtle professional colour grade' if instr.empty?
        "A real professional architectural photograph, the same scene with this colour grade and mood: #{instr}. " \
        'Natural believable photographic colour, high dynamic range, crisp detail, every material and object unchanged.'
      end

      # 强度 0-100 → denoise 0.18-0.35（官方模板：>0.35 容易出瑕疵）
      def enhance_denoise(strength)
        (0.18 + strength.to_i.clamp(0, 100) / 100.0 * 0.17).round(3)
      end

      def enhance_prompt
        'A real professional architectural and interior photograph, shot on a full-frame camera, perfectly exposed, ' \
        'realistic global illumination and soft shadows, every surface with real physical material texture: wood grain, ' \
        'fabric weave, stone veining, metal and glass reflections. Natural colour, high dynamic range, crisp detail, ' \
        'no haze. Edges defined only by real light and material, never by drawn outlines.'
      end

      # 目标输出尺寸（8 的倍数），跟面板上"输出清晰度"一致
      def output_dims(aspect_ratio, resolution)
        short = RES_SHORT_EDGE[resolution.to_s] || 1080
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
          'A real professional interior photograph of this room for Architectural Digest, shot on a Canon EOS R5 with a 24mm tilt-shift lens at f/8, eye level, straight vertical lines, perfectly exposed.' :
          'A real professional architectural photograph of this building for an architecture magazine, shot on a Canon EOS R5 with a 24mm tilt-shift lens at f/8, straight vertical lines, perfectly exposed.')

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

        # 9-28 实测成品灰暗发闷：光的描述要具体到"光从哪来、落在哪、多亮"，并明确要干净通透的曝光
        parts << (interior ?
          'The room is bright and well lit with clean whites and rich deep shadows: daylight enters from the windows and falls across the floor and walls, every light fixture is switched on and glowing, casting warm pools of light and soft gradients onto the walls, ceiling and furniture. Realistic global illumination and bounce light, soft contact shadows under furniture, ambient occlusion in corners, subtle reflections on the floor.' :
          'The building is crisply lit with clean highlights and rich shadows, realistic global illumination, soft contact shadows, reflections in the glazing, atmospheric depth.')
        parts << 'Photorealistic, every surface shows real physical material texture: visible wood grain, fabric weave and ' \
                 'soft folds, stone veining, brushed metal, glass with reflections. Natural colour, high dynamic range, ' \
                 'strong but natural contrast, crisp detail, no haze, no grey veil. Edges between surfaces are defined ' \
                 'only by real light, shadow and material change, like in a camera photograph - never by drawn outlines.' +
                 (interior ? '' : ' Real grass, real paving, real trees and real sky.')
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
          hint = material_physics_hint(name, x[:texture_file] || x['texture_file'])
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
