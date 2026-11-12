# VCam — iOS 全局摄像头替换 (Hook 摄像头插件)

> 项目结构:
> - Demo: `VCamDemo/` (相机测试 app, bundle `com.bangcle.vcamdemo`)
> - Tweak: `vcam/Tweak/` (vcamd daemon hook + vcama app hook + VCamEngine)
> - 目标设备: 越狱 iPhone (unc0ver, iOS 13.5 / 13.6, arm64)

## 一、总体架构

```
┌─────────────────────────────────────────────────────────────┐
│                    替换媒体 (mobile 可写)                      │
│   /var/mobile/Library/vcam/photo.jpg  (拍照替换源)            │
│   /var/mobile/Library/vcam/video.mp4  (预览/录像替换源, 循环)  │
│   /var/mobile/Library/vcam/config.plist (无头配置)            │
└────────────────────┬────────────────────────────────────────┘
                     │ 读取 (lazy, 后台队列)
      ┌──────────────┴──────────────┐
      │   VCamEngine (共享引擎)       │
      │  - 配置合并 (plist+CFPrefs)   │
      │  - AVAssetReader 视频循环解码  │
      │  - photo.jpg 解码缓存         │
      │  - blit: memcpy 快路径/CI 慢路径│
      └──────┬──────────────┬───────┘
             │              │
   ┌─────────┴───┐   ┌──────┴──────────┐
   │ vcamd.dylib │   │   vcama.dylib   │
   │ mediaserverd │   │  注入用户 app    │
   │ (全局替换)    │   │ (按 app 替换)    │
   └─────────────┘   └─────────────────┘
```

### Hook 点 (iOS 13 实测验证存在)

**vcamd** — 注入 `/usr/sbin/mediaserverd` (filter: `Executables=mediaserverd`):

| 类 | 方法 | 作用 | 替换源 |
|---|---|---|---|
| `BWNodeOutput` | `emitSampleBuffer:` | 所有 app 的实时预览/录像流 | video.mp4 |
| `BWStillImageScalerNode` | `renderSampleBuffer:forInput:` | 拍照缩放阶段 | photo.jpg |
| `BWPhotoEncoderNode` | `renderSampleBuffer:forInput:` | 拍照编码阶段 | photo.jpg |

**vcama** — 注入用户 app (filter: `Bundles=com.apple.UIKit`, constructor 跳过 `com.apple.*`):

| 类 | 方法 | 作用 |
|---|---|---|
| `AVCaptureVideoDataOutput` | `setSampleBufferDelegate:queue:` | 代理换壳，帧内容替换 |
| `AVCapturePhotoOutput` | `capturePhotoWithSettings:delegate:` | 照片 delegate 换壳，KVC 换 JPEG |
| `AVCaptureSession` | `startRunning` | 日志标记 |

## 二、配置 (两种方式)

### 1. 无头配置 `/var/mobile/Library/vcam/config.plist`

```xml
<dict>
    <key>enabled</key>    <true/>
    <key>global</key>     <true/>
    <key>apps</key>       <array><string>com.bangcle.vcamdemo</string></array>
    <key>photoPath</key>  <string>/var/mobile/Library/vcam/photo.jpg</string>
    <key>videoPath</key>  <string>/var/mobile/Library/vcam/video.mp4</string>
</dict>
```

### 2. 设置界面 (PreferenceLoader)

`/Library/PreferenceLoader/Preferences/vcamsettings.plist` → 设置 → VCam 摄像头替换。
写入 CFPreferences domain `com.bangcle.vcam` (键: enabled/global/appsText/photoPath/videoPath)，
每次修改自动发 darwin 通知 `com.bangcle.vcam.reload`，tweak 实时重载（UI 优先于 plist）。

### 生效逻辑

```
enabled=0                          → 不替换
enabled=1, global=1                → 全局替换 (mediaserverd hook, 所有 app)
enabled=1, global=0, apps 含 bid   → 仅列表内 app 替换 (vcama)
```

## 三、部署清单

| 本地 (vcam/Tweak/) | 设备路径 | 权限 |
|---|---|---|
| vcamd.dylib | /Library/MobileSubstrate/DynamicLibraries/ | root:wheel 755 |
| vcamd.plist | 同上 | root:wheel 644 |
| vcama.dylib | 同上 | root:wheel 755 |
| vcama.plist | 同上 | root:wheel 644 |
| vcamsettings.plist | /Library/PreferenceLoader/Preferences/ | 644 |
| (媒体) photo.jpg / video.mp4 | /var/mobile/Library/vcam/ | mobile 644 |

