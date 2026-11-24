You are reviewing groups of personal photos to help clean up a photo library. Each group holds shots
that an on-device model judged to be the same people in a similar pose (bursts, retakes, duplicates).

Batch file: {BATCH}

Read the batch file. For each group, open its contact sheet image(s) listed in `sheets` with the Read
tool. Every photo on a sheet has a red number badge. Look at all photos of the group, then decide for
every number:

- fav: the best shot of the group. Judge like a careful person choosing which photo to keep:
  everyone's eyes open, faces sharp and in focus, natural expressions and smiles, nobody cut off or
  blocked, no motion blur, good exposure and framing. Faces matter more than background.
  Usually exactly one fav per group. Pick two only if both are excellent and clearly different
  (for example a different expression worth keeping).
- keep: the photo shows something the fav does not: different people, a clearly different pose,
  expression, scene or moment. Also keep when the photo is not really a repeat of the fav at all.
- remove: a near-repeat of the fav that adds nothing: blurrier, eyes closed, worse expression, worse
  framing, darker, a lower-quality copy, OR simply a near-identical copy. The goal is to clean up the
  library, so do NOT keep near-identical shots "as a backup": if two shots are about equally good and
  nearly the same, pick one as fav and remove the other.

`suggested_fav` is the on-device model's guess (photo 1). Treat it as a hint only.

The library owner wants to keep more photos of themself and clean up everything else aggressively.
`you` lists the photo numbers that contain the owner (blue "YOU" badge on the sheet; face recognition
already ran, do not second-guess it):
- If any photo in the group has YOU, the fav must be a YOU photo: judge it mainly by the owner's face
  (eyes open, sharp, good expression), then everyone else. You may also keep ONE more YOU photo when it
  is good and clearly different (other expression or pose). Other YOU photos are remove.
- If no photo has YOU, be strict: exactly one fav, everything else remove unless it is clearly a
  different moment worth having.

Write ONE JSON file to the batch's `output` path with the Write tool, keyed by group id:

{"g12": {"fav": [2], "keep": [5], "remove": [1, 3, 4],
         "why": "Everyone's eyes open and smiling; sharpest of the burst.",
         "notes": {"5": "Different pose, both kids facing camera."}},
 "g13": {...}}

Every number of every group must appear in exactly one of fav / keep / remove. "why" is one short
sentence (max 20 words) about the fav. "notes" is optional, only for keep photos. Write valid JSON only
and do not modify any other file. When done, reply with one line: groups reviewed, photos marked remove.
