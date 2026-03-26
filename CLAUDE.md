# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

本地 AI 终端助手，基于 Ollama + 千问模型，支持自然语言生成 Linux 命令，并具有技能记忆系统（语义向量检索）。

## 架构

```
用户输入 → ai.sh (Bash) → skill_manager.py (Python)
                              ↓
                    Ollama HTTP API (localhost:11434)
                              ↓
                    FAISS 向量检索 + JSON 存储
```

**核心文件**：
- `ai.sh` - 主入口脚本，处理用户交互流程
- `skill_manager.py` - 技能管理核心，包含向量检索和持久化
- `skills.json` - 技能存储文件
- `config.json` - 模型配置（chat_model, embed_model）

## 常用命令

```bash
# 运行 AI 终端
./ai.sh <需求描述>

# 技能管理（快捷命令）
./ai.sh skill                        # 列出所有技能
./ai.sh delete <命令|触发语|ID>      # 删除匹配的技能

# 删除示例
./ai.sh delete ls -la                # 按命令删除
./ai.sh delete 帮我执行top命令       # 按触发语删除（语义匹配）
./ai.sh delete a1b2c3                # 按 ID 删除

# 技能管理（底层命令）
python3 skill_manager.py list [--limit N]
python3 skill_manager.py delete <query>
python3 skill_manager.py search "查询内容" --threshold 0.85 --topk 5
python3 skill_manager.py add "触发语" "命令" --effect "描述"
python3 skill_manager.py check "触发语" "命令"
python3 skill_manager.py dedupe
python3 skill_manager.py reembed --force
```

## 关键阈值

- `SEARCH_THRESHOLD_DEFAULT = 0.85` - 技能匹配阈值
- `DEDUP_BY_TRIGGER_THRESHOLD = 0.92` - 触发语去重阈值

## 已修复的 Bug

### 技能自动保存问题（已修复）

**原因**：原逻辑在用户确认前就调用了 `add_skill()` 保存技能。

**修复**：新增 `check_skill_status()` 函数（预览模式），先检查状态，用户确认后才调用 `add_skill()` 保存。