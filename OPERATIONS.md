# NanoClaw 运维指南

## 服务管理命令

### 查看状态
```bash
systemctl --user status nanoclaw
```

### 启动服务
```bash
systemctl --user start nanoclaw
```

### 停止服务
```bash
systemctl --user stop nanoclaw
```

### 重启服务
```bash
systemctl --user restart nanoclaw
```

### 查看实时日志
```bash
tail -f logs/nanoclaw.log
```

### 查看错误日志
```bash
tail -f logs/nanoclaw.error.log
```

### 查看 systemd 日志
```bash
journalctl --user -u nanoclaw -f
```

## 开发调试

### 修改代码后重新编译
```bash
npm run build
systemctl --user restart nanoclaw
```

### 运行开发模式（不通过 systemd）
```bash
# 先停止服务
systemctl --user stop nanoclaw

# 手动运行（可实时看到日志）
nvm use 22
npm run dev
# 或直接运行
node dist/index.js
```

## WSL 重启后

NanoClaw 会在 WSL 重启后**自动启动**，因为：
1. systemd 用户服务已启用（enabled）
2. 使用绝对路径调用 Node.js，不依赖 nvm 环境变量
3. `Restart=always` 配置会在崩溃时自动重启

如果 WSL 重启后没有自动启动：
```bash
# 手动启动
systemctl --user start nanoclaw

# 检查是否启用
systemctl --user is-enabled nanoclaw
# 如果显示 disabled，启用它：
systemctl --user enable nanoclaw
```

## Discord 配置

### Bot Token 位置
- 配置文件：`.env`
- 容器环境：`data/env/env`（与 .env 同步）

### 修改 Token 后
```bash
# 1. 编辑 .env
vim .env

# 2. 同步到容器环境
cp .env data/env/env

# 3. 重启服务
systemctl --user restart nanoclaw
```

### 注册新频道
```bash
npx tsx setup/index.ts --step register -- \
  --jid "dc:CHANNEL_ID" \
  --name "频道名称" \
  --trigger "@Andy" \
  --folder "main" \
  --no-trigger-required
```

## Docker 相关

### Docker 使用 sudo
NanoClaw 配置为使用 `sudo docker` 运行容器，因为用户组权限未完全生效。

### 查看运行中的容器
```bash
sudo docker ps
```

### 停止所有 NanoClaw 容器
```bash
sudo docker ps --filter name=nanoclaw- --format "{{.Names}}" | xargs -I {} sudo docker stop {}
```

### 重新构建容器镜像
```bash
sudo ./container/build.sh
```

## 故障排查

### 服务无法启动
```bash
# 1. 检查错误日志
tail -50 logs/nanoclaw.error.log

# 2. 检查 systemd 日志
journalctl --user -u nanoclaw -n 50

# 3. 手动运行查看详细错误
systemctl --user stop nanoclaw
node dist/index.js
```

### Discord Bot 无响应
```bash
# 1. 确认服务运行
systemctl --user status nanoclaw

# 2. 检查 Discord Token 是否配置
grep DISCORD_BOT_TOKEN .env

# 3. 查看日志中的错误
tail -100 logs/nanoclaw.log | grep -i error
```

### 容器运行失败
```bash
# 1. 确认 Docker 运行
sudo docker info

# 2. 检查容器镜像
sudo docker images | grep nanoclaw-agent

# 3. 测试容器
echo '{"prompt":"test","groupFolder":"test","chatJid":"test@g.us","isMain":false}' | sudo docker run -i nanoclaw-agent:latest
```

## 更新 NanoClaw

### 更新代码（保留自定义配置）
```bash
# 使用 /update 技能
/update
```

### 手动更新
```bash
# 1. 拉取最新代码
git pull origin main

# 2. 重新安装依赖
npm install

# 3. 重新编译
npm run build

# 4. 重启服务
systemctl --user restart nanoclaw
```

## 常用路径

| 项目 | 路径 |
|------|------|
| 项目根目录 | `/home/.ws/.in_wsl/ws/nanoclaw` |
| 配置文件 | `.env` |
| 日志文件 | `logs/nanoclaw.log` |
| 错误日志 | `logs/nanoclaw.error.log` |
| 数据库 | `store/messages.db` |
| 组配置 | `groups/*/CLAUDE.md` |
| Discord 频道数据 | `groups/main/` |
| systemd 服务 | `~/.config/systemd/user/nanoclaw.service` |

## 快捷命令别名（可选）

在 `~/.bashrc` 或 `~/.zshrc` 中添加：

```bash
# NanoClaw 快捷命令
alias ncstatus='systemctl --user status nanoclaw'
alias ncstart='systemctl --user start nanoclaw'
alias ncstop='systemctl --user stop nanoclaw'
alias ncrestart='systemctl --user restart nanoclaw'
alias nclog='tail -f /home/.ws/.in_wsl/ws/nanoclaw/logs/nanoclaw.log'
alias ncerror='tail -f /home/.ws/.in_wsl/ws/nanoclaw/logs/nanoclaw.error.log'
```

然后执行 `source ~/.bashrc` 生效。