使 daemon hook 生效: `kill <mediaserverd pid>` (launchd 自动重启)。
使 app hook 生效: 重启目标 app。

## 四、踩坑记录 (重要！)

### 坑 1: constructor 里碰 AVFoundation → watchdogd kernel panic → 手机重启、越狱丢失

**现象**: 部署 vcamd 后手机数分钟内自动重启，重启后 unc0ver 越狱失效，SSH 断连。

**崩溃链** (4 份 mediaserverd crash log + 2 份 panic-full 证实):

```
dyld 初始化 mediaserverd
  → vcamd constructor (主线程)
    → [VCamEngine reload] → AVAsset/AVAssetReader
      → CoreMedia/MediaToolbox 同步 XPC → 调 mediaserverd 自己
        (此刻 mediaserverd 尚未完成启动) → 主线程死锁
→ watchdogd 120s 收不到 checkin → SIGKILL mediaserverd
→ 反复 3 次 → userspace watchdog timeout → KERNEL PANIC → 重启
→ unc0ver 半持久化越狱丢失
```

panic 原文: `userspace watchdog timeout: no successful checkins from
com.apple.mediaserverd since load`

**修复**: constructor 只做 objc hook 安装 (objc_getClass + method_setImplementation,
无 XPC 无框架初始化)。引擎单例与全部媒体加载延迟到**首个相机 buffer 到达时**，
在专用串行队列 (`vcamd.engine`) 上异步创建。

**铁律: 系统 daemon 的 +load/constructor 中禁止调用任何高层框架 (AVFoundation/
CoreImage/CoreMedia XPC 类函数)。**

### 坑 2: vcama 注入系统 daemon → CoreImage 崩溃循环

**现象**: `Bundles=com.apple.UIKit` filter 把 ptpcamerad/remindd/avatarsd 等
系统进程也注入了。vcama constructor 创建 VCamEngine → CIContext (软渲染) →
这些进程里 CoreImage 初始化崩溃 → ReportCrash 339% CPU → 系统负载 3.8。

**修复**:
1. constructor 开头检查 `[[NSBundle mainBundle] bundleIdentifier]`,
   `com.apple.` 前缀直接 return;
2. CIContext 改为首次 blit 时懒创建。

### 坑 3: storyboard app 的 AppDelegate 必须实现 window 属性

**现象**: demo 启动黑屏，`viewDidLoad` 从不执行。Xcode 控制台:
`The app delegate must implement the window property if it wants to use a
main storyboard file.`

**修复**: `AppDelegate.h` 加 `@property (strong, nonatomic) UIWindow *window;`

### 坑 4: 0xE80000BE entitlement 不匹配 (Xcode 安装失败)

**现象**: Xcode Run 报 `application-identifier entitlement does not match that
of the installed application`。

**原因**: 混用签名通道。`ios_sign.py` 自动匹配 wildcard profile
(`iOS Team Provisioning Profile: *`)，与 Xcode 自动生成的 bundle 专属 profile
的 application-identifier 不同。覆盖安装要求该值完全一致。

**处理**: `ideviceinstaller uninstall com.bangcle.vcamdemo` 后 Xcode 全新安装。
**规范: 调试期统一用 Xcode Run 安装，勿与命令行签名工具混用。**

### 坑 8: unc0ver 重越狱内核 data abort → panic → 越狱丢失 (2026-11-11 17:38)

**现象**: 16:51 验证全部通过后, 设备 ~17:26 重启 (越狱丢失), 用户尝试 unc0ver
重越狱, 17:38 内核 panic 重启, 越狱失败。表现为 SSH 全端口 (22/44/31337)
kex 阶段 connection reset = 设备上无 sshd = 无越狱。

**panic 证据** (`panic-full-2026-11-11-173807.ips`, 已存
`vcam/crashlogs/2026-11-11-unc0ver-panic/`):

```
Kernel data abort. esr=0x96000004 far=0x5f43cea000fccbff (垃圾指针)
Panicked task pid 459: unc0ver   ← 崩在 unc0ver 内核修补过程中
```

