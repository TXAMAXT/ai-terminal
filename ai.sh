#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

# ====================================
# 危险命令黑名单检测
# ====================================
is_dangerous_cmd() {
  local cmd="$1"
  local patterns=(
    "rm[[:space:]]+(-[rf]+|--no-preserve-root)[[:space:]]*/"
    "rm[[:space:]]+-rf[[:space:]]+/\*"
    "mkfs"
    "dd[[:space:]]+if="
    ":[[:space:]]*\(\)[[:space:]]*\{[[:space:]]*:[[:space:]]*\|[[:space:]]*:[[:space:]]*&[[:space:]]*\}"
    ">[[:space:]]*/dev/sd[a-z]"
    "chmod[[:space:]]+-R[[:space:]]+777[[:space:]]+/"
    "chown[[:space:]]+-R[[:space:]]+.+[[:space:]]+/"
    "shutdown"
    "reboot"
    "init[[:space:]]+[06]"
    "systemctl[[:space:]]+(stop|disable|mask)[[:space:]]+ssh"
    "iptables[[:space:]]+-F"
    "ufw[[:space:]]+disable"
    "curl.*\|[[:space:]]*bash"
    "wget.*\|[[:space:]]*bash"
  )

  for pattern in "${patterns[@]}"; do
    if echo "$cmd" | grep -qiE "$pattern"; then
      return 0
    fi
  done
  return 1
}

# ====================================
# 语言配置
# ====================================
# 读取语言设置
CURRENT_LANG="$(python3 -c "
import json, os
cfg = os.path.join('${SCRIPT_DIR}', 'config.json')
try:
    with open(cfg) as f:
        print(json.load(f).get('language', 'chinese'))
except: print('chinese')
" 2>/dev/null || echo 'chinese')"

# 读取 chat_model
MODEL="$(python3 -c "
import json, os
cfg = os.path.join('${SCRIPT_DIR}', 'config.json')
m = 'qwen2.5:7b'
try:
    with open(cfg) as f:
        m = json.load(f).get('chat_model', m)
except: pass
print(m)
")"

