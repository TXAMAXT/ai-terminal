# AI 终端助手

一个完全本地运行的 AI 终端助手，基于 Ollama + 千问模型，支持自然语言生成 Linux 命令，并具备技能记忆系统。

---

## 功能特性

- **自然语言生成命令**：用中文描述需求，自动生成 Linux 命令
- **技能记忆系统**：保存常用命令，语义匹配自动调用
- **安全防护**：危险命令检测，二次确认机制
- **交互命令支持**：支持 top / vim / less 等交互式命令
- **执行失败分析**：自动分析失败原因并给出建议
- **完全本地运行**：无需联网

---

## 环境要求

- Linux（推荐 Ubuntu 22.04+）
- Python 3.10+
- Ollama

---

## 安装

### 1. 安装 Ollama

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

### 2. 下载模型

```bash
# 对话模型
ollama pull qwen2.5:7b

# 向量模型
ollama pull nomic-embed-text
```

### 3. 安装 Python 依赖

```bash
pip install faiss-cpu numpy requests
```

### 4. 配置

```bash
mkdir -p ~/ai-terminal
cd ~/ai-terminal

# 下载文件
# ai.sh, skill_manager.py, skills.json, config.json

chmod +x ai.sh
```

### 5. 添加别名

```bash
echo 'alias ai="~/ai-terminal/ai.sh"' >> ~/.bashrc
source ~/.bashrc
```

---

## 使用

### 基本用法

```bash
ai 列出当前目录文件
ai 查看系统进程
ai 查看磁盘空间
```

### 技能管理

```bash
# 列出所有技能
ai skill

# 删除技能（支持命令、触发语或 ID）
ai delete ls -la
ai delete 帮我执行top命令
ai delete a1b2c3

# 注意：包含特殊字符（; | & > <）的命令需要用引号包裹
ai delete "cat /etc/resolv.conf; ip a"
```

删除时会显示匹配结果，让用户确认后执行：

```
🔍 找到以下匹配的技能：

[1] (匹配度=1.0000) ls

请选择要删除的技能编号（回车取消）：
```

### 执行流程

1. **技能匹配**：语义搜索已有技能，展示 TopK 候选
2. **命令生成**：若无匹配，调用 LLM 生成命令
3. **安全检查**：检测危险命令（如 `rm -rf /`）
4. **用户确认**：执行前确认，危险命令二次确认
5. **技能保存**：成功后可选择保存为技能

### 安全特性

危险命令检测黑名单：

- `rm -rf /`、`rm -rf /*`
- `mkfs`、`dd if=`
- `curl | bash`、`wget | bash`
- `chmod -R 777 /`

检测到危险命令时：

```
⚠️  警告：检测到危险命令！
命令：rm -rf /tmp
是否执行？(y/n): y
⚠️  这是危险命令，确定要执行吗？(yes/no): yes
```

---

## 技能系统

### 技能结构

```json
{
  "id": "a1b2c3",
  "triggers": ["列出目录文件", "查看当前目录"],
  "command": "ls -la",
  "effect": "列出当前目录下所有文件",
  "embedding_model": "nomic-embed-text",
  "embedding": [...]
}
```

### 特性

- **随机 ID**：6 位字母数字，永不重复
- **语义匹配**：基于向量相似度检索
- **智能合并**：相同命令自动合并触发语
- **差异提示**：触发语相似但命令不同时提示用户选择

---

## 配置

### config.json

```json
{
  "chat_model": "qwen2.5:7b",
  "embed_model": "nomic-embed-text"
}
```

### 切换模型

修改 `embed_model` 后，系统自动重新计算所有技能的向量。

---

## 架构

```
用户输入 → ai.sh → skill_manager.py → Ollama API → FAISS 检索 → 执行命令
```

---

## 常见问题

### Q: 如何查看已有技能？

```bash
ai skill
```

### Q: 如何删除技能？

```bash
ai delete <命令|触发语|ID>

# 包含特殊字符的命令需要引号
ai delete "cat file; ip a"
```

### Q: 如何切换模型？

修改 `config.json` 中的 `chat_model` 或 `embed_model`。

### Q: 危险命令如何处理？

系统会检测并警告，需要输入 `yes` 确认才会执行。