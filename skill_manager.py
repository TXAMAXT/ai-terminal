#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import json
import argparse
import time
import sys
import random
import string
from typing import Any, Dict, List, Optional, Tuple

import faiss
import numpy as np
import requests

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
SKILL_FILE = os.path.join(BASE_DIR, "skills.json")
CONFIG_FILE = os.path.join(BASE_DIR, "config.json")

OLLAMA_EMBED_URL = "http://localhost:11434/api/embeddings"
REQUEST_TIMEOUT_SEC = 60

# --- Tunables ---
SEARCH_THRESHOLD_DEFAULT = 0.85
DEDUP_BY_TRIGGER_THRESHOLD = 0.92
DELETE_MATCH_THRESHOLD = 0.75  # 删除时语义匹配阈值


def generate_id(length: int = 6) -> str:
    """生成随机 ID，如 'a1b2c3'"""
    chars = string.ascii_lowercase + string.digits
    return ''.join(random.choice(chars) for _ in range(length))


def load_config() -> Dict[str, Any]:
    if not os.path.exists(CONFIG_FILE):
        return {}
    try:
        with open(CONFIG_FILE, "r", encoding="utf-8") as f:
            return json.load(f) or {}
    except Exception:
        return {}


def current_embed_model() -> str:
    cfg = load_config()
    return cfg.get("embed_model", "nomic-embed-text")


def get_embedding(text: str, model: Optional[str] = None) -> np.ndarray:
    m = model or current_embed_model()
    r = requests.post(
        OLLAMA_EMBED_URL,
        json={"model": m, "prompt": text},
        timeout=REQUEST_TIMEOUT_SEC,
    )
    r.raise_for_status()
    emb = r.json()["embedding"]
    return np.array(emb, dtype=np.float32)


def _safe_float32_contig_2d(vectors: List[List[float]]) -> np.ndarray:
    arr = np.array(vectors, dtype=np.float32)
    arr = np.ascontiguousarray(arr)
    if arr.ndim != 2:
        arr = arr.reshape(1, -1).astype(np.float32)
        arr = np.ascontiguousarray(arr)
    return arr


def load_skills_raw() -> List[Dict[str, Any]]:
    if not os.path.exists(SKILL_FILE):
        return []
    with open(SKILL_FILE, "r", encoding="utf-8") as f:
        data = json.load(f)
        return data if isinstance(data, list) else []


def save_skills_atomic(skills: List[Dict[str, Any]]) -> None:
    tmp = SKILL_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(skills, f, ensure_ascii=False, indent=2)
    os.replace(tmp, SKILL_FILE)


def backup_skills() -> str:
    ts = time.strftime("%Y%m%d-%H%M%S")
    bak = f"{SKILL_FILE}.bak.{ts}"
    if os.path.exists(SKILL_FILE):
        with open(SKILL_FILE, "rb") as src, open(bak, "wb") as dst:
            dst.write(src.read())

    # 自动清理旧备份，只保留最近 5 个
    cleanup_old_backups(keep=5)

    return bak


def cleanup_old_backups(keep: int = 5) -> None:
    """清理旧备份文件，只保留最近的 N 个"""
    import glob
    pattern = f"{SKILL_FILE}.bak.*"
    backups = sorted(glob.glob(pattern), reverse=True)  # 按时间倒序
    for old_bak in backups[keep:]:
        try:
            os.remove(old_bak)
        except OSError:
            pass


def restore_backup(bak_path: str) -> None:
    if os.path.exists(bak_path):
        os.replace(bak_path, SKILL_FILE)