# 获取多语言文本
get_text() {
  local key="$1"
  case "$CURRENT_LANG" in
    english)
      case "$key" in
        "usage") echo "Usage: ai <your request>" ;;
        "skill_usage") echo "ai skill                    # List all skills" ;;
        "delete_usage") echo "ai delete <command|trigger|ID>   # Delete matching skill" ;;
        "not_found") echo "No matching skill found" ;;
        "found_skills") echo "Found matching skills:" ;;
        "select_delete") echo "Select skill number to delete (Enter to cancel): " ;;
        "select_execute") echo "Select skill number to execute (Enter to skip, 0 to skip): " ;;
        "cancelled") echo "Cancelled" ;;
        "invalid") echo "Invalid selection" ;;
        "dangerous") echo "WARNING: Dangerous command detected!" ;;
        "command_label") echo "Command:" ;;
        "confirm_execute") echo "Execute? (y/n): " ;;
        "confirm_danger") echo "This is a dangerous command. Confirm? (yes/no): " ;;
        "execute_label") echo "Executing:" ;;
        "not_recognized") echo "Command not recognized" ;;
        "execution_failed") echo "Command failed, analyzing..." ;;
        "save_skill") echo "Save as skill? (y/n): " ;;
        "skill_saved") echo "Skill saved" ;;
        "skill_merged") echo "Merged to existing skill" ;;
        "similar_trigger") echo "Similar trigger detected, but different command:" ;;
        "existing_cmd") echo "Existing command:" ;;
        "current_cmd") echo "Current command:" ;;
        "save_new") echo "Save as new skill? (y/n): " ;;
        "match_score") echo "Score=" ;;
        "description") echo "Description:" ;;
        "matching_skills") echo "Matching skills (Top $TOPK, threshold $THRESH):" ;;
        "delete_hint") echo "Note: Commands with special characters (; | & > <) need quotes:" ;;
        "delete_example") echo '  ai delete "cat file; ip a"' ;;
        "language_set") echo "Language switched to:" ;;
        "merged_no_change") echo "Trigger already exists for this command, no need to save" ;;
        "will_skip") echo "Trigger highly similar to existing skill, skipping" ;;
        "desc_prompt") echo "Describe the command in one English sentence (keep command in English, no code blocks):" ;;
        # 关键字
        "cmd_keyword") echo "Command:" ;;
      esac
      ;;
    *)  # chinese (默认)
      case "$key" in
        "usage") echo "用法：ai <你的需求>" ;;
        "skill_usage") echo "ai skill                    # 列出所有技能" ;;
        "delete_usage") echo "ai delete <命令|触发语|ID>   # 删除匹配的技能" ;;
        "not_found") echo "未找到匹配的技能" ;;
        "found_skills") echo "找到以下匹配的技能：" ;;
        "select_delete") echo "请选择要删除的技能编号（回车取消）： " ;;
        "select_execute") echo "请选择要执行的技能编号（回车跳过，输入 0 跳过）： " ;;
        "cancelled") echo "已取消" ;;
        "invalid") echo "无效的选择" ;;
        "dangerous") echo "⚠️  警告：检测到危险命令！" ;;
        "command_label") echo "命令：" ;;
        "confirm_execute") echo "是否执行？(y/n): " ;;
        "confirm_danger") echo "⚠️  这是危险命令，确定要执行吗？(yes/no): " ;;
        "execute_label") echo "▶ 执行：" ;;
        "not_recognized") echo "未识别到命令" ;;
        "execution_failed") echo "命令执行失败，正在分析..." ;;
        "save_skill") echo "是否保存为技能？(y/n): " ;;
        "skill_saved") echo "✅ 技能已保存" ;;
        "skill_merged") echo "✅ 已合并到已有技能" ;;
        "similar_trigger") echo "⚠ 检测到相似触发语，但命令不同：" ;;
        "existing_cmd") echo "  已有命令:" ;;
        "current_cmd") echo "  当前命令:" ;;
        "save_new") echo "是否保存为新技能？(y/n): " ;;
        "match_score") echo "匹配度=" ;;
        "description") echo "说明：" ;;
        "matching_skills") echo "🧠 命中候选技能（Top $TOPK，阈值 $THRESH）：" ;;
        "delete_hint") echo "⚠️  包含特殊字符（; | & > <）的命令请用引号包裹：" ;;
        "delete_example") echo '  ai delete "cat file; ip a"' ;;
        "language_set") echo "✅ 语言已切换为：" ;;
        "merged_no_change") echo "ℹ️ 触发语已存在于该命令的技能中，无需保存" ;;
        "will_skip") echo "⚠ 触发语与已有技能高度重复，跳过保存" ;;
        "desc_prompt") echo "用一句中文说明下面命令的作用（命令保持英文，不要加代码块）：" ;;
        # 关键字
        "cmd_keyword") echo "命令：" ;;
      esac
      ;;
  esac
}

# 构建 prompt
build_prompt() {
  local user_input="$1"
  case "$CURRENT_LANG" in
    english)
      cat <<EOF
You are a senior Linux developer assistant.

