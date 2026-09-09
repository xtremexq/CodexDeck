# Explicit environment membership. Account credentials and runtime databases are never shared.
function Assert-DeckEntryName([string]$Name) {
    if ($Name -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$' -or $Name -match '^(con|prn|aux|nul|com[0-9]|lpt[0-9])$') { throw 'Invalid entry name.' }
}
function Read-DeckEnvironmentJson([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        if ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked environment metadata is not supported.' }
        return [IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop
    }
}
function Write-DeckEnvironmentJson([string]$Path, $Value) {
    if (Test-Path -LiteralPath $Path) { [void](Read-DeckEnvironmentJson $Path) }
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $Value -Depth 20), [Text.UTF8Encoding]::new($false))
    try {
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) } }
}
function Get-DeckEntryDirectory([string]$SuiteRoot, [string]$Name) {
    Assert-DeckEntryName $Name
    $root = Get-Item -LiteralPath (Join-Path $SuiteRoot 'accounts')
    $item = Get-Item -LiteralPath (Join-Path $root.FullName $Name)
    if (-not $item.PSIsContainer -or $item.Parent.FullName -ne $root.FullName -or
        (($root.Attributes -bor $item.Attributes) -band [IO.FileAttributes]::ReparsePoint)) { throw 'Entries must be real directories inside accounts.' }
    return $item.FullName
}
function Get-DeckPoolEntry([string]$SuiteRoot, [string]$Name) {
    Assert-DeckEntryName $Name
    $path = Join-Path $SuiteRoot "accounts/$Name/deck-entry.json"
    $entry = Read-DeckEnvironmentJson $path
    if ($entry) {
        if ($entry.Version -ne 1 -or $entry.Kind -ne 'pool' -or $entry.Mode -notin @('Ordered','Best') -or -not @($entry.Accounts).Count) { throw 'Invalid pooled entry configuration.' }
        return $entry
    }
}
function Get-DeckEntryNames([string]$SuiteRoot) {
    @(Get-ChildItem -LiteralPath (Join-Path $SuiteRoot 'accounts') -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$' -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
        Sort-Object @{Expression={ if (Test-Path -LiteralPath (Join-Path $_.FullName 'deck-entry.json')) { 0 } else { 1 } }},
        @{Expression={ if ($_.Name -match '^account(\d+)$') { [long]$Matches[1] } else { [long]::MaxValue } }},Name | ForEach-Object Name)
}
function Get-DeckPoolAccountPlan([string]$SuiteRoot, [string]$Name) {
    $auth=Read-DeckEnvironmentJson (Join-Path (Get-DeckEntryDirectory $SuiteRoot $Name) 'auth.json')
    foreach ($token in @($auth.tokens.id_token,$auth.tokens.access_token)) {
        try {
            $part=$token.Split('.')[1].Replace('-','+').Replace('_','/')
            $claims=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part.PadRight($part.Length+(4-$part.Length%4)%4,'='))) | ConvertFrom-Json
            $plan=$claims.'https://api.openai.com/auth'.chatgpt_plan_type
            if ($plan) { return ([string]$plan).ToLowerInvariant() }
        } catch { }
    }
    return 'unknown'
}
function Resolve-DeckEntryPool([string]$SuiteRoot, $Entry) {
    $names = @($Entry.Accounts)
    if (@($names | Where-Object { $_ -in @('*','*free','*paid') }).Count) {
        if ($names.Count -ne 1) { throw 'Use either * or an explicit pool membership.' }
        $filter=$names[0]
        $names = @(Get-DeckEntryNames $SuiteRoot | Where-Object {
            -not (Get-DeckPoolEntry $SuiteRoot $_) -and (Test-Path -LiteralPath (Join-Path $SuiteRoot "accounts/$_/auth.json"))
        } | Where-Object {
            $filter -eq '*' -or ($filter -eq '*free' -and (Get-DeckPoolAccountPlan $SuiteRoot $_) -eq 'free') -or
            ($filter -eq '*paid' -and (Get-DeckPoolAccountPlan $SuiteRoot $_) -in @('plus','pro','team','business','enterprise','edu'))
        })
    }
    if (-not $names.Count -or $names.Count -gt 200 -or @($names | Sort-Object -Unique).Count -ne $names.Count) { throw 'A pool needs 1-200 distinct signed-in accounts.' }
    foreach ($name in $names) {
        $dir = Get-DeckEntryDirectory $SuiteRoot $name
        if ((Get-DeckPoolEntry $SuiteRoot $name) -or -not (Test-Path -LiteralPath (Join-Path $dir 'auth.json') -PathType Leaf)) { throw 'Pool members must be signed-in accounts, not pooled entries.' }
    }
    return $names
}
function Set-DeckPoolEntry([string]$SuiteRoot, [string]$Name, [string[]]$Members, [string]$Mode = 'Ordered', [switch]$ValidateOnly) {
    Assert-DeckEntryName $Name
    if ($Name -in @('help','list','status','dashboard','share','unshare','sharing')) { throw 'That name is reserved for a command.' }
    if ($Mode -notin @('Ordered','Best')) { throw 'Choose Ordered or Best.' }
    $entry = [pscustomobject]@{Version=1; Kind='pool'; Accounts=@($Members); Mode=$Mode}
    # Validate selected membership now. Wildcard membership can start empty and is resolved at launch.
    if (($Members -join ',') -notin @('*','*free','*paid')) { [void](Resolve-DeckEntryPool $SuiteRoot $entry) }
    $accounts = Join-Path $SuiteRoot 'accounts'
    if (-not $ValidateOnly) { [void][IO.Directory]::CreateDirectory($accounts) }
    if ((Get-Item -LiteralPath $accounts).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked accounts root is not supported.' }
    $dir = Join-Path $accounts $Name
    if (Test-Path -LiteralPath $dir) {
        $dir = Get-DeckEntryDirectory $SuiteRoot $Name
        if (-not (Get-DeckPoolEntry $SuiteRoot $Name)) { throw 'An ordinary account already uses that name. Choose a new pooled entry name.' }
        Assert-DeckEntryIdle $SuiteRoot $Name
    } elseif (-not $ValidateOnly) { [void][IO.Directory]::CreateDirectory($dir) }
    if (Test-Path -LiteralPath (Join-Path $dir 'auth.json')) { throw 'A pooled entry cannot own a login.' }
    if ($ValidateOnly) { return }
    Write-DeckEnvironmentJson (Join-Path $dir 'deck-entry.json') $entry
    foreach ($resource in @('skills','memories','rules','prompts')) { [void][IO.Directory]::CreateDirectory((Join-Path $dir $resource)) }
    return "Pooled entry $Name saved ($Mode; $($Members -join ', ')). Launch with: codex-auth $Name"
}
function Assert-DeckEntryIdle([string]$SuiteRoot, [string]$Name) {
    $dir = Get-DeckEntryDirectory $SuiteRoot $Name
    if (($env:CODEX_HOME -and [IO.Path]::GetFullPath($env:CODEX_HOME).TrimEnd('\') -eq $dir) -or
        ((Get-Command Get-DeckSessions -ErrorAction SilentlyContinue) -and @(Get-DeckSessions (Join-Path $SuiteRoot 'deck') | Where-Object Account -eq $Name).Count)) { throw "Close $Name's connected terminals before changing its environment." }
}
function Get-DeckSharing([string]$SuiteRoot, [string]$Name) {
    $dir = Get-DeckEntryDirectory $SuiteRoot $Name
    $state = Read-DeckEnvironmentJson (Join-Path $dir 'deck-sharing.json')
    if (-not $state) { return [pscustomobject]@{Version=1; Bindings=@()} }
    if ($state.Version -ne 1) { throw 'Unsupported sharing configuration.' }
    return $state
}
function Assert-DeckResource([string]$Resource) {
    if ($Resource -notmatch '^(skills(/[a-zA-Z0-9][a-zA-Z0-9_-]{0,79})?|memories|rules|prompts|AGENTS\.md|mcp:[a-zA-Z0-9_-]{1,80})$') {
        throw 'Share skills, skills/name, memories, rules, prompts, AGENTS.md, or mcp:server-name. Credentials and databases cannot be shared.'
    }
}
function Get-DeckResourcePath([string]$Directory, [string]$Resource) {
    Assert-DeckResource $Resource
    if ($Resource.StartsWith('mcp:')) { throw 'MCP definitions use launch overrides, not filesystem links.' }
    $path = [IO.Path]::GetFullPath((Join-Path $Directory $Resource))
    if (-not $path.StartsWith($Directory.TrimEnd('\')+'\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Resource escaped its entry.' }
    $parent = Split-Path $path -Parent
    while ($parent -ne $Directory) {
        if ((Test-Path -LiteralPath $parent) -and ((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Cannot share a resource inside a linked directory.' }
        $parent = Split-Path $parent -Parent
    }
    return $path
}
function Assert-DeckPlainResource([string]$Path) {
    if ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Resource changed to an unexpected link.' }
}
function ConvertTo-DeckTomlValue($Value) {
    if ($Value -is [string]) { return ConvertTo-Json -InputObject $Value -Compress }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    if ($Value -is [System.Collections.IDictionary]) {
        $parts = @($Value.Keys | Sort-Object | ForEach-Object { (ConvertTo-Json -InputObject ([string]$_) -Compress)+' = '+(ConvertTo-DeckTomlValue $Value[$_]) })
        return '{ '+($parts -join ', ')+' }'
    }
    if ($Value -is [pscustomobject]) {
        $table = @{}; foreach ($p in $Value.PSObject.Properties) { if ($null -ne $p.Value) { $table[$p.Name]=$p.Value } }
        return ConvertTo-DeckTomlValue $table
    }
    if ($Value -is [array]) { return '['+(@($Value | ForEach-Object { ConvertTo-DeckTomlValue $_ }) -join ', ')+']' }
    if ($Value -is [ValueType]) { return [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture) }
    throw 'Unsupported MCP configuration value.'
}
function ConvertTo-DeckCodexArguments([string[]]$Arguments) {
    foreach ($argument in $Arguments) {
        # Windows PowerShell's native argument marshaller otherwise strips TOML string quotes.
        if ($PSVersionTable.PSVersion.Major -le 5) { $argument -replace '(\\*)"', '$1$1\"' }
        else { $argument }
    }
}
function Get-DeckMcpDefinition([string]$Directory, [string]$Server) {
    # Codex parses its own TOML; no lossy regular-expression parsing or extra TOML dependency.
    $previous = $env:CODEX_HOME
    $previousErrors = $ErrorActionPreference
    Push-Location $Directory
    try {
        $env:CODEX_HOME = $Directory
        $ErrorActionPreference = 'Continue'
        $output = & codex mcp get $Server --json 2>$null
        $ErrorActionPreference = $previousErrors
        if ($LASTEXITCODE -ne 0) { throw "Cannot read MCP server $Server from its source entry." }
        $serverConfig = ($output -join "`n") | ConvertFrom-Json -ErrorAction Stop
        $definition = @{}
        if ($serverConfig.transport.type -notin @('stdio','streamable_http')) { throw 'Unsupported MCP transport.' }
        foreach ($p in $serverConfig.transport.PSObject.Properties) {
            if ($p.Name -ne 'type' -and $null -ne $p.Value) { $definition[$p.Name] = $p.Value }
        }
        foreach ($key in @('enabled','required','startup_timeout_sec','tool_timeout_sec','enabled_tools','disabled_tools')) {
            if ($null -ne $serverConfig.$key) { $definition[$key] = $serverConfig.$key }
        }
        return $definition
    } finally { $ErrorActionPreference = $previousErrors; $env:CODEX_HOME = $previous; Pop-Location }
}
function Get-DeckAvailableResources([string]$SuiteRoot, [string]$Name) {
    $dir=Get-DeckEntryDirectory $SuiteRoot $Name
    foreach ($resource in @('skills','memories','rules','prompts','AGENTS.md')) {
        if (Test-Path -LiteralPath (Join-Path $dir $resource)) { $resource }
    }
    foreach ($skill in Get-ChildItem -LiteralPath (Join-Path $dir 'skills') -Directory -ErrorAction SilentlyContinue) {
        if ($skill.Name -match '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}$') { 'skills/'+$skill.Name }
    }
    $previous=$env:CODEX_HOME; $previousErrors=$ErrorActionPreference
    Push-Location $dir
    try {
        $env:CODEX_HOME=$dir; $ErrorActionPreference='Continue'
        $output=& codex mcp list --json 2>$null
        $ErrorActionPreference=$previousErrors
        if ($LASTEXITCODE -ne 0) { throw 'Could not list source MCP definitions.' }
        foreach ($server in (($output -join "`n") | ConvertFrom-Json)) {
            if ($server.name -match '^[a-zA-Z0-9_-]{1,80}$') { 'mcp:'+$server.name }
        }
    } finally { $ErrorActionPreference=$previousErrors; $env:CODEX_HOME=$previous; Pop-Location }
}
function Set-DeckResourceSharing([string]$SuiteRoot, [string]$Source, [string[]]$Targets, [string[]]$Resources, [switch]$Detach, [switch]$ValidateOnly) {
    if (-not $Targets.Count -or -not $Resources.Count) { throw 'Specify targets and resources.' }
    # All means the entries that exist now: a future account still starts isolated.
    if ($Targets -contains '*') {
        if ($Targets.Count -ne 1) { throw 'Use * alone for all current entries.' }
        $Targets = @(Get-DeckEntryNames $SuiteRoot | Where-Object { $Detach -or $_ -ne $Source })
    }
    if (-not $Targets.Count) { throw 'No target entries.' }
    $lockPath = Join-Path $SuiteRoot '.environment.lock'
    if ((Test-Path -LiteralPath $lockPath) -and ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Linked environment lock.' }
    $guard = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $plans = @()
        foreach ($name in @($Targets | Select-Object -Unique)) {
            Assert-DeckEntryIdle $SuiteRoot $name
            $dir = Get-DeckEntryDirectory $SuiteRoot $name
            $state = Get-DeckSharing $SuiteRoot $name
            foreach ($resource in @($Resources | Select-Object -Unique)) {
                Assert-DeckResource $resource
                $binding = @($state.Bindings | Where-Object Resource -eq $resource) | Select-Object -First 1
                if ($Detach) {
                    if ($binding) {
                        if (-not $resource.StartsWith('mcp:')) {
                            $backup=Get-DeckSharingBackupPath $dir $binding.Backup
                            if ($binding.Backup -and -not (Test-Path -LiteralPath $backup)) { throw 'Private backup is missing; nothing was detached.' }
                            $path=Get-DeckResourcePath $dir $resource
                            if ($resource -eq 'AGENTS.md') {
                                Assert-DeckPlainResource $path
                                if ((Test-Path -LiteralPath $path) -and (Get-FileHash -LiteralPath $path).Hash -ne $binding.Hash) { throw 'Shared instructions were edited locally. Preserve those edits before unsharing.' }
                            } else { Assert-DeckResourceLink $SuiteRoot $dir $binding }
                        }
                        $plans += @{Name=$name; Dir=$dir; Resource=$resource; Binding=$binding; State=$state}
                    }
                    continue
                }
                if ($name -eq $Source) { throw 'Source and target must differ.' }
                $sourceDir = Get-DeckEntryDirectory $SuiteRoot $Source
                if ($binding) { throw "$name already shares $resource. Unshare it first." }
                foreach ($existing in @($state.Bindings.Resource)+@($Resources)) {
                    if ($existing -and $existing -ne $resource -and ($existing.StartsWith($resource+'/') -or $resource.StartsWith($existing+'/'))) { throw 'Cannot overlap a shared directory and its children.' }
                }
                if (@((Get-DeckSharing $SuiteRoot $Source).Bindings | Where-Object { $_.Resource -eq $resource -or $resource.StartsWith($_.Resource+'/') }).Count) { throw 'Choose the original resource owner; chained sharing is not supported.' }
                if ($resource.StartsWith('mcp:')) { [void](Get-DeckMcpDefinition $sourceDir $resource.Substring(4)) }
                else {
                    $sourcePath = Get-DeckResourcePath $sourceDir $resource
                    $sourceItem = Get-Item -LiteralPath $sourcePath -Force
                    if ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Resource owners must hold a real resource, not a link.' }
                    if (($resource -eq 'AGENTS.md') -eq $sourceItem.PSIsContainer) { throw 'Unexpected resource file type.' }
                    $targetPath = Get-DeckResourcePath $dir $resource
                    if ((Test-Path -LiteralPath $targetPath) -and ((Get-Item -LiteralPath $targetPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Target already contains an unmanaged link.' }
                }
                $plans += @{Name=$name; Dir=$dir; Resource=$resource; SourceDir=$sourceDir; State=$state}
            }
        }
        if ($ValidateOnly) { return }
        foreach ($plan in $plans) {
            $resource = $plan.Resource; $dir = $plan.Dir
            $state = Get-DeckSharing $SuiteRoot $plan.Name
            $statePath = Join-Path $dir 'deck-sharing.json'
            if ($Detach) {
                $binding = $plan.Binding
                if (-not $resource.StartsWith('mcp:')) {
                    $path = Get-DeckResourcePath $dir $resource
                    $backup = Get-DeckSharingBackupPath $dir $binding.Backup
                    if ($binding.Backup -and -not (Test-Path -LiteralPath $backup)) { throw 'Private backup is missing; nothing was detached.' }
                    if ($resource -eq 'AGENTS.md') {
                        Assert-DeckPlainResource $path
                        if ((Test-Path -LiteralPath $path) -and (Get-FileHash -LiteralPath $path).Hash -ne $binding.Hash) { throw 'Shared instructions were edited locally. Preserve those edits before unsharing.' }
                        if (Test-Path -LiteralPath $path) { [IO.File]::Delete($path) }
                    } else {
                        Assert-DeckResourceLink $SuiteRoot $dir $binding
                        # Delete only the junction itself. Never recurse into the shared owner.
                        [IO.Directory]::Delete($path)
                    }
                    if ($backup -and (Test-Path -LiteralPath $backup)) { Move-Item -LiteralPath $backup -Destination $path }
                }
                $state.Bindings = @($state.Bindings | Where-Object Resource -ne $resource)
                Write-DeckEnvironmentJson $statePath $state
            } else {
                $binding = [pscustomobject]@{Resource=$resource; Source=$Source; Backup=''; Hash=''}
                if (-not $resource.StartsWith('mcp:')) {
                    $path = Get-DeckResourcePath $dir $resource
                    $sourcePath = Get-DeckResourcePath $plan.SourceDir $resource
                    $backup = $null
                    if (Test-Path -LiteralPath $path) {
                        $binding.Backup = [guid]::NewGuid().ToString('N')
                        $backup = Get-DeckSharingBackupPath $dir $binding.Backup
                        [void][IO.Directory]::CreateDirectory((Split-Path $backup -Parent))
                        Move-Item -LiteralPath $path -Destination $backup
                    }
                    try {
                        [void][IO.Directory]::CreateDirectory((Split-Path $path -Parent))
                        if ($resource -eq 'AGENTS.md') { Copy-Item -LiteralPath $sourcePath -Destination $path; $binding.Hash=(Get-FileHash -LiteralPath $path).Hash }
                        else { [void](New-Item -ItemType Junction -Path $path -Target $sourcePath) }
                        $state.Bindings = @($state.Bindings)+@($binding)
                        Write-DeckEnvironmentJson $statePath $state
                    } catch {
                        if (Test-Path -LiteralPath $path) {
                            if ($resource -eq 'AGENTS.md') { [IO.File]::Delete($path) } else { [IO.Directory]::Delete($path) }
                        }
                        if ($backup) { Move-Item -LiteralPath $backup -Destination $path }
                        throw
                    }
                } else { $state.Bindings=@($state.Bindings)+@($binding); Write-DeckEnvironmentJson $statePath $state }
            }
            Write-Output ("{0}: {1} {2}" -f $plan.Name, $(if ($Detach) { 'unshared' } else { 'shared' }), $resource)
        }
    } finally { $guard.Dispose() }
}
function Get-DeckSharingBackupPath([string]$Directory, [string]$Id) {
    if (-not $Id) { return $null }
    if ($Id -notmatch '^[a-f0-9]{32}$') { throw 'Invalid private resource backup.' }
    $root = Join-Path $Directory '.deck-sharing-backups'
    if ((Test-Path -LiteralPath $root) -and ((Get-Item -LiteralPath $root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Linked backup directory.' }
    $path = Join-Path $root $Id
    if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Linked private resource backup.' }
    return $path
}
function Assert-DeckResourceLink([string]$SuiteRoot, [string]$Directory, $Binding) {
    $path = Get-DeckResourcePath $Directory $Binding.Resource
    $source = Get-DeckResourcePath (Get-DeckEntryDirectory $SuiteRoot $Binding.Source) $Binding.Resource
    Assert-DeckPlainResource $source
    $item = Get-Item -LiteralPath $path -Force
    if ($item.LinkType -ne 'Junction' -or @($item.Target).Count -ne 1 -or [IO.Path]::GetFullPath(@($item.Target)[0]) -ne $source) { throw 'Shared resource link changed unexpectedly.' }
}
function Get-DeckSharedArguments([string]$SuiteRoot, [string]$Name) {
    $dir = Get-DeckEntryDirectory $SuiteRoot $Name
    $state = Get-DeckSharing $SuiteRoot $Name
    foreach ($binding in $state.Bindings) {
        Assert-DeckResource $binding.Resource
        $sourceDir = Get-DeckEntryDirectory $SuiteRoot $binding.Source
        if ($binding.Resource.StartsWith('mcp:')) {
            $server = $binding.Resource.Substring(4)
            $definition = Get-DeckMcpDefinition $sourceDir $server
            '-c'; ('mcp_servers.'+$server+'='+(ConvertTo-DeckTomlValue $definition))
        } elseif ($binding.Resource -eq 'AGENTS.md') {
            $path = Get-DeckResourcePath $dir $binding.Resource
            Assert-DeckPlainResource $path
            if ((Get-FileHash -LiteralPath $path).Hash -ne $binding.Hash) { throw 'Shared instructions were edited locally. Preserve those edits before launching.' }
            $source = Get-DeckResourcePath $sourceDir $binding.Resource
            Assert-DeckPlainResource $source
            if ((Get-FileHash -LiteralPath $source).Hash -ne $binding.Hash) {
                Copy-Item -LiteralPath $source -Destination $path -Force
                $binding.Hash = (Get-FileHash -LiteralPath $path).Hash
                Write-DeckEnvironmentJson (Join-Path $dir 'deck-sharing.json') $state
            }
        } else { Assert-DeckResourceLink $SuiteRoot $dir $binding }
    }
}
function Assert-DeckEntryUnreferenced([string]$SuiteRoot, [string]$Name) {
    foreach ($other in Get-DeckEntryNames $SuiteRoot) {
        $sharing = Get-DeckSharing $SuiteRoot $other
        if (($other -eq $Name -and @($sharing.Bindings).Count) -or @($sharing.Bindings | Where-Object Source -eq $Name).Count) { throw 'Unshare this entry and its consumers before renaming or deleting it.' }
        $pool = Get-DeckPoolEntry $SuiteRoot $other
        if ($other -ne $Name -and $pool -and $Name -in $pool.Accounts) { throw "Update pool $other before renaming or deleting this member." }
    }
}
