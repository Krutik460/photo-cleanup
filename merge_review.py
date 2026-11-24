"""Validate Haiku's answers and convert them into per-photo picks for the review page.

Reads <out>/review_batches/*.json and the matching <out>/review_raw/*.json answers, and writes
<out>/haiku/<batch>.json as {photoId: {"state": "fav" | "keep" | "remove", "why": "..."}}.

Safety rules: a group whose answer is missing, malformed, or has no favorite is left out entirely
(the on-device pick stays). Any photo the answer does not mention is kept, never removed. A group
with you in it always keeps at least one photo of you.

Usage: python3 merge_review.py <out-folder>
"""

import json
import os
import sys


def numbers(value):
    out = set()
    for v in value or []:
        try:
            out.add(str(int(v)))
        except (TypeError, ValueError):
            pass
    return out


def main(out):
    out = os.path.realpath(out)
    bdir = os.path.join(out, "review_batches")
    problems, written, missing = [], 0, []
    for name in sorted(os.listdir(bdir)):
        batch = json.load(open(os.path.join(bdir, name)))
        try:
            raw = json.load(open(batch["output"]))
        except FileNotFoundError:
            missing.append(batch["name"])
            continue
        except json.JSONDecodeError as e:
            problems.append(f"{batch['name']}: invalid JSON ({e})")
            continue
        picks = {}
        for g in batch["groups"]:
            ans = raw.get(g["group"])
            if not isinstance(ans, dict):
                problems.append(f"{batch['name']}/{g['group']}: no answer")
                continue
            valid = set(g["members"])
            fav, keep, remove = numbers(ans.get("fav")) & valid, numbers(ans.get("keep")) & valid, numbers(ans.get("remove")) & valid
            if not fav:
                problems.append(f"{batch['name']}/{g['group']}: no favorite")
                continue
            you = {str(n) for n in g.get("you", [])}
            if you and not (fav | keep) & you:
                # Never let a review drop every photo of you: the on-device best shot of you stays.
                best_you = min(you, key=int)
                fav.add(best_you)
                problems.append(f"{batch['name']}/{g['group']}: answer kept no photo of you; kept #{best_you}")
            keep -= fav
            remove -= fav | keep
            notes = ans.get("notes") if isinstance(ans.get("notes"), dict) else {}
            for num, pid in g["members"].items():
                if num in fav:
                    picks[pid] = {"state": "fav", "why": str(notes.get(num) or ans.get("why") or "")[:200]}
                elif num in remove:
                    picks[pid] = {"state": "remove"}
                else:
                    picks[pid] = {"state": "keep", "why": str(notes.get(num) or "")[:200]}
        path = os.path.join(out, "haiku", batch["name"] + ".json")
        with open(path + ".tmp", "w") as f:
            json.dump(picks, f, indent=1)
        os.replace(path + ".tmp", path)
        written += 1
    print(f"merged {written} batches; {len(missing)} without an answer yet; {len(problems)} problems")
    for m in missing:
        print("  missing:", m)
    for p in problems:
        print("  problem:", p)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
