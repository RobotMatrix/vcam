# VCam — iOS 全局/按 app 摄像头替换

越狱设备上的摄像头内容替换工具链,用于安全测试验证(相机流被替换时的检测与取证场景)。

## 结构

```
vcam/          tweak 部署件与文档
 ├─ Tweak/     vcamd.dylib (mediaserverd 全局替换) + vcama.dylib (app 内替换) + VCamEngine
 ├─ README_VCAM.md   架构 / 部署 / 踩坑记录 (坑1-10) / 端到端验证日志
 └─ crashlogs/       unc0ver 重越狱内核 panic 等崩溃证据
VCamDemo/      单帧管道相机测试 app (预览/拍照/录像同源, 水印叠加 + EXIF 注入, 45s 自动测试流)
```

详细文档: **[vcam/README_VCAM.md](vcam/README_VCAM.md)**

## 生效逻辑

```
enabled=0                        → 不替换
enabled=1, global=1              → 全局替换 (mediaserverd hook, 所有 app)
enabled=1, global=0, apps 含 bid → 仅列表内 app 替换 (vcama)
```
