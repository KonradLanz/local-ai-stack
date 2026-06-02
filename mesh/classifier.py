"""
mesh/classifier.py — Task type classifier
Classifies an incoming prompt into a task_type used for routing.
No external model needed: keyword scoring + character heuristics.
Copyright 2026 GrEEV.com KG

Task types: code, anonymize, summarize, translate, rag, chat,
            classify, ipr-screen
"""

import re
from typing import Optional

# Keyword → task_type signal maps. Each entry: (pattern, task_type, weight)
_SIGNALS = [
    # code
    (r"```[a-z]*\n",              "code", 3.0),
    (r"\bdef \w+\(",              "code", 2.5),
    (r"\bfunction \w+\(",         "code", 2.5),
    (r"\bclass \w+[:(]",          "code", 2.0),
    (r"\b(bug|error|exception|traceback|stacktrace|debug)\b", "code", 1.5),
    (r"\b(python|javascript|typescript|rust|golang|java|swift|bash|powershell)\b", "code", 1.0),
    (r"\b(refactor|implement|write a function|unit test)\b", "code", 1.5),

    # anonymize
    (r"\b(anonymi[sz]e|redact|gdpr|pii|personal data|remove names?)\b", "anonymize", 3.0),
    (r"\b(replace|mask).{0,20}(name|email|phone|address)\b",            "anonymize", 2.0),

    # summarize
    (r"\b(summarize|summary|tldr|tl;dr|key points?|bullet points?)\b",  "summarize", 2.5),
    (r"\b(shorten|condense|brief|overview)\b",                          "summarize", 1.5),

    # translate
    (r"\b(translate|translation|übersetze?|tradui[st])\b",              "translate", 3.0),
    (r"\b(from (english|german|french|spanish|italian|japanese|chinese) to)\b", "translate", 2.5),

    # rag
    (r"\b(according to|based on|in the document|in the pdf|the report says)\b", "rag", 2.0),
    (r"\b(find in|search|look up|retrieve)\b",                                 "rag", 1.0),

    # classify
    (r"\b(classify|categorize?|label|sentiment|positive|negative|neutral)\b",  "classify", 2.0),
    (r"\b(is this|which category|what type)\b",                                "classify", 1.0),

    # ipr-screen (internal use — prompts that might contain sensitive IP)
    (r"\b(patent|invention|trade secret|confidential|proprietary|nda)\b",      "ipr-screen", 3.0),
]

_COMPILED = [(re.compile(p, re.IGNORECASE), t, w) for p, t, w in _SIGNALS]


def classify(prompt: str) -> dict:
    """
    Returns: {
        "task_type": str,
        "confidence": float (0.0-1.0),
        "scores": {task_type: score, ...}
    }
    """
    scores: dict[str, float] = {}
    for pattern, task_type, weight in _COMPILED:
        if pattern.search(prompt):
            scores[task_type] = scores.get(task_type, 0.0) + weight

    if not scores:
        return {"task_type": "chat", "confidence": 0.5, "scores": {}}

    top_type  = max(scores, key=lambda k: scores[k])
    top_score = scores[top_type]
    total     = sum(scores.values())
    confidence = min(top_score / max(total, 1.0), 1.0)

    return {"task_type": top_type, "confidence": confidence, "scores": scores}
