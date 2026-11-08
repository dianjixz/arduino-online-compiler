# Arduino Online Compiler

在浏览器里贴一份 `platformio.ini` 和一段 `src/main.cpp`，云端用 PlatformIO 编译，然后下载加密后的固件产物——本地不需要装任何工具链。

这个项目是从 [ESPHome 在线编译](../esphome-online-compiler-main) 改造而来：保留了 OAuth 登录、双 token 降级、Workflow 派发、状态轮询、产物代理下载这些基础设施，把编译侧换成了 **PlatformIO + Arduino 框架**，输入从「一份 YAML」换成「`platformio.ini` + `src/main.cpp`」两个文本框。

## 功能

- ✅ 极简双文本域：`platformio.ini`（CodeMirror INI 高亮）+ `src/main.cpp`（C++ 高亮），首次进入自带可编译的示例工程。
- ✅ 本地自动保存草稿、压缩包密码、PlatformIO 版本与最近一次编译状态，刷新页面后自动恢复并继续轮询。
- ✅ 产物为加密 zip：`firmware-<request_id>-password.zip`，密码可在页面上自定义并本地保存。
- ✅ 编译失败自动拉取失败 job 的日志并抽取错误上下文，同时保留 GitHub Workflow 链接。
- ✅ 双 token 策略：平台 `GITHUB_SERVICE_TOKEN` 优先，遇到 401/403/429 自动降级到个人 OAuth 授权。
- ✅ 中英双语界面（默认跟随浏览器语言）。

## 支持范围

| 项目 | 支持情况 |
| --- | --- |
| 平台（`platform`） | `espressif32`、`espressif8266`（含 `@版本` 固定写法，如 `espressif32@6.9.0`） |
| 框架（`framework`） | 必须包含 `arduino` |
| 板卡（`board`） | 对应平台的任意合法 board id，例如 `esp32dev`、`esp32-s3-devkitc-1`、`esp32-c3-devkitm-1`、`nodemcuv2`、`d1_mini` |
| 体积上限 | `platformio.ini` ≤ 24KB，`main.cpp` ≤ 64KB |
| 明确不支持 | `extra_scripts`、`platform_packages`、远程平台/依赖地址（`http(s)://`），以及非 Arduino 框架 |

> 注意：官方 `platformio/espressif32` 当前停在 6.9.0（对应 Arduino core 2.0.17）。想用 Arduino core 3.x 或 ESP32-C6/H2/P4 需要把 `platform` 换成 pioarduino 维护的 fork，本项目出于安全考虑只允许平台**名称**、不允许远程平台 URL，必要时请自行扩展白名单。

## 目录结构

```
.
├── frontend/                     Vue 3 + Vite SPA（编辑器、状态轮询、下载）
│   └── src/components/
│       ├── CodeEditor.vue        CodeMirror 6 封装（cpp / ini 两种语言）
│       └── CompileForm.vue       表单 + 编译状态机
├── functions/[[path]].ts         Cloudflare Pages Function：OAuth、会话、GitHub API 代理
├── scripts/collect-artifacts.sh  CI 与本地共用的产物收集脚本（含 merged bin、flash 命令）
├── .github/workflows/pio-compile.yml  PlatformIO 编译工作流
└── .dev.vars.example             Wrangler 本地密钥模板
```

## 本地开发

```bash
# 1. 前端
npm install --prefix frontend
npm run typecheck --prefix frontend   # vue-tsc 类型检查（可选但推荐）
npm run dev --prefix frontend         # http://localhost:5173

# 2. Pages Functions（另开一个终端，需要 wrangler）
cp .dev.vars.example .dev.vars        # 填入 OAuth / 仓库配置
npm run build --prefix frontend       # 生成 frontend/dist
wrangler pages dev frontend/dist --local --port 8787
```

Vite 已把 `/auth/*` 与 `/api/*` 代理到 `http://127.0.0.1:8787`。

## 部署到 Cloudflare Pages

1. 新建 Pages 项目并连接本仓库。
2. 构建配置：
   - Build Command：`npm install && npm run build --prefix frontend`
   - Build Output Directory：`frontend/dist`
   - Functions Directory：`functions`
3. 在 **Settings → Variables（Production & Preview）** 配置：

