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

## Zsh 补全和交互工具

保留 Oh My Zsh、Powerlevel10k、`zsh-autosuggestions`、`zsh-syntax-highlighting` 和 zoxide。
交互配置位于 `shell/interactive-tools.zsh`，由 `.zshrc` 加载。

| 操作 | 效果 |
| --- | --- |
| 输入命令后按 `→` | 接受灰色的历史命令建议 |
| 按 `Tab` | 用 fzf-tab 搜索补全候选，查看补全定义提供的参数说明 |
| 补全菜单中按 `<` / `>` | 切换候选分组；按 `Esc` 取消，按 `Enter` 填入候选 |
| `Ctrl+R` | 模糊搜索历史命令，选中后填回命令行 |
| `Ctrl+T` | 搜索文件或目录，预览内容并将路径填入命令行 |
| `Alt+C` | 搜索当前目录下的子目录并进入 |
| `Alt+H` | 查看当前命令的手册，按 `q` 返回正在编辑的命令 |
| `tldr tar` / `tldr git commit` | 查看常用命令示例；用 `tldr --update` 更新本地文档 |
| `z 目录关键词` / `zi 关键词` | 跳转到常用目录 / 交互选择常用目录 |
| `extract 文件.zip` | 根据格式解压，支持 zip、tar.gz、7z 等 |
| `copypath [文件或目录]` | 复制绝对路径；省略参数时复制当前目录路径 |
| `copyfile 文件` | 复制文本文件内容 |

macOS 终端若没有把 Option 配置为 Meta，可先按 `Esc` 再按 `c` / `h`。
查看别名的帮助时，若提示按键继续，按空格即可打开实际命令的手册。
参数说明取决于对应命令的补全定义；完整说明用 `Alt+H` 查看，简短示例用 `tldr` 查看。
`fzf-tab` 在按 Tab 时显示菜单；`zsh-autosuggestions` 在输入时显示历史建议。

### 新机器安装依赖

除原有主题和插件外，需要 `fzf`、`bat`、`tldr`、`zoxide`，以及两个外部插件：

```sh
brew install fzf bat tldr zoxide
gh repo clone Aloxaf/fzf-tab "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/fzf-tab" -- --depth=1
gh repo clone zsh-users/zsh-completions "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-completions" -- --depth=1
tldr --update
```

`colored-man-pages`、`extract`、`copypath`、`copyfile` 和 fzf 的集成脚本由 Oh My Zsh 自带。
`zsh-completions/src` 必须在 Oh My Zsh 运行 `compinit` 前加入 `fpath`。
加载顺序保持 `fzf` → `fzf-tab` → `zsh-autosuggestions` → `zsh-syntax-highlighting`。

修改后新开终端，或运行 `exec zsh`。外部插件独立安装，不随 dotfiles 的 Git 提交保存；
可分别进入插件目录运行 `gh repo sync` 更新。
