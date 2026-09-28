# 交接说明：AI 渲染工作室（SketchUp 插件）

给在这台电脑上接手的 Claude（桌面版，能操作电脑）。先把这份文件读完再动手。

## 1. 用户要什么（硬性要求，不要违反）

- SketchUp 一键出**照片级**室内/建筑渲染图。
- **跟 SketchUp 模型完全一致**：形状、位置、尺寸、颜色、材质、每条石膏线、每个雕花都不能改，不能加东西（画、摆件）、不能丢东西。
- **只用本地模型**（ComfyUI + RTX 5070 Ti 16GB），**不用任何在线 API**。
- 渲染模型用 **Flux.2 Klein 9B**。用户试过并否决了 RealVisXL + ControlNet（"像卡通"）、Z-Image Turbo + ControlNet（"画成了另一个房间"），**不要再提**。
- 提高真实感靠**加辅助模型**（LoRA、分析模型等），不是调高"AI 强度"。
- 用户说中文；界面语言选的是哈萨克语（Қазақша）。

## 2. 电脑上的位置

| 东西 | 位置 |
|---|---|
| 插件（就是本文件夹） | `F:\SU插件\extension\ai_render_studio.rb` + `ai_render_studio\` |
| 同文件夹里另一个插件，别动 | `material_painter.rb` + `material_painter\` |
| SketchUp 加载方式 | 一个 devload.rb 去 `require 'F:/SU插件/extension/ai_render_studio.rb'` |
| ComfyUI | ComfyUI Desktop，API `http://127.0.0.1:8188` |
| ComfyUI 输入/输出 | `F:\Comfy-Desktop\ComfyUI-Shared\input` / `...\output\SU_AI_Render\` |
| 插件日志和中间文件 | `%TEMP%\ai_render_studio\` |
| 源码仓库 | GitHub `Aydin-bolat/key-overlay`，分支 `claude/ai-render-plugin-realism-t77qet`，插件在仓库的 `extension/` 下 |

`%TEMP%\ai_render_studio\` 里每次渲染会留下这些文件：
- `render.log`：每一步的日志。关键行包括 `struct LoRA ON/off`、`scene analysis ON/off`、`gen=2.0MP`、`attempt N structure score=`。
- `last_prompt.txt`：发给 Flux 的完整提示词。
- `last_graph.json`：发给 ComfyUI 的出图工作流（API 格式）。
- `last_scene.txt` / `last_scene_graph.json`：场景分析的结果和它的工作流。
- `source_*.png`：给 AI 的 SketchUp 截图。
- `sketchup_*.png`：原样视图，对比条左边用的就是它。
- `lines_*.png`：消隐线线稿，白底黑线。
- `result_*.png`：出图结果。

改了插件代码以后：SketchUp 菜单里点「重新加载插件（开发）」，或者重启 SketchUp。

## 3. 渲染流程（代码在 `ai_render_studio\`）

1. `model_extractor.rb`：从当前视角提取物体、屏幕位置、尺寸、颜色、材质、相机、太阳，写成 GROUND TRUTH。
2. `capture.rb` 截三张图：
   - `textured`：带材质、无边线；
   - `lines`：消隐线模式，白底黑线；
   - `as_is`：原样视图。

   截图长边 2048 像素。
3. `main.rb` → `start_scene_analysis`：场景分析。用 Qwen3-VL 8B（`text_encoders\qwen3vl_8b_fp8_scaled.safetensors`）看截图 + 线稿，写出空间、墙板/拱形/角线/雕花、每件物体的造型、容易看错的地方、必须留空的墙面。结果放进提示词的 SCENE ANALYSIS 段，同一视角会缓存。构建代码在 `flux_builder.rb` → `build_scene`，节点是 ComfyUI 原生的 `TextGenerate` + `PreviewAny`。
4. `flux_builder.rb` → `build_edit`：Flux.2 Klein 9B KV 图像编辑，节点照官方模板 `image_flux2_klein_9b_kv_image_edit`：
   - 模型：UNETLoader(`flux-2-klein-9b-kv-fp8`)、CLIPLoader flux2(`qwen_3_8b_fp8mixed`)、VAE(`flux2-vae`)；
   - 结构 LoRA：LoraLoaderModelOnly，`loras\refcontrol-flux2-klein-9b-lineart.safetensors`，权重 1.0；
   - 采样：FluxKVCache、CFGGuider cfg 1、euler、Flux2Scheduler 4 步、EmptyFlux2LatentImage 纯噪点起步；
   - 参考图：每张 VAEEncode → ReferenceLatent，正、负条件都接。结构 LoRA 模式下：
     - 图 1 = 线稿，反相成黑底白线，缩放到约 2MP，出图尺寸跟它一样；
     - 图 2 = SketchUp 截图，1MP。
   - 提示词：`refcontrol.` 开头 + SCENE ANALYSIS + GROUND TRUTH + CHANGE BUDGET + 光照预设 + 照片要求。一共约 6000+ 字符。
5. `geometry_check.rb`：拿线稿给出图打"结构吻合度"分，低于 0.55 就换种子重出，最多 3 张，留最高分那张。
6. `build_upscale`：用 ESRGAN + lanczos 放大到目标分辨率。

代码约定：`main.rb` 和 `html\i18n.js` 是 **CRLF** 换行，改的时候保持 CRLF。每个 .rb 改完单独跑一次 `ruby -c 文件名`。

## 4. 试过什么、结果如何（按时间）

| 做法 | 结果 |
|---|---|
| Flux Klein，截图 + 深度图 + 法线图当参考，无 LoRA | 照片感好（用户说"好多了"）。但墙板线条、拱形、天花雕花、床头绗缝、床头柜浮雕会被改掉或丢掉，偶尔墙上多一幅画、壁灯画成吊灯 |
| + RefControl 线稿 LoRA（0.9，1MP） | 墙板线条回来了一部分；换种子后细节时有时无 |
| 从截图出发（img2img，SplitSigmasDenoise） | **失败**：出图发灰发平，像矢量图，石膏线照样丢。原因：Klein 是 4 步蒸馏模型，2MP 时调度偏移大，"denoise 0.6" 实际从约 90% 噪声开始，后几步又是它没训练过的噪声点。**已撤回，别再试** |
| 现在：纯噪点 4 步 + 线稿 2MP 逐像素对齐 + LoRA 1.0 + Qwen3-VL 场景分析 + 室内颜色照 SketchUp | 用户说"不行" |

## 5. 当前问题和线索

用户最后两次发来的对比图，**右边的 AI 图几乎一模一样**：同样的书、同样的外套、同样的衣柜。纯噪点出图每次随机种子不同，不可能一样。所以**第一件事是确认 SketchUp 实际跑的是哪版代码、这张图是不是新渲染出来的**：
- `ai_render_studio\flux_builder.rb` 里应该**没有** `SplitSigmasDenoise`，应该**有** `GEN_MP = 2.0`。
- 最新的 `last_graph.json` 里应该是 `EmptyFlux2LatentImage`、`img0_s` 的 `megapixels` 是 `2.0`、LoRA `strength_model` 是 `1.0`。
- `render.log` 最后一段应该有 `scene analysis ON` 和 `gen=2.0MP`。

那张图本身的问题：
- 整体发灰、发暗、发平，没有照片的光影；
- 墙面拱形墙板、天花角线和雕花全没了；
- 床头绗缝没了，变成两块平板；
- 床头柜的拱形浮雕没了。

值得查的怀疑点（按我认为的可能性排）：
1. **代码版本 / 结果不是新的**：见上面。
2. **提示词太长太杂**：约 6000 字符，里面有 GROUND TRUTH 物体清单（构件名是乱码，比如 网格057、建E_model9948，前 10 个几乎全是墙板线条）、材质质感字典、光照预设等。RefControl 作者的示例提示词很短。可以试"`refcontrol` + 两三句描述"。
3. **参考截图太暗**：模型里的太阳是 18:30（`太阳在地平线以下`），而 `Capture.textured` 截图时开着阴影，给 AI 的 `source_*.png` 可能整张发暗，但光照预设写的是"正午"。看一下 `source_*.png`。可以试面板里取消「截图带 SketchUp 阴影」，或者代码里用 `Capture.textured(bright: true)`。
4. **线稿**：打开 `lines_*.png` 看看。绗缝床头、植物、雕花这种高面数模型的线可能密成一团。另外反相约定（黑底白线）是根据作者示例图判断的，可以做个 A/B：反相 vs 不反相。
5. **RefControl LoRA 是在 Klein Base（非蒸馏）上训练的**，作者说蒸馏 4 步版也能用，但效果可能打折。可以试 Base 版 + 更多步数。
6. **2MP 出图**：Klein 官方模板是 1MP。可以 A/B：1MP vs 2MP。

最省事的实验方法：不要每次都从 SketchUp 跑，**直接在 ComfyUI 里改 `last_graph.json` 做 A/B**。固定种子，一次只改一个变量。可以把 JSON 拖进 ComfyUI 网页界面，也可以用 PowerShell 提交：

```powershell
$g = Get-Content "$env:TEMP\ai_render_studio\last_graph.json" -Raw | ConvertFrom-Json
$body = @{ prompt = $g } | ConvertTo-Json -Depth 64
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8188/prompt -Body $body -ContentType 'application/json'
# 出图在 F:\Comfy-Desktop\ComfyUI-Shared\output\SU_AI_Render\
```

找到效果好的参数组合后，再改回插件代码（`flux_builder.rb` 的 `build_edit` / `render_prompt`）。

## 6. 以后要做的（等出图效果调好再说）

- 真实感辅助：Realistic Detail LoRA（`SOLRICKS/Flux2-Klein-9B-Realistic-Detail`，权重约 0.6）、SeedVR2 放大。
- 装到别的电脑：
  - 去掉写死的 `F:/Comfy-Desktop/...` 路径和 8188 端口（Desktop 默认端口是 8000）；
  - 去掉对 `dev\comfy_headless.ps1` 的依赖；
  - 加 `doctor.ps1`、`status.json`。
