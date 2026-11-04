#!/usr/bin/env python3
"""Renders docs/diagrams/wealthwise-architecture.gif  (pip install pillow; python3 scripts/make-architecture-gif.py)"""
import math, os
from PIL import Image, ImageDraw, ImageFont

W, H, S = 1280, 720, 2                      # final size, supersample factor
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "diagrams", "wealthwise-architecture.gif")

PAPER, SURFACE, INK, INK2, RULE = "#edf0f2", "#f8f9fa", "#0f1e2e", "#44566a", "#cbd4db"
ACCENT, EVENT, RESP, LINE, GLOW = "#2b4bd6", "#b86e00", "#17695d", "#8ea0b1", "#e4e9fb"

def font(names, size):
    for n in names:
        for d in ("/usr/share/fonts/truetype/dejavu/", "/usr/share/fonts/truetype/liberation/", "/Library/Fonts/", "C:/Windows/Fonts/"):
            p = os.path.join(d, n)
            if os.path.exists(p):
                return ImageFont.truetype(p, size * S)
    return ImageFont.load_default()

SANS = ["DejaVuSans.ttf", "LiberationSans-Regular.ttf", "arial.ttf"]
SANSB = ["DejaVuSans-Bold.ttf", "LiberationSans-Bold.ttf", "arialbd.ttf"]
SERIFB = ["DejaVuSerif-Bold.ttf", "LiberationSerif-Bold.ttf", "timesbd.ttf"]
f_title, f_name, f_sub = font(SERIFB, 30), font(SANSB, 17), font(SANS, 13)
f_cap, f_cap2, f_small = font(SANSB, 21), font(SANS, 15), font(SANS, 13)

NODES = {  # key: (x0, y0, x1, y1, title, subtitle)
    "browser":  (40, 285, 200, 365, "Browser", "Angular SPA"),
    "ingress":  (255, 285, 375, 365, "Ingress", "ingress-nginx"),
    "web":      (410, 285, 550, 365, "Web \u00d72", "nginx + Angular"),
    "kong":     (585, 285, 735, 365, "Kong", "key-auth \u00b7 rate limit"),
    "api":      (770, 270, 940, 380, "API", ".NET 10 \u00b7 EF Core"),
    "queue":    (1030, 270, 1200, 380, "Queue", "SQS API \u00b7 ElasticMQ"),
    "db":       (770, 470, 940, 560, "PostgreSQL", "StatefulSet \u00b7 PVC"),
    "consumer": (1030, 470, 1200, 560, "Event consumer", "hosted service in API"),
}
ARROWS = [("browser", "ingress"), ("ingress", "web"), ("web", "kong"), ("kong", "api"),
          ("api", "queue"), ("api", "db"), ("queue", "consumer"), ("consumer", "db")]

def c(k):
    x0, y0, x1, y1 = NODES[k][:4]; return ((x0 + x1) / 2, (y0 + y1) / 2)

def P(*keys): return [c(k) for k in keys]
STEPS = [  # path, color, caption, start frame, end frame
    (P("browser", "ingress"), ACCENT, "Advisor submits a trade in the Angular app", 0, 8),
    (P("ingress", "web"), ACCENT, "ingress-nginx routes the request to the web service", 8, 16),
    (P("web", "kong"), ACCENT, "nginx adds the API key server-side and forwards /api", 16, 24),
    (P("kong", "api"), ACCENT, "Kong checks the key, rate-limits, adds a correlation id", 24, 32),
    (P("api", "db"), ACCENT, "The domain model enforces trade rules; PostgreSQL commits", 32, 41),
    (P("api", "queue"), EVENT, "After commit, trade.executed is published to the queue", 41, 50),
    (P("queue", "consumer"), EVENT, "The consumer receives the event (at-least-once delivery)", 50, 59),
    (P("consumer", "db"), EVENT, "Idempotent audit write: a duplicate delivery is ignored", 59, 68),
]
RESPONSE = (P("api", "kong", "web", "ingress", "browser"), RESP, 41, 68)
TOTAL, HOLD_CAPTION = 78, "Trade committed, event audited, 201 Created returned"

def ease(t): t = max(0, min(1, t)); return t * t * (3 - 2 * t)

