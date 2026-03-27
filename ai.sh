#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

# ====================================
# 危险命令黑名单检测
# ====================================
is_dangerous_cmd() {
  local cmd="$1"
  # 危险模式列表
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
      return 0  # 是危险命令
    fi
  done
  return 1  # 安全
}

# 读取 chat_model（没有就默认）
MODEL="$(python3 - <<'PY'
import json, os
cfg = os.path.join(os.path.dirname(__file__), "config.json")
m = "qwen2.5:7b"
try:
    with open(cfg, "r", encoding="utf-8") as f:
        m = json.load(f).get("chat_model", m)
except Exception:
    pass
print(m)
PY
)"

USER_INPUT="${*:-}"
if [[ -z "$USER_INPUT" ]]; then
  echo "用法：ai <你的需求>"
  echo "      ai skill                    # 列出所有技能"
  echo "      ai delete <命令|触发语|ID>   # 删除匹配的技能"
  exit 1
fi

# ====================================
# ① 内置命令处理
# ====================================
# 列出技能
if [[ "$USER_INPUT" == "skill" || "$USER_INPUT" == "skills" ]]; then
  python3 "$SCRIPT_DIR/skill_manager.py" list
  exit 0
fi

# 删除技能（支持命令、触发语或 ID）
if [[ "$USER_INPUT" == delete* ]]; then
  DEL_QUERY="$(echo "$USER_INPUT" | sed 's/^delete[[:space:]]*//')"
  if [[ -z "$DEL_QUERY" ]]; then
    echo "用法：ai delete <命令|触发语|ID>"
    echo "示例："
    echo "  ai delete ls -la"
    echo "  ai delete 帮我执行top命令"
    echo "  ai delete a1b2c3"
    echo ""
    echo "⚠️  包含特殊字符（; | & > <）的命令请用引号包裹："
    echo "  ai delete \"cat file; ip a\""
    exit 1
  fi

  # 搜索匹配的技能
  SEARCH_RESULT="$(python3 "$SCRIPT_DIR/skill_manager.py" search-delete -- "$DEL_QUERY" 2>/dev/null || true)"

  if [[ -z "$SEARCH_RESULT" || "$SEARCH_RESULT" == "not_found" ]]; then
    echo "未找到匹配的技能"
    exit 1
  fi

  # 显示匹配结果
  echo ""
  echo "🔍 找到以下匹配的技能："
  echo ""

  while IFS=$'\t' read -r IDX SID SCORE CMD; do
    [[ -z "${IDX:-}" ]] && continue
    echo "[$IDX] (匹配度=$SCORE) $CMD"
  done <<< "$SEARCH_RESULT"

  echo ""
  read -r -p "请选择要删除的技能编号（回车取消）： " PICK

  if [[ -z "${PICK:-}" ]]; then
    echo "已取消"
    exit 0
  fi

  # 获取选中技能的 ID
  DEL_ID="$(awk -F'\t' -v p="$PICK" '$1==p {print $2; exit}' <<< "$SEARCH_RESULT")"

  if [[ -z "$DEL_ID" ]]; then
    echo "无效的选择"
    exit 1
  fi

  python3 "$SCRIPT_DIR/skill_manager.py" delete-id "$DEL_ID"
  exit $?
fi

# ====================================
# ② TopK 候选 Skill
# 每行：idx<TAB>command<TAB>score<TAB>id<TAB>effect
# ====================================
TOPK=5
THRESH=0.85

SEARCH_OUT="$(python3 "$SCRIPT_DIR/skill_manager.py" search "$USER_INPUT" --threshold "$THRESH" --topk "$TOPK" 2>/dev/null || true)"

