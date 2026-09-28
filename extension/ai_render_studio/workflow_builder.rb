# frozen_string_literal: true

require 'json'

module AydinCreative
  module AiRenderStudio
    # 渲染引擎：RealVisXL SDXL img2img + 双 ControlNet(Depth+Canny)（2026-09-28 从
    # Flux.2 Klein 9B KV 换回来 —— 真实原因：Flux.2 Klein 是从纯噪声生成、靠
    # ReferenceLatent 软引导 + 文字"CHANGE BUDGET 0"指令来"请"模型别改东西，这只是
    # 软约束，实测哪怕 AI 强度调到 0，画面里的物件照样会凭空消失/变形——因为生成过程
    # 压根不是从真实像素出发，没有任何机制真正锁住它。
    # 查了中英文两边的资料，建筑/室内 AI 渲染这个领域收敛到同一套方案：img2img（真实
    # 像素当起点，denoise 决定改多少）+ ControlNet（Canny 锁边缘、Depth 锁空间进深），
    # 这是唯一有"数学上的强制力"的方案——不是求模型别改，是从结构上让它很难改。
    # 咱们比一般教程更有优势：Canny/Depth 不用图像算法从截图里猜（那样会丢细节/不准），
    # 直接用 `Capture.lines`/`Capture.geometry_maps` 从真实 3D 模型渲出来，是 ground truth。
    module WorkflowBuilder
      module_function

      STRUCT_CKPT = 'RealVisXL_V5.0_fp16.safetensors'
      STRUCT_CANNY_CN = 'controlnet-canny-sdxl-1.0.fp16.safetensors'
      STRUCT_DEPTH_CN = 'controlnet-depth-sdxl-1.0-small.fp16.safetensors'
      # 看图识物用的小型 VLM——ControlNet 能锁住"这里有个这个形状的东西"，但锁不住
      # "这个形状的东西到底是床还是沙发"，深度/边线图不带语义类别信息。真实踩过的坑：
      # 一个 VRay 导入的模型构件名全是"建E_model7723"这种自动生成的乱码，ground_truth_block
      # 里没有任何"这里有张床"的文字锚点，结果床被 AI 认成了沙发+脚凳（结构位置/轮廓完全
      # 吻合，纯粹是物体类别认错了）。构件名靠不住时，直接找模型"看图说话"补上这个锚点。
      VISION_CLIP = 'gemma4_e4b_it_fp8_scaled.safetensors' # 跟旧 Qwen 管线验证过能用的同一个视觉模型

      # opts:
      #   kind:               'exterior' | 'interior'（只用来给提示词加一句场景类型，不影响图结构）
      #   input_filename:     ComfyUI input 目录里的结构图文件名（SketchUp 截图，也是 img2img 的起点像素）
      #   reference_filename: 可选，参考图文件名（只走文字提示，材质/光照灵感用，不再喂像素——见下）
      #   depth_filename:     Capture.geometry_maps 生成的深度图文件名（现在是硬约束，必须有）
      #   canny_filename:     Capture.lines 生成的线稿图文件名（SketchUp 真实边线，现在是硬约束，必须有）
      #   model_context:      ModelExtractor.extract 的结果 Hash
      #   preset_prompt:      白天/黑夜预设那句英文
      #   user_prompt:        用户手写的补充（可空）
      #   ai_strength:        0-100 —— 现在真正映射到 denoise + ControlNet 强度两个数值参数，
      #                        不再只是一句"请模型别改"的文字请求
      #   aspect_ratio/resolution: 最终输出比例/清晰度
      #   seed:               整数（可空 → 随机）
      # 调参血泪史：前几轮全是自己瞎猜（denoise/cn强度在同一个滑块里反复拉扯），
      # 结果要么结构崩要么画质糊，Ayden 说得对——没去看真正做出过好效果的人怎么配的。
      # 后来去查了实际发布过的 archviz ComfyUI 工作流（civitai 上一个真实点赞量不低的
      # SDXL+ControlNet 建筑工作流、以及另一篇 4-pass 教程），发现人家从来不指望"结构锁定"
      # 这一遍就把材质画到位——是分成"结构/geometry"(中等denoise + ControlNet强度~0.8/
      # end~0.7) → "材质/material"(低denoise~0.45，这一遍完全不带ControlNet) 两遍，
      # 一遍一个职责。这跟咱们的两阶段架构(build()的ControlNet锁定 → build_enhance纯
      # 精修)形状是对的，问题出在具体数值上——之前 denoise 常年顶到 0.70-0.90 是在逼这一遍
      # 同时干两件事，参考别人验证过的真实数值往回调。
      STRUCT_DENOISE_MIN = 0.55  # ai_strength=0——参考发布工作流"geometry pass"档位，不再自己瞎顶
      STRUCT_DENOISE_MAX = 0.72  # ai_strength=100
      STRUCT_CN_STRENGTH_MAX = 0.80 # ai_strength=0——参考发布工作流的 0.8
      STRUCT_CN_STRENGTH_MIN = 0.40 # ai_strength=100
      STRUCT_CN_END_MAX = 0.75  # ai_strength=0——参考发布工作流的 end=0.7，留够步数给材质
      STRUCT_CN_END_MIN = 0.45  # ai_strength=100

      def build(opts)
        strength = (opts[:ai_strength].nil? ? 25 : opts[:ai_strength].to_i).clamp(0, 100)
        t = strength / 100.0
        structure_image = opts.fetch(:input_filename)
        depth_image = opts[:depth_filename].to_s.empty? ? nil : opts[:depth_filename]
        canny_image = opts[:canny_filename].to_s.empty? ? nil : opts[:canny_filename]
        seed = opts[:seed] && opts[:seed].to_i.positive? ? opts[:seed].to_i : rand(1..2_147_483_646)
        stamp = Time.now.strftime('%Y%m%d_%H%M%S')

        denoise = (STRUCT_DENOISE_MIN + t * (STRUCT_DENOISE_MAX - STRUCT_DENOISE_MIN)).round(3)
        cn_strength = (STRUCT_CN_STRENGTH_MAX - t * (STRUCT_CN_STRENGTH_MAX - STRUCT_CN_STRENGTH_MIN)).round(3)
        cn_end = (STRUCT_CN_END_MAX - t * (STRUCT_CN_END_MAX - STRUCT_CN_END_MIN)).round(3)

        graph = {
          '1' => { 'class_type' => 'CheckpointLoaderSimple', 'inputs' => { 'ckpt_name' => STRUCT_CKPT } },
          '2' => { 'class_type' => 'LoadImage', 'inputs' => { 'image' => structure_image } },
          # SDXL 在明显偏离它训练时那套分辨率桶(~1MP 附近)的尺寸上跑，denoise 一高就容易崩成
          # 马赛克/重复贴块（实测复现过）——结构图原始分辨率是按输出长边定的(1400 左右)，
          # 跟 SDXL 舒适区不是一回事，扩散阶段必须先缩到 ~1MP，最终分辨率交给后面
          # apply_resolution 再放大，这是从旧 Flux.2 管线里学到、这次重写时漏掉又踩回来的教训。
          '2s' => { 'class_type' => 'ImageScaleToTotalPixels', 'inputs' => {
            'image' => ['2', 0], 'upscale_method' => 'lanczos', 'megapixels' => 1.0, 'resolution_steps' => 1
          } },
          '2sz' => { 'class_type' => 'GetImageSize', 'inputs' => { 'image' => ['2s', 0] } },
          # 看图识物：小型 VLM 直接看结构图，逐类点名"这里到底有没有床/沙发/椅子/桌子/…"。
          # 真实调试过一次：单独把 VLM 输出用 ShowText 摘出来看，它其实**答对了**（准确说出
          # "Bed: Center, Background"）——问题不在识别，在它被埋进一大段长提示词里权重被
          # 稀释，扩散模型没真正听进去。改法：(1) 逼它用简短的"类别(位置)"清单格式作答，
          # 不要长句/编号/markdown；(2) 挪到提示词最前面(首因效应，注意力权重更高)；
          # (3) 用 ComfyUI CLIPTextEncode 原生支持的 (文本:权重) 语法把这段整体加权。
          'vclip' => { 'class_type' => 'CLIPLoader', 'inputs' => { 'clip_name' => VISION_CLIP, 'type' => 'ltxv' } },
          'vlm' => { 'class_type' => 'TextGenerate', 'inputs' => {
            'clip' => ['vclip', 0], 'image' => ['2s', 0], 'prompt' => vision_checklist_prompt,
            'max_length' => 150, 'sampling_mode' => 'off'
          } },
          'vlm_a' => { 'class_type' => 'StringConcatenate', 'inputs' => {
            'string_a' => "#{vision_lead_in(opts)}\n(", 'string_b' => ['vlm', 0], 'delimiter' => ''
          } },
          'vlm_b' => { 'class_type' => 'StringConcatenate', 'inputs' => {
            'string_a' => ['vlm_a', 0], 'string_b' => ':1.4)', 'delimiter' => ''
          } },
          # 2026-09-28：以前这里拼的是给 LLM 型模型写的长篇 ground truth(几百上千 token)，
          # SDXL 的 CLIP 一段只读 77 token，后面全是噪声，反而冲淡了关键词。改成 SDXL 认的
          # 短关键词串(见 sdxl_prompt)；长篇结构化描述留给云端引擎(CloudPrompt)。
          'p2' => { 'class_type' => 'StringConcatenate', 'inputs' => {
            'string_a' => ['vlm_b', 0], 'string_b' => sdxl_prompt(opts), 'delimiter' => ",\n"
          } },
          '3' => { 'class_type' => 'CLIPTextEncode', 'inputs' => { 'clip' => ['1', 1], 'text' => ['p2', 0] } },
          '4' => { 'class_type' => 'CLIPTextEncode', 'inputs' => { 'clip' => ['1', 1], 'text' => structural_negative } },
          '9' => { 'class_type' => 'VAEEncode', 'inputs' => { 'pixels' => ['2s', 0], 'vae' => ['1', 2] } }
        }

        # ControlNet 链：Depth 先锁空间进深，Canny 再锁边缘/线脚——都是从真实 3D 模型渲出来的
        # ground truth（不是图像算法从截图里猜的），一层套一层地把 positive/negative 都接住。
        # 深度图/边线图各自的原始分辨率跟结构图不一样(深度图是射线网格，通常粗得多)，喂给
        # ControlNet 前必须显式缩放到跟扩散阶段完全一致的宽高，不能指望节点自己对齐。
        pos_link = ['3', 0]
        neg_link = ['4', 0]
        cn_layers = [[depth_image, STRUCT_DEPTH_CN, 'depth'], [canny_image, STRUCT_CANNY_CN, 'canny']]
        cn_layers.each_with_index do |(filename, model_name, tag), i|
          next unless filename
          base = "cn_#{tag}"
          graph["#{base}_img"] = { 'class_type' => 'LoadImage', 'inputs' => { 'image' => filename } }
          graph["#{base}_rs"] = { 'class_type' => 'ImageScale', 'inputs' => {
            'image' => ["#{base}_img", 0], 'upscale_method' => 'lanczos',
            'width' => ['2sz', 0], 'height' => ['2sz', 1], 'crop' => 'disabled'
          } }
          cn_input = ["#{base}_rs", 0]
          if tag == 'canny'
            # 2026-09-28 修的 bug：Capture.lines 出的是"白底/色块 + 黑线"，而 SDXL Canny ControlNet
            # 训练时吃的是"黑底白线"的 Canny 边缘图。以前直接把线稿原图喂进去，等于告诉模型
            # "满屏都是边缘"，Canny 约束基本失效——这是本地管线结构总是跑偏的主要原因之一。
            # 过一遍 Canny 节点，得到标准的黑底白线边缘图。
            graph["#{base}_edge"] = { 'class_type' => 'Canny', 'inputs' => {
              'image' => ["#{base}_rs", 0], 'low_threshold' => 0.15, 'high_threshold' => 0.35
            } }
            cn_input = ["#{base}_edge", 0]
          end
          graph["#{base}_model"] = { 'class_type' => 'ControlNetLoader', 'inputs' => { 'control_net_name' => model_name } }
          graph["#{base}_apply"] = { 'class_type' => 'ControlNetApplyAdvanced', 'inputs' => {
            'positive' => pos_link, 'negative' => neg_link, 'control_net' => ["#{base}_model", 0],
            'image' => cn_input, 'strength' => cn_strength, 'start_percent' => 0.0, 'end_percent' => cn_end
          } }
          pos_link = ["#{base}_apply", 0]
          neg_link = ["#{base}_apply", 1]
          _ = i
        end

        graph['12'] = { 'class_type' => 'KSampler', 'inputs' => {
          'model' => ['1', 0], 'seed' => seed, 'steps' => 28, 'cfg' => 4.5,
          'sampler_name' => 'dpmpp_2m', 'scheduler' => 'karras',
          'positive' => pos_link, 'negative' => neg_link, 'latent_image' => ['9', 0], 'denoise' => denoise
        } }
        graph['124'] = { 'class_type' => 'VAEDecode', 'inputs' => { 'samples' => ['12', 0], 'vae' => ['1', 2] } }
        # 不带 "_final" 后缀、也不在这里放大到目标分辨率——这一步是"结构锁定"阶段的中间产物，
        # 真正对外的成品要再经过 build_enhance 那一遍低降噪精修（见 main.rb 的两阶段调用），
        # 那一遍没有 ControlNet 掺和，专心把材质画细，还顺便负责放大到目标分辨率。
        # 直接在这一步就放大再喂给第二阶段，会把这一步已经不算干净的画面等比例放大，
        # 反而放大了瑕疵；分辨率放大放在第二阶段末尾一次做完更干净。
        graph['94'] = { 'class_type' => 'SaveImage', 'inputs' => { 'filename_prefix' => "SU_AI_Render/#{stamp}_stage1", 'images' => ['124', 0] } }
        graph
      end

      # ---- 提示词拼装 -------------------------------------------------------
      # 结构（不许改什么/改多少）现在完全靠 denoise + ControlNet 两个数值参数硬保证，
      # 提示词只负责材质/光照/氛围这些"怎么好看"的部分——这跟 Flux.2 Klein 时代刚好反过来
      # （那时候提示词还要兼职"请模型别改东西"，这次不用了，这部分交给 ControlNet）。
      # 拆成 lead_in / body / suffix 三段（而不是一整串）是因为最前面要插一段 ComfyUI 图里
      # 跑出来的 VLM"看图识物"结果并加权（见 build() 里的 StringConcatenate 链），
      # Ruby 这边只管拼 VLM 前后的文字。
      def vision_lead_in(opts)
        kind_label = opts[:kind].to_s == 'interior' ? 'interior' : 'exterior'
        "professional architectural #{kind_label} photograph of"
      end

      # SDXL 用的短提示词：关键词、逗号分隔、重要的放前面，整体尽量压在 ~60 个词以内。
      def sdxl_prompt(opts)
        interior = opts[:kind].to_s == 'interior'
        kw = []
        mats = materials_keywords(opts[:model_context])
        kw << mats unless mats.empty?
        kw << opts[:user_prompt].to_s.strip.tr("\n", ' ') unless opts[:user_prompt].to_s.strip.empty?
        kw << opts[:preset_prompt].to_s.split(/[.;]/).first.to_s.strip unless opts[:preset_prompt].to_s.strip.empty?
        kw << (interior ? 'warm interior lighting, soft daylight from windows' : 'natural daylight, real sky, real landscaping')
        kw << 'photorealistic, physically based materials, fine surface texture, soft realistic shadows, ' \
              'ambient occlusion, DSLR 24mm, high dynamic range, sharp focus, 8k photo'
        kw.join(', ')
      end

      # 材质 → 关键词（取画面占比最高的几种，名字能用就用名字，否则只用物理类别）
      def materials_keywords(ctx)
        return '' unless ctx
        mats = ctx[:visible_materials] || ctx['visible_materials'] || []
        mats.first(6).map do |x|
          name = (x[:name] || x['name']).to_s
          next if name.start_with?('(')
          hint = material_physics_hint(name, x[:texture_file] || x['texture_file'])
          hint ? hint.split(':').first : nil
        end.compact.uniq.map { |c| "real #{c}" }.join(', ')
      end

      def structural_prompt_body(opts, strength)
        parts = []
        parts << 'The exact geometry, camera framing and position of every object shown are fixed by Depth and ' \
                  'Canny edge maps applied as hard structural constraints elsewhere in this pipeline - focus ' \
                  'entirely on materials, lighting and atmosphere.'
        parts << ground_truth_block(opts[:model_context])
        parts << strength_directive(strength)

        ref_note = opts[:reference_filename].to_s.empty? ? nil : reference_directive(strength)
        if ref_note
          parts << ref_note
        elsif !opts[:preset_prompt].to_s.strip.empty?
          parts << "Lighting and weather mood: #{opts[:preset_prompt].strip}"
        end
        parts.join("\n\n")
      end

      def structural_prompt_suffix(opts)
        kind_label = opts[:kind].to_s == 'interior' ? 'interior' : 'exterior'
        parts = []
        unless opts[:user_prompt].to_s.strip.empty?
          parts << "Additional art direction from the designer (follow this): #{opts[:user_prompt].strip.tr("\n", ' ')}"
        end
        parts << photo_contract(kind_label)
        parts.join("\n\n")
      end

      # 清单式提问逼模型逐类点名——比开放式"描述一下这张图"精确得多（同样的技巧在旧 Qwen
      # 管线里验证过：开放式描述会漏细节，清单式能强迫覆盖到每一类）。
      # 真实调试过一次(用 ShowText 单独摘出过 VLM 原始回答)：这个模型的识别本身是准的，
      # 之前那版长句子+编号+"Background/Foreground"这种啰嗦格式，在拼进最终大段提示词后
      # 权重被稀释掉了，扩散模型没真正听进去。这版逼它只输出"类别(位置)"的极简逗号列表，
      # 没有多余的句子和格式噪音——越短越不容易被后面一大段 ground truth 文本盖过去。
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

      def structural_negative
        'changed composition, added or removed objects, missing furniture, extra furniture, duplicated objects, ' \
        'floating objects, deformed or warped geometry, wrong proportions, melted or distorted shapes, ' \
        'sketchup screenshot, clay render, cgi, 3d render, cartoon, illustration, flat untextured surfaces, ' \
        'plastic looking material, black outlines, sketch strokes, oversharpen halos, washed out, muddy, ' \
        'dark murky, watermark, text, logo, blurry, low quality'
      end

      # ---- 参考图指令 -------------------------------------------------------
      # 这版架构里参考图不再把像素喂给模型（SDXL 单文本编码器，没有 Flux.2 Klein 那种多图
      # 输入能力），只作为文字层面的风格提示——真正的材质/光照描述交给用户在提示词框里写，
      # 或者靠预设。这是这次换回 img2img+ControlNet 架构的已知取舍，先牺牲参考图的精确度
      # 换"绝对不丢物体"这个更重要的保证，后续如果需要可以接 IP-Adapter 之类的方案补回来。
      def reference_directive(strength)
        if strength <= 35
          'A reference photo was provided by the designer for MATERIALS AND LIGHTING MOOD ONLY - lean the colour ' \
          'palette, surface finishes and lighting quality in that general direction. Do NOT change any furniture, ' \
          'object, layout or architectural feature to match it - the geometry constraints above are absolute.'
        else
          'A reference photo was provided as a style cue: lean the materials, lighting mood and overall aesthetic ' \
          'toward it, while the geometry constraints above remain the structural basis of the render.'
        end
      end

      # ---- 摄影合同（固定尾串）——— 往"专业建筑摄影"方向拉硬一点 -----------
      # 室内/室外分开写：之前踩过的坑——室外那套"草地/碎石铺装/远山"的措辞如果不分场景
      # 无脑拼进每张图，室内场景 AI 真的会去地板上画草地和碎石花园（实测复现过）。
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

      # ---- 细节锁：独立的第二遍（Qwen 管线遗留，Flux.2 Klein 暂时不用）-------
      # 换成 Flux.2 Klein 9B 后先停用：实测它自己对线脚/接缝这类细节保留得就不错，
      # 不再需要这个单独的 Canny ControlNet 补细节遍。方法留着，以后要是发现细节
      # 丢失还想用，把这里改回真实判断、在 main.rb 里接上就行。
      def detail_needed?(_lines_filename, _strength)
        false
      end

      def build_detail_pass(base_filename:, lines_filename:, strength:, resolution: nil, aspect_ratio: nil)
        s = strength.to_i.clamp(0, 100)
        cn = (0.58 - s / 280.0).round(3).clamp(0.12, 0.58)   # s0≈0.58, s50≈0.40, s75≈0.31 —— 轻推，别把画面拉回平面
        dn = 0.34                                             # 低去噪：只补细节，不重画
        seed = rand(1..2_147_483_646)
        stamp = Time.now.strftime('%Y%m%d_%H%M%S')

        pos = 'a real professional interior / architectural photograph, DSLR, natural light, rich physically-based ' \
              'materials with fine microtexture, warm realistic lighting, soft true shadows and reflections, ' \
              'high dynamic range, colour graded. Every architectural line is crisp and accurate: wall panel ' \
              'mouldings, ceiling cornice profiles, trim reveals, quilted / tufted upholstery seams, cabinet ' \
              'grooves - sharp and exactly matching the line drawing. Keep the colours, materials, furniture and ' \
              'lighting of the input photo unchanged; only sharpen and correct the geometry and add real texture.'
        neg = 'blurred or melted mouldings, smeared trim, lost panel lines, flat untextured surfaces, ' \
              'sketchup screenshot, clay render, cgi, 3d render, cartoon, illustration, plastic, warped geometry, ' \
              'wobbly lines, oversharpen halos, washed out, muddy, dark murky, watermark, text'

        g = {
          '1' => { 'class_type' => 'CheckpointLoaderSimple', 'inputs' => { 'ckpt_name' => 'RealVisXL_V5.0_fp16.safetensors' } },
          '2' => { 'class_type' => 'LoadImage', 'inputs' => { 'image' => base_filename } },
          '3' => { 'class_type' => 'LoadImage', 'inputs' => { 'image' => lines_filename } },
          '4' => { 'class_type' => 'Canny', 'inputs' => { 'image' => ['3', 0], 'low_threshold' => 0.1, 'high_threshold' => 0.35 } },
          '5' => { 'class_type' => 'ControlNetLoader', 'inputs' => { 'control_net_name' => 'controlnet-canny-sdxl-1.0.fp16.safetensors' } },
          '6' => { 'class_type' => 'CLIPTextEncode', 'inputs' => { 'clip' => ['1', 1], 'text' => pos } },
          '7' => { 'class_type' => 'CLIPTextEncode', 'inputs' => { 'clip' => ['1', 1], 'text' => neg } },
          '8' => { 'class_type' => 'ControlNetApplyAdvanced', 'inputs' => {
            'positive' => ['6', 0], 'negative' => ['7', 0], 'control_net' => ['5', 0], 'image' => ['4', 0],
            'strength' => cn, 'start_percent' => 0.0, 'end_percent' => 1.0
          } },
          '9'  => { 'class_type' => 'VAEEncode', 'inputs' => { 'pixels' => ['2', 0], 'vae' => ['1', 2] } },
          '10' => { 'class_type' => 'KSampler', 'inputs' => {
            'model' => ['1', 0], 'seed' => seed, 'steps' => 22, 'cfg' => 5.0,
            'sampler_name' => 'dpmpp_2m', 'scheduler' => 'karras',
            'positive' => ['8', 0], 'negative' => ['8', 1], 'latent_image' => ['9', 0], 'denoise' => dn
          } },
          '11' => { 'class_type' => 'VAEDecode', 'inputs' => { 'samples' => ['10', 0], 'vae' => ['1', 2] } }
        }
        last = '11'
        if resolution && aspect_ratio
          short = RES_SHORT_EDGE[resolution.to_s] || 1080
          ar = aspect_ratio.to_f
          ar = 16.0 / 9.0 if ar <= 0
          w = (ar >= 1.0 ? (short * ar).round : short)
          h = (ar >= 1.0 ? short : (short / ar).round)
          w -= w % 8; h -= h % 8
          if [w, h].max > 1600
            g['20'] = { 'class_type' => 'UpscaleModelLoader', 'inputs' => { 'model_name' => 'realesrganX4plus_v1.pt' } }
            g['21'] = { 'class_type' => 'ImageUpscaleWithModel', 'inputs' => { 'upscale_model' => ['20', 0], 'image' => ['11', 0] } }
            g['22'] = { 'class_type' => 'ImageScale', 'inputs' => { 'image' => ['21', 0], 'upscale_method' => 'lanczos', 'width' => w, 'height' => h, 'crop' => 'disabled' } }
            last = '22'
          else
            g['22'] = { 'class_type' => 'ImageScale', 'inputs' => { 'image' => ['11', 0], 'upscale_method' => 'lanczos', 'width' => w, 'height' => h, 'crop' => 'disabled' } }
            last = '22'
          end
        end
        g['30'] = { 'class_type' => 'SaveImage', 'inputs' => { 'images' => [last, 0], 'filename_prefix' => "SU_AI_Render/#{stamp}_final" } }
        g
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

      # ---- 输出分辨率 / 比例 -------------------------------------------
      # img2img 直接在结构图原始分辨率(SOURCE_LONG_EDGE=1400 长边)上跑，这里把最终图
      # 缩放到用户选的目标像素；长边 >1600 时先过 ESRGAN 4x 再精确缩放（见 memory 里
      # "别把扩散推到 4K" 的教训）。图源是 VAEDecode(124)，输出接回 SaveImage(94)。
      RES_SHORT_EDGE = {
        '240p' => 240, '360p' => 360, '480p' => 480, '720p' => 720,
        '1080p' => 1080, '1440p' => 1440, '2160p' => 2160, '4k' => 2160, '4K' => 2160
      }.freeze

      def apply_resolution(graph, aspect_ratio, resolution)
        short = RES_SHORT_EDGE[resolution.to_s] || 1080
        ar = aspect_ratio.to_f
        ar = 16.0 / 9.0 if ar <= 0

        if ar >= 1.0
          w = (short * ar).round
          h = short
        else
          w = short
          h = (short / ar).round
        end
        w -= w % 8
        h -= h % 8
        w = 64 if w < 64
        h = 64 if h < 64

        if [w, h].max <= 1600
          graph['50'] = { 'class_type' => 'ImageScale', 'inputs' => {
            'image' => ['124', 0], 'upscale_method' => 'lanczos',
            'width' => w, 'height' => h, 'crop' => 'disabled'
          } }
          graph['94']['inputs']['images'] = ['50', 0]
        else
          graph['51'] = { 'class_type' => 'UpscaleModelLoader',
                          'inputs' => { 'model_name' => 'realesrganX4plus_v1.pt' } }
          graph['52'] = { 'class_type' => 'ImageUpscaleWithModel',
                          'inputs' => { 'upscale_model' => ['51', 0], 'image' => ['124', 0] } }
          graph['53'] = { 'class_type' => 'ImageScale', 'inputs' => {
            'image' => ['52', 0], 'upscale_method' => 'lanczos',
            'width' => w, 'height' => h, 'crop' => 'disabled'
          } }
          graph['94']['inputs']['images'] = ['53', 0]
        end
      end

      # ---- AI 调色 --------------------------------------------------------
      # 拿现有渲染图，走一遍低降噪 RealVisXL，只改色调/对比/氛围，不动内容。
      def build_grade(input_filename:, instruction:)
        instr = instruction.to_s.strip
        instr = 'subtle professional color grade' if instr.empty?
        pos = "Professional photographic color grading applied to this photo: #{instr}. " \
              'Keep the composition, geometry, objects and details EXACTLY the same - only adjust colour, ' \
              'white balance, tone curve, contrast, saturation and overall mood. Result must still look like a ' \
              'real photograph, natural and believable.'
        neg = 'changed composition, added or removed objects, deformed geometry, warped lines, cartoon, ' \
              'illustration, cgi, 3d render, oversharpened, halo artifacts, banding, posterization, watermark, text'
        seed = rand(1..2_147_483_646)
        stamp = Time.now.strftime('%Y%m%d_%H%M%S')

        {
          '1'  => { 'class_type' => 'CheckpointLoaderSimple', 'inputs' => { 'ckpt_name' => 'RealVisXL_V5.0_fp16.safetensors' } },
          '2'  => { 'class_type' => 'LoadImage', 'inputs' => { 'image' => input_filename } },
          '3'  => { 'class_type' => 'CLIPTextEncode', 'inputs' => { 'clip' => ['1', 1], 'text' => pos } },
          '4'  => { 'class_type' => 'CLIPTextEncode', 'inputs' => { 'clip' => ['1', 1], 'text' => neg } },
          '5'  => { 'class_type' => 'VAEEncode', 'inputs' => { 'pixels' => ['2', 0], 'vae' => ['1', 2] } },
          '6'  => { 'class_type' => 'KSampler', 'inputs' => {
            'model' => ['1', 0], 'seed' => seed, 'steps' => 22, 'cfg' => 5.0,
            'sampler_name' => 'dpmpp_2m', 'scheduler' => 'karras',
            'positive' => ['3', 0], 'negative' => ['4', 0], 'latent_image' => ['5', 0], 'denoise' => 0.30
          } },
          '7'  => { 'class_type' => 'VAEDecode', 'inputs' => { 'samples' => ['6', 0], 'vae' => ['1', 2] } },
          '8'  => { 'class_type' => 'SaveImage', 'inputs' => { 'images' => ['7', 0], 'filename_prefix' => "SU_AI_Render/#{stamp}_grade_final" } }
        }
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

      # ---- 真实感增强：任意来源的渲染图都能喂进来精修材质/光影细节 ------------
      # 给"上传别的渲染软件出的图，让它更照片级"这个功能用。Ayden 明确要求"绝对不
      # 改变任何物体"，所以走 RealVisXL 低降噪 img2img（有真实像素当起点），
      # 不用 Flux.2 Klein 那条从纯噪声生成、靠 ReferenceLatent 软约束的路线——
      # denoise 有一个绝对上限，比生成式管线更能把"不改构图"这个承诺落到实处。
      ENHANCE_DENOISE_MIN = 0.12
      ENHANCE_DENOISE_MAX = 0.45

      # resolution/aspect_ratio 可选——不传就只精修不改尺寸（"上传图片增强真实感"那个独立
      # 功能用这个默认行为）；传了就在精修完之后再放大到目标分辨率（结构锁定管线两阶段的
      # 第二阶段用这个，一次做完精修+放大，见 build() 顶部注释）。
      # depth_filename/canny_filename：渲染管线第二阶段会传进来——带着结构约束精修，
      # denoise 封顶 0.32。以前第二阶段不带约束、denoise 0.45，会把第一阶段锁住的结构画走样。
      def build_enhance(input_filename:, strength:, resolution: nil, aspect_ratio: nil,
                        depth_filename: nil, canny_filename: nil)
        s = strength.to_i.clamp(0, 100)
        dn = (ENHANCE_DENOISE_MIN + (s / 100.0) * (ENHANCE_DENOISE_MAX - ENHANCE_DENOISE_MIN)).round(3)
        guided = depth_filename || canny_filename
        dn = [dn, 0.32].min if guided
        seed = rand(1..2_147_483_646)
        stamp = Time.now.strftime('%Y%m%d_%H%M%S')

        pos = 'Enhance this existing render into an authentic real photograph: physically-accurate materials with ' \
              'fine microtexture (wood grain, fabric weave, stone veining, metal reflections as appropriate to each ' \
              'surface), realistic soft shadows and ambient occlusion, believable reflections, natural lighting ' \
              'falloff, subtle film grain, balanced colour grading, crisp but natural focus. Do NOT change the ' \
              'composition, camera angle, perspective, layout, objects, furniture, colours or the count/position of ' \
              'anything in the scene - only add photographic realism, fine surface detail and natural imperfections ' \
              'on top of exactly what is already there.'
        neg = 'changed composition, added or removed objects, different camera angle, deformed or warped geometry, ' \
              'cartoon, illustration, cgi look, 3d render look, clay render, flat untextured surfaces, plastic sheen, ' \
              'oversharpened halos, banding, posterization, watermark, text, logo, blurry, low quality'

        g = {
          '1' => { 'class_type' => 'CheckpointLoaderSimple', 'inputs' => { 'ckpt_name' => 'RealVisXL_V5.0_fp16.safetensors' } },
          '2' => { 'class_type' => 'LoadImage', 'inputs' => { 'image' => input_filename } },
          # 跟 build() 里同样的教训：输入图分辨率跟 SDXL 舒适区差太远、denoise 又不算低时
          # 会画崩(马赛克/重复贴块)——上传的外部渲染图分辨率可能是任意的，必须先归一化。
          '2s' => { 'class_type' => 'ImageScaleToTotalPixels', 'inputs' => {
            'image' => ['2', 0], 'upscale_method' => 'lanczos', 'megapixels' => 1.0, 'resolution_steps' => 1
          } },
          '3' => { 'class_type' => 'CLIPTextEncode', 'inputs' => { 'clip' => ['1', 1], 'text' => pos } },
          '4' => { 'class_type' => 'CLIPTextEncode', 'inputs' => { 'clip' => ['1', 1], 'text' => neg } },
          '5' => { 'class_type' => 'VAEEncode', 'inputs' => { 'pixels' => ['2s', 0], 'vae' => ['1', 2] } },
          '6' => { 'class_type' => 'KSampler', 'inputs' => {
            'model' => ['1', 0], 'seed' => seed, 'steps' => 24, 'cfg' => 5.0,
            'sampler_name' => 'dpmpp_2m', 'scheduler' => 'karras',
            'positive' => ['3', 0], 'negative' => ['4', 0], 'latent_image' => ['5', 0], 'denoise' => dn
          } },
          '7' => { 'class_type' => 'VAEDecode', 'inputs' => { 'samples' => ['6', 0], 'vae' => ['1', 2] } }
        }

        if guided
          g['2sz'] = { 'class_type' => 'GetImageSize', 'inputs' => { 'image' => ['2s', 0] } }
          pos = ['3', 0]
          neg = ['4', 0]
          [[depth_filename, STRUCT_DEPTH_CN, 'depth'], [canny_filename, STRUCT_CANNY_CN, 'canny']].each do |file, cn, tag|
            next unless file
            b = "e_#{tag}"
            g["#{b}_img"] = { 'class_type' => 'LoadImage', 'inputs' => { 'image' => file } }
            g["#{b}_rs"] = { 'class_type' => 'ImageScale', 'inputs' => {
              'image' => ["#{b}_img", 0], 'upscale_method' => 'lanczos',
              'width' => ['2sz', 0], 'height' => ['2sz', 1], 'crop' => 'disabled'
            } }
            src = ["#{b}_rs", 0]
            if tag == 'canny'
              g["#{b}_edge"] = { 'class_type' => 'Canny', 'inputs' => { 'image' => src, 'low_threshold' => 0.15, 'high_threshold' => 0.35 } }
              src = ["#{b}_edge", 0]
            end
            g["#{b}_model"] = { 'class_type' => 'ControlNetLoader', 'inputs' => { 'control_net_name' => cn } }
            g["#{b}_apply"] = { 'class_type' => 'ControlNetApplyAdvanced', 'inputs' => {
              'positive' => pos, 'negative' => neg, 'control_net' => ["#{b}_model", 0], 'image' => src,
              'strength' => 0.5, 'start_percent' => 0.0, 'end_percent' => 0.8
            } }
            pos = ["#{b}_apply", 0]
            neg = ["#{b}_apply", 1]
          end
          g['6']['inputs']['positive'] = pos
          g['6']['inputs']['negative'] = neg
        end

        last = '7'
        if resolution && aspect_ratio
          short = RES_SHORT_EDGE[resolution.to_s] || 1080
          ar = aspect_ratio.to_f
          ar = 16.0 / 9.0 if ar <= 0
          w = (ar >= 1.0 ? (short * ar).round : short)
          h = (ar >= 1.0 ? short : (short / ar).round)
          w -= w % 8; h -= h % 8
          if [w, h].max > 1600
            g['20'] = { 'class_type' => 'UpscaleModelLoader', 'inputs' => { 'model_name' => 'realesrganX4plus_v1.pt' } }
            g['21'] = { 'class_type' => 'ImageUpscaleWithModel', 'inputs' => { 'upscale_model' => ['20', 0], 'image' => ['7', 0] } }
            g['22'] = { 'class_type' => 'ImageScale', 'inputs' => { 'image' => ['21', 0], 'upscale_method' => 'lanczos', 'width' => w, 'height' => h, 'crop' => 'disabled' } }
          else
            g['22'] = { 'class_type' => 'ImageScale', 'inputs' => { 'image' => ['7', 0], 'upscale_method' => 'lanczos', 'width' => w, 'height' => h, 'crop' => 'disabled' } }
          end
          last = '22'
        end
        g['8'] = { 'class_type' => 'SaveImage', 'inputs' => { 'images' => [last, 0], 'filename_prefix' => "SU_AI_Render/#{stamp}_enhance_final" } }
        g
      end

      # ---- Ground truth 文本块 -------------------------------------------

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