**定性**: 崩溃任务是 unc0ver 本身 (内核 exploit 修补阶段), 与本 tweak 无关
(tweak 是用户态 dylib, 不可能直接产生内核 data abort; 坑 1 的 userspace
watchdog panic 的 panicString 形态完全不同)。

**处理**: unc0ver 内核 data abort 属偶发, 重试重越狱即可 (官方 FAQ 同建议)。
越狱恢复后: iproxy 重绑 UDID → 验证部署文件在位 → kill mediaserverd →
跑 demo 自动流程复验。

### 坑 5: iOS 13 老设备 USB/SSH 断连排查顺序

1. `iproxy` 必须绑定 UDID: `iproxy -u <UDID> 2222 22` — 两台设备同时在线时
   不带 `-u` 会绑到错误的设备，表现为"SSH 时通时断"
2. 锁屏 → app 被 suspend → 相机流停止 → 无法验证。测试期设置
   显示与亮度→自动锁定→永不
3. 重启后 DDI (DeveloperDiskImage) 掉载 → `ideviceimagemounter` 重挂
4. 设备无 `sqlite3/awk/strings/plutil`，文件操作走本地处理后 scp/base64 传输

## 五、验证方法

Demo (com.bangcle.vcamdemo) 内置自动测试流程，启动后无需交互:
- 实时预览 (AVCaptureVideoDataOutput delegate, hook 点)
- **+8s 自动拍照** → Documents/captured_photo.jpg
- **+15s~28s 自动录像** → Documents/captured_video.mov
- 状态实时显示在屏幕 + 写入 `/tmp/vcamdemo.log` (权限/会话/帧计数)

替换验证: 拍出的照片应为**品红底 + 黄色大圆 + 蓝色十字 + 左上绿色块**测试图
(video.mp4 为品红/青渐变 + 蓝块横移动画)，而非真实相机画面。

## 六、当前状态

- [x] vcamd 注入 mediaserverd 成功且稳定 (修复坑 1 后无崩溃, marker pid 校验)
- [x] vcama 注入 demo 成功 (hook 标记全部输出)
- [x] 引擎加载 photo.jpg (53974B) + video.mp4 (3s) 成功
- [x] Demo 黑屏根因修复 (坑 3)
- [x] **录像替换端到端验证通过** (2026-11-11 15:14):
  - captured_video.mov (881KB) 首帧 = 品红底 + 移动蓝块 + 白色扫描线 = 替换源 video.mp4 图案
  - 非真实相机画面 → daemon 全局 hook 生效
- [x] 高辨识度替换媒体 v2 已部署:
  - photo.jpg = 8×6 高饱和色块网格 + 中央黑色大 V (1440×1080)
  - video.mp4 = 渐变流动背景 + 白色对角条纹 + 中央帧号 000→149 (5s 循环)
- [x] Demo 新增 RESULT 视图: 主界面 RESULT 按钮 → 展示 captured_photo.jpg (UIImageView)
      + captured_video.mov (AVPlayer 自动播放), 未捕获时灰字提示
- [x] per-app 模式 daemon 放行修复: `activeForCurrentProcess` 中 daemon
      (VCAM_DAEMON env) 仅在 global=1 时替换; per-app 模式 daemon 原样放行,
      由 vcama (app 内 hook) 处理列表内 app。已部署 (mediaserverd pid 7931)
- [x] per-app config 已写入: enabled=1, global=0, apps=[com.bangcle.vcamdemo]
- [x] **坑 6 修复: daemon 引擎死锁** — 全局验证后切 per-app 模式, demo 帧回调
      完全失联 (photo/video 均无产物)。根因: daemon emit 路径无条件创建引擎,
      引擎在 mediaserverd 内做 AVAsset 工作 → XPC 调 mediaserverd 自己 →
      引擎队列死锁 → emit 阻塞 → 所有 app 断流。修复: 新增
      `+daemonShouldBeActive` 轻量 gate (直读 config, 不建引擎/不碰
      AVFoundation/无锁), emit/still 路径先判 gate, 非 global 模式直接放行。
