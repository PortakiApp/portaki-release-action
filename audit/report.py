#!/usr/bin/env python3
"""Réduit la sortie JSON de `cargo audit` au rapport que la publication atteste.

    report.py <cargo-audit.json> <rapport.json> <seuil>

Le seuil (`critical`, `high`, `medium`, `low` ou `none`) dit à partir de quelle gravité une
vulnérabilité fait échouer : code de sortie 1, rapport écrit quand même. Les avis
informationnels (`unmaintained`, `unsound`, `notice`, `yanked`) avertissent, jamais n'échouent.

La gravité vient du vecteur CVSS 3.x de l'avis RustSec. Un avis sans vecteur (ou en CVSS 4,
que ce script ne calcule pas) est de gravité `unknown` : il avertit, faute de pouvoir dire
qu'il est critique.

`report.py --self-test` vérifie le calcul CVSS sur des scores connus.
"""

import json
import math
import os
import sys

ORDER = ["low", "medium", "high", "critical"]

WEIGHTS = {
    "AV": {"N": 0.85, "A": 0.62, "L": 0.55, "P": 0.2},
    "AC": {"L": 0.77, "H": 0.44},
    "UI": {"N": 0.85, "R": 0.62},
    "CIA": {"H": 0.56, "L": 0.22, "N": 0.0},
}


def roundup(value):
    """Arrondi supérieur au dixième, tel que la spécification CVSS 3.1 le définit."""
    scaled = int(round(value * 100000))
    if scaled % 10000 == 0:
        return scaled / 100000.0
    return (math.floor(scaled / 10000) + 1) / 10.0


def cvss3_score(vector):
    """Score de base d'un vecteur `CVSS:3.x/…`, ou None s'il n'en est pas un."""
    if not isinstance(vector, str) or not vector.startswith("CVSS:3."):
        return None
    try:
        metrics = dict(part.split(":", 1) for part in vector.split("/")[1:])
        changed = metrics["S"] == "C"
        pr = {"N": 0.85, "L": 0.68 if changed else 0.62, "H": 0.5 if changed else 0.27}[metrics["PR"]]
        c, i, a = (WEIGHTS["CIA"][metrics[k]] for k in ("C", "I", "A"))
        iss = 1 - (1 - c) * (1 - i) * (1 - a)
        impact = 7.52 * (iss - 0.029) - 3.25 * (iss - 0.02) ** 15 if changed else 6.42 * iss
        exploitability = (
            8.22 * WEIGHTS["AV"][metrics["AV"]] * WEIGHTS["AC"][metrics["AC"]] * pr * WEIGHTS["UI"][metrics["UI"]]
        )
    except (KeyError, ValueError):
        return None
    if impact <= 0:
        return 0.0
    total = 1.08 * (impact + exploitability) if changed else impact + exploitability
    return roundup(min(total, 10))


def severity(score):
    if score is None:
        return "unknown"
    if score >= 9.0:
        return "critical"
    if score >= 7.0:
        return "high"
    if score >= 4.0:
        return "medium"
    return "low"


def blocks(level, threshold):
    return threshold in ORDER and level in ORDER and ORDER.index(level) >= ORDER.index(threshold)


