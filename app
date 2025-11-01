# app.py
import json
import os
import re
from pathlib import Path
from typing import Dict, List, Tuple, Set

from flask import Flask, request, jsonify
from flask_cors import CORS


app = Flask(__name__)
CORS(app)


EDU_MAP = {
    "nenhum": 0,
    "fundamental": 0,         
    "ensino medio": 1,        
    "ensino médio": 1,
    "superior incompleto": 2,
    "graduacao incompleta": 2,  
    "graduação incompleta": 2,
    "superior completo": 3,
    "graduacao completa": 3,   
    "graduação completa": 3,
    "pós-graduação": 4,
    "pos-graduacao": 4,         
    "pos graduação": 4,
    "mestrado": 5,
    "doutorado": 6,
}

CATALOG_SKILLS = [
    "full stack", "sql", "suporte", "python", "java", "react",
    "angular", "javascript", "c#", "aws", "docker", "git", "scrum",
]


def _normalize(txt: str) -> str:
    """
    Normaliza texto para matching simples:
      - lower
      - troca acentos comuns
      - remove duplicidades de espaços
    """
    txt = (txt or "").lower()

   
    repl = (
        ("á", "a"), ("ã", "a"), ("â", "a"), ("à", "a"),
        ("é", "e"), ("ê", "e"),
        ("í", "i"),
        ("ó", "o"), ("õ", "o"), ("ô", "o"),
        ("ú", "u"),
        ("ç", "c"),
    )
    for a, b in repl:
        txt = txt.replace(a, b)

    txt = re.sub(r"\s+", " ", txt).strip()
    return txt


def read_profiles(filename: str = "profiles.json") -> List[Dict]:
    """
    Lê o dataset de perfis:
      - se 'filename' for relativo, resolve ao lado do app.py
      - trata erros de arquivo/JSON e retorna lista vazia em caso de falha
    """
    base_dir = Path(__file__).parent
    file_path = Path(filename)
    if not file_path.is_absolute():
        file_path = base_dir / file_path

    try:
        with file_path.open("r", encoding="utf-8") as fh:
            data = json.load(fh)
            if isinstance(data, list):
                return data
            print(f"[read_profiles] JSON não é lista em {file_path}")
            return []
    except FileNotFoundError:
        print(f"[read_profiles] arquivo não encontrado: {file_path}")
        return []
    except json.JSONDecodeError as exc:
        print(f"[read_profiles] JSON inválido em {file_path}: {exc}")
        return []
    except Exception as exc:
        print(f"[read_profiles] erro ao abrir {file_path}: {exc}")
        return []



def extract_requirements(raw_text: str) -> Dict:
    """
    Extrai requisitos a partir de texto livre da vaga:
      - skills (conjunto)
      - experience (anos, int)
      - education (string canônica de EDU_MAP; se nada encontrado -> 'nenhum')
    """
    text = _normalize(raw_text)

    
    found_skills: Set[str] = {s for s in CATALOG_SKILLS if s in text}

    
    exp_years = 0
    m = re.search(r"\b(\d+)\s*\+?\s*an(?:o|os)\b", text)
    if m:
        try:
            exp_years = int(m.group(1))
        except ValueError:
            exp_years = 0

    
    chosen_edu_label = "nenhum"
    chosen_edu_level = 0
    for label, lvl in EDU_MAP.items():
        if label in text and lvl > chosen_edu_level:
            chosen_edu_label = label
            chosen_edu_level = lvl

    return {
        "skills": found_skills,
        "experience": exp_years,
        "education": chosen_edu_label,
    }



