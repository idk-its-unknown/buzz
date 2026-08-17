<#
.SYNOPSIS
  Guided re-apply of carried patch commits onto a new upstream base.

.DESCRIPTION
  DRY RUN BY DEFAULT. Without -Apply it only prints the exact plan and performs
  read-only checks. With -Apply it:

    1. Refuses if the working tree is dirty.
    2. Creates a NEW branch <branch_prefix><yyyy-MM-dd> at -TargetRef
       (the old carry branch is never touched - it stays at its SHA).
    3. Cherry-picks the carry commits listed in patch-commits.json, in order.
       Stops cleanly on the first conflict with instructions.
    4. On success, runs the fast gate: cargo test -p buzz-cli.
    5. Prints the exact commands for the heavy desktop gates and the artifact
       rebuild. It does NOT auto-run them.

  NOTE: -Apply changes which branch is checked out in the buzz repo. Do not run
  it while someone is actively working in that checkout.

  Exit codes: 0 = success (or dry run), 1 = precondition/param error,
              2 = stopped on cherry-pick conflict, 3 = buzz-cli gate failed.

.PARAMETER TargetRef
  Mandatory. The new base: usually the newest desktop-v* tag (e.g.
  desktop-v0.5.15), or upstream/main for a bleeding-edge rebase.

.PARAMETER Apply
  Actually do it. Omit for the default dry run.

.PARAMETER BranchName
  Override the default <branch_prefix><yyyy-MM-dd> branch name (needed if you
  rebase twice in one day). The prefix comes from branch_prefix in
  patch-commits.json (default 'patched-').

.EXAMPLE
  powershell -File rebase-patches.ps1 -TargetRef desktop-v0.5.15          # dry run
.EXAMPLE
  powershell -File rebase-patches.ps1 -TargetRef desktop-v0.5.15 -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetRef,

    [switch]$Apply,

    [string]$BranchName,

    [string]$RepoPath
)

$ErrorActionPreference = 'Continue'
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptDir 'patch-commits.json'

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

function Fail {
    param([string]$Msg, [int]$Code)
    Write-Host ""
    Write-Host ("STOP: {0}" -f $Msg)
    exit $Code
}

