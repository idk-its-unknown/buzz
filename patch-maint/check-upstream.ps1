<#
.SYNOPSIS
  DETECTION ONLY - upstream drift check for a patched Buzz build (carry model).

.DESCRIPTION
  Safe to run at any time, from anywhere. The ONLY write it performs against the
  repo is `git fetch upstream --tags`, which updates remote-tracking refs and
  tags only. It never checks out branches, never touches the working tree, and
  never creates local branches.

  What it does:
    1. Fetch upstream (skippable with -NoFetch).
    2. Find the newest desktop-v* tag and upstream/main HEAD.
    3. Compare against the current patch branch's merge-base with upstream/main.
    4. Adoption scan: git log --grep over the new range and over all refs, plus
       a diff scan of the three watched patch-area files.
    5. Write a dated markdown report to reports\upstream-check-<date>.md and
       print a one-line verdict.

  Verdicts:
    UP-TO-DATE                      merge-base == upstream/main HEAD
    BEHIND-CLEAN                    behind, patch areas untouched, no adoption signal
    BEHIND-CONFLICT-LIKELY          behind AND upstream touched our watched files
    UPSTREAM-ADOPTED-CHECK-MANUALLY adoption-pattern hits in the new range - a carry
                                    may be droppable; inspect by hand before rebasing

  Exit codes: 0 = UP-TO-DATE or BEHIND-CLEAN, 2 = BEHIND-CONFLICT-LIKELY,
              3 = UPSTREAM-ADOPTED-CHECK-MANUALLY, 1 = operational error.

.EXAMPLE
  powershell -File patch-maint\check-upstream.ps1
.EXAMPLE
  powershell -File patch-maint\check-upstream.ps1 -NoFetch
#>
[CmdletBinding()]
param(
    [string]$RepoPath,
    [switch]$NoFetch
)

$ErrorActionPreference = 'Continue'
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptDir 'patch-commits.json'
$ReportsDir = Join-Path $ScriptDir 'reports'

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string[]]$GitArgs,
        [switch]$AllowFail
    )
    $out = & git -C $script:RepoPath @GitArgs
    $script:LastGitExit = $LASTEXITCODE
    if ($LASTEXITCODE -ne 0) {
        if (-not $AllowFail) {
            throw ("git {0} failed (exit {1})" -f ($GitArgs -join ' '), $LASTEXITCODE)
        }
    }
    if ($null -eq $out) { return @() }
    return @($out)
}

