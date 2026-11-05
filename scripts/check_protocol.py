#!/usr/bin/env python3
"""Vérifie que la montre (Kotlin) et l'iPhone (Swift) parlent le même protocole.
Échoue (code 1) à la moindre incohérence, ce qui bloque la publication."""
import re
import sys

kt = open("wear/app/src/main/java/fr/nino/watchlink/HeartRateService.kt", encoding="utf-8").read()
sw = open("ios/WatchLink/HeartRateManager.swift", encoding="utf-8").read()
errors = []

cmds = {n: int(v, 16) for n, v in re.findall(r"const val (CMD_[A-Z_]+) = 0x([0-9A-Fa-f]+)", kt)}
events = {n: int(v, 16) for n, v in re.findall(r"const val (EVENT_[A-Z_]+) = 0x([0-9A-Fa-f]+)", kt)}

# 1. Les octets sont signés en Kotlin : le dispatcher doit les convertir en non signé
m = re.search(r"when \(value\.firstOrNull\(\)([^\n]*)\)", kt)
if not m or "0xFF" not in m.group(1):
    errors.append("handleCommand compare un octet signé : les commandes >= 0x80 seraient ignorées")

# 2. Chaque commande déclarée a une branche
for name in cmds:
    if not re.search(rf"\b{name}\s*->", kt):
        errors.append(f"{name} est déclarée mais jamais traitée")

# 3. Les valeurs sont uniques
for table, label in ((cmds, "commande"), (events, "événement")):
    seen = {}
    for n, v in table.items():
        if v in seen:
            errors.append(f"{label} 0x{v:02X} utilisée par {seen[v]} et {n}")
        seen[v] = n

# 4. Chaque commande envoyée par l'iPhone existe côté montre
sent = {int(v, 16) for v in re.findall(r"write\(\[0x([0-9A-Fa-f]{2})", sw)}
sent |= {int(v, 16) for v in re.findall(r"var bytes: \[UInt8\] = \[0x([0-9A-Fa-f]{2})\]", sw)}
sent |= {int(v, 16) for v in re.findall(r"write\(\[(0x[0-9A-Fa-f]{2}),", sw) if False}
known = set(cmds.values())
for v in sorted(sent):
    if v not in known:
        errors.append(f"l'iPhone envoie la commande 0x{v:02X} que la montre ne connaît pas")

# 5. Chaque événement lu par l'iPhone existe côté montre
read = {int(v, 16) for v in re.findall(r"kind == 0x([0-9A-Fa-f]{2})", sw)}
for v in sorted(read):
    if v not in set(events.values()):
        errors.append(f"l'iPhone lit l'événement 0x{v:02X} que la montre n'envoie pas")
for n, v in events.items():
    if v not in read and n != "EVENT_PHONE_ALERT":
        errors.append(f"{n} est envoyé par la montre mais jamais lu par l'iPhone")

# 6. Taille minimale exigée par l'iPhone <= taille réellement envoyée par la montre
sizes = {"EVENT_STEPS": 5, "EVENT_WORN": 2, "EVENT_PHONE_ALERT": 2, "EVENT_INFO": 13,
         "EVENT_REMOTE": 2, "EVENT_MODEL": 2, "EVENT_VERSION": 2, "EVENT_PSM": 3,
         "EVENT_UPDATE_PSM": 3, "EVENT_UPDATE": 3}
for n, size in sizes.items():
    v = events.get(n)
    if v is None:
        errors.append(f"{n} absent côté montre")
        continue
    for cnt in re.findall(rf"kind == 0x{v:02X}, bytes\.count >= (\d+)", sw):
        if int(cnt) > size:
            errors.append(f"{n} : l'iPhone exige {cnt} octets mais la montre en envoie {size}")

# 7. Taille des commandes : ce que la montre exige <= ce que l'iPhone envoie
cmd_sizes = {"CMD_BRIGHTNESS": 3, "CMD_TIMEOUT": 3, "CMD_DND": 2, "CMD_SAVER": 2, "CMD_REMOTE": 4,
             "CMD_TAP": 5, "CMD_SWIPE": 11, "CMD_NAV": 2, "CMD_SET_MOVE": 3, "CMD_SET_APPS": 3,
             "CMD_SET_QUIET": 4, "CMD_SET_INTERVAL": 3, "CMD_SET_MIRROR": 2, "CMD_SYNC_REQUEST": 5,
             "CMD_UPDATE": 5}
for n, size in cmd_sizes.items():
    branch = re.search(rf"{n} -> if \(value\.size >= (\d+)\)", kt)
    if branch and int(branch.group(1)) > size:
        errors.append(f"{n} : la montre exige {branch.group(1)} octets, l'iPhone en envoie {size}")

if errors:
    print("PROTOCOLE INCOHÉRENT :")
    for e in errors:
        print(" -", e)
    sys.exit(1)
print(f"Protocole cohérent : {len(cmds)} commandes, {len(events)} événements vérifiés.")