try {
    # ---- Preconditions (read-only) -----------------------------------------
    if (-not (Test-Path $ConfigPath)) { Fail "Config not found: $ConfigPath" 1 }
    $config = Get-Content -Raw -Encoding UTF8 $ConfigPath | ConvertFrom-Json

    if (-not $RepoPath) { $RepoPath = $config.repo_path }
    if (-not $RepoPath) { $RepoPath = Split-Path -Parent $ScriptDir }  # default: the repo containing patch-maint/
    $script:RepoPath = $RepoPath
    if (-not (Test-Path (Join-Path $RepoPath '.git'))) { Fail "Not a git repo: $RepoPath" 1 }

    if (-not $BranchName) {
        $prefix = $config.branch_prefix
        if (-not $prefix) { $prefix = 'patched-' }
        $BranchName = $prefix + (Get-Date -Format 'yyyy-MM-dd')
    }

    # Target must resolve to a commit
    $targetSha = @(Invoke-Git @('rev-parse', '--verify', '--quiet', "$TargetRef^{commit}") -AllowFail)
    if ($script:LastGitExit -ne 0) {
        Fail "TargetRef '$TargetRef' does not resolve. Run check-upstream.ps1 first (it fetches), or check the spelling." 1
    }
    $targetSha = $targetSha[0]
    $targetDesc = @(Invoke-Git @('log', '-1', '--format=%h %ad %s', '--date=short', $targetSha))[0]

    # New branch must not already exist (idempotence guard)
    $null = Invoke-Git @('rev-parse', '--verify', '--quiet', "refs/heads/$BranchName") -AllowFail
    if ($script:LastGitExit -eq 0) {
        Fail "Branch '$BranchName' already exists. Pass -BranchName <other-name>, or delete/rename the existing branch first." 1
    }

    # Working tree state
    $dirty = @(Invoke-Git @('status', '--porcelain'))
    $isDirty = ($dirty.Count -gt 0)

    # Current checkout (so we can tell the user how to get back)
    $prevRef = @(Invoke-Git @('rev-parse', '--abbrev-ref', 'HEAD'))[0]

    # Carry commits must resolve; note any already contained in the target
    $carries = @($config.patch_commits)
    if ($carries.Count -eq 0) { Fail "patch-commits.json has no patch_commits - nothing to carry." 1 }
    $carryInfo = @()
    foreach ($pc in $carries) {
        $null = Invoke-Git @('rev-parse', '--verify', '--quiet', ($pc.sha + '^{commit}')) -AllowFail
        if ($script:LastGitExit -ne 0) {
            Fail ("Carry commit {0} ({1}) does not resolve in {2}. patch-commits.json is stale." -f $pc.short, $pc.title, $RepoPath) 1
        }
        $null = Invoke-Git @('merge-base', '--is-ancestor', $pc.sha, $targetSha) -AllowFail
        $contained = ($script:LastGitExit -eq 0)
        $carryInfo += [pscustomobject]@{ Commit = $pc; Contained = $contained }
    }

    # ---- Plan --------------------------------------------------------------
    Write-Host ""
    Write-Host "=== Carry re-apply plan ==="
    Write-Host ("  repo:        {0}" -f $RepoPath)
    Write-Host ("  target:      {0} -> {1}" -f $TargetRef, $targetDesc)
    Write-Host ("  new branch:  {0}" -f $BranchName)
    Write-Host ("  old branch:  {0} (will NOT be touched)" -f $config.current_branch)
    Write-Host ("  checkout is: {0}" -f $prevRef)
    Write-Host "  cherry-pick order:"
    $i = 0
    foreach ($ci in $carryInfo) {
        $i++
        if ($ci.Contained) {
            Write-Host ("    {0}. {1}  {2}   << ALREADY CONTAINED IN TARGET - will be skipped; check drop_if" -f $i, $ci.Commit.short, $ci.Commit.title)
        } else {
            Write-Host ("    {0}. {1}  {2}" -f $i, $ci.Commit.short, $ci.Commit.title)
        }
    }
    Write-Host "  then: gate 'cargo test -p buzz-cli' (desktop gates printed, not run)"
    Write-Host ""
    if ($isDirty) {
        Write-Host ("  BLOCKER: working tree in {0} is DIRTY ({1} entries). -Apply will refuse. Commit or stash first." -f $RepoPath, $dirty.Count)
        Write-Host ""
    }

    if (-not $Apply) {
        Write-Host "DRY RUN - nothing was changed. Re-run with -Apply to execute."
        exit 0
    }

    # ---- Apply -------------------------------------------------------------
    if ($isDirty) {
        Fail "Working tree is dirty - refusing to run. Commit or stash changes in $RepoPath first." 1
    }

    Write-Host ("Creating branch {0} at {1}..." -f $BranchName, $TargetRef)
    $null = Invoke-Git @('switch', '-c', $BranchName, $targetSha)

    foreach ($ci in $carryInfo) {
        $pc = $ci.Commit
        if ($ci.Contained) {
            Write-Host ("Skipping {0} - already contained in target (upstream adoption? check drop_if: {1})" -f $pc.short, $pc.drop_if)
            continue
        }
        Write-Host ("Cherry-picking {0}  {1} ..." -f $pc.short, $pc.title)
        $null = Invoke-Git @('cherry-pick', $pc.sha) -AllowFail
        if ($script:LastGitExit -ne 0) {
            Write-Host ""
            Write-Host ("CONFLICT while cherry-picking {0} ({1})." -f $pc.short, $pc.title)
            Write-Host "The repo is left mid-cherry-pick on branch $BranchName so you can resolve by hand:"
            Write-Host ""
            Write-Host ("  1. cd {0}" -f $RepoPath)
            Write-Host "  2. git status                       # see conflicted files"
            Write-Host "  3. resolve conflicts, then: git add <files> ; git cherry-pick --continue"
            Write-Host ("  4. re-run remaining picks by hand if any, then run the gate: cargo test -p buzz-cli")
            Write-Host ""
            Write-Host "To bail out instead:"
            Write-Host ("  git cherry-pick --abort ; git switch {0}" -f $prevRef)
            Write-Host ("  (old branch {0} is untouched either way)" -f $config.current_branch)
            Write-Host ""
            Write-Host "If the conflict is because upstream adopted the feature, DROP the commit:"
            Write-Host ("  drop_if: {0}" -f $pc.drop_if)
            Write-Host "  -> remove it from patch-commits.json and re-run this script on a fresh -BranchName."
            exit 2
        }
    }

    # ---- Fast gate: cargo test -p buzz-cli ---------------------------------
    Write-Host ""
    Write-Host "Running gate: cargo test -p buzz-cli (PowerShell host, MSVC toolchain)..."
    # Windows toolchain notes: run from PowerShell (Git Bash's coreutils `link`
    # shadows MSVC link.exe). Adjust cmakeBin for your VS install if needed.
    $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
    $cmakeBin = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin'
    if ($env:Path -notlike "*$cargoBin*") { $env:Path = "$cargoBin;$env:Path" }
    if ($env:Path -notlike "*$cmakeBin*") { $env:Path = "$env:Path;$cmakeBin" }
    $env:CARGO_HTTP_MULTIPLEXING = 'false'

    Push-Location $RepoPath
    & cargo test -p buzz-cli
    $gateExit = $LASTEXITCODE
    Pop-Location

    Write-Host ""
    if ($gateExit -ne 0) {
        Write-Host ("GATE FAILED: cargo test -p buzz-cli exited {0}." -f $gateExit)
        Write-Host "The new branch exists and the picks are committed - investigate the failure before going further."
        Write-Host "(The 6 known Windows-environment failures are all in the DESKTOP crate, not buzz-cli - they do not excuse a buzz-cli failure.)"
        exit 3
    }
    Write-Host "GATE PASSED: cargo test -p buzz-cli"

    # ---- Next steps (printed, not run) -------------------------------------
    Write-Host ""
    Write-Host "=== SUCCESS - branch $BranchName ready. Remaining manual steps ==="
    Write-Host ""
    Write-Host "Heavy desktop gates (run from PowerShell, NOT Git Bash):"
    Write-Host ("  cd {0}\desktop" -f $RepoPath)
    Write-Host "  pnpm typecheck"
    Write-Host "  pnpm test"
    Write-Host ""
    Write-Host "  # stage the 6 sidecar binaries, then check the tauri crate:"
    Write-Host ("  cd {0}" -f $RepoPath)
    Write-Host "  cargo build -p buzz-acp -p buzz-agent -p buzz-backend-kubernetes -p buzz-dev-mcp -p git-credential-nostr -p buzz-cli"
    Write-Host "  # copy each from target\debug to desktop\src-tauri\binaries\<name>-x86_64-pc-windows-msvc.exe"
    Write-Host ("  cd {0}\desktop\src-tauri" -f $RepoPath)
    Write-Host "  cargo check --tests"
    Write-Host ""
    Write-Host "  When judging 'pnpm test' / desktop test output, EXCLUDE the 6 known"
    Write-Host "  Windows-environment failures listed in MAINTENANCE.md / patch-commits.json."
    Write-Host ""
    Write-Host "Artifact rebuild (after all gates pass):"
    Write-Host ("  git -C {0} bundle create {1}\buzz-patches.bundle {2}..{3}" -f $RepoPath, $ScriptDir, $targetSha.Substring(0, 9), $BranchName)
    Write-Host ("  cd {0}\desktop ; pnpm tauri build      # desktop installers" -f $RepoPath)
    Write-Host ""
    Write-Host "Bookkeeping:"
    Write-Host ("  - update patch-commits.json: current_branch -> {0}, base_ref -> {1}" -f $BranchName, $targetSha)
    Write-Host "  - ship the rebuilt CLI/bundle to your deployment target (see DEPLOYMENT-NOTES.md)"
    Write-Host ("  - old branch {0} left untouched; return to it any time with: git switch {0}" -f $config.current_branch)
    exit 0
}
catch {
    Write-Host ""
    Write-Host ("ERROR: {0}" -f $_.Exception.Message)
    exit 1
}