def migrate_skills_inplace(skills: List[Dict[str, Any]]) -> bool:
    """
    迁移旧格式：
      - trigger -> triggers
      - 补齐：effect、embedding_model
    """
    changed = False
    cur_model = current_embed_model()

    for s in skills:
        if "triggers" not in s:
            if "trigger" in s and isinstance(s["trigger"], str) and s["trigger"].strip():
                s["triggers"] = [s["trigger"].strip()]
            else:
                s["triggers"] = []
            if "trigger" in s:
                del s["trigger"]
            changed = True

        if "effect" not in s:
            s["effect"] = ""
            changed = True

        if "command" not in s:
            s["command"] = ""
            changed = True

        if "embedding_model" not in s:
            s["embedding_model"] = cur_model
            changed = True

        if "embedding" not in s or not isinstance(s["embedding"], list):
            s["embedding"] = []
            changed = True

    ids = [x.get("id") for x in skills]
    if any(i is None for i in ids) or len(set([i for i in ids if i is not None])) != len([i for i in ids if i is not None]):
        existing_ids = set(i for i in ids if i is not None)
        for s in skills:
            if s.get("id") is None:
                # 生成不重复的随机 ID
                new_id = generate_id()
                while new_id in existing_ids:
                    new_id = generate_id()
                s["id"] = new_id
                existing_ids.add(new_id)
        changed = True

    return changed


def skill_text(skill: Dict[str, Any]) -> str:
    triggers = [t.strip() for t in (skill.get("triggers") or []) if isinstance(t, str) and t.strip()]
    return " | ".join(triggers).strip()


def reembed_all(skills: List[Dict[str, Any]], force: bool = False) -> None:
    """
    自动重算 embedding（带进度 + 回滚）
    - force=True：强制所有 skill 重算
    """
    cur_model = current_embed_model()
    n = len(skills)
    if n == 0:
        return

    bak = backup_skills()
    try:
        for i, s in enumerate(skills, start=1):
            text = skill_text(s)
            if not text:
                continue

            need = force or (s.get("embedding_model") != cur_model) or (not s.get("embedding"))
            if not need:
                continue

            print(f"[reembed] {i}/{n} id={s.get('id')} model={cur_model}", file=sys.stderr)
            emb = get_embedding(text, model=cur_model)
            s["embedding"] = emb.tolist()
            s["embedding_model"] = cur_model

        save_skills_atomic(skills)
        print("[reembed] done", file=sys.stderr)

    except Exception as e:
        print(f"[reembed] failed, rollback: {e}", file=sys.stderr)
        restore_backup(bak)
        raise


def ensure_embeddings_up_to_date(skills: List[Dict[str, Any]]) -> bool:
    """
    embed_model 变化就自动重算全库（带回滚）。
    返回：是否执行了重算
    """
    cur_model = current_embed_model()
    for s in skills:
        if s.get("embedding_model") != cur_model and skill_text(s):
            reembed_all(skills, force=False)
            return True
    return False


def dedupe_by_command(skills: List[Dict[str, Any]]) -> Tuple[List[Dict[str, Any]], bool]:
    changed = False
    by_cmd: Dict[str, Dict[str, Any]] = {}
    kept: List[Dict[str, Any]] = []

    for s in skills:
        cmd = (s.get("command") or "").strip()
        if not cmd:
            kept.append(s)
            continue

        if cmd not in by_cmd:
            by_cmd[cmd] = s
            kept.append(s)
        else:
            base = by_cmd[cmd]
            t1 = set([x.strip() for x in base.get("triggers", []) if isinstance(x, str)])
            t2 = set([x.strip() for x in s.get("triggers", []) if isinstance(x, str)])
            base["triggers"] = sorted([x for x in (t1 | t2) if x])

            e1 = (base.get("effect") or "").strip()
            e2 = (s.get("effect") or "").strip()
            if len(e2) > len(e1):
                base["effect"] = e2

            try:
                kept.remove(s)
            except ValueError:
                pass

            changed = True

    return kept, changed


def dedupe_skills() -> Tuple[List[Dict[str, Any]], bool]:
    skills = load_skills_raw()
    changed = migrate_skills_inplace(skills)

    skills, changed2 = dedupe_by_command(skills)
    changed = changed or changed2

    did = ensure_embeddings_up_to_date(skills)
    changed = changed or did

    if changed:
        save_skills_atomic(skills)

    return skills, changed


def build_index(skills: List[Dict[str, Any]]) -> Tuple[Optional[faiss.IndexFlatIP], List[Dict[str, Any]]]:
    usable = []
    vecs = []
    dim = None

    for s in skills:
        emb = s.get("embedding")
        if not isinstance(emb, list) or len(emb) == 0:
            continue
        if dim is None:
            dim = len(emb)
        if len(emb) != dim:
            continue
        usable.append(s)
        vecs.append(emb)

    if not usable:
        return None, []

    vectors = _safe_float32_contig_2d(vecs)
    faiss.normalize_L2(vectors)

    index = faiss.IndexFlatIP(vectors.shape[1])
    index.add(vectors)
    return index, usable


