# AI 渲染工作室 (AI Render Studio) — SketchUp 插件

SketchUp 一键 AI 照片级渲染，全部在本地 ComfyUI 里运行，不用任何在线 API。
`extension/` 就是 `F:\SU插件\extension` 的内容（同一个文件夹里还有 Material Painter 插件）。

## 渲染引擎：Flux.2 Klein 9B（最初的 Flux 管线）

中间试过 RealVisXL + ControlNet、Z-Image Turbo + ControlNet，实测都不如最初的 Flux（前者像线稿上色，后者画成了另一个房间），已全部删除，回到 Flux：

1. **提取模型信息**：从 SketchUp 当前视角里提取每个参与渲染的物体——名称、屏幕位置、真实尺寸、主色/副色、距离，以及每种材质（带物理质感描述：光滑/硬度/绒毛…）、相机、太阳，写成 GROUND TRUTH 交给模型，防止变形、改物体、丢物体；
2. **看图识物**（gemma 视觉模型，可选）：构件名是乱码时补上物体类别（床不会被认成沙发）；
3. **参考图**：Image 1 = SketchUp 截图，Image 2/3 = 从真实 3D 模型射线采样的深度图 / 法线图，Image 4 = 你给的风格参考图（可选）；
4. **改动预算**：「AI 强度」写成 CHANGE BUDGET 指令，0 = 一个物件都不改；
5. **结构吻合度检查**：出图后用 SketchUp 线稿给结果打分，偏差大就自动换种子重出，最多 3 张，留分数最高的（面板上可关）；
6. 最好那张放大到目标分辨率（ESRGAN + lanczos）。

节点接法照 ComfyUI 官方模板 `image_flux2_klein_9b_kv_image_edit`（ReferenceLatent、FluxKVCache、CFGGuider cfg 1、euler、Flux2Scheduler 4 步）。提示词各段是最初写给 Flux 的原文。

结果窗口的「AI 调色」「上传图片增强真实感」也用 Flux.2 Klein 图像编辑。

## 需要的模型（面板会自动检测，缺的可以一键下载）

| 放到 `ComfyUI/models/` 下的 | 文件 |
|---|---|
| `diffusion_models/` | flux-2-klein-9b-kv-fp8.safetensors |
| `text_encoders/` | qwen_3_8b_fp8mixed.safetensors |
| `vae/` | flux2-vae.safetensors |
| `text_encoders/`（可选，看图识物） | gemma4_e4b_it_fp8_scaled.safetensors |
| `upscale_models/`（可选，放大用） | 任意 RealESRGAN 4x |

一键下载会问 ComfyUI 要实际的模型文件夹，连不上 huggingface.co 时自动改用 hf-mirror.com，支持断点续传，在独立后台进程里下载（关掉 SketchUp 也不停）。

## 排查

日志都在 `%TEMP%\ai_render_studio\`：
- `render.log`：每一步的记录，包括每一张的结构吻合度分数和选用的模型文件；
- `last_prompt.txt`：最近一次的完整提示词（含 GROUND TRUTH）；
- `last_graph.json`：最近一次提交给 ComfyUI 的工作流，可以拖进 ComfyUI 界面里直接看、直接调参。
