#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

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
  exit 1
fi

# ====================================
# ① TopK 候选 Skill
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
# ② 调用模型生成命令（中文解释 + 英文命令）
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

# 清洗：去代码块/反引号/“或者”只取第一条/取第一行
CMD="$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<< "$CMD")"
CMD="$(sed 's/```//g' <<< "$CMD")"
CMD="$(tr -d '\`' <<< "$CMD")"
CMD="$(awk -F '或者' '{print $1}' <<< "$CMD")"
CMD="$(head -n 1 <<< "$CMD")"
CMD="$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<< "$CMD")"

# 兜底：如果还空，就取第一条像命令的行
if [[ -z "$CMD" ]]; then
  CMD="$(grep -E '^[a-zA-Z]' <<< "$RESPONSE" | head -n 1 || true)"
fi

if [[ -z "$CMD" ]]; then
  echo "未识别到命令"
  exit 1
fi

read -r -p "是否执行？(y/n): " CONFIRM
if [[ "${CONFIRM:-}" != "y" ]]; then
  exit 0
fi

echo ""
eval "$CMD"
STATUS=$?

# ====================================
# ③ 失败分析
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
# ④ 成功后：自动合并/新增 skill
# ====================================
ADD_OUT="$(python3 "$SCRIPT_DIR/skill_manager.py" add "$USER_INPUT" "$CMD" 2>/dev/null || true)"
ADD_STATUS="$(awk '{print $1}' <<< "$ADD_OUT")"
ADD_ID="$(awk '{print $2}' <<< "$ADD_OUT")"

if [[ "$ADD_STATUS" == "merged" ]]; then
  echo "✅ 已合并到已有技能（追加触发语/必要时自动重算 embedding）"
  exit 0
fi

if [[ "$ADD_STATUS" == "skipped" ]]; then
  echo "⚠ 触发语与已有技能高度重复，已跳过新增"
  exit 0
fi

read -r -p "是否保存为技能？(y/n): " SAVE_SKILL
if [[ "${SAVE_SKILL:-}" != "y" ]]; then
  exit 0
fi

DESC="$(printf "%s" "用一句中文说明下面命令的作用（命令保持英文，不要加代码块）：$CMD" | ollama run "$MODEL")"
python3 "$SCRIPT_DIR/skill_manager.py" set-effect "$ADD_ID" "$DESC" >/dev/null 2>&1 || true

echo "✅ 技能已保存（id=$ADD_ID）"
exit 0