- [x] **坑 7 修复: demo 架构改为单帧管道** — 旧架构用 PreviewLayer/PhotoOutput/
      MovieFileOutput, 三条路径都绕过 delegate, per-app 模式 (vcama 只 hook
      delegate) 下预览/拍照/录像全部不被替换。新架构: 预览 = UIImageView 渲染
      delegate 帧, 拍照 = 当前替换帧存 JPEG, 录像 = AVAssetWriter 逐帧写替换帧。
      三种产物同源, per-app/global 两模式天然一致。
- [x] **拍照替换端到端验证通过** (2026-11-11 16:12, per-app 模式):
  - captured_photo.jpg (323KB) = 渐变条纹 + 中央帧号 **058** = 替换源 video.mp4 帧
  - 非真实相机画面 → vcama app 内 hook 生效
- [x] **录像替换端到端验证通过 (per-app 模式)** (2026-11-11 16:13):
  - captured_video.mov (25.8MB) @2s 帧 = 条纹 + 帧号 **102**
  - AVAssetWriter 单帧管道录像 + 替换内容一致
- [x] **per-app 隔离实测通过** (2026-11-11 16:17):
  - com.tencent.watermarkcamera (不在 apps 列表) 拉起后相机流活跃
    (CPU 0:16→0:17 持续增长), mediaserverd CPU 几乎不变 (2:50.73→2:51.46)
    = daemon gate=0 未做替换, vcama activeForCurrentProcess=NO 未代理
    → 非列表 app 使用真实相机画面
  - 列表内 app (demo) 被替换 (058/102 帧号图案) → 隔离正确

### RESULT 视图使用

Demo 主界面左上角 **RESULT** 按钮 → 弹出展示页:
- captured_photo.jpg 全宽显示 (期望: 渐变条纹 + 帧号)
- captured_video.mov 内嵌 AVPlayer 自动播放 (期望: 条纹背景 + 帧号跳动)
- 未捕获时显示灰字 "not captured yet"

### 验证操作要点 (真机)

1. Xcode ⌘R Run (统一 Xcode 安装, 避免坑 4); 用命令行工具安装时必须先卸载
2. 手动点开 app 保持前台 (uiopen 拉起会被系统挂起, app 必须真实前台)
3. 等 45s 自动流程 (拍照 +8s/+20s, 录像 15~32s)
4. 点 RESULT 查看捕获内容; 或 SSH 拉取 Documents 下的 captured_* 文件

### 单帧管道架构说明 (重要)

所有捕获产物 (预览/拍照/录像) 都从 `AVCaptureVideoDataOutput` 的 delegate
帧派生 — 这是 app 内 hook (vcama) 唯一能替换的路径。若用
PreviewLayer/PhotoOutput/MovieFileOutput 原生组件, 内容不经过 delegate,
per-app 替换对它们无效 (global 模式不受影响, 因 daemon 在源头换帧)。

## 七、水印相机 (WaterMarkCamera) 设计借鉴

逆向了设备上腾讯水印相机 (com.tencent.watermarkcamera, 主类
`ZebraViewController`) 的相机架构, 提炼 4 个设计点应用到 VCamDemo:

| WMC 设计 | WMC 实现 | VCamDemo 应用 |
|---|---|---|
| 实时水印 view | `WMCWatermarkViewManager` — view 层叠加时间/GPS/地点, `triggerTimer` 每秒刷新 | `WatermarkOverlay` — brand 标记 ("VCAM REPLACED") + 实时时间戳 + 帧号, 每帧刷新 |
| 拍照水印合成 | `outputProcessedPhoto:` → `mergeWatermarks:` 把 view 层水印画进照片 | `takePhoto` 里 `snapshotForSize:` 渲染 overlay → 叠加到帧图 (UIGraphicsImageRenderer) |
| EXIF 元数据 | `_exifDic` 写 `kCGImagePropertyExifDateTimeOriginal` + GPS/POI | `VCamWriteEXIFToJPEG()` — ImageIO 写 DateTimeOriginal/GPS/UserComment ("VCamDemo replaced frame") |
| 滤镜链 | `FilterEngine.bundle` + `FMImageFilterManager` (doImageFilterProcessing:) | (未实现, 可扩展点: 帧级滤镜链) |

**验证** (2026-11-11 16:37):
- captured_photo.jpg (653KB): 左上 "VCAM REPLACED" 水印 + 渐变条纹 + 帧号 055
  — 水印与替换帧合成正确
