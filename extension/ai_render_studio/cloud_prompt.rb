# frozen_string_literal: true

module AydinCreative
  module AiRenderStudio
    # 给云端多模态图像模型(Nano Banana Pro / Seedream)写的提示词。
    #
    # 跟 WorkflowBuilder 里给 SDXL 写的提示词完全是两回事：SDXL 只认关键词、77 token 截断；
    # 这类模型是"读指令干活"的，所以这里写成一份清楚的工作单——
    #   图 1 = SketchUp 视图(要变成照片的那张)
    #   图 2 = 从 3D 模型直接渲出的线稿(每条线都是真实棱边，用来对齐几何)
    #   图 3 = 可选参考图(只借材质/光照/色调)
    # 核心要求放最前面、写死：只重新贴材质+打光，几何/相机/物件一个都不许动。
    # 越往后越是"怎么更好看"的次要信息。整体控制在 ~500 英文词以内，Seedream 官方上限是 600 词。
    module CloudPrompt
      module_function

      def render_prompt(kind:, ctx:, preset: nil, user_prompt: nil, strength: 10, has_lines: true,
                        has_reference: false, retry_note: false)
        interior = kind.to_s == 'interior'
        s = strength.to_i.clamp(0, 100)
        out = []

        imgs = ['Image 1 is a SketchUp 3D-model viewport of an architectural ' + (interior ? 'interior' : 'exterior') + '.']
        imgs << 'Image 2 is an edge drawing rendered from the same 3D model at the same camera (flat colours, black lines, no textures): every black line in it is a real edge of the model.' if has_lines
        imgs << "Image #{has_lines ? 3 : 2} is a reference photo for materials, colour palette and lighting mood ONLY." if has_reference
        out << imgs.join(' ')

        out << 'TASK: turn Image 1 into a real photograph of the same space, taken from exactly the same camera position ' \
               'with the same lens. This is a re-materialising and re-lighting job, not a redesign.'

        out << hard_rules(s, interior, has_lines)
        out << 'RETRY: a previous attempt drifted from the model geometry. Be even more literal: trace every edge of ' \
               'Image 2 exactly, change nothing but surface appearance and light.' if retry_note

        out << 'WHAT TO CHANGE: replace every flat SketchUp colour and low-resolution texture with a physically accurate ' \
               'real material (visible microtexture, correct roughness and reflections), and light the scene like a ' \
               'professional architectural photographer: natural light direction, soft contact shadows, ambient ' \
               'occlusion in corners, believable bounce light, glass that reflects and refracts.'

        mats = materials_line(ctx)
        out << mats if mats
        objs = objects_line(ctx)
        out << objs if objs
        out << flat_colour_key(interior)

        light = lighting_line(ctx, preset, has_reference)
        out << light if light
        out << "Designer notes (follow them unless they conflict with the rules above): #{user_prompt.to_s.strip.tr("\n", ' ')}" unless user_prompt.to_s.strip.empty?

        out << photo_style(interior)
        out.join("\n\n")
      end

      def hard_rules(s, interior, has_lines)
        align = has_lines ? ' Every edge in Image 2 must land on the same pixel position in your result.' : ''
        keep =
          'RULES (absolute): keep the camera, perspective, focal length, framing and horizon identical so the result ' \
          'overlays Image 1 pixel for pixel.' + align + ' Keep every wall, floor, ceiling, opening, window, door, ' \
          'stair, piece of furniture, fixture, lamp and object exactly where it is, with the same shape, size, ' \
          'proportions and count. Never merge, split, move, resize, rotate, replace or remove anything, and never ' \
          'turn one object into a different kind of object.'

        extra =
          if s <= 20
            ' Add NOTHING: no extra furniture, decor, cushions, books, plants, artwork, people, cars or lights. ' \
            'Only where Image 1 shows empty background (plain SketchUp sky or void beyond the model) may you show a ' +
            (interior ? 'plausible soft daylight view through the windows.' : 'real sky and a quiet, understated distant surrounding.')
          elsif s <= 50
            if interior
              ' You may add only tiny styling touches that do not hide anything (a throw, a vase, books on existing shelves) and a real view through the windows.'
            else
              ' You may add context only OUTSIDE the modelled objects: real sky, planting on empty ground, a few correctly-scaled people. Nothing may overlap or hide the modelled building.'
            end
          elsif s <= 80
            ' You may add decor and landscaping and refine small details, but the architecture, openings and every ' \
            'piece of main furniture stay exactly as modelled.'
          else
            ' Use the model as a strong guide for camera and layout; you may reinterpret materials and secondary ' \
            'details more freely.'
          end
        keep + extra
      end

      def materials_line(ctx)
        return nil unless ctx
        mats = ctx[:visible_materials] || ctx['visible_materials'] || []
        nq = (ctx[:naming_quality] || ctx['naming_quality'] || {})
        poor = (nq[:verdict] || nq['verdict']).to_s == 'poor'
        items = mats.first(10).map do |x|
          name = (x[:name] || x['name']).to_s
          next if name.start_with?('(')
          tex = x[:texture_file] || x['texture_file']
          hint = WorkflowBuilder.material_physics_hint(name, tex)
          next if poor && hint.nil?
          frac = ((x[:screen_fraction] || x['screen_fraction']).to_f * 100).round
          label = poor ? "a surface (~#{frac}% of view)" : "\"#{name}\" (~#{frac}% of view)"
          hint ? "#{label}: #{hint}" : label
        end.compact
        return nil if items.empty?
        "MATERIALS the designer assigned in the model (most prominent first; keep each surface's colour family, make it real): #{items.join('; ')}."
      end

      def objects_line(ctx)
        return nil unless ctx
        objs = ctx[:visible_objects] || ctx['visible_objects'] || []
        return nil if objs.empty?
        nq = (ctx[:naming_quality] || ctx['naming_quality'] || {})
        use_names = %w[good mixed].include?((nq[:verdict] || nq['verdict']).to_s)
        listed = objs.first(14).map do |o|
          name = (o[:name] || o['name']).to_s.strip
          zone = o[:screen_zone] || o['screen_zone']
          name = '' unless use_names
          name.empty? ? "an object at #{zone}" : "\"#{name}\" at #{zone}"
        end
        "OBJECT INVENTORY from the 3D model (#{objs.size} separate objects in view, all must survive, none may be added): #{listed.join('; ')}."
      end

      def flat_colour_key(interior)
        if interior
          'SketchUp shading is not final appearance: flat unshaded fills are placeholder colours for real materials. ' \
          'No black outlines anywhere.'
        else
          'SketchUp shading is not final appearance: flat yellow/orange ground = paving or paths, flat green ground = ' \
          'lawn/planting, flat blue = water. Replace every flat fill with the real material it represents. No black outlines anywhere.'
        end
      end

      def lighting_line(ctx, preset, has_reference)
        return 'LIGHTING: follow the lighting mood of the reference image.' if has_reference && preset.to_s.strip.empty?
        return "LIGHTING: #{preset.strip}" unless preset.to_s.strip.empty?

        sun = ctx && (ctx[:sun] || ctx['sun'])
        if sun && (sun[:available] || sun['available'])
          "LIGHTING: match the model's real sun — #{sun[:sun_description] || sun['sun_description']} " \
          "(#{sun[:date_time] || sun['date_time']}); shadows fall in that direction."
        end
      end

      def photo_style(interior)
        base = 'LOOK: an authentic high-end architectural photograph, full-frame camera, 24-35mm lens, straight ' \
               'verticals, balanced HDR exposure, natural colour grading, crisp detail, subtle sensor grain. It must not ' \
               'look like CGI, a 3D render, a clay render or an illustration. No text, logo or watermark.'
        base + (interior ? ' Interior: warm 2700-3000K artificial light where fixtures exist, daylight through windows.' : '')
      end

      # ---- 结果窗口里的两个小功能，走云端时用 ---------------------------------
      def grade_prompt(instruction)
        instr = instruction.to_s.strip
        instr = 'a subtle professional colour grade' if instr.empty?
        "Apply this photographic colour grade to the image: #{instr}. Change ONLY colour, white balance, tone curve, " \
        'contrast, saturation and mood. Keep the composition, every object, every edge, every material and all ' \
        'detail exactly the same. The result must still be a natural, believable photograph.'
      end

      def enhance_prompt(strength)
        s = strength.to_i.clamp(0, 100)
        amount = s <= 35 ? 'subtly' : (s <= 70 ? 'clearly' : 'strongly')
        "This is a 3D architectural render. #{amount.capitalize} upgrade it into an authentic photograph: real " \
        'material microtexture (wood grain, fabric weave, stone veining, metal reflections), physically correct soft ' \
        'shadows and ambient occlusion, believable reflections, natural light falloff, photographic colour. ' \
        'Do NOT change the composition, camera, perspective, layout, objects, furniture, colours or the count or ' \
        'position of anything. The result must overlay the input pixel for pixel. No text or watermark.'
      end
    end
  end
end
