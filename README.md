# Project Zomboid (Store Mods) — AMP template

An AMP template for Project Zomboid where the **Steam Workshop store actually works**.
Install a mod from the store, press Update, and it is live. No copying mod IDs, no
hunting through `mod.info` files, no load-order guesswork.

## Why this exists

AMP's Steam Workshop store downloads workshop items, but Project Zomboid only loads
mods that are named in `Mods=` and `WorkshopItems=` in its server `.ini`. The store has
no way to write those lines — the mod IDs it would need are buried inside each item's
`mod.info`, and one workshop item can contain several mods. So on the stock template a
store install downloads files and nothing else happens; you still have to fill in the
two text boxes by hand. (The stock template's own help text even warns you off the
workshop list under Updates for this reason.)

Games like Minecraft don't have this problem because dropping a jar in a folder *is*
installing it. This template gives Project Zomboid the same experience by deriving the
mod IDs itself during the update.

## What it does

On every update, after the game and any store items are downloaded:

* reads the list of items you installed from the store
* finds each item's mods and their IDs from `mod.info`
* writes `Mods=` and `WorkshopItems=` for you, in **dependency order** — a mod that
  declares `require` / `loadAfter` / `loadBefore` is placed accordingly
* **warns about missing dependencies**, including which workshop item provides them
* **warns about declared conflicts** between mods you have active
* **warns about texture-only mods** (no scripts, Lua or maps), which usually do nothing on
  a dedicated server — players see a texture pack by installing it themselves — and some of
  which have made servers grow until they were killed for running out of memory
* uninstall an item in the store and its mods come back out of the list

Everything it does is written to the update log, so you can see exactly what changed.

**It warns; it does not veto.** If you install something, it gets activated. Mod authors'
compatibility metadata goes stale, conflicts get patched, and a texture pack that misbehaved
last year may be fine today — you are the one who can judge that, so the warnings tell you
what to watch for and leave the decision with you. If you would rather have the strict
behaviour for texture-only mods, turn on **Skip Texture-Only Mods**.

### It won't fight you

* **Switching to this template changes nothing on its own.** The first time it sees an
  item whose mods are already in your list, it keeps your exact selection — including
  leaving optional sub-mods off.
* **Remove a mod ID by hand and it stays removed.** It won't put it back.
* **Mods it doesn't manage are left alone**, so hand-added entries survive.
* **Anything unexpected and it changes nothing.** Errors are logged, not applied.

## Installing

In AMP, go to **Configuration → Instance Deployment → Template Repositories** (on the
controller/ADS instance) and add:

```
StevenG916/project-zomboid-store-amp-template:main
```

Refresh the template list, then create a new instance and pick
**Project Zomboid (Store Mods)**.

Then just use the store: open the instance, go to the **Steam Workshop** page, install
mods, and press **Update**. Watch the update log for `[StoreMods]` lines.

### Settings

Under **Configuration → Project Zomboid → Store Mods**:

| Setting | Default | What it does |
| --- | --- | --- |
| Auto-Activate Store Mods | on | Activate store mods on update. Off = freeze the current list. |
| Enforce Mod Load Order | on | Sort the list so dependencies load first. |
| Skip Texture-Only Mods | off | Refuse texture/model-only mods instead of activating them with a warning. |

There are deliberately **no "Load Mods" / "Install Workshop Items" boxes** in this
template. That is what makes it safe: because AMP is not managing those two keys, it
never overwrites them, and the activation script can own them. If you need to set the
list by hand, edit the server `.ini` (`Zomboid/Server/<servername>.ini`) in the File
Manager while the server is stopped — the script preserves entries it doesn't manage.

## Moving an existing server onto this template

Your mod list lives in the server `.ini`, not in the template, so it comes with you.
Point a new instance at the same data, or copy your `Zomboid` folder across, then install
the same mods from the store. The first update adopts what you already had rather than
changing it — so nothing moves until you install or uninstall something.

## Requirements and caveats

* **Linux hosts need `python3`.** It is present in AMP's own container image
  (`cubecoders/ampbase:debian`) and on any mainstream distro. If it is missing, the stage
  says so and leaves your config untouched.
* **Windows support is best-effort.** The PowerShell version mirrors the Linux one but has
  had far less testing — please open an issue if it misbehaves. It fails safe: if it
  errors, your config is unchanged.
* **Map mods**: if a mod adds a new map *area*, you still need to add it to the `Map`
  setting yourself. The log reminds you when an item contains map tiles.
* **Client-side mods still need installing on clients.** The server list only controls
  what the server loads and what clients are told to download.
* Mods are downloaded by AMP's normal workshop mechanism, so they are re-checked on each
  update. That is also what keeps them up to date.

## How it works, for the curious

Two moving parts:

1. **The template omits `Mods` / `WorkshopItems` as settings.** AMP merges its settings
   into the `.ini` on start and on save, overwriting external edits — but only for keys it
   has a setting for. Keys it doesn't know are left untouched, which is what makes
   script-owned mod lines possible.
2. **An update stage runs `pzstoremods`**, which reads the store's item list from
   `steamcmdplugin.kvp`, its own options from `App.AppSettings` in `GenericModule.kvp`,
   scans the downloaded workshop content for `mod.info` metadata, and rewrites just those
   two lines. Update stages run while the game is stopped, so there is no race with the
   server rewriting its own config.

Load-order sorting is a stable topological sort: entries keep their relative order unless
a declared constraint forces a move, and every move is logged. This is the same metadata
the "Mod Load Order Sorter" workshop mod uses in-game — done server-side, where a
client-side UI mod can't help.

## Credits

Base template from [CubeCoders/AMPTemplates](https://github.com/CubeCoders/AMPTemplates)
(`project-zomboid`, by Greelan, IceOfWraith and Dhraz) — this fork adds store mod
activation and keeps the rest current with upstream. Not affiliated with CubeCoders or
The Indie Stone.