try {
    # ---- Load config -------------------------------------------------------
    if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }
    $config = Get-Content -Raw -Encoding UTF8 $ConfigPath | ConvertFrom-Json

    if (-not $RepoPath) { $RepoPath = $config.repo_path }
    if (-not $RepoPath) { $RepoPath = Split-Path -Parent $ScriptDir }  # default: the repo containing patch-maint/
    $script:RepoPath = $RepoPath
    if (-not (Test-Path (Join-Path $RepoPath '.git'))) { throw "Not a git repo: $RepoPath" }

    $remotes = @(Invoke-Git @('remote'))
    if ($remotes -notcontains $config.upstream_remote) {
        throw ("Remote '{0}' not found in {1}" -f $config.upstream_remote, $RepoPath)
    }

    # ---- Fetch (the single permitted write: remote-tracking refs + tags) ---
    if (-not $NoFetch) {
        Write-Host ("Fetching {0} (+ tags)..." -f $config.upstream_remote)
        & git -C $RepoPath fetch $config.upstream_remote --tags
        if ($LASTEXITCODE -ne 0) { throw "git fetch failed (exit $LASTEXITCODE)" }
    } else {
        Write-Host "Skipping fetch (-NoFetch)."
    }

    # ---- Resolve branch / heads / merge-base -------------------------------
    $branch = $config.current_branch
    $branchSha = @(Invoke-Git @('rev-parse', '--verify', '--quiet', "refs/heads/$branch") -AllowFail)
    if ($script:LastGitExit -ne 0) {
        $branch = @(Invoke-Git @('branch', '--show-current'))[0]
        Write-Warning ("Configured branch '{0}' not found; falling back to checked-out branch '{1}'." -f $config.current_branch, $branch)
        $branchSha = @(Invoke-Git @('rev-parse', '--verify', "refs/heads/$branch"))
    }
    $branchSha = $branchSha[0]

    $mainRef  = $config.upstream_main
    $mainSha  = @(Invoke-Git @('rev-parse', $mainRef))[0]
    $mainDesc = @(Invoke-Git @('log', '-1', '--format=%h %ad %s', '--date=short', $mainRef))[0]

    $mergeBase = @(Invoke-Git @('merge-base', $branch, $mainRef))[0]
    $mergeBaseDesc = @(Invoke-Git @('log', '-1', '--format=%h %ad %s', '--date=short', $mergeBase))[0]

    # Sanity: configured patch commits must still resolve on the branch
    $patchNotes = @()
    foreach ($pc in $config.patch_commits) {
        $null = Invoke-Git @('rev-parse', '--verify', '--quiet', ($pc.sha + '^{commit}')) -AllowFail
        if ($script:LastGitExit -ne 0) {
            $patchNotes += ("WARNING: configured patch commit {0} ({1}) does not resolve - patch-commits.json is stale." -f $pc.short, $pc.title)
        }
    }

    # ---- Tags --------------------------------------------------------------
    $allDesktopTags = @(Invoke-Git @('tag', '-l', $config.desktop_tag_pattern, '--sort=creatordate'))
    $newestTag = $null
    if ($allDesktopTags.Count -gt 0) { $newestTag = $allDesktopTags[$allDesktopTags.Count - 1] }

    # Tags cut after our merge-base (i.e. releases we do not have)
    $newTags = @(Invoke-Git @('tag', '-l', $config.desktop_tag_pattern, '--contains', $mergeBase, '--sort=creatordate') -AllowFail)
    if ($script:LastGitExit -ne 0) { $newTags = @() }

    # ---- Behind counts -----------------------------------------------------
    # A tag is a NEW release only if it contains our merge-base ($newTags).
    # NOTE: an ancestor check is NOT enough - release tags can sit on 1-commit
    # side branches, which makes an old tag look "not an ancestor" of our base.
    $behindMain = [int](@(Invoke-Git @('rev-list', '--count', "$mergeBase..$mainRef"))[0])
    $behindNewestTag = $null
    $newestTagIsNew = $false
    if ($newestTag -and ($newTags -contains $newestTag)) {
        $newestTagIsNew = $true
        $behindNewestTag = [int](@(Invoke-Git @('rev-list', '--count', "$mergeBase..$newestTag"))[0])
    }

    # ---- Adoption scan 1: commit messages in the new range -----------------
    # Full commit messages (subject + body), fixed-string, case-insensitive.
    $rangeHits = @{}
    foreach ($p in $config.adoption_patterns) {
        $lines = @(Invoke-Git @('log', "$mergeBase..$mainRef", "--grep=$p", '-i', '-F', '--format=%h %ad %s', '--date=short') -AllowFail)
        if ($script:LastGitExit -eq 0 -and $lines.Count -gt 0) { $rangeHits[$p] = $lines }
    }

    # ---- Adoption scan 2: all refs beyond the merge-base (informational) ---
    # Catches upstream feature branches not yet on main. Excludes history at or
    # below the merge-base, and filters out our own carry commits.
    $ourShas = @($config.patch_commits | ForEach-Object { $_.sha })
    $allRefHits = @{}
    foreach ($p in $config.adoption_patterns) {
        $lines = @(Invoke-Git @('log', '--all', "^$mergeBase", "--grep=$p", '-i', '-F', '--format=%H|%ad|%s', '--date=short') -AllowFail)
        if ($script:LastGitExit -ne 0) { continue }
        $kept = @()
        foreach ($ln in $lines) {
            $fullSha = $ln.Split('|')[0]
            if ($ourShas -notcontains $fullSha) {
                $parts = $ln.Split('|', 3)
                $kept += ("{0} {1} {2}" -f $fullSha.Substring(0, 9), $parts[1], $parts[2])
            }
        }
        if ($kept.Count -gt 0) { $allRefHits[$p] = $kept }
    }

    # ---- Adoption scan 3: diff of watched patch-area files -----------------
    $watched = @($config.watched_paths)
    $diffStat = @(Invoke-Git (@('diff', '--stat', "$mergeBase..$mainRef", '--') + $watched))
    $diffFull = @(Invoke-Git (@('diff', "$mergeBase..$mainRef", '--') + $watched))
    $watchedTouched = ($diffFull.Count -gt 0)

    $changedLines = @($diffFull | Where-Object { $_ -match '^[+-]' -and $_ -notmatch '^(\+\+\+|---)' })
    $diffHits = @{}
    foreach ($p in $config.adoption_patterns) {
        $re = [regex]::Escape($p)
        $hits = @($changedLines | Where-Object { $_ -match $re })
        if ($hits.Count -gt 0) { $diffHits[$p] = $hits }
    }

    # ---- Verdict -----------------------------------------------------------
    $adoptionSignal = ($rangeHits.Count -gt 0) -or ($diffHits.Count -gt 0)
    if ($behindMain -eq 0) {
        $verdict = 'UP-TO-DATE'
        $exitCode = 0
    } elseif ($adoptionSignal) {
        $verdict = 'UPSTREAM-ADOPTED-CHECK-MANUALLY'
        $exitCode = 3
    } elseif ($watchedTouched) {
        $verdict = 'BEHIND-CONFLICT-LIKELY'
        $exitCode = 2
    } else {
        $verdict = 'BEHIND-CLEAN'
        $exitCode = 0
    }

    # ---- Report ------------------------------------------------------------
    if (-not (Test-Path $ReportsDir)) { New-Item -ItemType Directory -Path $ReportsDir | Out-Null }
    $today = Get-Date -Format 'yyyy-MM-dd'
    $reportPath = Join-Path $ReportsDir ("upstream-check-{0}.md" -f $today)

    $md = New-Object System.Collections.Generic.List[string]
    $md.Add("# Upstream check - $today")
    $md.Add("")
    $md.Add("**VERDICT: $verdict**")
    $md.Add("")
    $md.Add(("Generated {0} by check-upstream.ps1 (detection only; fetch={1})." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), (-not $NoFetch)))
    $md.Add("")
    $md.Add("## Position")
    $md.Add("")
    $md.Add("| item | value |")
    $md.Add("|---|---|")
    $md.Add("| patch branch | ``$branch`` @ ``$($branchSha.Substring(0,9))`` |")
    $md.Add("| merge-base with $mainRef | ``$mergeBaseDesc`` |")
    $md.Add("| $mainRef HEAD | ``$mainDesc`` |")
    $md.Add("| commits behind $mainRef | **$behindMain** |")
    if ($newestTag) {
        $md.Add("| newest desktop tag | ``$newestTag`` |")
        if ($newestTagIsNew) {
            $md.Add("| commits from merge-base to ``$newestTag`` | $behindNewestTag |")
        } else {
            $md.Add("| newest tag vs base | ``$newestTag`` predates our base - no new desktop release yet |")
        }
    } else {
        $md.Add("| newest desktop tag | none found |")
    }
    if ($newTags.Count -gt 0) {
        $md.Add("| new desktop tags since our base | " + (($newTags -join ', ')) + " |")
    } else {
        $md.Add("| new desktop tags since our base | none |")
    }
    $md.Add("")
    foreach ($n in $patchNotes) { $md.Add("> $n"); $md.Add("") }

    $md.Add("## Adoption scan - commit messages in ``merge-base..$mainRef`` (verdict-driving)")
    $md.Add("")
    if ($rangeHits.Count -eq 0) {
        $md.Add("No adoption-pattern hits in the new upstream range.")
    } else {
        foreach ($k in $rangeHits.Keys) {
            $md.Add("### pattern: ``$k``")
            $md.Add("")
            $shown = @($rangeHits[$k] | Select-Object -First 30)
            foreach ($ln in $shown) { $md.Add("- ``$ln``") }
            if ($rangeHits[$k].Count -gt 30) { $md.Add(("- ... plus {0} more" -f ($rangeHits[$k].Count - 30))) }
            $md.Add("")
        }
    }
    $md.Add("")

    $md.Add("## Adoption scan - watched patch-area files, ``merge-base..$mainRef`` (verdict-driving)")
    $md.Add("")
    $md.Add("Watched files:")
    foreach ($w in $watched) { $md.Add("- ``$w``") }
    $md.Add("")
    if (-not $watchedTouched) {
        $md.Add("Upstream did NOT touch any watched file in this range.")
    } else {
        $md.Add("Upstream TOUCHED watched file(s) in this range (conflict early-warning):")
        $md.Add("")
        $md.Add('```')
        foreach ($ln in $diffStat) { $md.Add($ln) }
        $md.Add('```')
        $md.Add("")
        if ($diffHits.Count -gt 0) {
            $md.Add("Adoption-pattern hits inside the changed lines:")
            $md.Add("")
            foreach ($k in $diffHits.Keys) {
                $md.Add("### pattern: ``$k``")
                $md.Add("")
                $md.Add('```diff')
                foreach ($ln in @($diffHits[$k] | Select-Object -First 40)) { $md.Add($ln) }
                if ($diffHits[$k].Count -gt 40) { $md.Add(("... plus {0} more lines" -f ($diffHits[$k].Count - 40))) }
                $md.Add('```')
                $md.Add("")
            }
        } else {
            $md.Add("No adoption patterns inside the changed lines - looks like unrelated churn, but expect cherry-pick conflicts.")
        }
    }
    $md.Add("")

    $md.Add("## Adoption scan - all refs beyond merge-base (informational only)")
    $md.Add("")
    $md.Add("Catches upstream feature branches not yet merged to main. Our own carry commits are excluded. Does not affect the verdict.")
    $md.Add("")
    if ($allRefHits.Count -eq 0) {
        $md.Add("No hits.")
    } else {
        foreach ($k in $allRefHits.Keys) {
            $md.Add("### pattern: ``$k``")
            $md.Add("")
            $shown = @($allRefHits[$k] | Select-Object -First 20)
            foreach ($ln in $shown) { $md.Add("- ``$ln``") }
            if ($allRefHits[$k].Count -gt 20) { $md.Add(("- ... plus {0} more" -f ($allRefHits[$k].Count - 20))) }
            $md.Add("")
        }
    }
    $md.Add("")

    $md.Add("## What to do with this verdict")
    $md.Add("")
    switch ($verdict) {
        'UP-TO-DATE' {
            $md.Add("Nothing. Re-run after the next upstream release.")
        }
        'BEHIND-CLEAN' {
            $md.Add("Rebase when convenient (next desktop-v* release is the natural moment):")
            $md.Add("")
            if ($newestTagIsNew) {
                $md.Add("    powershell -File $ScriptDir\rebase-patches.ps1 -TargetRef $newestTag           # dry run")
                $md.Add("    powershell -File $ScriptDir\rebase-patches.ps1 -TargetRef $newestTag -Apply")
            } else {
                $md.Add("    powershell -File $ScriptDir\rebase-patches.ps1 -TargetRef <desktop-vX.Y.Z>     # dry run first")
            }
        }
        'BEHIND-CONFLICT-LIKELY' {
            $md.Add("Upstream touched our patch areas. Expect cherry-pick conflicts. Read the diff above before rebasing; budget time for manual conflict resolution. rebase-patches.ps1 will stop cleanly at the first conflict.")
        }
        'UPSTREAM-ADOPTED-CHECK-MANUALLY' {
            $md.Add("Possible upstream adoption of a carried patch. Inspect the hit commits above. If upstream now ships equivalent functionality, DROP the corresponding commit from patch-commits.json instead of carrying it, then rebase with the remaining commit(s). See MAINTENANCE.md 'Drop-on-adoption'.")
        }
    }
    $md.Add("")

    Set-Content -Path $reportPath -Value ($md -join "`r`n") -Encoding UTF8

    # ---- Stdout summary ----------------------------------------------------
    Write-Host ""
    Write-Host ("VERDICT: {0}" -f $verdict)
    Write-Host ("  behind {0}: {1} commit(s)" -f $mainRef, $behindMain)
    if ($newTags.Count -gt 0) {
        Write-Host ("  new desktop tags since base: {0}" -f ($newTags -join ', '))
    } else {
        Write-Host "  new desktop tags since base: none"
    }
    if ($rangeHits.Count -gt 0) { Write-Host ("  adoption hits (main range): patterns -> {0}" -f (($rangeHits.Keys | Sort-Object) -join ', ')) }
    if ($watchedTouched) { Write-Host "  watched patch-area files: TOUCHED by upstream" }
    Write-Host ("  report: {0}" -f $reportPath)
    exit $exitCode
}
catch {
    Write-Host ""
    Write-Host ("ERROR: {0}" -f $_.Exception.Message)
    exit 1
}
