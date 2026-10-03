# 蜂享 BeeShare 节点 · 发布镜像

这里只存放蜂享 BeeShare 节点程序（beeshare-node）的安装包和安装脚本，方便快速下载。网站：https://beeshare.cc

当前版本：0.1.0

## 安装

从 Gitee 安装（macOS / Linux）：

```bash
curl -fsSL https://gitee.com/muhouxiaoou/beeshare-node/raw/main/install.sh | sh
```

从 Gitee 安装（Windows PowerShell）：

```powershell
irm https://gitee.com/muhouxiaoou/beeshare-node/raw/main/install.ps1 | iex
```

从官网安装：

```bash
curl -fsSL https://beeshare.cc/install.sh | sh
```

安装后到网站「节点 → 添加节点」生成绑定码，运行 `beeshare-node bind <绑定码>`。

## 安全

- 安装脚本会核对安装包的 SHA-256，和清单 `manifest.json` 不一致就放弃安装。
- 装好之后的每一次更新，节点都会用程序内置的发布公钥验证清单签名（`manifest.json.sig`），镜像上的文件被换掉也装不上。
