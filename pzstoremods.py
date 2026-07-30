#!/usr/bin/env python3
"""pzstoremods — activate AMP-store Steam Workshop mods on a Project Zomboid server.

AMP's Steam Workshop store downloads workshop items but cannot activate them for
Project Zomboid: the server only loads mods listed in Mods= / WorkshopItems= in
its .ini, and the mod IDs needed for Mods= live inside each item's mod.info
(one workshop item can contain several mods). This script closes that gap. It is
run as an update stage by the "Project Zomboid (Store Mods)" AMP template, so the
flow becomes: install from the store -> press Update -> the mod is active.

It runs with the instance datapath as the working directory, while the game is
stopped, and is the sole owner of the Mods= / WorkshopItems= lines (the template
deliberately does not declare those as AMP settings, so AMP never overwrites
them). Anything else in the .ini is left untouched.

What it does each run:
  * reads the store's installed item list (steamcmdplugin.kvp)
  * derives mod IDs from each downloaded item's mod.info
  * refuses texture-only mods by default (no scripts/lua/maps). Server-side
    texture packs are a known cause of runaway native memory use on dedicated
    servers, and they only need to be installed client-side to be seen
  * refuses a mod that declares (or is declared) incompatible with an active one
  * keeps Mods= in dependency order using require / loadAfter / loadBefore
  * warns about declared requirements that are not active
  * adopts a pre-existing selection on first run, so switching to this template
    changes nothing until you use the store; mods you removed by hand stay
    removed; entries it does not manage are preserved

Toggles (Configuration -> Project Zomboid -> Store Mods):
  Auto-Activate Store Mods, Allow Texture-Only Mods, Enforce Mod Load Order

Project: https://github.com/StevenG916/project-zomboid-store-amp-template
"""

import glob
import json
import os
import re
import sys

ROOT = os.getcwd()  # AMP runs update stages with the instance datapath as cwd
GENERIC_KVP = os.path.join(ROOT, "GenericModule.kvp")
STEAMCMD_KVP = os.path.join(ROOT, "steamcmdplugin.kvp")
STATE_FILE = os.path.join(ROOT, "pzstoremods.state.json")
WORKSHOP_APPID = "108600"


def log(msg):
    print("[StoreMods] " + msg, flush=True)


def kvp_value(path, key):
    """Read a single KEY=value line out of an AMP .kvp file."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.lstrip("﻿").rstrip("\r\n")
                if line.startswith(key + "="):
                    return line[len(key) + 1:]
    except OSError:
        pass
    return None


def app_settings():
    """AMP persists template field values as a JSON object in GenericModule.kvp."""
    raw = kvp_value(GENERIC_KVP, "App.AppSettings")
    if not raw:
        return {}
    try:
        val = json.loads(raw)
        return val if isinstance(val, dict) else {}
    except ValueError:
        return {}


def flag(settings, name, default):
    val = settings.get(name)
    if val is None or val == "":
        return default
    return str(val).strip().lower() in ("true", "1", "yes", "on")


def store_item_ids():
    """Workshop item IDs the AMP store currently has installed."""
    raw = kvp_value(STEAMCMD_KVP, "SteamWorkshop.WorkshopItemIDs")
    return re.findall(r"\d{6,}", raw) if raw else []


def base_dir():
    """Absolute game base directory, from the template's own setting."""
    rel = kvp_value(GENERIC_KVP, "App.BaseDirectory") or "./project-zomboid/380870/"
    return os.path.normpath(os.path.join(ROOT, rel))


def ini_path(base, settings):
    name = (settings.get("servername") or "servertest").strip() or "servertest"
    return os.path.join(base, "Zomboid", "Server", name + ".ini")


def split_ids(value):
    """Split a comma-separated mod.info list into bare mod IDs."""
    out = set()
    for part in value.split(","):
        part = part.strip().lstrip("\\").strip()
        if part:
            out.add(part)
    return out


