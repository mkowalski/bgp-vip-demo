#!/usr/bin/env python3
"""Generate drawings/bgp-vip-pr-timeline.svg from the PR data table below.

Update PRS/PHASES and re-run:  python3 drawings/gen-pr-timeline.py
Dates from:  gh api repos/<org>/<repo>/pulls/<n> --jq '[.created_at,.merged_at,.state]'
"""
import datetime as dt

TODAY = dt.date(2026, 8, 13)
START = dt.date(2026, 6, 20)
END = dt.date(2026, 8, 15)

X0, X1 = 216, 950          # plot area
Y0 = 100                   # first row
ROW = 24                   # row pitch
LABEL_X = 140

def x(d):
    return X0 + (d - START).days / (END - START).days * (X1 - X0)

# (repo-label-or-None, pr-label, opened, merged|None, state, text-side)
# state: merged | open | closed ; side: 'r' text right of bar, 'l' left
PRS = [
    ("openshift/kube-vip", "#2 #3 go/Makefile CI — fork build fixes", "2026-06-24", "2026-06-24", "merged", "r"),
    (None, "#4 Dockerfile.openshift", "2026-06-26", "2026-06-26", "merged", "r"),
    (None, "#6 route re-assert — closed: FRR fix suffices", "2026-07-14", None, "closed", "r"),
    ("kube-vip/kube-vip", "#1627 kubeconfig", "2026-07-09", "2026-07-14", "merged", "r"),
    (None, "#1636 re-assert + realm", "2026-07-15", "2026-07-21", "merged", "r"),
    (None, "#1671 backend health-check addr", "2026-08-06", "2026-08-08", "merged", "l"),
    (None, "#1675 vip_skipdad (DAD skip)", "2026-08-07", "2026-08-08", "merged", "l"),
    ("openshift/api", "#2923 gate + vipManagement", "2026-07-09", "2026-07-24", "merged", "l"),
    (None, "#2972 BGPVIPConfig CRD (TP API, draft)", "2026-08-10", None, "open", "l"),
    ("dev-scripts", "#1929 BGP ToR", "2026-07-09", "2026-07-23", "merged", "r"),
    (None, "#1939 BGP_VIP_MANAGEMENT knob", "2026-07-30", "2026-07-31", "merged", "l"),
    (None, "#1945 dual-stack v6 ToR peer + e2e optional fields", "2026-08-06", None, "open", "l"),
    ("FRRouting/frr", "#22676 zebra table-scoped fix", "2026-07-15", "2026-07-21", "merged", "r"),
    ("metallb/frr-k8s", "#470 redistribute design", "2026-07-15", None, "open", "l"),
    ("openshift/release", "#81957 kube-vip CI images", "2026-07-15", "2026-07-27", "merged", "l"),
    (None, "#82698 e2e-metal-ipi-bgp-vip lane", "2026-07-30", "2026-07-31", "merged", "l"),
    (None, "#82912 coexistence lanes + FRR-state verify", "2026-08-04", "2026-08-13", "merged", "l"),
    ("cluster-network-operator", "#3046 statusmanager fix", "2026-07-10", None, "open", "l"),
    (None, "#3047 BGP VIP support", "2026-07-10", None, "open", "l"),
    (None, "#3070 frr-k8s CRD align", "2026-07-20", "2026-07-22", "merged", "r"),
    (None, "#3089 api vendor bump", "2026-07-24", "2026-07-29", "merged", "l"),
    ("baremetal-runtimecfg", "#395 FRR peer-file rendering", "2026-07-10", "2026-08-13", "merged", "l"),
    ("ocp-build-data", "#11838 ose-kube-vip onboarding", "2026-07-15", None, "open", "l"),
    ("machine-config-operator", "#6326 BGP VIP static pods", "2026-07-22", None, "open", "l"),
    (None, "#6334 api vendor bump", "2026-07-24", "2026-07-27", "merged", "l"),
    ("openshift/installer", "#10713 rebase/vendor wave", "2026-07-24", "2026-07-28", "merged", "l"),
    (None, "#10718 BGP VIP support", "2026-07-28", None, "open", "l"),
]

PHASES = [
    ("demo development (runs 1-27)", "2026-06-22", "2026-07-06"),
    ("upstreaming wave", "2026-07-09", "2026-07-16"),
    ("api merge + vendor wave", "2026-07-20", "2026-07-29"),
    ("CI lanes", "2026-07-30", "2026-08-01"),
    ("coexistence + dual-stack", "2026-08-04", "2026-08-07"),
    ("TP API + review chase", "2026-08-08", "2026-08-13"),
]