def search_skill(query: str, threshold: float = SEARCH_THRESHOLD_DEFAULT, topk: int = 1) -> Optional[List[Tuple[Dict[str, Any], float]]]:
    skills, _ = dedupe_skills()
    if not skills:
        return None

    index, usable = build_index(skills)
    if index is None or not usable:
        return None

    q = get_embedding(query).astype(np.float32).reshape(1, -1)
    q = np.ascontiguousarray(q)
    faiss.normalize_L2(q)

    topk = max(1, int(topk))
    D, I = index.search(q, topk)

    results: List[Tuple[Dict[str, Any], float]] = []
    for score, idx in zip(D[0].tolist(), I[0].tolist()):
        if idx < 0:
            continue
        score = float(score)
        if score >= threshold:
            results.append((usable[int(idx)], score))

    if not results:
        return None

    results.sort(key=lambda x: x[1], reverse=True)
    return results


def check_skill_status(trigger: str, command: str) -> Tuple[str, Optional[str]]:
    """
    预览技能状态（不保存）：
    返回：
      - 'will_merge', skill_id：将合并到已有技能（命令相同）
      - 'will_skip', skill_id：触发语和命令都相同，跳过新增
      - 'similar_trigger', skill_id：触发语相似但命令不同，提示用户
      - 'will_add', None：将新增技能
    """
    trigger = (trigger or "").strip()
    command = (command or "").strip()

    skills, _ = dedupe_skills()

    # 同 command 将合并触发语
    if command:
        for s in skills:
            if (s.get("command") or "").strip() == command:
                triggers = [t.strip() for t in s.get("triggers", []) if isinstance(t, str) and t.strip()]
                if trigger and trigger not in triggers:
                    return "will_merge", str(s["id"])
                return "merged_no_change", str(s["id"])

    # trigger 高度重复但命令不同：提示用户选择
    if trigger:
        hit = search_skill(trigger, threshold=DEDUP_BY_TRIGGER_THRESHOLD, topk=1)
        if hit:
            s, _ = hit[0]
            # 命令不同，让用户决定是否保存
            return "similar_trigger", str(s["id"])

    return "will_add", None


def add_skill(trigger: str, command: str, effect: str = "", force: bool = False) -> Tuple[str, str]:
    """
    添加或合并技能

    Args:
        trigger: 触发语
        command: 命令
        effect: 效果描述
        force: 强制添加，跳过触发语重复检查

    Returns:
        (status, id) - status: added/merged/skipped
    """
    trigger = (trigger or "").strip()
    command = (command or "").strip()
    effect = (effect or "").strip()

    skills, _ = dedupe_skills()
    changed = False

    # 同 command 合并
    if command:
        for s in skills:
            if (s.get("command") or "").strip() == command:
                triggers = [t.strip() for t in s.get("triggers", []) if isinstance(t, str) and t.strip()]
                if trigger and trigger not in triggers:
                    triggers.append(trigger)
                    s["triggers"] = triggers
                    changed = True
                if effect and len(effect) > len((s.get("effect") or "").strip()):
                    s["effect"] = effect
                    changed = True
                if changed:
                    # triggers 变了就重算当前 embedding（同 model）
                    reembed_all(skills, force=False)
                return "merged", str(s["id"])

    # trigger 高度重复则跳过新增（除非 force=True）
    if trigger and not force:
        hit = search_skill(trigger, threshold=DEDUP_BY_TRIGGER_THRESHOLD, topk=1)
        if hit:
            s, _ = hit[0]
            return "skipped", str(s["id"])

    # 新增
    cur_model = current_embed_model()

    # 生成不重复的随机 ID
    existing_ids = set(s.get("id") for s in skills)
    new_id = generate_id()
    while new_id in existing_ids:
        new_id = generate_id()

    new_skill = {
        "id": new_id,
        "triggers": [trigger] if trigger else [],
        "command": command,
        "effect": effect,
        "embedding_model": cur_model,
        "embedding": [],
    }

    text = skill_text(new_skill)
    if text:
        new_skill["embedding"] = get_embedding(text, model=cur_model).tolist()

    skills.append(new_skill)

    save_skills_atomic(skills)
    return "added", str(new_skill["id"])


