# MNN Chat 装到 iPhone 15 Pro —— 付费开发者账号版（Windows 全程）

你有付费 Apple Developer Program 账号，所以**不需要删 entitlements**。
但要注意一个陷阱，见下面第 0 节。

---

## 0. 先搞清楚：付费账号 + Sideloadly ≠ 有内存特权

Sideloadly 重签时会**自己生成一份 provisioning profile**，它不会去你后台勾 capability。
结果就是：ipa 里写着 `increased-memory-limit`，但新 profile 里没有这一项，
**签名时被静默丢弃，或直接报错**。

所以在 Sideloadly 这条路线上，付费号和免费号的内存上限完全一样。

要用上你花钱买的东西，必须**自己签名**（路线 A）。

| | 路线 A：signed（推荐） | 路线 B：unsigned + Sideloadly |
|---|---|---|
| entitlements | 保留，内存上限拉满 | 必须清空 |
| 有效期 | **1 年** | 7 天 |
| 同时安装数 | 100 台设备 | 3 个 |
| 能跑 4B 模型 | ✅ | ❌ 大概率 OOM |
| Windows 端工具 | iMazing / 3uTools | Sideloadly |
| 准备成本 | 要做证书 + profile，约 20 分钟 | 几乎为零 |

---

# 路线 A：自己签名（保住 entitlements）

## A1. 在开发者后台准备 App ID

1. 打开 https://developer.apple.com/account/resources/identifiers/list
2. 点 **+** → 选 **App IDs** → **App** → Continue
3. **Bundle ID** 填 `com.你的名字.mnnchat`（Explicit，记下来）
4. 往下滚到 **Capabilities**，**勾选这两项**：
   - ☑️ **Extended Virtual Addressing**
   - ☑️ **Increased Memory Limit**
   > 这两项在付费 ADP / 企业 ADEP 下都可勾选。免费账号列表里根本看不到。
5. Save

## A2. 生成证书

1. https://developer.apple.com/account/resources/certificates/list → **+**
2. 选 **Apple Development**（真机调试用这个）
3. 按提示上传 CSR：
   - Windows 上用 **iMazing** 或 **3uTools** 可以一键生成 CSR 并导出 p12
   - 或者用 OpenSSL：
     ```powershell
     openssl req -new -newkey rsa:2048 -nodes -keyout mnn.key -out mnn.csr -subj "/CN=MNN Chat/O=YourName/C=CN"
     ```
     上传 `mnn.csr`，下载 `development.cer`，再转 p12：
     ```powershell
     openssl x509 -in development.cer -inform DER -out mnn.pem -outform PEM
     openssl pkcs12 -export -inkey mnn.key -in mnn.pem -out mnn.p12 -passout pass:你的密码
     ```
4. 记下 **Team ID**（后台右上角，10 位，形如 `A1B2C3D4E5`）

## A3. 注册设备 + 生成描述文件

1. https://developer.apple.com/account/resources/devices/list → **+**
   填入 iPhone 的 **UDID**
   - 获取 UDID：手机连电脑，iTunes / iMazing / 3uTools 都能看到
2. https://developer.apple.com/account/resources/profiles/list → **+**
   - 选 **iOS App Development**
   - App ID 选 A1 建的那个
   - 证书选 A2 的
   - 设备勾上你的 iPhone
   - 命名保存 → 下载 `mnn.mobileprovision`

> ⚠️ 顺序很重要：**先勾 capability，再生成 profile**。
> 顺序反了，profile 里就没有那两个 key，签出来照样没有内存特权。

## A4. 转成 base64 填进 GitHub Secrets

在 Windows PowerShell 里：

```powershell
# 证书
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\mnn.p12")) | Set-Clipboard
# 描述文件
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\mnn.mobileprovision")) | Set-Clipboard
```

打开 GitHub 仓库 → **Settings → Secrets and variables → Actions → New repository secret**，
依次添加：

| Secret 名 | 值 |
|---|---|
| `BUILD_CERT_P12_BASE64` | 上面 p12 的 base64（注意是单行，别带换行） |
| `BUILD_CERT_PASSWORD` | p12 导出时设的密码 |
| `PROVISIONING_PROFILE_BASE64` | mobileprovision 的 base64 |
| `KEYCHAIN_PASSWORD` | 随便编一个，如 `mnn-ci-2026` |
| `TEAM_ID` | 你的 10 位 Team ID |
| `BUNDLE_ID` | A1 里填的 Bundle ID |

## A5. 跑 workflow

1. Actions → **Build MNN Chat iOS IPA** → Run workflow
2. **sign_mode 选 `signed`**
3. `with_diffusion` 想省时间可以关（不编文生图，省约 30%）
4. 等 25~50 分钟

