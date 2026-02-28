import os
import json
import faiss
import numpy as np
import requests

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
SKILL_FILE = os.path.join(BASE_DIR, "skills.json")

OLLAMA_URL = "http://localhost:11434/api/embeddings"
EMBED_MODEL = "nomic-embed-text"

# ==============================
# 生成 embedding
# ==============================

def get_embedding(text):
    response = requests.post(
        OLLAMA_URL,
        json={
            "model": EMBED_MODEL,
            "prompt": text
        }
    )
    return np.array(response.json()["embedding"], dtype=np.float32)

# ==============================
# 加载技能
# ==============================

def load_skills():
    if not os.path.exists(SKILL_FILE):
        return []
    with open(SKILL_FILE, "r") as f:
        return json.load(f)

# ==============================
# 保存技能
# ==============================

def save_skills(skills):
    with open(SKILL_FILE, "w") as f:
        json.dump(skills, f, indent=2)

# ==============================
# 查找相似技能
# ==============================

def search_skill(query, threshold=0.85):
    skills = load_skills()
    if not skills:
        return None

    dim = len(skills[0]["embedding"])
    index = faiss.IndexFlatIP(dim)

    vectors = np.array([s["embedding"] for s in skills])
    faiss.normalize_L2(vectors)

    index.add(vectors)

    q_vec = get_embedding(query).reshape(1, -1)
    faiss.normalize_L2(q_vec)

    D, I = index.search(q_vec, 1)

    score = D[0][0]
    idx = I[0][0]

    if score > threshold:
        return skills[idx]

    return None

# ==============================
# 添加技能（自动去重）
# ==============================

def add_skill(trigger, command, effect):
    skills = load_skills()

    # 查重
    existing = search_skill(trigger, threshold=0.92)
    if existing:
        print("⚠ 检测到重复技能，跳过保存")
        return

    emb = get_embedding(trigger)

    new_id = len(skills) + 1

    skills.append({
        "id": new_id,
        "trigger": trigger,
        "command": command,
        "effect": effect,
        "embedding": emb.tolist()
    })

    save_skills(skills)
    print("✅ 技能已保存")