def set_effect(skill_id: str, effect: str) -> bool:
    skills, _ = dedupe_skills()
    changed = False
    for s in skills:
        if str(s.get("id", "")) == str(skill_id):
            s["effect"] = (effect or "").strip()
            changed = True
            break
    if changed:
        save_skills_atomic(skills)
    return changed


def list_skills(limit: int = 50) -> List[Dict[str, Any]]:
    """列出所有技能"""
    skills, _ = dedupe_skills()
    return skills[:limit] if limit > 0 else skills


def get_skill_command(skill_id: str) -> Optional[str]:
    """根据 ID 获取技能命令"""
    skills, _ = dedupe_skills()
    for s in skills:
        if str(s.get("id", "")) == skill_id:
            return s.get("command", "")
    return None


def search_for_delete(query: str, topk: int = 5) -> List[Tuple[Dict[str, Any], float]]:
    """
    搜索匹配的技能（用于删除前确认）
    返回匹配列表：[(skill, score), ...]
    """
    skills, _ = dedupe_skills()
    query = query.strip()

    if not query:
        return []

    results = []

    # 1. 精确命令匹配
    for s in skills:
        if (s.get("command") or "").strip() == query:
            results.append((s, 1.0))
            return results  # 精确匹配直接返回

    # 2. ID 匹配
    for s in skills:
        if str(s.get("id", "")) == query:
            results.append((s, 1.0))
            return results

    # 3. 触发语精确匹配
    for s in skills:
        triggers = [t.strip() for t in s.get("triggers", []) if isinstance(t, str)]
        if query in triggers:
            results.append((s, 1.0))
            return results

    # 4. 语义匹配
    hit = search_skill(query, threshold=DELETE_MATCH_THRESHOLD, topk=topk)
    if hit:
        return hit

    return results


def delete_by_id(skill_id: str) -> Tuple[bool, str]:
    """根据 ID 删除技能"""
    skills, _ = dedupe_skills()
    for s in skills:
        if str(s.get("id", "")) == skill_id:
            cmd = s.get("command", "")
            skills.remove(s)
            save_skills_atomic(skills)
            return True, f"已删除: {cmd}"
    return False, f"未找到 ID: {skill_id}"


def delete_skill(query: str) -> Tuple[bool, str]:
    """
    删除技能，支持多种匹配方式：
    1. 精确命令匹配：delete "ls -la"
    2. 语义匹配：delete "查看文件"
    3. ID 匹配：delete "a1b2c3"

    返回：(是否成功, 消息)
    """
    skills, _ = dedupe_skills()
    query = query.strip()

    if not query:
        return False, "请提供要删除的技能（命令、触发语或 ID）"

    # 1. 尝试精确命令匹配
    for s in skills:
        if (s.get("command") or "").strip() == query:
            skills.remove(s)
            save_skills_atomic(skills)
            return True, f"已删除命令: {query}"

    # 2. 尝试 ID 匹配
    for s in skills:
        if str(s.get("id", "")) == query:
            cmd = s.get("command", "")
            skills.remove(s)
            save_skills_atomic(skills)
            return True, f"已删除 ID {query}: {cmd}"

    # 3. 尝试语义匹配
    hit = search_skill(query, threshold=DELETE_MATCH_THRESHOLD, topk=1)
    if hit:
        s, score = hit[0]
        cmd = s.get("command", "")
        skills.remove(s)
        save_skills_atomic(skills)
        return True, f"已删除（匹配度 {score:.2f}）: {cmd}"

    return False, f"未找到匹配的技能: {query}"


