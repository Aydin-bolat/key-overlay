# AI 渲染工作室 (AI Render Studio) — SketchUp 插件

SketchUp 一键 AI 照片级渲染，全部在本地 ComfyUI 里运行，不用任何在线 API。
`extension/` 就是 `F:\SU插件\extension` 的内容（同一个文件夹里还有 Material Painter 插件）。

## 渲染引擎：Flux.2 Klein 9B（最初的 Flux 管线）

中间试过 RealVisXL + ControlNet、Z-Image Turbo + ControlNet，实测都不如最初的 Flux（前者像线稿上色，后者画成了另一个房间），已全部删除，回到 Flux：

1. **提取模型信息**：从 SketchUp 当前视角里提取每个参与渲染的物体——名称、屏幕位置、真实尺寸、主色/副色、距离，以及每种材质（带物理质感描述：光滑/硬度/绒毛…）、相机、太阳，写成 GROUND TRUTH 交给模型，防止变形、改物体、丢物体；
2. **AI 场景分析**（Qwen3-VL 8B，可选，推荐）：出图前单独跑一次，看 SketchUp 截图 + 线稿，写出空间类型、墙板/拱形/角线/雕花、每件家具灯具的造型细节（绗缝、浮雕、壁灯还是吊灯）、容易看错的地方、必须留空的墙面，作为 SCENE ANALYSIS 交给 Flux。结果显示在面板的「AI 场景分析结果」里，看错了就在「附加描述」里纠正。同一视角不重复分析。没装这个模型时退回 gemma 看图识物（只补物体类别）；
3. **参考图**：Image 1 = SketchUp 截图，Image 2/3 = 从真实 3D 模型射线采样的深度图 / 法线图，Image 4 = 你给的风格参考图（可选）；
4. **从 SketchUp 画面出发（img2img）**：生成不从纯噪点开始，而是从 SketchUp 截图本身开始，只重画一部分。「AI 强度」直接决定重画多少：0 → 重画 60%（结构、石膏线、物件位置和颜色都从截图继承，只把材质和光影变成照片），100 → 完全重画。出图约 2MP，细线不会被简化掉。另外写成 CHANGE BUDGET 指令；
5. **结构吻合度检查**：出图后用 SketchUp 线稿给结果打分，偏差大就自动换种子重出，最多 3 张，留分数最高的（面板上可关）；
6. 最好那张放大到目标分辨率（ESRGAN + lanczos）。

### 结构 LoRA（RefControl 线稿，可选，推荐）

Flux 只拿截图当"软参考"时，墙板线条、拱形、柜子造型会被它自己重新设计。装上 [RefControl FLUX.2 Klein 9B 线稿 LoRA](https://huggingface.co/thedeoxen/refcontrol-FLUX.2-klein-9B-reference-lineart-lora) 后（面板里「下载结构 LoRA」一键下载，存为 `loras/refcontrol-flux2-klein-9b-lineart.safetensors`）：

- 图 1 = SketchUp 消隐线模式截的线稿（白面 + 黑细线，跟材质颜色无关）= 控制图；
- 图 2 = SketchUp 截图 = 参考图（物体、颜色、材质从这里取）；
- 提示词带触发词 `refcontrol`，LoRA 权重 1.0（作者推荐 0.8–1.0）；线稿缩放到跟出图同样大小、逐像素对齐。

这个模式下按 RefControl 的约定只喂这两张图，不再加深度图/法线图。面板上可以随时关掉结构 LoRA 做对比。

节点接法照 ComfyUI 官方模板 `image_flux2_klein_9b_kv_image_edit`（ReferenceLatent、FluxKVCache、CFGGuider cfg 1、euler、Flux2Scheduler 4 步）。提示词各段是最初写给 Flux 的原文。

结果窗口的「AI 调色」「上传图片增强真实感」也用 Flux.2 Klein 图像编辑。

## 需要的模型（面板会自动检测，缺的可以一键下载）

| 放到 `ComfyUI/models/` 下的 | 文件 |
|---|---|
| `diffusion_models/` | flux-2-klein-9b-kv-fp8.safetensors |
| `text_encoders/` | qwen_3_8b_fp8mixed.safetensors |
| `vae/` | flux2-vae.safetensors |
| `text_encoders/`（可选，推荐，场景分析） | qwen3vl_8b_fp8_scaled.safetensors（[Comfy-Org/Qwen3-VL](https://huggingface.co/Comfy-Org/Qwen3-VL)，约 10.6 GB，面板一键下载） |
| `text_encoders/`（可选，看图识物，没有场景分析模型时用） | gemma4_e4b_it_fp8_scaled.safetensors |
| `upscale_models/`（可选，放大用） | 任意 RealESRGAN 4x |

一键下载会问 ComfyUI 要实际的模型文件夹，连不上 huggingface.co 时自动改用 hf-mirror.com，支持断点续传，在独立后台进程里下载（关掉 SketchUp 也不停）。

## 排查

日志都在 `%TEMP%\ai_render_studio\`：
- `render.log`：每一步的记录，包括每一张的结构吻合度分数和选用的模型文件；
- `last_prompt.txt`：最近一次的完整提示词（含 SCENE ANALYSIS、GROUND TRUTH）；
- `last_scene.txt` / `last_scene_graph.json`：最近一次的场景分析结果和它的工作流；
- `last_graph.json`：最近一次提交给 ComfyUI 的工作流，可以拖进 ComfyUI 界面里直接看、直接调参。
