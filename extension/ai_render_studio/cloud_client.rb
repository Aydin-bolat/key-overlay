# frozen_string_literal: true

require 'net/http'
require 'openssl'
require 'json'
require 'uri'

module AydinCreative
  module AiRenderStudio
    # 云端照片级渲染引擎（2026-09-28 加入）。
    #
    # 为什么要上云：本地 RealVisXL(SDXL) 是 2024 年的底模，单个 CLIP 文本编码器只吃 77 个 token，
    # 咱们那一大段 ground truth 文字它基本读不进去；从 SketchUp 平涂色块出发，denoise 低了就是
    # "CG 感"，高了就改结构——这是底模能力的天花板，调参数调不出来。
    # 2026 年做 SU→照片级 这件事，业内(Veras/VizBase/MeltFlex 等商用插件、各种评测)基本收敛到
    # 多模态"图像编辑"大模型：Google Nano Banana Pro(Gemini 3 Pro Image) 真实感/建筑透视最好，
    # 字节 Seedream(豆包/即梦) 真实感接近、价格约 1/5、国内直连。它们能真正"看懂"图，
    # 能同时吃 SU 截图 + 线稿图 + 参考图，按长篇指令只换材质光照、不动几何。
    #
    # 两个提供方共用同一个接口：
    #   client.render(prompt:, images: [{path:|bytes:, mime:}], aspect:, size_tier:, pixel_size:)
    #   → 返回 PNG/JPEG 字节
    # 只用 Ruby 标准库 Net::HTTP；跑在 main.rb 的后台线程里，不卡 SketchUp。
    module Cloud
      class Error < StandardError; end

      # Gemini 支持的画面比例（imageConfig.aspectRatio 只接受这些值）
      GEMINI_RATIOS = {
        '1:1' => 1.0, '5:4' => 1.25, '4:3' => 4.0 / 3, '3:2' => 1.5, '16:9' => 16.0 / 9, '21:9' => 21.0 / 9,
        '4:5' => 0.8, '3:4' => 0.75, '2:3' => 2.0 / 3, '9:16' => 9.0 / 16
      }.freeze

      module_function

      # 任意比例 → Gemini 能接受的最接近比例（按对数距离，横竖对称）
      def snap_ratio(ar)
        ar = ar.to_f
        ar = 16.0 / 9 if ar <= 0
        GEMINI_RATIOS.min_by { |_k, v| (Math.log(v) - Math.log(ar)).abs }
      end

      # 面板上的清晰度 → 云端档位
      def size_tier(resolution)
        case resolution.to_s
        when '240p', '360p', '480p', '720p' then '1K'
        when '2160p', '4k', '4K' then '4K'
        else '2K'
        end
      end

      def mime_for(path)
        %w[.jpg .jpeg].include?(File.extname(path.to_s).downcase) ? 'image/jpeg' : 'image/png'
      end

      def build_client(settings)
        case settings[:engine].to_s
        when 'seedream' then SeedreamClient.new(settings)
        else GeminiClient.new(settings)
        end
      end

      # ---- 共用 HTTP -------------------------------------------------------
      class Base
        def initialize(settings)
          @settings = settings
        end

        private

        # proxy: "127.0.0.1:7890" / "http://127.0.0.1:7890"；留空 = 读系统环境变量 https_proxy。
        # (Clash/V2Ray 默认只改 Windows 系统代理、不设环境变量，所以访问 Google 需要在面板里填一次。)
        def http_for(uri, read_timeout)
          proxy = @settings[:proxy].to_s.strip
          h =
            if proxy.empty?
              Net::HTTP.new(uri.host, uri.port)
            else
              pu = URI.parse(proxy.include?('://') ? proxy : "http://#{proxy}")
              Net::HTTP.new(uri.host, uri.port, pu.host, pu.port, pu.user, pu.password)
            end
          h.use_ssl = (uri.scheme == 'https')
          h.open_timeout = 30
          h.read_timeout = read_timeout
          h.write_timeout = 120 if h.respond_to?(:write_timeout=)
          h
        end

        def post_json(url, body_hash, headers, read_timeout: 360, tries: 2)
          uri = URI.parse(url)
          body = JSON.generate(body_hash)
          last = nil
          tries.times do |i|
            begin
              h = http_for(uri, read_timeout)
              req = Net::HTTP::Post.new(uri.request_uri, { 'Content-Type' => 'application/json' }.merge(headers))
              req.body = body
              res = h.start { |conn| conn.request(req) }
              code = res.code.to_i
              # 429/5xx 是服务端临时问题，值得再试一次；4xx 是请求本身的问题，直接报
              if (code == 429 || code >= 500) && i < tries - 1
                last = Error.new("HTTP #{code}: #{res.body.to_s[0, 300]}")
                sleep(4 * (i + 1))
                next
              end
              return res
            rescue OpenSSL::SSL::SSLError => e
              raise Error, "SSL 连接失败（#{e.message}）。如果在用代理，请确认面板里的代理地址正确。"
            rescue Net::OpenTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ETIMEDOUT,
                   Errno::EHOSTUNREACH, SocketError, EOFError => e
              last = e
              sleep(3 * (i + 1)) if i < tries - 1
            end
          end
          raise Error, "连不上 #{uri.host}（#{last.class}: #{last&.message}）。国内访问 Google 需要在设置里填代理地址，例如 127.0.0.1:7890。"
        end

        def parse_json(res)
          JSON.parse(res.body.to_s)
        rescue JSON::ParserError
          raise Error, "返回的不是 JSON (HTTP #{res.code}): #{res.body.to_s[0, 400]}"
        end

        def image_bytes(img)
          img[:bytes] || File.binread(img[:path])
        end

        def b64(bytes)
          [bytes].pack('m0')
        end
      end

      # ---- Google Nano Banana Pro / Nano Banana 2 (Gemini 图像模型) -------------------
      class GeminiClient < Base
        ENDPOINT = 'https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent'
        DEFAULT_MODEL = 'gemini-3-pro-image-preview' # Nano Banana Pro；Nano Banana 2 = gemini-3.1-flash-image-preview

        def label
          "Gemini #{model}"
        end

        def model
          m = @settings[:gemini_model].to_s.strip
          m.empty? ? DEFAULT_MODEL : m
        end

        def render(prompt:, images:, aspect: nil, size_tier: '2K', pixel_size: nil, seed: nil)
          key = @settings[:gemini_key].to_s.strip
          raise Error, '没有填写 Gemini API Key（面板「渲染引擎」里设置）' if key.empty?

          parts = images.map do |img|
            { inline_data: { mime_type: img[:mime] || 'image/png', data: b64(image_bytes(img)) } }
          end
          parts << { text: prompt }

          gen = { responseModalities: %w[TEXT IMAGE], imageConfig: { imageSize: size_tier } }
          gen[:imageConfig][:aspectRatio] = aspect if aspect
          gen[:seed] = seed.to_i if seed && seed.to_i.positive?

          body = { contents: [{ role: 'user', parts: parts }], generationConfig: gen }
          res = post_json(format(ENDPOINT, model), body, { 'x-goog-api-key' => key })
          data = parse_json(res)
          unless res.is_a?(Net::HTTPSuccess)
            msg = data.dig('error', 'message') || res.body.to_s[0, 400]
            raise Error, "Gemini 拒绝请求 (HTTP #{res.code}): #{msg}"
          end

          cand = (data['candidates'] || []).first
          parts_out = cand && cand.dig('content', 'parts') || []
          img = parts_out.find { |p| p['inlineData'] || p['inline_data'] }
          if img
            inl = img['inlineData'] || img['inline_data']
            return inl['data'].unpack1('m')
          end

          # 没出图：把原因说清楚(安全拦截/只回了文字/配额)
          reason = cand && cand['finishReason']
          block = data.dig('promptFeedback', 'blockReason')
          text = parts_out.map { |p| p['text'] }.compact.join(' ')[0, 300]
          raise Error, "Gemini 没有返回图片（finishReason=#{reason || '-'} block=#{block || '-'}）#{text.empty? ? '' : "：#{text}"}"
        end
      end

      # ---- 字节 Seedream（火山方舟 Ark）------------------------------------------------
      class SeedreamClient < Base
        ENDPOINT = 'https://ark.cn-beijing.volces.com/api/v3/images/generations'
        DEFAULT_MODEL = 'doubao-seedream-4-5-251128' # 5.0 lite = doubao-seedream-5-0-260128

        def label
          "Seedream #{model}"
        end

        def model
          m = @settings[:seedream_model].to_s.strip
          m.empty? ? DEFAULT_MODEL : m
        end

        def render(prompt:, images:, aspect: nil, size_tier: '2K', pixel_size: nil, seed: nil)
          key = @settings[:seedream_key].to_s.strip
          raise Error, '没有填写火山方舟 (Seedream) API Key（面板「渲染引擎」里设置）' if key.empty?

          body = {
            model: model,
            prompt: prompt,
            image: images.map { |img| "data:#{img[:mime] || 'image/png'};base64,#{b64(image_bytes(img))}" },
            size: pixel_size || size_tier,
            sequential_image_generation: 'disabled',
            response_format: 'b64_json',
            watermark: false
          }
          _ = seed # 方舟图像接口的 seed 各模型版本支持不一，不传，避免 400

          data = request(body, key)
          # 有的模型版本不接受精确像素尺寸 → 退回档位写法再试一次（让模型按输入图比例出图）
          if data[:size_error] && pixel_size
            body[:size] = size_tier
            data = request(body, key)
          end
          raise Error, data[:message] if data[:message]

          item = (data[:json]['data'] || []).first
          raise Error, "Seedream 没有返回图片：#{data[:json].to_s[0, 300]}" unless item
          return item['b64_json'].unpack1('m') if item['b64_json']
          return download(item['url']) if item['url']

          raise Error, "Seedream 返回格式无法识别：#{item.keys.join(',')}"
        end

        private

        def request(body, key)
          res = post_json(ENDPOINT, body, { 'Authorization' => "Bearer #{key}" })
          json = parse_json(res)
          return { json: json } if res.is_a?(Net::HTTPSuccess)

          msg = json.dig('error', 'message') || res.body.to_s[0, 400]
          { json: json, size_error: msg.to_s =~ /size/i ? true : false,
            message: "Seedream 拒绝请求 (HTTP #{res.code}): #{msg}" }
        end

        def download(url)
          uri = URI.parse(url)
          res = http_for(uri, 120).start { |c| c.get(uri.request_uri) }
          raise Error, "下载 Seedream 结果失败 (HTTP #{res.code})" unless res.is_a?(Net::HTTPSuccess)
          res.body
        end
      end
    end
  end
end