def main():
    parser = argparse.ArgumentParser(description="Skill manager for ai-terminal")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_search = sub.add_parser("search", help="search skills by semantic similarity")
    p_search.add_argument("query", type=str)
    p_search.add_argument("--threshold", type=float, default=SEARCH_THRESHOLD_DEFAULT)
    p_search.add_argument("--topk", type=int, default=1)

    p_add = sub.add_parser("add", help="add/merge a skill by command")
    p_add.add_argument("trigger", type=str)
    p_add.add_argument("command", type=str)
    p_add.add_argument("--effect", type=str, default="")
    p_add.add_argument("--force", action="store_true", help="force add even if trigger is similar")

    p_check = sub.add_parser("check", help="preview skill status without saving")
    p_check.add_argument("trigger", type=str)
    p_check.add_argument("command", type=str)

    p_set = sub.add_parser("set-effect", help="set effect text for a skill id")
    p_set.add_argument("id", type=str)
    p_set.add_argument("effect", type=str)

    p_list = sub.add_parser("list", help="list all skills")
    p_list.add_argument("--limit", type=int, default=50, help="max number of skills to show")

    p_search_del = sub.add_parser("search-delete", help="search skills for deletion")
    p_search_del.add_argument("query", type=str, nargs="+", help="search query")
    p_search_del.add_argument("--topk", type=int, default=5)

    p_del_id = sub.add_parser("delete-id", help="delete skill by id")
    p_del_id.add_argument("id", type=str, help="skill id to delete")

    p_delete = sub.add_parser("delete", help="delete a skill by command, trigger, or id (legacy)")
    p_delete.add_argument("query", type=str, nargs="*", help="command, trigger phrase, or skill id to delete")

    p_get_cmd = sub.add_parser("get-cmd", help="get command by skill id")
    p_get_cmd.add_argument("id", type=str, help="skill id")

    sub.add_parser("dedupe", help="dedupe skills.json by command and auto-reembed when embed_model changes")

    p_reembed = sub.add_parser("reembed", help="force re-embed all skills using current embed_model")
    p_reembed.add_argument("--force", action="store_true")

    args = parser.parse_args()

    if args.cmd == "search":
        res = search_skill(args.query, threshold=args.threshold, topk=args.topk)
        if not res:
            return
        for i, (skill, score) in enumerate(res, start=1):
            cmd = (skill.get("command") or "").replace("\t", " ")
            eff = (skill.get("effect") or "").replace("\t", " ").replace("\n", " ").strip()
            sid = skill.get("id", "")
            print(f"{i}\t{cmd}\t{score:.4f}\t{sid}\t{eff}")
        return

    if args.cmd == "check":
        status, sid = check_skill_status(args.trigger, args.command)
        print(f"{status} {sid if sid else ''}")
        return

    if args.cmd == "add":
        status, sid = add_skill(args.trigger, args.command, args.effect, force=args.force)
        print(f"{status} {sid}")
        return

    if args.cmd == "set-effect":
        ok = set_effect(args.id, args.effect)
        print("ok" if ok else "nochange")
        return

    if args.cmd == "list":
        skills = list_skills(limit=args.limit)
        if not skills:
            print("没有技能")
            return
        print(f"共 {len(skills)} 个技能：")
        print("-" * 60)
        for s in skills:
            cmd = (s.get("command") or "").replace("\n", " ")
            triggers = ", ".join(s.get("triggers", [])[:3])
            print(f"• {cmd}")
            print(f"  触发语: {triggers}")
        return

    if args.cmd == "search-delete":
        query = " ".join(args.query)
        results = search_for_delete(query, topk=args.topk)
        if not results:
            print("not_found")
            return
        for i, (s, score) in enumerate(results, start=1):
            cmd = (s.get("command") or "").replace("\t", " ")
            sid = s.get("id", "")
            print(f"{i}\t{sid}\t{score:.4f}\t{cmd}")
        return

    if args.cmd == "delete-id":
        ok, msg = delete_by_id(args.id)
        print(msg)
        return

    if args.cmd == "delete":
        query = " ".join(args.query)
        ok, msg = delete_skill(query)
        print(msg)
        return

    if args.cmd == "get-cmd":
        cmd = get_skill_command(args.id)
        if cmd:
            print(cmd)
        return

    if args.cmd == "dedupe":
        _, changed = dedupe_skills()
        print("changed" if changed else "nochange")
        return

    if args.cmd == "reembed":
        skills = load_skills_raw()
        migrate_skills_inplace(skills)
        reembed_all(skills, force=bool(args.force))
        print("done")
        return


if __name__ == "__main__":
    main()