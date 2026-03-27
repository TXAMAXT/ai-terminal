# AI Terminal Assistant

A fully local AI terminal assistant powered by Ollama + Qwen model. Generate Linux commands from natural language with a skill memory system.

---

## Features

- **Natural Language Command Generation**: Describe your needs in Chinese or English, automatically generate Linux commands
- **Skill Memory System**: Save frequently used commands with semantic matching for automatic invocation
- **Security Protection**: Dangerous command detection with double confirmation mechanism
- **Interactive Command Support**: Supports interactive commands like `top`, `vim`, `less`, etc.
- **Failure Analysis**: Automatically analyzes command failures and provides suggestions
- **Multi-language Support**: Switch between Chinese and English with `ai chinese` / `ai english`
- **Fully Local**: No internet connection required

---

## Requirements

- Linux (Ubuntu 22.04+ recommended)
- Python 3.10+
- Ollama

---

## Installation

### 1. Install Ollama

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

### 2. Download Models

```bash
# Chat model
ollama pull qwen2.5:7b

# Embedding model
ollama pull nomic-embed-text
```

### 3. Install Python Dependencies

```bash
pip install faiss-cpu numpy requests
```

### 4. Setup

```bash
mkdir -p ~/ai-terminal
cd ~/ai-terminal

# Download files
# ai.sh, skill_manager.py, skills.json, config.json

chmod +x ai.sh
```

### 5. Add Alias

```bash
echo 'alias ai="~/ai-terminal/ai.sh"' >> ~/.bashrc
source ~/.bashrc
```

---

## Usage

### Basic Usage

```bash
# Chinese
ai 列出当前目录文件
ai 查看系统进程
ai 查看磁盘空间

# English
ai list files in current directory
ai show system processes
ai check disk space
```

### Language Switching

```bash
# Switch to Chinese
ai chinese

# Switch to English
ai english
```

### Skill Management

```bash
# List all skills
ai skill

# Delete skills (supports command, trigger phrase, or ID)
ai delete ls -la
ai delete 帮我执行top命令
ai delete a1b2c3

# Note: Commands with special characters (; | & > <) need quotes
ai delete "cat /etc/resolv.conf; ip a"
```

Delete confirmation shows matching results:

```
Found matching skills:

[1] (Score=1.0000) ls

Select skill number to delete (Enter to cancel):
```

### Execution Flow

1. **Skill Matching**: Semantic search through existing skills, display TopK candidates
2. **Command Generation**: If no match, call LLM to generate command
3. **Security Check**: Detect dangerous commands (e.g., `rm -rf /`)
4. **User Confirmation**: Confirm before execution, double confirmation for dangerous commands
5. **Skill Saving**: Optionally save as skill after successful execution

### Security Features

Dangerous command blacklist:

- `rm -rf /`, `rm -rf /*`
- `mkfs`, `dd if=`
- `curl | bash`, `wget | bash`
- `chmod -R 777 /`

When a dangerous command is detected:

```
⚠️  WARNING: Dangerous command detected!
Command: rm -rf /tmp
Execute? (y/n): y
⚠️  This is a dangerous command. Confirm? (yes/no): yes
```

---

## Skill System

### Skill Structure

```json
{
  "id": "a1b2c3",
  "triggers": ["列出目录文件", "查看当前目录"],
  "command": "ls -la",
  "effect": "List all files in current directory",
  "embedding_model": "nomic-embed-text",
  "embedding": [...]
}
```

### Features

- **Random ID**: 6-character alphanumeric, never duplicated
- **Semantic Matching**: Vector similarity-based retrieval
- **Smart Merge**: Automatically merge trigger phrases for identical commands
- **Difference Prompt**: Prompt user when trigger is similar but command differs

---

## Configuration

### config.json

```json
{
  "chat_model": "qwen2.5:7b",
  "embed_model": "nomic-embed-text",
  "language": "chinese"
}
```

### Switching Models

After modifying `embed_model`, the system automatically re-calculates embeddings for all skills.

---

## Architecture

```
User Input → ai.sh → skill_manager.py → Ollama API → FAISS Search → Execute Command
```

---

## FAQ

### Q: How to view existing skills?

```bash
ai skill
```

### Q: How to delete a skill?

```bash
ai delete <command|trigger|ID>

# Commands with special characters need quotes
ai delete "cat file; ip a"
```

### Q: How to switch models?

Modify `chat_model` or `embed_model` in `config.json`.

### Q: How are dangerous commands handled?

The system detects and warns about dangerous commands. Type `yes` to confirm execution.

### Q: How to switch language?

```bash
ai chinese   # Switch to Chinese
ai english   # Switch to English
```

---

## License

MIT License