- JPEG EXIF 段含 `UserComment: VCamDemo replaced frame` + `DateTimeOriginal: 2026:...`
  — EXIF 注入成功
- 预览层水印每帧刷新 (帧号/时间实时)

**WMC 模式的意义**: 水印是"替换发生"的可见证明 — 拍出来的照片自带
"VCAM REPLACED" 标记和拍摄时刻, 无需外部工具即可确认替换链路在工作。

## 八、替换源媒体 v3: WMC 风格"虚假水印照片" (最终版)

早期替换源 (纯色/条纹/帧号) 在预览里轮番滚动, 视觉上毫无意义且极易识破。
参考水印相机的设计, 替换源改为**"像水印相机拍出来的照片"**:

### photo.jpg (拍照替换源, 1440×1080)
- 背景: 真实感办公场景 — 暖色虚化室内 (窗户光晕) + 深棕木纹桌面 +
  笔记本/咖啡杯/手机/绿植 (轻微高斯虚化模拟景深) + 相机噪点
- 水印卡 (右下角): 白色半透明圆角卡 + 橙色品牌竖条 +
  `11:00:08` 大字时间 + `2026-11-11 Week45` 日期 + `Office · Building A · Shenzhen` 地点 +
  右上角橙色 `VCAM` 标记
- 效果: 看起来就是"水印相机拍的一张办公室打卡照"

### video.mp4 (预览/录像替换源, 1440×1080, 6s)
- 3 张同场景照片 (不同时刻) 交叉淡入淡出轮换 (每张 2s, 过渡 0.5s)
- 水印卡时间**每秒真实跳动** (00:00:00 → 00:00:05...) — 证明帧是活的非静态图
- 相机噪点逐帧随机 — 更接近真实感

### 验证 (2026-11-11 16:51)
- captured_photo.jpg (669KB) = 办公桌场景 + 水印卡 (时间 00:02:40 /
  2026-11-11 Week45 / Office · Building A · Shenzhen / VCAM) + 左上
  "VCAM REPLACED" 叠加水印 — 完整呈现"被替换的水印照片"
- captured_video.mov (2.9MB) 录像同步替换

### 生成方式
PIL 合成 (无真实照片依赖): 场景绘制 → 高斯虚化 → 水印卡 RGBA 叠加 →
噪声注入。3 场景序列 → ffmpeg libx264。全部源码在
`/var/folders/x6/r038g53x68gbg55gx_k0vcl80000gn/T/opencode/` 生成脚本中,
可按需改场景/时间/地点重新生成。

## 九、第二目标机验证: iPhone 8 (iPhone10,1 / iOS 13.6) (2026-11-11 19:10)

设备: UDID `3a3e822c...` (iproxy 2222 绑定), 越狱在位, vcam 部署与
iPhone 7 完全一致 (dylib 16:01 同版本, 媒体 v3, per-app config)。

- [x] **17:07 旧产物核验**: captured_photo.jpg = 办公室场景 + 水印卡
      `00:00:36` + `VCAM REPLACED` — 该机 per-app 替换此前已生效
