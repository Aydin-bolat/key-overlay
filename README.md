# AI 渲染工作室 (AI Render Studio) — SketchUp 插件

SketchUp 一键 AI 照片级渲染，**全部在本地 ComfyUI 里运行，不用任何在线 API**。
`extension/` 就是 `F:\SU插件\extension` 的内容，同一个文件夹里还有 Material Painter 插件。

## 0.2.0：新的本地照片级管线（默认引擎）

```
SketchUp 视图截图 ─┐
                   ├─► Z-Image Turbo + Fun ControlNet Union ─► 结构吻合度检查 ─► SeedVR2 7B 精修放大 ─► 成品
SketchUp 真实边线 ─┘   （img2img，边线锁结构）                  （偏差大就换种子重出，最多 3 张，留最好的）
```

| 环节 | 用什么 | 为什么 |
|---|---|---|
| 出图 | **Z-Image Turbo**（阿里通义，6B，8 步） | 目前本地开源模型里照片真实感最好的一档，16GB 显存能跑；文本编码器是 Qwen3-4B，能读长描述，不像 SDXL 只读 77 个 token |
| 锁结构 | **Z-Image Fun ControlNet Union** | 输入不是从截图里猜出来的边缘，而是 SketchUp 从 3D 模型直接渲出的真实棱边；同时从 SketchUp 截图的真实像素出发做 img2img，材质颜色分区也保留 |
| 兜底 | 结构吻合度检查 | 把照片边缘和模型棱边做对比打分，偏了就自动换种子重出，最后显示在结果窗口右上角 |
| 精修放大 | **SeedVR2 7B int8**（字节，一步扩散） | 放大时补出真实的微观纹理（木纹、织物、石材），不改几何，并用 LAB 把颜色对齐回原图。取代原来的"RealVisXL 低降噪重画 + ESRGAN" |

以上都是 ComfyUI 的原生节点，节点接法照 ComfyUI 官方模板（`image_z_image_turbo_fun_union_controlnet`、`utility_seedvr2_7b_int8_upscale_image`），**不需要装任何自定义节点**。

另外，旧的 RealVisXL 引擎也修了 3 个问题，它仍然可以在面板里选：
- Canny ControlNet 之前收到的是反相的线稿，边线约束基本失效；
- 第二遍精修不带任何约束，而且 denoise 是 0.45，会把结构改掉；
- 提示词太长，超出 SDXL 的 77 token 上限。

## 需要下载的模型

先把 **ComfyUI Desktop 更新到最新版**：Z-Image ControlNet 和 SeedVR2 的原生节点只有新版才有。

| 放到 `ComfyUI/models/` 下的 | 文件 | 下载地址 |
|---|---|---|
| `diffusion_models/` | z_image_turbo_bf16.safetensors | https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/diffusion_models/z_image_turbo_bf16.safetensors |
| `text_encoders/` | qwen_3_4b.safetensors | https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors |
| `vae/` | ae.safetensors | https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/vae/ae.safetensors |
| `model_patches/` | Z-Image-Turbo-Fun-Controlnet-Union.safetensors | https://huggingface.co/alibaba-pai/Z-Image-Turbo-Fun-Controlnet-Union/resolve/main/Z-Image-Turbo-Fun-Controlnet-Union.safetensors |
| `diffusion_models/` | seedvr2_7b_int8_convrot.safetensors（推荐） | https://huggingface.co/Comfy-Org/SeedVR2/resolve/main/diffusion_models/seedvr2_7b_int8_convrot.safetensors |
| `vae/` | seedvr2_ema_vae_fp16.safetensors（推荐） | https://huggingface.co/Comfy-Org/SeedVR2/resolve/main/vae/seedvr2_ema_vae_fp16.safetensors |

补充说明：
- ControlNet 也有 2.1 版（`alibaba-pai/Z-Image-Turbo-Fun-Controlnet-Union-2.1`），放进 `model_patches/` 后插件会优先用它。
- 显存吃紧的话，SeedVR2 可以换成 3B 版：`seedvr2_3b_int8_convrot.safetensors`，同一个仓库里有。
- SeedVR2 是可选的。没装的话，插件会用普通放大（ESRGAN + lanczos），照样能出图，只是细节差一些。
- 插件按文件名自动识别模型，不用改代码。打开渲染面板时，最上面会列出缺哪些文件。

国内下载 HuggingFace 慢的话，可以把上面地址里的 `huggingface.co` 换成 `hf-mirror.com`。

## 安装 / 更新

1. 用本仓库的 `extension/` 覆盖 `F:\SU插件\extension`。
2. 在 SketchUp 里点「扩展 → AI 渲染工作室 → 重新加载插件（开发）」，或者直接重启 SketchUp。
3. 打开面板，引擎保持默认的「Z-Image Turbo + SeedVR2」，AI 强度保持 0 到 20（只换材质和光照）。

## 排查

日志都在 `%TEMP%\ai_render_studio\`：
- `render.log`：每一步的记录，包括每一张的结构吻合度分数和选用的模型文件。
- `last_prompt.txt`：最近一次的提示词。
- `last_graph.json` / `last_finish_graph.json`：最近一次提交给 ComfyUI 的工作流。可以拖进 ComfyUI 界面里直接看、直接调参。
