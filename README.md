# AI 渲染工作室 (AI Render Studio) — SketchUp 插件

SketchUp 一键 AI 照片级渲染。`extension/` 就是 `F:\SU插件\extension` 的内容（同一个文件夹里还有 Material Painter 插件）。

## 0.2.0 更新内容

### 1. 新增云端照片级引擎（默认）

| 引擎 | 真实感 | 说明 |
|---|---|---|
| **Nano Banana Pro**（Google Gemini 3 Pro Image） | 最强 | 默认。按张计费，国内需要代理 |
| **Seedream**（字节 · 火山方舟） | 接近 Nano Banana Pro | 价格约为前者 1/5，国内直连 |
| 本地 ComfyUI（RealVisXL） | 一般 | 免费离线，作为备用 |

云端渲染流程：
1. **截两张图**：SketchUp 视图截图（关掉边线、开材质），加上从 3D 模型直接渲出的线稿。
2. **一起发给多模态模型**，提示词只让它换材质和光照，几何、相机、物件数量一律不许动。拖了参考图的话，参考图作为第 3 张一起发。
3. **结构检查**：出图后，把照片的边缘和 SketchUp 线稿对比，算出「结构吻合度」。低于 50% 就自动重出，最多 3 张，最后保留分数最高的一张。结果窗口右上角会显示这个分数。
4. 结果窗口里的「AI 调色」和「上传图片增强真实感」，在选了云端引擎时也走云端。

### 2. 修复本地 ComfyUI 流程的 3 个问题

- **Canny ControlNet 输入是反的**。线稿是"白底黑线"，但 SDXL Canny 模型要的是"黑底白线"的边缘图，结果边线约束基本失效。现在先经过一个 Canny 节点再送进去。
- **第二遍精修不带任何约束**，而且 denoise 是 0.45，会把第一遍锁住的结构画走样。现在第二遍也带深度和边线 ControlNet（强度 0.5），denoise 最高 0.32。
- **提示词太长**。SDXL 的 CLIP 一段只读 77 个 token，原来那一大段描述它基本读不进去。现在改成短关键词。

## 安装 / 更新

1. 用本仓库的 `extension/` 覆盖 `F:\SU插件\extension`。
2. 在 SketchUp 里点「扩展 → AI 渲染工作室 → 重新加载插件（开发）」，或者直接重启 SketchUp。
3. 打开渲染面板，在最上面的「渲染引擎」里：
   - **Nano Banana Pro**：到 <https://aistudio.google.com/apikey> 创建 API Key（需要开通付费），粘贴进去后点「保存设置」。国内访问的话，在「高级」里把代理填成你 Clash 或 V2Ray 的本地端口，例如 `127.0.0.1:7890`。
   - **Seedream**：到火山方舟控制台 <https://console.volcengine.com/ark> 开通 Seedream 模型，并创建 API Key。
4. 「AI 强度」保持 0 到 20：完全不加东西，只换材质和光照。

API Key 存在 SketchUp 自己的偏好设置里（Windows 注册表，跟本机用户绑定），不会写进插件文件夹，面板上只显示最后 4 位。

## 模型 ID

在「高级」里可以改模型 ID，留空就用默认值：

- Gemini：默认 `gemini-3-pro-image-preview`（Nano Banana Pro）。想更快更便宜，可以填 `gemini-3.1-flash-image-preview`（Nano Banana 2）。
- Seedream：默认 `doubao-seedream-4-5-251128`。换 5.0 lite 填 `doubao-seedream-5-0-260128`。

以后模型正式版改名了，直接在这里改，不用动代码。

## 排查

日志都在 `%TEMP%\ai_render_studio\`：
- `render.log`：每一步的记录，包括每次尝试的结构吻合度分数。
- `last_cloud_prompt.txt`：最近一次发给云端的完整提示词。

云端出的图保存在 `F:\Comfy-Desktop\ComfyUI-Shared\output\SU_AI_Render\`（文件名带 `_cloud_`）。
