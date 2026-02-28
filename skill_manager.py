#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import json
import argparse
import time
import sys
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
    return bak


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
        for i, s in enumerate(skills, start=1):
            s["id"] = i
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

    if changed:
        for i, s in enumerate(kept, start=1):
            s["id"] = i

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


def add_skill(trigger: str, command: str, effect: str = "") -> Tuple[str, int]:
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
                return "merged", int(s["id"])

    # trigger 高度重复则跳过新增（避免污染）
    if trigger:
        hit = search_skill(trigger, threshold=DEDUP_BY_TRIGGER_THRESHOLD, topk=1)
        if hit:
            s, _ = hit[0]
            return "skipped", int(s["id"])

    # 新增
    cur_model = current_embed_model()
    new_skill = {
        "id": len(skills) + 1,
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
    for i, s in enumerate(skills, start=1):
        s["id"] = i

    save_skills_atomic(skills)
    return "added", int(new_skill["id"])


def set_effect(skill_id: int, effect: str) -> bool:
    skills, _ = dedupe_skills()
    changed = False
    for s in skills:
        if int(s.get("id", -1)) == int(skill_id):
            s["effect"] = (effect or "").strip()
            changed = True
            break
    if changed:
        save_skills_atomic(skills)
    return changed


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

    p_set = sub.add_parser("set-effect", help="set effect text for a skill id")
    p_set.add_argument("id", type=int)
    p_set.add_argument("effect", type=str)

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

    if args.cmd == "add":
        status, sid = add_skill(args.trigger, args.command, args.effect)
        print(f"{status} {sid}")
        return

    if args.cmd == "set-effect":
        ok = set_effect(args.id, args.effect)
        print("ok" if ok else "nochange")
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