| 变量 | 说明 |
| --- | --- |
| `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` | GitHub OAuth App 凭据 |
| `GITHUB_OAUTH_REDIRECT_URI` | 必须与 OAuth App 回调地址一致，例如 `https://<你的域名>/auth/callback` |
| `SESSION_SECRET` | 32+ 字节随机串（会话 cookie 的 HMAC 密钥） |
| `GITHUB_REPO_OWNER` / `GITHUB_REPO_NAME` | 承载 Actions 的仓库 |
| `GITHUB_WORKFLOW_ID` | `pio-compile.yml` |
| `GITHUB_WORKFLOW_REF` | 默认 `main` |
| `FRONTEND_URL` | 授权完成后的跳转地址 |
| `ALLOWED_ORIGINS` | 允许的跨域来源，逗号分隔 |
| `GITHUB_REQUIRE_PRIVATE_REPO` | 访问私有仓库时设为 `true`（会申请 `repo` scope） |
| `GITHUB_SERVICE_TOKEN` | 可选，平台默认 Fine-grained PAT（仅需 `workflow` + `public_repo`） |

## 编译流水线

```
浏览器                      Pages Functions                    GitHub Actions
  │ POST /api/compile {encodedIni, encodedSketch, password}
  │────────────────────────▶ 校验体积/密码/ini 白名单
  │                          取 token（service 优先，失败降级 session）
  │                          workflow_dispatch ─────────────▶ 建 run（run-name 含 request_id）
  │◀── {requestId, runId}    按 run-name 匹配最近 run
  │ GET /api/status/...（10s 轮询）
  │────────────────────────▶ runs/:id + artifacts
  │◀── {status, conclusion, artifactUrl, failedJobId}
  │ GET /api/artifacts/...  手动跟随 302 到 Azure Blob 后流式回传
```

工作流步骤：解码输入 → 防御性校验 → 缓存 `.platformio` → 安装 PlatformIO → `pio run -d project --no-ansi` → 收集产物 → 打包加密 zip → 上传 artifact（保留 1 天）→ 写 Job Summary。

### 产物内容

```
firmware-<request_id>-password.zip
└── <env>/
    ├── firmware.bin / firmware.hex / firmware.uf2
    ├── firmware.elf
    ├── bootloader.bin, partitions.bin, boot_app0.bin   （ESP32 系）
    ├── merged-0x0.bin        ← 单文件镜像（esptool merge_bin 生成，直刷 0x0）
    └── flash_args.txt        ← 现成的 esptool / avrdude 命令
└── build.log
└── BUILD-INFO.txt
```

`flash_args.txt` 示例：

```bash
esptool.py --chip esp32 -p COM_PORT -b 460800 write_flash 0x0 merged-0x0.bin
```

## 安全说明

- 工作流固定 `permissions: contents: read`，构建过程中不注入任何 secret；`GITHUB_TOKEN` 不会被导出到构建环境。
- `platformio.ini` 在后端和白名单层都做了校验，拦截 `extra_scripts`、`platform_packages`、远程 URL——这些都会在 runner 上执行任意代码。**库（`lib_deps`）的 PlatformIO 包仍可能携带构建脚本，这是本方案残留的风险，公开服务上线前请自行评估。**
- 压缩包密码作为 `workflow_dispatch` 输入传递，能读该 run 的人可以看到它；密码只用于防止产物被随意抓取，不构成访问控制。
- 公开仓库的 Actions 分钟数免费，但任何人都能调用本服务消耗资源：上线前建议加 Cloudflare Turnstile、按 GitHub 用户/ IP 限流，并限制仓库并发。
- 永远不要把真实密钥写进仓库；生产变量走 Cloudflare 控制台，本地放 `.dev.vars`（已被 `.gitignore` 忽略）。

## 常见问题

| 现象 | 原因与处理 |
| --- | --- |
| `Unknown board ID` | `board` 写了平台里不存在的名字；先用 `pio boards espressif32` 查 |
| `Could not find a version that satisfies the requirement platformio==x.y.z` | 版本号写错或该版本不存在，清空版本框用最新版即可 |
| 编译超时 | 工作流超时 25 分钟；首次编译需要下载平台与工具链，缓存命中后会快很多 |
| 产物里没有 `merged-0x0.bin` | 8266/AVR 平台没有分段镜像，直接看 `flash_args.txt` |
