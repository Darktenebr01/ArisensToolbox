"""Pure parsers for bridge sidecar data.

Kept free of UI imports so they can be unit-tested without a display.
"""
import re


def parse_enums(text):
    """Parse enums.txt (key\\tvalue\\tname lines) into the structure tabs need."""
    E = {}
    for line in text.splitlines():
        parts = line.split("\t", 2)
        if len(parts) == 3 and parts[1].lstrip("-").isdigit():
            E.setdefault(parts[0], []).append({"v": int(parts[1]), "n": parts[2]})

    def per_job(entries, strip, others=False):
        jobs = [{"labels": ["(none)"], "ids": [0]} for _ in range(10)]
        extra = []
        for ent in entries or []:
            m = re.match(r"^Job(\d\d)_", ent["n"])
            j = int(m.group(1)) if m else 0
            if 1 <= j <= 10:
                t = jobs[j - 1]
                label = re.sub(r"^Job\d\d_", "", ent["n"]) if strip else ent["n"]
                t["labels"].append(label)
                t["ids"].append(ent["v"])
            elif others and ent["v"] != 0:
                extra.append(ent)
        for t in jobs:
            for ent in extra:
                t["labels"].append("[other] " + ent["n"])
                t["ids"].append(ent["v"])
        return jobs

    data = {
        "jobsCustom": per_job(E.get("custom"), True),
        "jobsNormal": per_job(E.get("normal"), True),
        "jobsAbility": per_job(E.get("ability"), False, True),
        "customName": {e["v"]: re.sub(r"^Job\d\d_", "", e["n"]) for e in E.get("custom", [])},
        "normalName": {e["v"]: re.sub(r"^Job\d\d_", "", e["n"]) for e in E.get("normal", [])},
        "equipList": [(e["v"], e["n"]) for e in E.get("equipskill", [])],
        "equipName": {e["v"]: e["n"] for e in E.get("equipskill", [])},
        "enhLabels": [f"{e['n']} ({e['v']})" for e in E.get("enhance", [])],
        "enhVals": [e["v"] for e in E.get("enhance", [])],
        "levelLabels": [f"{e['n']} ({e['v']})" for e in E.get("level", [])],
        "levelValues": [e["v"] for e in E.get("level", [])],
    }
    if not data["levelValues"]:
        data["levelLabels"] = ["0", "1", "2"]
        data["levelValues"] = [0, 1, 2]
    return data
