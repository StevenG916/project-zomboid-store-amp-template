# pzstoremods - activate AMP-store Steam Workshop mods on a Project Zomboid server.
#
# Windows counterpart of pzstoremods.py. See that file (or the project README) for
# what this does and why it is needed. Behaviour is intended to be identical:
# it derives mod IDs from each store-installed workshop item's mod.info, keeps Mods=
# in dependency order, warns (but does not refuse) on declared conflicts and on
# texture-only mods, and is the sole owner of the Mods= / WorkshopItems= lines in
# the server .ini.
#
# Runs with the instance datapath as the working directory while the game is
# stopped. Any unexpected error leaves the config untouched.
#
# Project: https://github.com/StevenG916/project-zomboid-store-amp-template

$ErrorActionPreference = 'Stop'
$WORKSHOP_APPID = '108600'
$Root = (Get-Location).Path
$GenericKvp = Join-Path $Root 'GenericModule.kvp'
$SteamKvp = Join-Path $Root 'steamcmdplugin.kvp'
$StateFile = Join-Path $Root 'pzstoremods.state.json'

function Write-StoreLog($msg) { Write-Host "[StoreMods] $msg" }

function Get-KvpValue($path, $key) {
    if (-not (Test-Path $path)) { return $null }
    foreach ($line in [System.IO.File]::ReadAllLines($path)) {
        $trimmed = $line.TrimStart([char]0xFEFF)
        if ($trimmed.StartsWith("$key=")) { return $trimmed.Substring($key.Length + 1) }
    }
    return $null
}

function Get-AppSettings {
    $raw = Get-KvpValue $GenericKvp 'App.AppSettings'
    if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
    try {
        $obj = $raw | ConvertFrom-Json
        $map = @{}
        foreach ($p in $obj.PSObject.Properties) { $map[$p.Name] = [string]$p.Value }
        return $map
    } catch { return @{} }
}

function Get-Flag($settings, $name, $default) {
    if (-not $settings.ContainsKey($name) -or [string]::IsNullOrWhiteSpace($settings[$name])) {
        return $default
    }
    return @('true', '1', 'yes', 'on') -contains $settings[$name].Trim().ToLower()
}

