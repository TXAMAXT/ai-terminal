# 🧠 AI 终端助手完整教程

## 一、项目简介

本工具是一个基于以下组件构建的本地离线 AI 命令行助手：

- **Ollama**
- 本地大模型（如 qwen / llama3 等）
- **Linux Shell**

### 功能

1. 自然语言 → 自动生成 Linux 命令  
2. 执行前确认  
3. 支持交互式命令（`top` / `vim` 等）  
4. 出错自动分析原因  
5. 全程本地运行，无需联网

---

## 二、环境要求

- 操作系统：Linux（Ubuntu 22.04+）  
- Shell：Bash  
- 已安装 Ollama  
- 内存：至少 8 GB（推荐 16 GB）

---

## 三、安装步骤

1. **安装 Ollama**  
   ```bash
   curl -fsSL https://ollama.com/install.sh | sh
   ```
   验证：
   ```bash
   ollama --version
   ```

2. **下载模型**  
   - 推荐轻量模型：`ollama pull qwen2.5:3b`  
   - 或更强模型：`ollama pull qwen2.5:7b`

3. **创建脚本目录**
  ```bash
  mkdir -p ~/ai-terminal
  ```
4. **创建 AI 命令脚本**  
```bash
vim ~/ai-terminal/ai.sh
```
   编辑并保存为 `~/ai-terminal/ai.sh`：

```bash
#!/bin/bash

MODEL="qwen2.5:7b" #个人pull的模型名称

PROMPT="你是一名资深 Linux + 开发工程师助手。

规则：
1. 全部用中文回答
2. 命令、参数、专有名词保持英文
3. 输出格式必须严格如下：

功能说明：
<中文说明>

命令：
<只输出一条shell命令>

不要输出代码块符号
不要解释格式规则

用户需求：
$*
"

# 调用 Ollama
RESPONSE=$(echo "$PROMPT" | ollama run $MODEL)

echo ""
echo "$RESPONSE"
echo ""

# 提取命令（取“命令：”后第一行）
CMD=$(echo "$RESPONSE" | awk '/命令：/{getline; print}')

if [ -z "$CMD" ]; then
    echo "未识别到命令"
    exit 1
fi

read -p "是否执行？(y/n): " CONFIRM

if [ "$CONFIRM" = "y" ]; then
    echo ""

    # 直接执行命令（保持交互能力）
    eval "$CMD"
    STATUS=$?

    # 如果出错才分析
    if [ $STATUS -ne 0 ]; then
        echo ""
        echo "命令执行失败，正在分析错误..."

        ERROR_PROMPT="用中文分析下面命令执行失败的原因，并给出解决建议。
命令：
$CMD

退出码：
$STATUS

请给出可能原因和解决方法。"

        echo "$ERROR_PROMPT" | ollama run $MODEL
    fi
fi

```

4. **添加执行权限**
   ```bash
   chmod +x ~/ai-terminal/ai.sh
   ```

5. **将脚本加入 `$PATH`**  
   编辑 `~/.bashrc`，追加:
   ```bash
   alias ai="~/ai-terminal/ai.sh"
   ```

   然后刷新配置：
   ```bash
   source ~/.bashrc
   ```

现在即可在终端中直接使用，例如：

```bash
ai 列出当前目录文件
```

---

## 四、使用教程

- **基本使用**
  ```bash
  ai 查看当前目录文件
  ```
  输出举例：
  ```
  AI 生成的命令：
  ls -al
  是否执行该命令？(y/n):
  ```

- **交互命令支持**  
  ```bash
  ai 查看系统实时进程
  ```
  会生成 `top` 并直接进入交互界面 ✔

- **出错自动分析**  
  如执行 `ai 删除一个不存在的文件` 失败，脚本将显示错误并自动用中文解释原因、给出解决方案。

---

## 五、工作原理

```text
用户输入
   ↓
生成 Prompt
   ↓
Ollama 本地模型
   ↓
生成 Linux 命令
   ↓
用户确认
   ↓
执行命令
   ↓
如果失败 → 自动分析
```