COLORS = {
    "merged": ("#bbf7d0", "#16a34a", "#166534"),
    "open":   ("#fde68a", "#d97706", "#92400e"),
    "closed": ("#e2e8f0", "#94a3b8", "#475569"),
}

rows = len(PRS)
height = Y0 + rows * ROW + 60
out = []
out.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="{height}" viewBox="0 0 1000 {height}" font-family="Inter, Helvetica, Arial, sans-serif">')
out.append(f'<text x="500" y="28" text-anchor="middle" font-size="17" font-weight="700" fill="#1e293b">Upstreaming timeline &#8212; every PR, per repository (bar: opened &#8594; merged/today)</text>')

# week gridlines
grid_bottom = Y0 + rows * ROW - 4
d = dt.date(2026, 6, 22)
axis = []
while d <= END:
    xx = x(d)
    axis.append(f'<line x1="{xx:.0f}" y1="80" x2="{xx:.0f}" y2="{grid_bottom}" stroke="#e2e8f0" stroke-width="1"/>'
                f'<text x="{xx:.0f}" y="74" text-anchor="middle" font-size="10" fill="#64748b">{d.strftime("%b %d")}</text>')
    d += dt.timedelta(days=7)
xx = x(TODAY)
axis.append(f'<line x1="{xx:.0f}" y1="80" x2="{xx:.0f}" y2="{grid_bottom}" stroke="#dc2626" stroke-width="1" stroke-dasharray="4 3"/>'
            f'<text x="{xx:.0f}" y="{grid_bottom+14}" text-anchor="middle" font-size="10" fill="#dc2626">today</text>')
out.append("".join(axis))

# phase bands
ph = []
for name, a, b in PHASES:
    xa, xb = x(dt.date.fromisoformat(a)), x(dt.date.fromisoformat(b))
    ph.append(f'<rect x="{xa:.0f}" y="82" width="{xb-xa:.0f}" height="10" rx="3" fill="#dbeafe"/>'
              f'<text x="{(xa+xb)/2:.0f}" y="55" text-anchor="middle" font-size="10" font-weight="600" fill="#1e40af">{name}</text>')
out.append("".join(ph))

# rows
body = []
y = Y0
for repo, label, opened, merged, state, side in PRS:
    fill, stroke, tcol = COLORS[state]
    xo = x(dt.date.fromisoformat(opened))
    xe = x(dt.date.fromisoformat(merged)) if merged else x(TODAY)
    w = max(xe - xo, 10)
    if repo:
        body.append(f'<text x="{LABEL_X}" y="{y+12}" text-anchor="end" font-size="12" font-weight="600" fill="#334155">{repo}</text>')
    body.append(f'<rect x="{xo:.0f}" y="{y}" width="{w:.0f}" height="16" rx="4" fill="{fill}" stroke="{stroke}" stroke-width="1.2"/>')
    if state == "merged":
        body.append(f'<circle cx="{xe:.0f}" cy="{y+8}" r="4" fill="{stroke}"/>')
    elif state == "open":
        body.append(f'<path d="M{xe-8:.0f},{y+2} L{xe:.0f},{y+8} L{xe-8:.0f},{y+14} z" fill="{stroke}"/>')
    else:
        body.append(f'<text x="{xo+w+2:.0f}" y="{y+13}" font-size="11" fill="{stroke}">&#10005;</text>')
    if side == "r":
        tx = xo + w + (14 if state == "closed" else 8)
        body.append(f'<text x="{tx:.0f}" y="{y+13}" font-size="11" fill="{tcol}">{label}</text>')
    else:
        body.append(f'<text x="{xo-6:.0f}" y="{y+13}" text-anchor="end" font-size="11" fill="{tcol}">{label}</text>')
    y += ROW

out.append("".join(body))

ly = height - 22
out.append(f'''<g font-size="11">
 <rect x="150" y="{ly}" width="26" height="12" rx="3" fill="#bbf7d0" stroke="#16a34a"/><text x="182" y="{ly+10}" fill="#166534">merged</text>
 <rect x="250" y="{ly}" width="26" height="12" rx="3" fill="#fde68a" stroke="#d97706"/><text x="282" y="{ly+10}" fill="#92400e">open (review-gated)</text>
 <rect x="420" y="{ly}" width="26" height="12" rx="3" fill="#e2e8f0" stroke="#94a3b8"/><text x="452" y="{ly+10}" fill="#475569">closed unmerged</text>
</g>''')
out.append('</svg>')

import pathlib
path = pathlib.Path(__file__).parent / "bgp-vip-pr-timeline.svg"
path.write_text("\n".join(out) + "\n")
print(f"wrote {path} ({rows} rows, height {height})")