function Split-ModIds($value) {
    $out = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($part in $value.Split(',')) {
        $p = $part.Trim().TrimStart('\').Trim()
        if ($p) { [void]$out.Add($p) }
    }
    return $out
}

function Split-IniList($value) {
    return @($value.Split(';') | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and $_ -ne '\' })
}

function New-MetaEntry {
    return [pscustomobject]@{
        require      = New-Object 'System.Collections.Generic.HashSet[string]'
        incompatible = New-Object 'System.Collections.Generic.HashSet[string]'
        after        = New-Object 'System.Collections.Generic.HashSet[string]'
        before       = New-Object 'System.Collections.Generic.HashSet[string]'
        code         = $false
        maps         = $false
        items        = New-Object 'System.Collections.Generic.HashSet[string]'
    }
}

function Get-WorkshopMetadata($wsDir) {
    $meta = @{}
    if (-not (Test-Path $wsDir)) { return $meta }
    foreach ($item in Get-ChildItem -Path $wsDir -Directory -ErrorAction SilentlyContinue) {
        if ($item.Name -notmatch '^\d+$') { continue }
        $modsRoot = Join-Path $item.FullName 'mods'
        if (-not (Test-Path $modsRoot)) { continue }
        foreach ($modDir in Get-ChildItem -Path $modsRoot -Directory -ErrorAction SilentlyContinue) {
            $ids = New-Object 'System.Collections.Generic.HashSet[string]'
            $req = New-Object 'System.Collections.Generic.HashSet[string]'
            $inc = New-Object 'System.Collections.Generic.HashSet[string]'
            $aft = New-Object 'System.Collections.Generic.HashSet[string]'
            $bef = New-Object 'System.Collections.Generic.HashSet[string]'
            $code = $false; $maps = $false
            foreach ($info in Get-ChildItem -Path $modDir.FullName -Recurse -Filter 'mod.info' -File -ErrorAction SilentlyContinue) {
                foreach ($line in [System.IO.File]::ReadAllLines($info.FullName)) {
                    $s = $line.Trim().TrimStart([char]0xFEFF)
                    $low = $s.ToLower()
                    if ($low.StartsWith('id=')) {
                        $v = $s.Substring(3).Trim(); if ($v) { [void]$ids.Add($v) }
                    } elseif ($low.StartsWith('require=')) {
                        foreach ($v in (Split-ModIds $s.Substring(8))) { [void]$req.Add($v) }
                    } elseif ($low.StartsWith('incompatible=')) {
                        foreach ($v in (Split-ModIds $s.Substring(13))) { [void]$inc.Add($v) }
                    } elseif ($low.StartsWith('loadafter=')) {
                        foreach ($v in (Split-ModIds $s.Substring(10))) { [void]$aft.Add($v) }
                    } elseif ($low.StartsWith('loadbefore=')) {
                        foreach ($v in (Split-ModIds $s.Substring(11))) { [void]$bef.Add($v) }
                    }
                }
            }
            foreach ($dir in @($modDir.FullName) + @(Get-ChildItem -Path $modDir.FullName -Recurse -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })) {
                $norm = $dir.Replace('\', '/')
                if ($norm -match '/media/(scripts|lua|maps)(/|$)') { $code = $true }
                if ($norm -match '/media/maps(/|$)') { $maps = $true }
            }
            foreach ($id in $ids) {
                if (-not $meta.ContainsKey($id)) { $meta[$id] = New-MetaEntry }
                $e = $meta[$id]
                foreach ($v in $req) { if ($v -ne $id) { [void]$e.require.Add($v) } }
                foreach ($v in $inc) { if ($v -ne $id) { [void]$e.incompatible.Add($v) } }
                foreach ($v in $aft) { if ($v -ne $id) { [void]$e.after.Add($v) } }
                foreach ($v in $bef) { if ($v -ne $id) { [void]$e.before.Add($v) } }
                if ($code) { $e.code = $true }
                if ($maps) { $e.maps = $true }
                [void]$e.items.Add($item.Name)
            }
        }
    }
    return $meta
}

function Get-Conflicts($modId, $active, $meta) {
    $found = New-Object 'System.Collections.Generic.HashSet[string]'
    if ($meta.ContainsKey($modId)) {
        foreach ($c in $meta[$modId].incompatible) { if ($active -contains $c) { [void]$found.Add($c) } }
    }
    foreach ($other in $active) {
        if ($meta.ContainsKey($other) -and $meta[$other].incompatible.Contains($modId)) {
            [void]$found.Add($other)
        }
    }
    return $found
}

function Get-TopoOrder($entries, $meta) {
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $uniq = @()
    foreach ($e in $entries) {
        $bare = $e.TrimStart('\')
        if ($seen.Add($bare)) { $uniq += $e }
    }
    $bareIds = @($uniq | ForEach-Object { $_.TrimStart('\') })
    $byId = @{}
    for ($i = 0; $i -lt $uniq.Count; $i++) { $byId[$bareIds[$i]] = $uniq[$i] }
    $preds = @{}
    foreach ($b in $bareIds) { $preds[$b] = New-Object 'System.Collections.Generic.HashSet[string]' }
    foreach ($b in $bareIds) {
        if (-not $meta.ContainsKey($b)) { continue }
        foreach ($dep in @($meta[$b].require) + @($meta[$b].after)) {
            if ($preds.ContainsKey($dep) -and $dep -ne $b) { [void]$preds[$b].Add($dep) }
        }
        foreach ($later in $meta[$b].before) {
            if ($preds.ContainsKey($later) -and $later -ne $b) { [void]$preds[$later].Add($b) }
        }
    }
    $ordered = @(); $placed = New-Object 'System.Collections.Generic.HashSet[string]'
    $remaining = [System.Collections.ArrayList]@($bareIds)
    while ($remaining.Count -gt 0) {
        $pick = $null
        foreach ($b in $remaining) {
            $ready = $true
            foreach ($p in $preds[$b]) { if (-not $placed.Contains($p)) { $ready = $false; break } }
            if ($ready) { $pick = $b; break }
        }
        if ($null -eq $pick) {
            Write-StoreLog ("load order: dependency cycle among " + ($remaining -join ', ') +
                " - leaving those in their current order")
            $ordered += @($remaining); break
        }
        $remaining.Remove($pick)
        [void]$placed.Add($pick)
        $ordered += $pick
    }
    $moved = @()
    for ($i = 0; $i -lt $ordered.Count -and $i -lt $bareIds.Count; $i++) {
        if ($ordered[$i] -ne $bareIds[$i]) { $moved += $ordered[$i] }
    }
    return @{ entries = @($ordered | ForEach-Object { $byId[$_] }); moved = $moved }
}

try {
    $settings = Get-AppSettings
    if (-not (Get-Flag $settings 'StoreModAutoActivate' $true)) {
        Write-StoreLog 'auto-activation is switched off; leaving the mod list alone'
        exit 0
    }
    $relBase = Get-KvpValue $GenericKvp 'App.BaseDirectory'
    if ([string]::IsNullOrWhiteSpace($relBase)) { $relBase = './project-zomboid/380870/' }
    $base = [System.IO.Path]::GetFullPath((Join-Path $Root $relBase))
    $serverName = $settings['servername']
    if ([string]::IsNullOrWhiteSpace($serverName)) { $serverName = 'servertest' }
    $ini = Join-Path $base ("Zomboid\Server\{0}.ini" -f $serverName.Trim())
    $wsDir = Join-Path $base ("steamapps\workshop\content\{0}" -f $WORKSHOP_APPID)

    if (-not (Test-Path $ini)) {
        Write-StoreLog ("server config not found yet ({0}) - start the server once, then update again" -f (Split-Path $ini -Leaf))
        exit 0
    }
    $rawIds = Get-KvpValue $SteamKvp 'SteamWorkshop.WorkshopItemIDs'
    $ids = @()
    if ($rawIds) { $ids = @([regex]::Matches($rawIds, '\d{6,}') | ForEach-Object { $_.Value }) }
    if ($ids.Count -eq 0 -and -not (Test-Path $wsDir)) {
        Write-StoreLog 'no workshop items installed from the store; nothing to do'
        exit 0
    }

    $skipTextures = Get-Flag $settings 'StoreModSkipTextureOnly' $false
    $enforceOrder = Get-Flag $settings 'StoreModEnforceOrder' $true

    $lines = [System.Collections.ArrayList]@([System.IO.File]::ReadAllLines($ini))
    $modsIdx = -1; $wsIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].StartsWith('Mods=')) { $modsIdx = $i }
        elseif ($lines[$i].StartsWith('WorkshopItems=')) { $wsIdx = $i }
    }
    if ($modsIdx -lt 0 -or $wsIdx -lt 0) {
        Write-StoreLog 'Mods= / WorkshopItems= missing from the server config; not touching it'
        exit 0
    }
    $currentMods = @(Split-IniList $lines[$modsIdx].Substring(5))
    $currentWs = @(Split-IniList $lines[$wsIdx].Substring(14))
    $active = @($currentMods | ForEach-Object { $_.TrimStart('\') })

    $meta = Get-WorkshopMetadata $wsDir
    # so a conflict is reported once, not once per direction
    $warnedPairs = New-Object 'System.Collections.Generic.HashSet[string]'
    $state = @{ items = @{} }
    if (Test-Path $StateFile) {
        try {
            $loaded = (Get-Content $StateFile -Raw) | ConvertFrom-Json
            foreach ($p in $loaded.items.PSObject.Properties) {
                $state.items[$p.Name] = @{
                    managed   = @($p.Value.managed)
                    activated = [bool]$p.Value.activated
                }
            }
        } catch { $state = @{ items = @{} } }
    }
    $items = $state.items

    foreach ($wsid in $ids) {
        if ($items.ContainsKey($wsid)) { continue }
        if (-not (Test-Path (Join-Path $wsDir $wsid))) {
            Write-StoreLog "${wsid}: not downloaded yet - it will be picked up after the next update"
            continue
        }
        $own = @($meta.Keys | Where-Object { $meta[$_].items.Contains($wsid) })
        $codeIds = @($own | Where-Object { $meta[$_].code } | Sort-Object)
        $textureIds = @($own | Where-Object { -not $meta[$_].code } | Sort-Object)
        $eligible = @($codeIds); if (-not $skipTextures) { $eligible += $textureIds }
        $adopted = @($eligible | Where-Object { $active -contains $_ })
        if ($adopted.Count -gt 0) {
            $items[$wsid] = @{ managed = $adopted; activated = $true }
            Write-StoreLog ("${wsid}: keeping the mods you already had active (" + ($adopted -join ', ') + ")")
            $optional = @($eligible | Where-Object { $adopted -notcontains $_ })
            if ($optional.Count -gt 0) {
                Write-StoreLog ("${wsid}: leaving these off, as before: " + ($optional -join ', '))
            }
            continue
        }
        $managed = @($eligible)
        $items[$wsid] = @{ managed = $managed; activated = $false }
        if ($managed.Count -gt 0) {
            Write-StoreLog ("${wsid}: activating " + ($managed -join ', '))
            foreach ($modId in $managed) {
                $others = @(@($active) + @($managed) | Where-Object { $_ -ne $modId })
                $clash = Get-Conflicts $modId $others $meta
                $fresh = @($clash | Sort-Object | Where-Object {
                    -not $warnedPairs.Contains((@($modId, $_) | Sort-Object) -join '|') })
                if ($fresh.Count -gt 0) {
                    foreach ($other in $fresh) {
                        [void]$warnedPairs.Add((@($modId, $other) | Sort-Object) -join '|')
                    }
                    Write-StoreLog ("${wsid}: WARNING - $modId is declared incompatible with " +
                        ($fresh -join ', ') + ". Activating it anyway, since that " +
                        "metadata is often out of date. If the server misbehaves, take one of them back out.")
                }
            }
            foreach ($modId in $managed) {
                if ($textureIds -contains $modId) {
                    Write-StoreLog ("${wsid}: WARNING - $modId contains only textures/models. " +
                        "Clients see a texture pack by installing it themselves, so this usually does " +
                        "nothing server-side, and such packs have caused servers to grow until they were " +
                        "killed for running out of memory. Activating it because you asked for it - keep " +
                        "an eye on memory use, and turn on 'Skip Texture-Only Mods' if you would rather " +
                        "not load these.")
                }
            }
            $missing = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($modId in $managed) {
                foreach ($dep in $meta[$modId].require) {
                    if ($active -notcontains $dep -and $managed -notcontains $dep) { [void]$missing.Add($dep) }
                }
            }
            if ($missing.Count -gt 0) {
                Write-StoreLog ("${wsid}: heads up - these required mods are not active: " +
                    (($missing | Sort-Object) -join ', ') + ". Check the item's workshop page for its dependencies.")
            }
            if (@($managed | Where-Object { $meta[$_].maps }).Count -gt 0) {
                Write-StoreLog "${wsid}: contains map tiles - if it adds a new map area, add it to the Map setting as well"
            }
        }
        if ($textureIds.Count -gt 0 -and $skipTextures) {
            Write-StoreLog ("${wsid}: skipping " + ($textureIds -join ', ') +
                " - 'Skip Texture-Only Mods' is on and it contains only textures/models. " +
                "Install it on the clients instead.")
        } elseif ($eligible.Count -eq 0) {
            Write-StoreLog "${wsid}: no mod.info found, so there is nothing to activate"
        }
    }

    foreach ($wsid in $ids) {
        if (-not $items.ContainsKey($wsid)) { continue }
        if (-not $items[$wsid].activated) { continue }
        $removedByHand = @($items[$wsid].managed | Where-Object { $active -notcontains $_ })
        if ($removedByHand.Count -gt 0) {
            $items[$wsid].managed = @($items[$wsid].managed | Where-Object { $active -contains $_ })
            Write-StoreLog ("${wsid}: " + ($removedByHand -join ', ') +
                " was taken out of the mod list by hand - leaving it out")
        }
    }

    $wantedMods = New-Object 'System.Collections.Generic.HashSet[string]'
    $wantedWs = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($wsid in $ids) {
        if ($items.ContainsKey($wsid) -and @($items[$wsid].managed).Count -gt 0) {
            [void]$wantedWs.Add($wsid)
            foreach ($m in $items[$wsid].managed) { [void]$wantedMods.Add($m) }
        }
    }

    $dropMods = New-Object 'System.Collections.Generic.HashSet[string]'
    $dropWs = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($wsid in @($items.Keys)) {
        if ($ids -notcontains $wsid) {
            [void]$dropWs.Add($wsid)
            foreach ($m in $items[$wsid].managed) { [void]$dropMods.Add($m) }
            $items.Remove($wsid)
        }
    }
    foreach ($m in @($dropMods)) { if ($wantedMods.Contains($m)) { [void]$dropMods.Remove($m) } }
    foreach ($w in @($dropWs)) { if ($wantedWs.Contains($w)) { [void]$dropWs.Remove($w) } }
    if ($dropMods.Count -gt 0 -or $dropWs.Count -gt 0) {
        Write-StoreLog ("removed from the store, so deactivating: " +
            ((@($dropMods) + @($dropWs)) | Sort-Object) -join ', ')
    }

    $prefix = ''
    if (@($currentMods | Where-Object { $_.StartsWith('\') }).Count -gt 0) {
        $prefix = '\'
    } elseif ($currentMods.Count -eq 0) {
        if (@(Get-ChildItem -Path $wsDir -Recurse -Filter 'mod.info' -File -ErrorAction SilentlyContinue |
              Where-Object { $_.Directory.Name -match '^4[2-9]' }).Count -gt 0) { $prefix = '\' }
    }
    $newMods = @($currentMods | Where-Object { -not $dropMods.Contains($_.TrimStart('\')) })
    $have = @($newMods | ForEach-Object { $_.TrimStart('\') })
    foreach ($m in ($wantedMods | Sort-Object)) { if ($have -notcontains $m) { $newMods += ($prefix + $m) } }
    if ($enforceOrder) {
        $sorted = Get-TopoOrder $newMods $meta
        $newMods = $sorted.entries
        if ($sorted.moved.Count -gt 0) {
            Write-StoreLog ("reordered for dependencies: " + ($sorted.moved -join ', '))
        }
    }
    $newWs = @($currentWs | Where-Object { -not $dropWs.Contains($_) })
    foreach ($w in ($wantedWs | Sort-Object)) { if ($newWs -notcontains $w) { $newWs += $w } }

    $final = @($newMods | ForEach-Object { $_.TrimStart('\') })
    foreach ($modId in ($final | Sort-Object)) {
        if (-not $meta.ContainsKey($modId)) { continue }
        foreach ($dep in ($meta[$modId].require | Sort-Object)) {
            if ($final -notcontains $dep) {
                $where = 'not installed'
                if ($meta.ContainsKey($dep)) {
                    $where = 'available in workshop item ' + (($meta[$dep].items | Sort-Object) -join ', ')
                }
                Write-StoreLog "note: $modId requires $dep ($where)"
            }
        }
        foreach ($other in ($meta[$modId].incompatible | Sort-Object)) {
            $pair = (@($modId, $other) | Sort-Object) -join '|'
            if ($final -contains $other -and $modId -lt $other -and -not $warnedPairs.Contains($pair)) {
                [void]$warnedPairs.Add($pair)
                Write-StoreLog "warning: $modId and $other are declared incompatible with each other, and both are active"
            }
        }
    }

    $changed = $false
    $modsValue = 'Mods=' + ($newMods -join ';') + $(if ($newMods.Count) { ';' } else { '' })
    $wsValue = 'WorkshopItems=' + ($newWs -join ';') + $(if ($newWs.Count) { ';' } else { '' })
    if ($lines[$modsIdx] -ne $modsValue) { $lines[$modsIdx] = $modsValue; $changed = $true }
    if ($lines[$wsIdx] -ne $wsValue) { $lines[$wsIdx] = $wsValue; $changed = $true }

    if ($changed) {
        $tmp = "$ini.pzstoremods"
        [System.IO.File]::WriteAllLines($tmp, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -Path $tmp -Destination $ini -Force
        Write-StoreLog ("server config updated - {0} mod(s) active" -f $newMods.Count)
    } else {
        Write-StoreLog 'mod list already correct - no changes needed'
    }

    foreach ($wsid in $ids) {
        if ($items.ContainsKey($wsid) -and @($items[$wsid].managed).Count -gt 0) {
            $items[$wsid].activated = $true
        }
    }
    ($state | ConvertTo-Json -Depth 6) | Set-Content -Path $StateFile -Encoding UTF8
    exit 0
} catch {
    Write-StoreLog ("stopped without changing anything: " + $_.Exception.Message)
    exit 0
}
