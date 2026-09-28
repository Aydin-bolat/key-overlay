# frozen_string_literal: true

module AydinCreative
  module AiRenderStudio
    # 白天 / 黑夜 光照与天气预设。key 传给对话框，text 注入工作流。
    module Presets
      DAY = [
        { key: 'midday',        label: '晴天正午',   text: 'Bright midday sun in a clear deep-blue sky, crisp short hard-edged shadows falling to one side, brilliant even daylight, interiors reading as cool daylight through the glazing.' },
        { key: 'overcast',      label: '多云柔光',   text: 'Soft overcast daylight from a bright white-grey sky, very soft diffuse shadows, gentle even illumination across every surface, neutral cool interior light.' },
        { key: 'golden',        label: '黄金时刻',   text: 'Warm late-afternoon golden-hour sun low on the horizon, long soft golden shadows raking across the facades, amber light, a warm glow just beginning to show in the interiors.' },
        { key: 'blue_hour',     label: '蓝调傍晚',   text: 'Dusk blue hour, a deep blue sky gradient with a last warm band at the horizon, no direct sun, soft ambient shadows, warm artificial light glowing strongly from every interior.' },
        { key: 'morning_mist',  label: '清晨薄雾',   text: 'Crisp early-morning light with low thin ground mist, a pale cool sky, long gentle shadows, a dew-fresh atmosphere, soft warm interior lamps still on.' },
        { key: 'rain',          label: '雨天',       text: 'Overcast rainy weather, wet reflective ground with shallow puddles and reflections, flat diffuse grey light and no shadows, a misty soft background, warm interior light glowing through rain-streaked glass.' },
        { key: 'snow',          label: '雪天',       text: 'Cold overcast snowy weather, fresh snow settled on roofs, ledges and ground, soft flat blue-grey light, muted desaturated tones, warm interior light contrasting the cold exterior.' },
        { key: 'dramatic_sky',  label: '戏剧天空',   text: 'Late afternoon with a dramatic partly-clouded sky, shafts of sunlight breaking through, strong directional light and deep soft shadows, high dynamic range, cinematic mood.' }
      ].freeze

      NIGHT = [
        { key: 'warm_interior', label: '暖色氛围灯', text: 'Night scene under a dark deep-blue sky, the building lit primarily by warm 2700K interior lighting glowing through every window, warm pools of light spilling onto the ground near the entrances.' },
        { key: 'facade_flood',  label: '建筑泛光',   text: 'Night scene with architectural facade floodlighting grazing the building surfaces to emphasise their texture and form, a cool-neutral exterior wash combined with a warm interior glow, dark sky.' },
        { key: 'city_night',    label: '城市夜景',   text: 'Night scene in an urban context with mixed city light — street lamps, signage glow, faint car light trails — warm interiors, wet-look asphalt reflecting the lights, a dark sky with a faint city glow on the horizon.' },
        { key: 'moonlight',     label: '月光冷调',   text: 'A clear night under bright moonlight, cool blue ambient exterior light and soft moon shadows, restrained warm light from just a few interior rooms, faint stars in the sky.' },
        { key: 'landscape_led', label: '景观灯光',   text: 'Night scene with designed landscape lighting — uplit trees, low bollard path lights, step and cove lighting — layered warm pools of light, dark surroundings, a soft warm glow from the interior.' }
      ].freeze

      module_function

      def all
        { day: DAY, night: NIGHT }
      end

      def text_for(mode, key)
        list = mode.to_s == 'night' ? NIGHT : DAY
        entry = list.find { |e| e[:key] == key }
        entry && entry[:text]
      end
    end
  end
end