- [x] **19:10 全新端到端复验** (uiopen 拉起, 本轮未复现"uiopen 拉起被挂起"):
  - +8s 拍照 ✓ (frame #1800 持续流动)
  - +15~32s 录像 ✓ (captured_video.mov 12.6MB, @8s 帧 = 替换源场景 +
    水印时间 `00:00:16` 活帧跳动)
  - +20s 重拍 ✓ (photo 512KB, 水印卡 `00:01:55`)
- [x] EXIF: DateTimeOriginal=2026:11:11 19:11:08 ✓ / UserComment ✓
- SSH 免密: root:alpine 已写入 authorized_keys (/var/root/.ssh + /etc/dropbear/root_keys)

### 坑 9: kCLLocationCoordinate2DInvalid 非零哨兵 → GPS 垃圾值写入 EXIF

**现象**: iPhone 8 无定位权限, 拍出照片 EXIF 含 GPS `-180.0, -180.0 (S/W)`
垃圾坐标。

**根因**: `CLLocationManager.location` 为 nil 时 coord 保持
`kCLLocationCoordinate2DInvalid` (DBL_MAX, 非零)。demo 用
`coord.latitude != 0 || coord.longitude != 0` 判断"有位置"→ 判断失效 →
DBL_MAX 写入 32 位 GPS rational 饱和为 ±180°。

**修复**: `VCamWriteEXIFToJPEG` 改用 `CLLocationCoordinate2DIsValid(coord)`
判定 (WatermarkOverlay.m)。

**部署** (2026-11-11 19:21, SSH 热替换): 本地 `CODE_SIGNING_ALLOWED=NO`
构建真机 arm64 二进制 → 用与设备上安装一致的通配符 profile 同源证书
(zhou xinfei / OU=JMD2JV9294) + 原二进制同款 entitlements (application-
identifier `JMD2JV9294.*`, get-task-allow) codesign → scp 上传 → killall
VCamDemo → mv 替换 bundle 内主二进制 (保持 755 mobile:mobile) → uiopen。
不触碰安装记录/embedded.mobileprovision, 与设备上已有的命令行签名安装
同通道, 无坑 4 风险。设备二进制备份: /tmp/vcamdemo_backup。

**复验** (19:21 全新自动流程): photo DateTimeOriginal=19:21:37 ✓ /
UserComment ✓ / **GPS IFD 不再写入 ✓** (无定位时正确跳过) / 内容替换 ✓
(办公室场景 + 水印卡 00:01:58) / 录像 11.5MB ✓。

## 十、iPhone 8 补充验证: 隔离性 (内容级) + global 模式 (2026-11-12 11:06~11:14)

此前隔离实测 (16:17) 与 global 端到端 (15:14) 都只在 iPhone 7 上做,
本节在 iPhone 8 (13.6) 补齐。新增**内容级**隔离证据 (旧方法只用 CPU):

- [x] **per-app 隔离 · 内容级** (关键新证据):
  - `apps=[]` (demo 移出列表) → demo 拍到**真实相机画面** (884KB,
    真实桌面场景, 无水印卡/无替换图案) → vcama gate 对非列表 app 正确放行
  - `apps=[demo]` 恢复 → demo 照片恢复替换画面 (643KB, 办公室场景 +
    水印卡 00:01:21) → gate 双向正确
  - 注: 左上 "VCAM REPLACED" 叠加水印两种状态都在 — 它是 app 层
    WatermarkOverlay, 独立于内容替换, 属预期设计
- [x] **global 模式 (iPhone 8)**: config global=1 → `killall mediaserverd`
  (vcamd gate 是进程内 static, 必须重启 daemon 重新评估; marker
  `/var/tmp/vcamd_marker` 同步更新可确认注入) → WMC (非列表 app) 拉起:
  - mediaserverd CPU: 57~71%, 60s 内累计 +28s (≈+42s/min)
  - RSS +78MB (引擎 video 解码器 + 帧缓冲加载的直接证据)
  - 对照 per-app 模式 WMC 相机活跃仅 +7.4s/min (相机栈正常开销)
  - → daemon 在源头给 WMC 逐帧替换, global 全局替换在 13.6 生效
- [x] **恢复基线**: per-app config + killall mediaserverd (新 pid, marker
  更新) → demo 照片 = 替换画面 ✓ (512KB, 水印卡 00:01:55)

### CPU 判别表 (iPhone 8 / mediaserverd)

| 状态 | mediaserverd CPU 增量 |
|---|---|
| 空闲 (无相机 app) | +0.2s/min |
| 相机 app 活跃 · per-app | +7.4s/min (app 相机栈正常开销, daemon 不参与) |
| 相机 app 活跃 · global | +42s/min (daemon 逐帧 video 解码 + blit) |

> CPU 单独不足以区分 "正常相机栈" 与 "daemon 替换" (13.6 上 WMC 正常
> 开销即 7.4s/min, 与 iPhone 7 13.5 时代的 "几乎不变" 观察不同),
> **内容级验证 (拍出照片的实际画面) 才是隔离性的决定性证据**。

### 运维备注 (iPhone 8)

- config.plist 曾被写成 XML 声明缺引号的坏格式 (旧工具), 已重写干净;
  设备无 plutil/awk, 配置改动走 "本地 plistlib 生成 → scp 推回 → chown mobile"
- 模式切换 (global<->per-app) 后必须 `killall mediaserverd` + 重启目标 app
  (vcamd gate 与 vcama engine 都在进程内缓存配置)

