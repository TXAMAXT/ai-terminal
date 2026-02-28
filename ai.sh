#!/bin/bash

MODEL="qwen2.5:7b"

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