def along(path, t):
    segs = [math.dist(path[i], path[i + 1]) for i in range(len(path) - 1)]
    d = t * sum(segs)
    for i, L in enumerate(segs):
        if d <= L or i == len(segs) - 1:
            u = 0 if L == 0 else min(1, d / L)
            return (path[i][0] + (path[i + 1][0] - path[i][0]) * u, path[i][1] + (path[i + 1][1] - path[i][1]) * u)
        d -= L

def mix(h1, h2, t):
    a = [int(h1[i:i + 2], 16) for i in (1, 3, 5)]; b = [int(h2[i:i + 2], 16) for i in (1, 3, 5)]
    return "#%02x%02x%02x" % tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))

def s(v): return v * S

def text_c(d, xy, txt, fnt, fill):
    d.text((s(xy[0]), s(xy[1])), txt, font=fnt, fill=fill, anchor="mm")

def dashed_rect(d, box, color, width, dash=10, gap=7):
    x0, y0, x1, y1 = box
    for (ax, ay, bx, by) in ((x0, y0, x1, y0), (x1, y0, x1, y1), (x1, y1, x0, y1), (x0, y1, x0, y0)):
        L = math.dist((ax, ay), (bx, by)); n = int(L // (dash + gap)) + 1
        for i in range(n):
            a = i * (dash + gap) / L; b = min(1, (i * (dash + gap) + dash) / L)
            d.line([(s(ax + (bx - ax) * a), s(ay + (by - ay) * a)), (s(ax + (bx - ax) * b), s(ay + (by - ay) * b))], fill=color, width=s(width))

def arrow(d, a, b, color, width=2):
    d.line([(s(a[0]), s(a[1])), (s(b[0]), s(b[1]))], fill=color, width=s(width))
    ang = math.atan2(b[1] - a[1], b[0] - a[0]); L = 9
    pts = [(b[0], b[1]), (b[0] - L * math.cos(ang - .45), b[1] - L * math.sin(ang - .45)), (b[0] - L * math.cos(ang + .45), b[1] - L * math.sin(ang + .45))]
    d.polygon([(s(x), s(y)) for x, y in pts], fill=color)

def edge_points(k1, k2):
    (x0, y0, x1, y1) = NODES[k1][:4]; (u0, v0, u1, v1) = NODES[k2][:4]
    c1, c2 = c(k1), c(k2)
    if abs(c1[1] - c2[1]) < 1:
        if c2[0] > c1[0]: return (x1 + 4, c1[1]), (u0 - 4, c2[1])
        return (x0 - 4, c1[1]), (u1 + 4, c2[1])
    return (c1[0], y1 + 4), (c2[0], v0 - 4)

def node(d, k, active):
    x0, y0, x1, y1, t, sub = NODES[k]
    d.rounded_rectangle([s(x0), s(y0), s(x1), s(y1)], radius=s(10), fill=GLOW if active else SURFACE,
                        outline=ACCENT if active else RULE, width=s(3 if active else 2))
    text_c(d, ((x0 + x1) / 2, (y0 + y1) / 2 - 10), t, f_name, INK)
    text_c(d, ((x0 + x1) / 2, (y0 + y1) / 2 + 13), sub, f_sub, INK2)

def background():
    im = Image.new("RGB", (s(W), s(H)), PAPER); d = ImageDraw.Draw(im)
    d.text((s(40), s(34)), "WealthWise architecture", font=f_title, fill=INK, anchor="lm")
    d.text((s(40), s(66)), "Runtime view on Kubernetes (kind) \u00b7 browser entry point http://localhost:8080", font=f_cap2, fill=INK2, anchor="lm")
    for i, (col, lab) in enumerate(((ACCENT, "request"), (EVENT, "async event"), (RESP, "response"))):
        x = 800 + i * 150
        d.ellipse([s(x), s(28), s(x + 16), s(44)], fill=col); d.text((s(x + 24), s(36)), lab, font=f_small, fill=INK2, anchor="lm")
    dashed_rect(d, (225, 100, 1255, 600), INK2, 2)
    d.text((s(243), s(122)), "kind cluster", font=f_name, fill=INK2, anchor="lm")
    d.text((s(243), s(144)), "only the ingress is reachable from outside", font=f_small, fill=INK2, anchor="lm")
    for a, b in ARROWS:
        p, q = edge_points(a, b); arrow(d, p, q, LINE)
    text_c(d, (227, 268), "localhost:8080", f_small, ACCENT)
    text_c(d, (985, 312), "publish", f_small, INK2)
    text_c(d, (855 + 40, 425), "read / write", f_small, INK2)
    text_c(d, (1115 + 28, 425), "consume", f_small, INK2)
    text_c(d, (985, 502), "audit", f_small, INK2)
    d.text((s(40), s(692)), "Delivery:  Jira  \u2192  GitHub PR  \u2192  Actions CI  \u2192  images  \u2192  Octopus  \u2192  kubectl apply",
           font=f_small, fill=INK2, anchor="lm")
    d.text((s(1240), s(692)), "Docker Compose ports: web 4200 \u00b7 Kong 8800 \u00b7 API 5080", font=f_small, fill=INK2, anchor="rm")
    return im

BG = background()

def packets(f):
    out = []
    for path, col, cap, a, b in STEPS:
        if a <= f < b + 3: out.append((path, col, ease((f - a) / (b - a)), a <= f < b))
    pth, col, a, b = RESPONSE
    if a <= f < b + 3: out.append((pth, col, ease((f - a) / (b - a)), a <= f < b))
    return out

def frame(f):
    im = BG.copy(); d = ImageDraw.Draw(im)
    pk = packets(f)
    centers = [along(path, t) for path, col, t, live in pk if live]
    for k, (x0, y0, x1, y1, *_) in NODES.items():
        active = any(x0 - 6 <= px <= x1 + 6 and y0 - 6 <= py <= y1 + 6 for px, py in centers)
        node(d, k, active)
    def in_node(x, y):
        return any(n[0] <= x <= n[2] and n[1] <= y <= n[3] for n in (v[:4] for v in NODES.values()))

    # Packets hide while inside a node (the node glows instead), so labels stay readable.
    for path, col, t, live in pk:
        if not live: continue
        for j, (back, fade) in enumerate(((0.07, .55), (0.045, .35), (0.022, .15))):
            tx, ty = along(path, max(0, t - back)); r = 8 - j
            if in_node(tx, ty): continue
            d.ellipse([s(tx - r), s(ty - r), s(tx + r), s(ty + r)], fill=mix(col, PAPER, 1 - fade))
        x, y = along(path, t)
        if in_node(x, y): continue
        d.ellipse([s(x - 11), s(y - 11), s(x + 11), s(y + 11)], fill="white")
        d.ellipse([s(x - 8), s(y - 8), s(x + 8), s(y + 8)], fill=col)
    live = [st for st in STEPS if st[3] <= f < st[4]]
    cap = live[-1][2] if live else HOLD_CAPTION
    col = live[-1][1] if live else INK
    d.rounded_rectangle([s(40), s(622), s(1240), s(668)], radius=s(8), fill=SURFACE, outline=RULE, width=s(2))
    d.rectangle([s(40), s(622), s(48), s(668)], fill=col)
    d.text((s(64), s(645)), cap, font=f_cap, fill=INK, anchor="lm")
    if RESPONSE[2] <= f < RESPONSE[3] and f < 59:
        d.text((s(1224), s(645)), "in parallel: 201 Created returns", font=f_cap2, fill=RESP, anchor="rm")
    return im.resize((W, H), Image.LANCZOS)

def main():
    frames = [frame(i) for i in range(TOTAL)]
    sample = Image.new("RGB", (W, H * 3))
    for i, idx in enumerate((0, 30, 55)): sample.paste(frames[idx], (0, H * i))
    pal = sample.quantize(colors=64, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    q = [fr.quantize(palette=pal, dither=Image.Dither.NONE) for fr in frames]
    durations = [70] * TOTAL; durations[-1] = 1400
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    q[0].save(OUT, save_all=True, append_images=q[1:], duration=durations, loop=0, optimize=True, disposal=1)
    for n, i in (("a", 5), ("b", 45), ("c", 77)):
        frames[i].save("/tmp/preview_%s.png" % n)
    print("wrote", os.path.abspath(OUT), os.path.getsize(OUT) // 1024, "KB")

if __name__ == "__main__":
    main()
