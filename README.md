# Groove（macOS 本地音乐播放器）

一个原生 SwiftUI 写的 Mac 本地音乐播放器，界面是暖色调的「Porthole」风格（深色 / 浅色两套）。需要 macOS 14 或更新版本。

A native SwiftUI local music player for macOS 14+, with lyrics, cover art fetching and a floating mini ball.

## 下载安装

到 [Releases](../../releases) 下载 `Groove-v1.2-macOS.dmg`，双击打开，把 `Groove` 拖到旁边的「应用程序」文件夹就装好了。

App 没有经过 Apple 公证（需要付费开发者账号），所以第一次打开时系统会提示「Apple 无法验证"Groove"是否包含恶意软件」。这样放行（只需要一次）：

1. 在提示框里点「完成」（不要点「移到废纸篓」）。
2. 打开「系统设置 → 隐私与安全性」，拉到最下面，找到「已阻止"Groove"以保护 Mac」，点「仍要打开」，输入开机密码。
3. 再打开一次 Groove，在弹出的提示里点「打开」。

如果还是打不开，或者提示「已损坏」，在「终端」里运行下面这行，然后再打开：

```bash
xattr -cr /Applications/Groove.app
```

支持 Apple 芯片和 Intel 芯片的 Mac，需要 macOS 14 或更新版本。

## 自己编译

需要先装好 Xcode（App Store 免费下载），装完打开一次让它装好组件，然后在终端里运行：

```bash
./build-app.sh
```

它会编译、打包，并安装到 `/Applications/Groove.app`（`build/Groove.app` 里也留一份）；旧版本正在运行的话会先退出，装好后再打开。也可以双击 `Package.swift` 用 Xcode 打开调试。之后运行 `./make-dmg.sh` 可以做成安装用的 dmg（放在 `dist/`）。

## 功能

- **歌曲库**：添加一个或多个音乐文件夹，自动扫描（包括子文件夹），每天安静地重新扫描一次。支持 MP3、FLAC、M4A/ALAC、AAC、WAV、AIFF。
- **分类**：歌曲、歌单（我的收藏 + 自建歌单）、专辑、歌手、文件夹。
- **拼音 / 英文首字母排序**：中文按拼音、英文按字母，统一按 A–Z 分组，右侧字母索引可以拖动；也能按歌手、专辑、时长、修改时间排序。
- **搜索**：歌名、歌手、专辑，也支持拼音（`qingtian`）和拼音首字母（`qt`）。
- **音质标签**：SQ（无损，16bit）和 HR（高解析，24bit 或高于 48kHz）。
- **封面和歌词**：优先用文件内嵌的、同文件夹的 `cover.jpg` / 同名 `.lrc`（支持 GBK 编码），都没有才联网获取（封面：iTunes、酷狗、网易云；歌词：只用公开的 LRCLIB）。设置里的「自定义歌词源…」可以自己添加歌词网址（默认没有，添加的来源由你自己负责）。也可以手动「联网搜索封面和歌词」挑一个；App 下载的可以一键删除，不动音乐文件。
- **正在播放 / 歌词页**：旋转的圆形封面 + 封面色模糊背景，歌词同步滚动、点某一行跳过去，可以微调歌词快慢。
- **悬浮球**（⇧⌘M）：主窗口收起，屏幕上留一个转动的封面小球，外圈是进度；鼠标移上去有上一首 / 播放暂停 / 下一首；拖到屏幕边缘自动贴边藏起一半；旁边可以显示当前一句歌词；大小可以在设置里调。
- **其它**：底部迷你播放条、播放队列、睡眠定时、媒体键和控制中心、空格播放/暂停、⌘← / ⌘→ 切歌、双击顶栏铺满屏幕。

## 数据存放位置

`~/Library/Application Support/LocalMusic/`：音乐库索引、歌单收藏、联网下载的封面和歌词缓存。删掉这个文件夹就是重置。

## 代码结构

```
Sources/LocalMusic/
  LocalMusicApp.swift        程序入口、菜单、快捷键
  Models/Track.swift         歌曲、歌单数据结构
  Library/                   扫描音乐库、读取标签、拼音排序、FLAC/LRC 解析
  Player/PlayerController    播放、队列、随机循环、睡眠定时、媒体键
  Online/                    封面 / 歌词的加载顺序和联网获取
  Views/                     界面
```

## 使用许可

仅供个人使用，禁止商用。

For personal use only. Commercial use is prohibited.