def scan_workshop(ws_dir):
    """Inspect every downloaded workshop item.

    Returns {mod_id: {require, incompatible, after, before, code, maps, items}}.
    Flags are OR-ed when a mod ID appears in more than one place."""
    meta = {}
    for item_dir in sorted(glob.glob(os.path.join(ws_dir, "*", ""))):
        wsid = os.path.basename(os.path.dirname(item_dir))
        if not wsid.isdigit():
            continue
        for mod_dir in sorted(glob.glob(os.path.join(item_dir, "mods", "*", ""))):
            ids, code, maps = set(), False, False
            req, inc, after, before = set(), set(), set(), set()
            for dirpath, _dirs, files in os.walk(mod_dir):
                if "mod.info" in files:
                    try:
                        with open(os.path.join(dirpath, "mod.info"),
                                  encoding="utf-8", errors="replace") as f:
                            for line in f:
                                s = line.strip().lstrip("﻿")
                                low = s.lower()
                                if low.startswith("id="):
                                    ids.add(s.split("=", 1)[1].strip())
                                elif low.startswith("require="):
                                    req |= split_ids(s.split("=", 1)[1])
                                elif low.startswith("incompatible="):
                                    inc |= split_ids(s.split("=", 1)[1])
                                elif low.startswith("loadafter="):
                                    after |= split_ids(s.split("=", 1)[1])
                                elif low.startswith("loadbefore="):
                                    before |= split_ids(s.split("=", 1)[1])
                    except OSError:
                        pass
                norm = dirpath.replace("\\", "/")
                if re.search(r"/media/(scripts|lua|maps)(/|$)", norm):
                    code = True
                if re.search(r"/media/maps(/|$)", norm):
                    maps = True
            for mod_id in ids:
                if not mod_id:
                    continue
                entry = meta.setdefault(mod_id, {
                    "require": set(), "incompatible": set(), "after": set(),
                    "before": set(), "code": False, "maps": False, "items": set()})
                entry["require"] |= req - {mod_id}
                entry["incompatible"] |= inc - {mod_id}
                entry["after"] |= after - {mod_id}
                entry["before"] |= before - {mod_id}
                entry["code"] |= code
                entry["maps"] |= maps
                entry["items"].add(wsid)
    return meta


def uses_backslash(ws_dir, entries):
    """Build 42 servers want mod IDs prefixed with a backslash. Follow whatever
    the existing list does; otherwise infer from the mod packaging layout."""
    for e in entries:
        if e.startswith("\\"):
            return True
    if entries:
        return False
    return bool(glob.glob(os.path.join(ws_dir, "*", "mods", "*", "4[2-9]*", "mod.info")))


def conflicts(mod_id, active, meta):
    """Declared incompatibilities in both directions."""
    found = set(meta.get(mod_id, {}).get("incompatible", set())) & active
    for other in active:
        if mod_id in meta.get(other, {}).get("incompatible", set()):
            found.add(other)
    return found


def topo_order(entries, meta):
    """Stable dependency sort. Entries keep their relative order except where a
    require / loadAfter / loadBefore constraint forces a move.
    Returns (ordered_entries, moved_ids)."""
    seen, uniq = set(), []
    for e in entries:
        bare = e.lstrip("\\")
        if bare not in seen:
            seen.add(bare)
            uniq.append(e)
    bare_ids = [e.lstrip("\\") for e in uniq]
    by_id = dict(zip(bare_ids, uniq))
    preds = {b: set() for b in bare_ids}
    for b in bare_ids:
        info = meta.get(b)
        if not info:
            continue
        for dep in (info["require"] | info["after"]):
            if dep in preds and dep != b:
                preds[b].add(dep)
        for later in info["before"]:
            if later in preds and later != b:
                preds[later].add(b)
    ordered, placed, remaining = [], set(), list(bare_ids)
    while remaining:
        pick = next((b for b in remaining if preds[b] <= placed), None)
        if pick is None:
            log("load order: dependency cycle among " + ", ".join(remaining) +
                " - leaving those in their current order")
            ordered += remaining
            break
        remaining.remove(pick)
        placed.add(pick)
        ordered.append(pick)
    moved = [b for i, b in enumerate(ordered) if i < len(bare_ids) and b != bare_ids[i]]
    return [by_id[b] for b in ordered], moved


