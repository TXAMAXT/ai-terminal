# 🧠 AI 终端助手完整安装与使用教程

---

# 一、项目简介

本项目是一个完全本地运行的 AI 终端助手，基于：

- Ollama
- 本地大模型（如 qwen2.5）
- 向量检索（FAISS）
- Bash Shell

它不仅可以：

- 自然语言生成 Linux 命令
- 执行前确认
- 支持交互式命令（top / vim / less 等）
- 执行失败自动分析

还具备：

- 技能（Skill）记忆系统
- 语义向量匹配
- TopK 候选技能选择
- 自动去重
- embedding 模型自动升级
- 失败自动回滚保护

---

# 二、环境要求

- Linux（推荐 Ubuntu 22.04+）
- Bash
- Python 3.10+
- 内存 ≥ 8GB（推荐 16GB）
- 已安装 Ollama

---

# 三、安装步骤

## 1️⃣ 安装 Ollama

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

验证：

```bash
ollama --version
```

---

## 2️⃣ 下载模型

### 下载对话模型

```bash
ollama pull qwen2.5:7b
```

### 下载 embedding 模型

```bash
ollama pull nomic-embed-text
```

---

## 3️⃣ 安装 Python 依赖

```bash
pip install faiss-cpu numpy requests
```

---

## 4️⃣ 创建项目目录

```bash
mkdir -p ~/ai-terminal
cd ~/ai-terminal
```

将以下文件放入该目录：

- ai.sh
- skill_manager.py
- skills.json
- config.json

---

## 5️⃣ config.json 示例

```json
{
  "chat_model": "qwen2.5:7b",
  "embed_model": "nomic-embed-text"
}
```

---

## 6️⃣ 添加执行权限

```bash
chmod +x ~/ai-terminal/ai.sh
```

---

## 7️⃣ 添加命令别名

编辑 ~/.bashrc：

```bash
alias ai="~/ai-terminal/ai.sh"
```

刷新配置：

```bash
source ~/.bashrc
```

---

# 四、使用教程

---

## 1️⃣ 基本使用

```bash
ai 列出当前目录文件
```

系统流程：

1. 语义匹配已有技能
2. 若命中 → 展示 TopK 候选
3. 选择执行
4. 若未命中 → 调用模型生成命令
5. 执行前确认

---

## 2️⃣ TopK 候选示例

```bash
ai 查看系统进程
```

输出示例：

```
🧠 命中候选技能：

[1] top
[2] ps aux
```

选择编号即可执行。

---

## 3️⃣ 交互命令支持

```bash
ai 实时查看CPU占用
```

将进入：

```
top
```

退出按 `q`

---

## 4️⃣ 出错自动分析

```bash
ai 删除不存在的文件
```

若命令失败：

- 自动捕获退出码
- 调用模型分析原因
- 中文解释解决方案

---

## 5️⃣ 技能自动保存

执行成功后：

```
是否保存为技能？(y/n)
```

保存后：

- 触发语加入向量库
- 下次语义相近时自动命中

---

# 五、技能系统说明

每个技能包含：

```json
{
  "id": 1,
  "triggers": ["列出目录文件"],
  "command": "ls",
  "effect": "显示当前目录内容",
  "embedding_model": "nomic-embed-text",
  "embedding": [...]
}
```

特性：

- 同 command 自动合并触发语
- 语义相似度自动匹配
- 自动去重
- TopK 候选排序

---

# 六、Embedding 自动升级机制

当你修改：

```json
"embed_model": "新的模型"
```

系统会：

1. 自动检测模型变化
2. 重新计算全部技能向量
3. 显示重算进度
4. 若失败 → 自动回滚 skills.json

无需手动操作。

---

# 七、系统架构

```
用户输入
   ↓
ai.sh
   ↓
skill_manager.py
   ↓
Ollama HTTP API
   ↓
Embedding 模型
   ↓
FAISS 检索
   ↓
执行 Shell 命令
```

---

# 八、常见问题

## Q1：embedding 地址是否固定？

默认：

```
http://localhost:11434/api/embeddings
```

除非你修改 Ollama 端口，否则无需更改。

---

## Q2：如何切换模型？

修改 config.json：

```json
"chat_model": "新模型"
```

或：

```json
"embed_model": "新embedding模型"
```

系统自动适配。

---