def reduce(raw, threshold):
    vulnerabilities = []
    for item in (raw.get("vulnerabilities") or {}).get("list") or []:
        advisory = item.get("advisory") or {}
        if advisory.get("withdrawn"):
            continue
        score = cvss3_score(advisory.get("cvss"))
        package = item.get("package") or {}
        vulnerabilities.append(
            {
                "id": advisory.get("id", ""),
                "package": package.get("name", ""),
                "version": package.get("version", ""),
                "severity": severity(score),
                "score": score,
                "title": advisory.get("title", ""),
            }
        )
    warnings = []
    for kind, items in (raw.get("warnings") or {}).items():
        for item in items or []:
            advisory = item.get("advisory") or {}
            package = item.get("package") or {}
            warnings.append(
                {
                    "id": advisory.get("id", ""),
                    "package": package.get("name", ""),
                    "version": package.get("version", ""),
                    "kind": item.get("kind") or kind,
                    "title": advisory.get("title", "") or kind,
                }
            )
    counts = {level: 0 for level in ORDER + ["unknown"]}
    for vulnerability in vulnerabilities:
        counts[vulnerability["severity"]] += 1
    counts["warnings"] = len(warnings)
    database = raw.get("database") or {}
    return {
        "schema": "portaki.cargo-audit/v1",
        "tool": "cargo-audit",
        "toolVersion": os.environ.get("CARGO_AUDIT_VERSION", ""),
        "database": {"lastCommit": database.get("last-commit", ""), "lastUpdated": database.get("last-updated", "")},
        "dependencies": (raw.get("lockfile") or {}).get("dependency-count", 0),
        "failOn": threshold,
        "counts": counts,
        "vulnerabilities": vulnerabilities,
        "warnings": warnings,
    }


def self_test():
    assert cvss3_score("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H") == 9.8
    assert cvss3_score("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:H/A:H") == 9.1
    assert cvss3_score("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:L/A:N") == 5.3
    assert cvss3_score("CVSS:3.1/AV:N/AC:L/PR:L/UI:N/S:C/C:H/I:H/A:H") == 9.9
    assert cvss3_score("CVSS:3.1/AV:L/AC:H/PR:H/UI:R/S:U/C:N/I:N/A:N") == 0.0
    assert cvss3_score("CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H/SC:N/SI:N/SA:N") is None
    assert cvss3_score(None) is None
    assert blocks("critical", "critical") and not blocks("high", "critical")
    assert blocks("high", "medium") and not blocks("unknown", "low") and not blocks("critical", "none")
    raw = {
        "vulnerabilities": {
            "list": [
                {"advisory": {"id": "A", "cvss": "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"}, "package": {"name": "p"}},
                {"advisory": {"id": "B", "cvss": None}, "package": {"name": "q"}},
                {"advisory": {"id": "C", "withdrawn": "2024-01-01"}, "package": {"name": "r"}},
            ]
        },
        "warnings": {"unmaintained": [{"kind": "unmaintained", "advisory": {"id": "D"}, "package": {"name": "s"}}]},
    }
    report = reduce(raw, "critical")
    assert report["counts"] == {"low": 0, "medium": 0, "high": 0, "critical": 1, "unknown": 1, "warnings": 1}
    print("report.py: self-test passed")


def main(argv):
    if argv[1:] == ["--self-test"]:
        self_test()
        return 0
    source, target, threshold = argv[1], argv[2], argv[3]
    if threshold not in ORDER + ["none"]:
        print(f"::error::audit-fail-on must be one of {', '.join(ORDER + ['none'])}, not '{threshold}'")
        return 2
    with open(source, encoding="utf-8") as handle:
        raw = json.load(handle)
    report = reduce(raw, threshold)
    with open(target, "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2)

    blocking = [v for v in report["vulnerabilities"] if blocks(v["severity"], threshold)]
    for vulnerability in report["vulnerabilities"]:
        level = "error" if vulnerability in blocking else "warning"
        score = "" if vulnerability["score"] is None else f", CVSS {vulnerability['score']}"
        print(
            f"::{level} title={vulnerability['id']}::{vulnerability['package']} {vulnerability['version']} — "
            f"{vulnerability['title']} ({vulnerability['severity']}{score})"
        )
    for warning in report["warnings"]:
        print(f"::warning title={warning['id'] or warning['kind']}::{warning['package']} {warning['version']} — {warning['kind']}")
    counts = report["counts"]
    print(
        f"cargo audit: {counts['critical']} critical, {counts['high']} high, {counts['medium']} medium, "
        f"{counts['low']} low, {counts['unknown']} without score, {counts['warnings']} warnings "
        f"(fails on: {threshold})"
    )
    return 1 if blocking else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
