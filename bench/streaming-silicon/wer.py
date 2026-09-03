#!/usr/bin/env python3
# wer.py reference.txt hypothesis.txt
import sys

def wer(ref, hyp):
    r, h = ref.split(), hyp.split()
    d = [[0]*(len(h)+1) for _ in range(len(r)+1)]
    for i in range(len(r)+1): d[i][0] = i
    for j in range(len(h)+1): d[0][j] = j
    for i in range(1, len(r)+1):
        for j in range(1, len(h)+1):
            cost = 0 if r[i-1].lower() == h[j-1].lower() else 1
            d[i][j] = min(d[i-1][j]+1, d[i][j-1]+1, d[i-1][j-1]+cost)
    return d[len(r)][len(h)] / max(len(r), 1)

ref = open(sys.argv[1]).read().strip()
hyp = open(sys.argv[2]).read().strip()
print(f"{wer(ref, hyp):.4f}")