Follow these rules strictly:
1. Answer in English
2. Output only ONE final command (no multiple options)
3. Do NOT use code block symbols (\`\`\`)
4. Output format (Command: on its own line):

Function:
<description>

Command:
<one shell command>

User request:
$user_input
EOF
      ;;
    *)
      cat <<EOF
你是一名资深 Linux + 开发工程师助手。

必须严格遵守：
1. 全部用中文回答
2. 只能输出一条最终命令（不要给多个候选）
3. 不允许输出代码块符号（\`\`\`）
4. 输出格式必须严格如下（注意"命令："单独一行）：

功能说明：
<中文说明>

命令：
<只输出一条shell命令>

用户需求：
$user_input
EOF
      ;;
  esac
}

# 构建错误分析 prompt
build_error_prompt() {
  local cmd="$1"
  local status="$2"
  case "$CURRENT_LANG" in
    english)
      cat <<EOF
Analyze the command failure in English and provide solutions.
Command:
$cmd

Exit code:
$status
EOF
      ;;
    *)
      cat <<EOF
用中文分析下面命令执行失败的原因，并给出解决建议。
命令：
$cmd

退出码：
$status
EOF
      ;;
  esac
}

# 构建描述 prompt
build_desc_prompt() {
  local cmd="$1"
  case "$CURRENT_LANG" in
    english)
      echo "Describe the command in one English sentence (keep command in English, no code blocks): $cmd"
      ;;
    *)
      echo "用一句中文说明下面命令的作用（命令保持英文，不要加代码块）：$cmd"
      ;;
  esac
}

# ====================================
# 用户输入处理
# ====================================
USER_INPUT="${*:-}"
if [[ -z "$USER_INPUT" ]]; then
  echo "$(get_text 'usage')"
  echo "      $(get_text 'skill_usage')"
  echo "      $(get_text 'delete_usage')"
  echo "      ai chinese                # 切换中文"
  echo "      ai english                # Switch to English"
  exit 1
fi

# ====================================
# ① 内置命令处理
# ====================================
# 语言切换
if [[ "$USER_INPUT" == "chinese" || "$USER_INPUT" == "english" ]]; then
  python3 "$SCRIPT_DIR/skill_manager.py" set-language "$USER_INPUT"
  if [[ "$USER_INPUT" == "chinese" ]]; then
    echo "✅ 语言已切换为：chinese"
  else
    echo "✅ Language switched to: english"
  fi
  exit 0
fi

# 列出技能
if [[ "$USER_INPUT" == "skill" || "$USER_INPUT" == "skills" ]]; then
  python3 "$SCRIPT_DIR/skill_manager.py" list --lang "$CURRENT_LANG"
  exit 0
fi

# 删除技能
if [[ "$USER_INPUT" == delete* ]]; then
  DEL_QUERY="$(echo "$USER_INPUT" | sed 's/^delete[[:space:]]*//')"
  if [[ -z "$DEL_QUERY" ]]; then
    echo "$(get_text 'delete_usage')"
    echo "示例："
    echo "  ai delete ls -la"
    echo "  ai delete 帮我执行top命令"
    echo "  ai delete a1b2c3"
    echo ""
    echo "$(get_text 'delete_hint')"
    echo "$(get_text 'delete_example')"
    exit 1
  fi

  SEARCH_RESULT="$(python3 "$SCRIPT_DIR/skill_manager.py" search-delete -- "$DEL_QUERY" 2>/dev/null || true)"

  if [[ -z "$SEARCH_RESULT" || "$SEARCH_RESULT" == "not_found" ]]; then
    echo "$(get_text 'not_found')"
    exit 1
  fi

  echo ""
  echo "$(get_text 'found_skills')"
  echo ""

  while IFS=$'\t' read -r IDX SID SCORE CMD; do
    [[ -z "${IDX:-}" ]] && continue
    echo "[$IDX] ($(get_text 'match_score')$SCORE) $CMD"
  done <<< "$SEARCH_RESULT"

  echo ""
  read -r -p "$(get_text 'select_delete')" PICK

  if [[ -z "${PICK:-}" ]]; then
    echo "$(get_text 'cancelled')"
    exit 0
  fi

  DEL_ID="$(awk -F'\t' -v p="$PICK" '$1==p {print $2; exit}' <<< "$SEARCH_RESULT")"

  if [[ -z "$DEL_ID" ]]; then
    echo "$(get_text 'invalid')"
    exit 1
  fi

  python3 "$SCRIPT_DIR/skill_manager.py" delete-id "$DEL_ID" --lang "$CURRENT_LANG"
  exit $?
fi

# ====================================
# ② TopK 候选 Skill
# ====================================
TOPK=5
THRESH=0.85

SEARCH_OUT="$(python3 "$SCRIPT_DIR/skill_manager.py" search "$USER_INPUT" --threshold "$THRESH" --topk "$TOPK" 2>/dev/null || true)"

if [[ -n "$SEARCH_OUT" ]]; then
  echo ""
  echo "$(get_text 'matching_skills')"
  echo ""

  while IFS=$'\t' read -r IDX CMD SCORE SID EFF; do
    [[ -z "${IDX:-}" ]] && continue
    SHORT_EFF="${EFF:-}"
    if [[ ${#SHORT_EFF} -gt 60 ]]; then
      SHORT_EFF="${SHORT_EFF:0:60}..."
    fi
    echo "[$IDX] ($(get_text 'match_score')$SCORE) $CMD"
    if [[ -n "$SHORT_EFF" ]]; then
      echo "     $(get_text 'description')$SHORT_EFF"
    fi
  done <<< "$SEARCH_OUT"

  echo ""
  read -r -p "$(get_text 'select_execute')" PICK

  if [[ -n "${PICK:-}" && "$PICK" != "0" ]]; then
    PICK_CMD="$(awk -F'\t' -v p="$PICK" '$1==p {print $2; exit}' <<< "$SEARCH_OUT")"
    if [[ -n "${PICK_CMD:-}" ]]; then
      if is_dangerous_cmd "$PICK_CMD"; then
        echo ""
        echo "$(get_text 'dangerous')"
        echo "$(get_text 'command_label') $PICK_CMD"
        read -r -p "$(get_text 'confirm_danger')" DANGER_CONFIRM
        if [[ "${DANGER_CONFIRM:-}" != "yes" ]]; then
          echo "$(get_text 'cancelled')"
          exit 0
        fi
      fi
      echo ""
      echo "$(get_text 'execute_label') $PICK_CMD"
      echo ""
      eval "$PICK_CMD"
      exit $?
    else
      echo "$(get_text 'not_found')"
    fi
  fi
fi

# ====================================
# ③ 调用模型生成命令
# ====================================
PROMPT="$(build_prompt "$USER_INPUT")"
RESPONSE="$(printf "%s" "$PROMPT" | ollama run "$MODEL")"

echo ""
echo "$RESPONSE"
echo ""

# 提取命令（根据语言使用不同关键字）
CMD_KEYWORD="$(get_text 'cmd_keyword')"

# 优先从同一行提取命令（处理 "Command: xxx" 格式）
CMD="$(echo "$RESPONSE" | grep "$CMD_KEYWORD" | head -n 1 | sed "s/.*$CMD_KEYWORD[[:space:]]*//" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

# 如果同一行没有命令，尝试从下一行提取（处理 "Command:\nxxx" 格式）
if [[ -z "$CMD" || "$CMD" == "$CMD_KEYWORD" ]]; then
  CMD="$(echo "$RESPONSE" | grep -A1 "$CMD_KEYWORD" | tail -n 1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  # 过滤掉关键字本身
  if [[ "$CMD" == "$CMD_KEYWORD" ]]; then
    CMD=""
  fi
fi

# 清洗命令
CMD="$(echo "$CMD" | sed 's/```//g; s/`//g' | awk -F'或者' '{print $1}' | awk -F' or ' '{print $1}' | head -n 1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

# 兜底
if [[ -z "$CMD" ]]; then
  CMD="$(grep -E '^[a-zA-Z]' <<< "$RESPONSE" | head -n 1 || true)"
fi

if [[ -z "$CMD" ]]; then
  echo "$(get_text 'not_recognized')"
  exit 1
fi

# 安全检查
if is_dangerous_cmd "$CMD"; then
  echo ""
  echo "$(get_text 'dangerous')"
  echo "$(get_text 'command_label') $CMD"
fi

read -r -p "$(get_text 'confirm_execute')" CONFIRM
if [[ "${CONFIRM:-}" != "y" ]]; then
  exit 0
fi

# 危险命令二次确认
if is_dangerous_cmd "$CMD"; then
  read -r -p "$(get_text 'confirm_danger')" DANGER_CONFIRM
  if [[ "${DANGER_CONFIRM:-}" != "yes" ]]; then
    echo "$(get_text 'cancelled')"
    exit 0
  fi
fi

echo ""
eval "$CMD"
STATUS=$?

# ====================================
# ④ 失败分析
# ====================================
if [[ $STATUS -ne 0 ]]; then
  echo ""
  echo "$(get_text 'execution_failed')"
  ERROR_PROMPT="$(build_error_prompt "$CMD" "$STATUS")"
  printf "%s" "$ERROR_PROMPT" | ollama run "$MODEL"
  exit $STATUS
fi

# ====================================
# ⑤ 成功后：预览技能状态
# ====================================
CHECK_OUT="$(python3 "$SCRIPT_DIR/skill_manager.py" check "$USER_INPUT" "$CMD" 2>/dev/null || true)"
CHECK_STATUS="$(awk '{print $1}' <<< "$CHECK_OUT")"
CHECK_ID="$(awk '{print $2}' <<< "$CHECK_OUT")"

if [[ "$CHECK_STATUS" == "will_merge" ]]; then
  echo "✅ $(get_text 'skill_merged')"
  read -r -p "$(get_text 'save_skill')" SAVE_SKILL
  if [[ "${SAVE_SKILL:-}" != "y" ]]; then
    echo "$(get_text 'cancelled')"
    exit 0
  fi
  python3 "$SCRIPT_DIR/skill_manager.py" add "$USER_INPUT" "$CMD" >/dev/null 2>&1
  echo "✅ $(get_text 'skill_merged')"
  exit 0
fi

if [[ "$CHECK_STATUS" == "merged_no_change" ]]; then
  echo "$(get_text 'merged_no_change')"
  exit 0
fi

if [[ "$CHECK_STATUS" == "will_skip" ]]; then
  echo "$(get_text 'will_skip')"
  exit 0
fi

SAVE_CONFIRMED="no"

if [[ "$CHECK_STATUS" == "similar_trigger" ]]; then
  EXISTING_CMD="$(python3 "$SCRIPT_DIR/skill_manager.py" get-cmd "$CHECK_ID" 2>/dev/null || true)"
  echo "$(get_text 'similar_trigger')"
  echo "$(get_text 'existing_cmd') $EXISTING_CMD"
  echo "$(get_text 'current_cmd') $CMD"
  read -r -p "$(get_text 'save_new')" SAVE_SKILL
  if [[ "${SAVE_SKILL:-}" != "y" ]]; then
    echo "$(get_text 'cancelled')"
    exit 0
  fi
  SAVE_CONFIRMED="yes"
fi

if [[ "$SAVE_CONFIRMED" != "yes" ]]; then
  read -r -p "$(get_text 'save_skill')" SAVE_SKILL
  if [[ "${SAVE_SKILL:-}" != "y" ]]; then
    exit 0
  fi
fi

DESC_PROMPT="$(build_desc_prompt "$CMD")"
DESC="$(printf "%s" "$DESC_PROMPT" | ollama run "$MODEL")"

if [[ "$SAVE_CONFIRMED" == "yes" ]]; then
  ADD_OUT="$(python3 "$SCRIPT_DIR/skill_manager.py" add "$USER_INPUT" "$CMD" --effect "$DESC" --force 2>/dev/null || true)"
else
  ADD_OUT="$(python3 "$SCRIPT_DIR/skill_manager.py" add "$USER_INPUT" "$CMD" --effect "$DESC" 2>/dev/null || true)"
fi

ADD_STATUS="$(awk '{print $1}' <<< "$ADD_OUT")"
ADD_ID="$(awk '{print $2}' <<< "$ADD_OUT")"

if [[ "$ADD_STATUS" == "skipped" ]]; then
  echo "⚠ $(get_text 'will_skip')"
elif [[ "$ADD_STATUS" == "merged" ]]; then
  echo "✅ $(get_text 'skill_merged') (id=$ADD_ID)"
else
  echo "✅ $(get_text 'skill_saved') (id=$ADD_ID)"
fi
exit 0