# Eric-Terminal 的 dotfiles

这是 Eric-Terminal 的 macOS 个人配置仓库，只纳管最核心的 shell 和 Git 配置。

## 已纳管

- `.zshrc`
- `.zprofile`
- `.p10k.zsh`
- `.gitconfig`

## 本机私有文件

以下文件只放在本机，不提交仓库：

- `~/.zshrc.local`：API Key、Token、私有代理、账号 ID、本机项目 alias
- `~/.gitconfig.local`：本机网络、私有账号、临时覆盖项

它们由正式配置读取，但不会进入 Git。

## 使用方式

在仓库目录执行：

```sh
ln -sf "$PWD/.zshrc" "$HOME/.zshrc"
ln -sf "$PWD/.zprofile" "$HOME/.zprofile"
ln -sf "$PWD/.p10k.zsh" "$HOME/.p10k.zsh"
ln -sf "$PWD/.gitconfig" "$HOME/.gitconfig"
```

执行前建议先备份原文件。