if [[ -n "$SEARCH_OUT" ]]; then
  echo ""
  echo "🧠 命中候选技能（Top $TOPK，阈值 $THRESH）："
  echo ""

  # 展示候选（不在 while 子shell 里改外部变量，纯打印）
  while IFS=$'\t' read -r IDX CMD SCORE SID EFF; do
    [[ -z "${IDX:-}" ]] && continue
    SHORT_EFF="${EFF:-}"
    if [[ ${#SHORT_EFF} -gt 60 ]]; then
      SHORT_EFF="${SHORT_EFF:0:60}..."
    fi
    echo "[$IDX] (score=$SCORE) $CMD"
    if [[ -n "$SHORT_EFF" ]]; then
      echo "     说明：$SHORT_EFF"
    fi
  done <<< "$SEARCH_OUT"

  echo ""
  read -r -p "请选择要执行的技能编号（回车跳过，输入 0 跳过）： " PICK

  if [[ -n "${PICK:-}" && "$PICK" != "0" ]]; then
    PICK_CMD="$(awk -F'\t' -v p="$PICK" '$1==p {print $2; exit}' <<< "$SEARCH_OUT")"
    if [[ -n "${PICK_CMD:-}" ]]; then
      # 安全检查
      if is_dangerous_cmd "$PICK_CMD"; then
        echo ""
        echo "⚠️  警告：检测到危险命令！"
        echo "命令：$PICK_CMD"
        read -r -p "确定要执行吗？(yes/no): " DANGER_CONFIRM
        if [[ "${DANGER_CONFIRM:-}" != "yes" ]]; then
          echo "已取消"
          exit 0
        fi
      fi
      echo ""
      echo "▶ 执行：$PICK_CMD"
      echo ""
      eval "$PICK_CMD"
      exit $?
    else
      echo "未找到该编号，继续走模型生成。"
    fi
  fi
fi

# ====================================
# ③ 调用模型生成命令（中文解释 + 英文命令）
# 用 heredoc 构造 PROMPT，避免引号地狱
# ====================================
PROMPT="$(cat <<EOF
你是一名资深 Linux + 开发工程师助手。

必须严格遵守：
1. 全部用中文回答
2. 只能输出一条最终命令（不要给多个候选）
3. 不允许输出代码块符号（\`\`\`）
4. 输出格式必须严格如下（注意“命令：”单独一行）：

功能说明：
<中文说明>

命令：
<只输出一条shell命令>

用户需求：
$USER_INPUT
EOF
)"

RESPONSE="$(printf "%s" "$PROMPT" | ollama run "$MODEL")"

echo ""
echo "$RESPONSE"
echo ""

# 提取命令：优先取 “命令：” 下一行；若同一行则截取后半部分
CMD="$(awk '
  BEGIN{found=0}
  /^命令：/{
    found=1
    if (length($0) > 7) { sub(/^命令：/, "", $0); print $0; exit }
    getline; print; exit
  }
' <<< "$RESPONSE")"

# 清洗：去代码块/反引号/”或者”只取第一条/取第一行/去首尾空白
CMD="$(echo "$CMD" | sed 's/```//g; s/`//g' | awk -F'或者' '{print $1}' | head -n 1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

# 兜底：如果还空，就取第一条像命令的行
if [[ -z "$CMD" ]]; then
  CMD="$(grep -E '^[a-zA-Z]' <<< "$RESPONSE" | head -n 1 || true)"
fi

if [[ -z "$CMD" ]]; then
  echo "未识别到命令"
  exit 1
fi

# 安全检查（在用户确认后进行二次确认）
if is_dangerous_cmd "$CMD"; then
  echo ""
  echo "⚠️  警告：检测到危险命令！"
  echo "命令：$CMD"
fi

read -r -p "是否执行？(y/n): " CONFIRM
if [[ "${CONFIRM:-}" != "y" ]]; then
  exit 0
fi

# 危险命令二次确认
if is_dangerous_cmd "$CMD"; then
  read -r -p "⚠️  这是危险命令，确定要执行吗？(yes/no): " DANGER_CONFIRM
  if [[ "${DANGER_CONFIRM:-}" != "yes" ]]; then
    echo "已取消"
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
  echo "命令执行失败，正在分析..."

  ERROR_PROMPT="$(cat <<EOF
用中文分析下面命令执行失败的原因，并给出解决建议。
命令：
$CMD

退出码：
$STATUS
EOF
)"
  printf "%s" "$ERROR_PROMPT" | ollama run "$MODEL"
  exit $STATUS
fi

# ====================================
# ⑤ 成功后：预览技能状态（不保存）
# ====================================
CHECK_OUT="$(python3 "$SCRIPT_DIR/skill_manager.py" check "$USER_INPUT" "$CMD" 2>/dev/null || true)"
CHECK_STATUS="$(awk '{print $1}' <<< "$CHECK_OUT")"
CHECK_ID="$(awk '{print $2}' <<< "$CHECK_OUT")"

if [[ "$CHECK_STATUS" == "will_merge" ]]; then
  echo "✅ 将合并到已有技能（追加触发语）"
  read -r -p "确认保存？(y/n): " SAVE_SKILL
  if [[ "${SAVE_SKILL:-}" != "y" ]]; then
    echo "已取消"
    exit 0
  fi
  python3 "$SCRIPT_DIR/skill_manager.py" add "$USER_INPUT" "$CMD" >/dev/null 2>&1
  echo "✅ 已合并"
  exit 0
fi

if [[ "$CHECK_STATUS" == "merged_no_change" ]]; then
  echo "ℹ️ 触发语已存在于该命令的技能中，无需保存"
  exit 0
fi

if [[ "$CHECK_STATUS" == "will_skip" ]]; then
  echo "⚠ 触发语与已有技能高度重复，跳过保存"
  exit 0
fi

# 标记是否已确认保存
SAVE_CONFIRMED="no"

if [[ "$CHECK_STATUS" == "similar_trigger" ]]; then
  # 触发语相似但命令不同，让用户选择
  EXISTING_CMD="$(python3 "$SCRIPT_DIR/skill_manager.py" get-cmd "$CHECK_ID" 2>/dev/null || true)"
  echo "⚠ 检测到相似触发语，但命令不同："
  echo "  已有命令: $EXISTING_CMD"
  echo "  当前命令: $CMD"
  read -r -p "是否保存为新技能？(y/n): " SAVE_SKILL
  if [[ "${SAVE_SKILL:-}" != "y" ]]; then
    echo "已取消"
    exit 0
  fi
  SAVE_CONFIRMED="yes"
fi

# will_add：询问是否保存；similar_trigger 已确认则跳过询问
if [[ "$SAVE_CONFIRMED" != "yes" ]]; then
  read -r -p "是否保存为技能？(y/n): " SAVE_SKILL
  if [[ "${SAVE_SKILL:-}" != "y" ]]; then
    exit 0
  fi
fi

DESC="$(printf "%s" "用一句中文说明下面命令的作用（命令保持英文，不要加代码块）：$CMD" | ollama run "$MODEL")"

# 如果是 similar_trigger 确认的，使用 --force 强制添加
if [[ "$SAVE_CONFIRMED" == "yes" ]]; then
  ADD_OUT="$(python3 "$SCRIPT_DIR/skill_manager.py" add "$USER_INPUT" "$CMD" --effect "$DESC" --force 2>/dev/null || true)"
else
  ADD_OUT="$(python3 "$SCRIPT_DIR/skill_manager.py" add "$USER_INPUT" "$CMD" --effect "$DESC" 2>/dev/null || true)"
fi

ADD_STATUS="$(awk '{print $1}' <<< "$ADD_OUT")"
ADD_ID="$(awk '{print $2}' <<< "$ADD_OUT")"

if [[ "$ADD_STATUS" == "skipped" ]]; then
  echo "⚠ 触发语与已有技能高度重复，未保存"
elif [[ "$ADD_STATUS" == "merged" ]]; then
  echo "✅ 已合并到已有技能（id=$ADD_ID）"
else
  echo "✅ 技能已保存（id=$ADD_ID）"
fi
exit 0