def read_state():
    try:
        with open(STATE_FILE) as f:
            state = json.load(f)
            state.setdefault("items", {})
            return state
    except (OSError, ValueError):
        return {"items": {}}


def write_state(state):
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=1)
    os.replace(tmp, STATE_FILE)


def parse_list(value):
    return [p.strip() for p in value.split(";") if p.strip() and p.strip() != "\\"]


def main():
    settings = app_settings()
    if not flag(settings, "StoreModAutoActivate", True):
        log("auto-activation is switched off; leaving the mod list alone")
        return 0

    base = base_dir()
    ini = ini_path(base, settings)
    ws_dir = os.path.join(base, "steamapps", "workshop", "content", WORKSHOP_APPID)
    if not os.path.exists(ini):
        log("server config not found yet (%s) - start the server once, then update again"
            % os.path.basename(ini))
        return 0

    ids = store_item_ids()
    if not ids and not os.path.isdir(ws_dir):
        log("no workshop items installed from the store; nothing to do")
        return 0

    allow_textures = flag(settings, "StoreModAllowTextureOnly", False)
    enforce_order = flag(settings, "StoreModEnforceOrder", True)

    with open(ini, encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
    mods_line = ws_line = None
    for i, line in enumerate(lines):
        if line.startswith("Mods="):
            mods_line = i
        elif line.startswith("WorkshopItems="):
            ws_line = i
    if mods_line is None or ws_line is None:
        log("Mods= / WorkshopItems= missing from the server config; not touching it")
        return 0

    current_mods = parse_list(lines[mods_line].rstrip("\r\n")[5:])
    current_ws = parse_list(lines[ws_line].rstrip("\r\n")[14:])
    active = {m.lstrip("\\") for m in current_mods}

    meta = scan_workshop(ws_dir)
    state = read_state()
    items = state["items"]

    for wsid in ids:
        if wsid in items:
            continue
        if not os.path.isdir(os.path.join(ws_dir, wsid)):
            log("%s: not downloaded yet - it will be picked up after the next update"
                % wsid)
            continue
        info = {m: v for m, v in meta.items() if wsid in v["items"]}
        code_ids = sorted(m for m in info if info[m]["code"])
        texture_ids = sorted(m for m in info if not info[m]["code"])
        eligible = code_ids + (texture_ids if allow_textures else [])
        adopted = [m for m in eligible if m in active]
        if adopted:
            # first run after switching templates: keep the existing selection
            items[wsid] = {"managed": adopted, "activated": True}
            log("%s: keeping the mods you already had active (%s)"
                % (wsid, ", ".join(adopted)))
            optional = sorted(set(eligible) - set(adopted))
            if optional:
                log("%s: leaving these off, as before: %s" % (wsid, ", ".join(optional)))
            continue
        managed = []
        for mod_id in eligible:
            clash = conflicts(mod_id, active | set(managed), meta)
            if clash:
                log("%s: NOT activating %s - it is declared incompatible with %s. "
                    "Remove the conflicting mod, then reinstall this item."
                    % (wsid, mod_id, ", ".join(sorted(clash))))
            else:
                managed.append(mod_id)
        items[wsid] = {"managed": managed, "activated": False}
        if managed:
            log("%s: activating %s" % (wsid, ", ".join(managed)))
            missing = set()
            for mod_id in managed:
                missing |= meta[mod_id]["require"] - active - set(managed)
            if missing:
                log("%s: heads up - these required mods are not active: %s. "
                    "Check the item's workshop page for its dependencies."
                    % (wsid, ", ".join(sorted(missing))))
            if any(meta[m]["maps"] for m in managed):
                log("%s: contains map tiles - if it adds a new map area, add it to the "
                    "Map setting as well" % wsid)
        if texture_ids and not allow_textures:
            log("%s: skipping %s - it only contains textures/models, so it does nothing "
                "server-side. Install it on the clients instead. (Override with "
                "'Allow Texture-Only Mods'.)" % (wsid, ", ".join(texture_ids)))
        elif not eligible:
            log("%s: no mod.info found, so there is nothing to activate" % wsid)

    # respect mods removed from the list by hand
    for wsid in ids:
        entry = items.get(wsid)
        if not entry or not entry.get("activated"):
            continue
        removed_by_hand = [m for m in entry["managed"] if m not in active]
        if removed_by_hand:
            entry["managed"] = [m for m in entry["managed"] if m in active]
            log("%s: %s was taken out of the mod list by hand - leaving it out"
                % (wsid, ", ".join(removed_by_hand)))

    wanted_mods, wanted_ws = set(), set()
    for wsid in ids:
        entry = items.get(wsid)
        if entry and entry.get("managed"):
            wanted_ws.add(wsid)
            wanted_mods.update(entry["managed"])

    # items uninstalled from the store lose their entries
    uninstalled = [w for w in list(items) if w not in ids]
    drop_mods, drop_ws = set(), set()
    for wsid in uninstalled:
        drop_ws.add(wsid)
        drop_mods.update(items[wsid].get("managed", []))
        del items[wsid]
    drop_mods -= wanted_mods
    drop_ws -= wanted_ws
    if drop_mods or drop_ws:
        log("removed from the store, so deactivating: %s"
            % ", ".join(sorted(drop_mods | drop_ws)))

    prefix = "\\" if uses_backslash(ws_dir, current_mods) else ""
    new_mods = [m for m in current_mods if m.lstrip("\\") not in drop_mods]
    have = {m.lstrip("\\") for m in new_mods}
    new_mods += [prefix + m for m in sorted(wanted_mods) if m not in have]
    if enforce_order:
        new_mods, moved = topo_order(new_mods, meta)
        if moved:
            log("reordered for dependencies: " + ", ".join(moved))
    new_ws = [w for w in current_ws if w not in drop_ws]
    new_ws += [w for w in sorted(wanted_ws) if w not in new_ws]

    # warn about anything unsatisfied across the whole final list
    final = {m.lstrip("\\") for m in new_mods}
    for mod_id in sorted(final):
        info = meta.get(mod_id)
        if not info:
            continue
        for dep in sorted(info["require"] - final):
            where = ("available in workshop item %s" % ", ".join(sorted(meta[dep]["items"]))
                     if dep in meta else "not installed")
            log("note: %s requires %s (%s)" % (mod_id, dep, where))
        for other in sorted(info["incompatible"] & final):
            if mod_id < other:
                log("warning: %s and %s are declared incompatible with each other"
                    % (mod_id, other))

    changed = False
    if new_mods != current_mods:
        lines[mods_line] = "Mods=" + ";".join(new_mods) + (";" if new_mods else "") + "\n"
        changed = True
    if new_ws != current_ws:
        lines[ws_line] = ("WorkshopItems=" + ";".join(new_ws) +
                          (";" if new_ws else "") + "\n")
        changed = True

    if changed:
        tmp = ini + ".pzstoremods"
        with open(tmp, "w", encoding="utf-8") as f:
            f.writelines(lines)
        os.replace(tmp, ini)
        log("server config updated - %d mod(s) active" % len(new_mods))
    else:
        log("mod list already correct - no changes needed")

    for wsid in ids:
        entry = items.get(wsid)
        if entry and entry.get("managed"):
            entry["activated"] = True
    write_state(state)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # never fail an update over mod bookkeeping
        log("stopped without changing anything: %s: %s" % (type(exc).__name__, exc))
        sys.exit(0)