跑完看 **Verify signature** 那步的日志，应该出现：

```
::notice::increased-memory-limit 已生效
::notice::extended-virtual-addressing 已生效
```

如果出现 `::warning::签名里没有 increased-memory-limit`，说明 A1 的勾选或 A3 的顺序出问题了，
回去检查后重新生成 profile。

## A6. 下载并安装

Artifacts 里下载 `MNNChat-signed-ipa.zip`，解压得到 `MNNChat-signed.ipa`。

安装方式（Windows，三选一）：

**iMazing**（推荐，最稳）
1. 装 https://imazing.com/ ，连上 iPhone
2. 选设备 → **Apps** → 底部 **Manage Apps** → 登录你的 Apple ID
3. 把 `MNNChat-signed.ipa` 拖进去，或点 **Install**
4. 因为已签名，装上即可用，**不会 7 天过期**

**3uTools**
1. 装 https://www.3u.com/ ，连设备
2. **Apps** → **IPA 签名/安装** → 选 ipa → 用你导入的证书签 → 安装

**Sideloadly（normal install 模式）**
把 ipa 拖进去，**Install Mode 选 `normal install`**（不是 Apple ID 那种），
配合已装好的证书使用。这个模式不会覆盖你的 entitlements。

## A7. 首次打开

设置 → 通用 → VPN与设备管理 → 信任你的开发证书。

---

# 路线 B：unsigned + Sideloadly（快速试水）

想 10 分钟内看到效果就用这个，但要接受删掉 entitlements、7 天过期、3 个 App 上限。

1. Actions 里 `sign_mode` 选 **`unsigned`**
2. 下载 `MNNChat-unsigned-ipa.zip`
3. 装 **web 版 iTunes**（不能是 Microsoft Store 版）
   https://www.apple.com/itunes/download/win64
4. 装 Sideloadly
   https://sideloadly.io/SideloadlySetup64.exe
5. 拖入 ipa，填 Apple ID（开了双重认证要用 App 专用密码）
6. Start → 手机信任证书

> 这条路 entitlements 被清空，**1.7B 勉强、4B 必崩**。

---

# 通用部分：App 内配置

## 模型选型（iPhone 15 Pro / 8GB）

| 模型 | 权重大小 | 路线 A | 路线 B |
|---|---|---|---|
| Qwen3-0.6B-MNN | ≈ 430 MB | ✅ 秒开 | ✅ 可用 |
| Qwen3-1.7B-MNN | ≈ 1.2 GB | ✅ **主力推荐** | ⚠️ 勉强 |
| Qwen3-4B-MNN | ≈ 2.6 GB | ✅ 可用 | ❌ 大概率 OOM |
| Qwen3-VL-4B-Instruct-MNN | ≈ 2.8 GB | ✅ | ❌ |

## 必调的三项设置

进 App 设置页（历史记录侧边栏进入）：

- **Backend** → `Metal`
- **Precision** → `low`（fp16）
- **mmap** → 开（8GB 内存必须）

---

# 常见报错

| 报错 | 原因 / 解法 |
|---|---|
| `A valid provisioning profile ... not found` | profile 和 Bundle ID / Team ID 不匹配；或 profile 里没包含这台设备的 UDID |
| `Provisioning profile doesn't include signing certificate` | profile 里选的证书和 p12 不是一对，回 A2/A3 重做 |
| `::warning::签名里没有 increased-memory-limit` | App ID 没勾 capability，或 profile 在勾选前生成。**先勾再生成** |
| `maximum App ID limit` | 只在免费账号出现，你付费号不会有 |
| `NP_E_CONN_FAILED` / `AFC_E_MUX_ERROR` | 装了 Store 版 iTunes，卸载换 web 版 |
| App 一开就闪退 | MNN.framework 编译开关不全，检查 workflow 里 `MNN_CMAKE_FLAGS` |
| 加载模型被系统杀 | 看 Verify signature 那步日志，确认 entitlements 真的进签名了 |

---

# 编译失败排查

**Build MNN.framework 失败**
- 多半是 `macos-15` 的 Xcode 与 MNN 不兼容 → `runs-on` 改 `macos-14` 重跑
- 日志里 `cmake: command not found` → 该 runner 镜像已自带，若真缺就加一步 `brew install cmake`

**Build app 失败**
- `No available simulator runtimes`：asset catalog 编译要模拟器 runtime。
  在 Build app 步骤追加 `EXCLUDED_SOURCE_FILE_NAMES="*.xcassets" ASSETCATALOG_COMPILER_APPICON_NAME=""`
  （App 少个图标，功能不受影响）
- SPM 拉包超时：重跑一次即可

把红色那步的日志贴出来，我按实际报错改 workflow。