def score_profile(profile: Dict, reqs: Dict) -> Tuple[int, str]:
    """
    Regras:
      - +1 ponto por cada skill coincidente
      - +1 ponto se experiência do perfil >= requerida (se houver requisito)
      - +1 ponto se escolaridade do perfil >= requerida (se houver requisito)
    Retorna: (score_total, justificativa_textual)
    """
    total = 0
    notes: List[str] = []

    prof_skills = {_normalize(s) for s in profile.get("skills", [])}
    prof_exp = int(profile.get("experience_years", 0))

    prof_edu_raw = _normalize(profile.get("education_level", ""))
    prof_edu_level = EDU_MAP.get(prof_edu_raw, 0)

    req_skills = set(reqs.get("skills", set()))
    req_exp = int(reqs.get("experience", 0))
    req_edu_level = EDU_MAP.get(_normalize(reqs.get("education", "nenhum")), 0)

   
    overlap = prof_skills & req_skills
    skill_points = len(overlap)
    total += skill_points

    if skill_points > 0:
        notes.append(f"Skills compatíveis (+{skill_points}): {', '.join(sorted(overlap))}.")
    elif req_skills:
        notes.append("Nenhuma skill compatível (0).")
    else:
        notes.append("A vaga não especificou skills obrigatórias.")

    
    if req_exp > 0:
        if prof_exp >= req_exp:
            total += 1
            notes.append(f"Experiência compatível (+1). Possui {prof_exp} ano(s); requer {req_exp}.")
        else:
            notes.append(f"Experiência abaixo (0). Possui {prof_exp} ano(s); requer {req_exp}.")
    else:
        notes.append(f"Experiência não foi requisito expresso (perfil: {prof_exp} ano[s]).")

   
    if req_edu_level > 0:
        if prof_edu_level >= req_edu_level:
            total += 1
            notes.append("Escolaridade compatível (+1).")
        else:
            notes.append("Escolaridade abaixo (0).")
    else:
        notes.append("Escolaridade não foi requisito expresso.")

    return total, " ".join(notes)



@app.route("/", methods=["GET"])
def home():
    
    return (
        "<h3>API de análise de perfis</h3>"
        "<p>Faça POST em <code>/analyze_text</code> com JSON "
        "<code>{\"description\": \"texto da vaga\"}</code>.</p>"
        "<p>Ex.: superior completo, 3 anos, Python, React, SQL, Docker, Git.</p>"
    )


@app.route("/analyze_text", methods=["POST"])
def analyze_text():
    """
    Aceita:
      - JSON: {'description': '...'}  (também aceita 'descricao' ou 'vaga')
      - Form:  description/descricao/vaga
      - Query: description/descricao/vaga (apenas para debug rápido)
    Retorna top-5 perfis ordenados por score desc.
    """
    
    payload = request.get_json(silent=True) or {}
    if not isinstance(payload, dict):
        payload = {}

    job_description = (
        payload.get("description")
        or payload.get("descricao")
        or payload.get("vaga")
        or request.form.get("description")
        or request.form.get("descricao")
        or request.form.get("vaga")
        or request.args.get("description")
        or request.args.get("descricao")
        or request.args.get("vaga")
        or ""
    )
    job_description = job_description.strip()

    if not job_description:
        return jsonify({
            "error": "A descrição da vaga não foi enviada.",
            "exemplo_json": {"description": "Dev full stack, 3 anos, superior completo, Python, React, SQL."}
        }), 400

    
    reqs = extract_requirements(job_description)

    
    dataset_path = os.getenv("DATASET_PATH", "profiles.json")
    profiles = read_profiles(dataset_path)
    if not profiles:
        return jsonify({"error": f"Não foi possível carregar perfis do dataset '{dataset_path}'."}), 500

   
    ranked = []
    for p in profiles:
        score, why = score_profile(p, reqs)
        ranked.append({
            "name": p.get("name"),
            "url": p.get("url"),
            "score": score,
            "justification": why,
        })

    ranked.sort(key=lambda r: r["score"], reverse=True)

    
    if request.args.get("debug") == "1":
        return jsonify({
            "parsed_requirements": reqs,
            "top5": ranked[:5]
        })

    return jsonify(ranked[:5])



if __name__ == "__main__":
    # Porta fixa 5000 para manter compatibilidade
    app.run(debug=True, port=5000)
