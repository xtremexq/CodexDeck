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
    if ($Name -in @('help','list','status','dashboard','resume','share','unshare','sharing')) { throw 'That name is reserved for a command.' }
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

# Optional managed integrations. Deck owns only the adapter and receipt; upstream
# packages are downloaded into versioned folders after an explicit enable/update.
function Get-DeckIntegrationCatalog([string]$SuiteRoot) {
    $path=Join-Path $SuiteRoot 'Deck.Integrations.json'
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw 'Deck integration manifest is missing. Reinstall Codex Deck.'}
    $catalog=[IO.File]::ReadAllText($path) | ConvertFrom-Json
    if($catalog.schema -ne 1){throw 'Unsupported Deck integration manifest.'}
    return $catalog
}
function Get-DeckIntegrationState([string]$SuiteRoot) {
    $path=Join-Path $SuiteRoot 'integrations/state.json'
    if(Test-Path -LiteralPath $path -PathType Leaf){
        try{return [IO.File]::ReadAllText($path) | ConvertFrom-Json}catch{}
    }
    return [pscustomobject]@{schema=1;components=[pscustomobject]@{}}
}
function Write-DeckIntegrationState([string]$SuiteRoot,$State) {
    $path=Join-Path $SuiteRoot 'integrations/state.json'; $directory=Split-Path -Parent $path
    [void][IO.Directory]::CreateDirectory($directory)
    $temporary=Join-Path $directory ([guid]::NewGuid().ToString('N')+'.tmp')
    try{
        [IO.File]::WriteAllText($temporary,(ConvertTo-Json -InputObject $State -Depth 12),[Text.UTF8Encoding]::new($false))
        if([IO.File]::Exists($path)){[IO.File]::Replace($temporary,$path,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temporary,$path)}
    }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}
function Get-DeckIntegrationComponent([string]$SuiteRoot,[ValidateSet('rtk','headroom','codegraph','browser_harness')][string]$Name) {
    $catalog=Get-DeckIntegrationCatalog $SuiteRoot
    $component=$catalog.components.$Name
    if(-not $component){throw "Unknown Deck integration: $Name"}
    return $component
}
function Get-DeckIntegrationStatus([string]$SuiteRoot,[ValidateSet('rtk','headroom','codegraph','browser_harness')][string]$Name) {
    $component=Get-DeckIntegrationComponent $SuiteRoot $Name
    if($Name -eq 'browser_harness'){
        $command=Get-Command browser-harness -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $executable=if($command){[string]$command.Source}else{''}
        $version=''
        if($executable){
            $cachePath=Join-Path $SuiteRoot 'integrations/browser-harness-detection.json'
            $file=Get-Item -LiteralPath $executable -ErrorAction SilentlyContinue
            if($file){
                try{
                    if(Test-Path -LiteralPath $cachePath -PathType Leaf){
                        $cached=[IO.File]::ReadAllText($cachePath) | ConvertFrom-Json
                        if($cached.executable -eq $executable -and $cached.length -eq $file.Length -and $cached.modifiedUtcTicks -eq $file.LastWriteTimeUtc.Ticks -and $cached.version -match '^\d+(?:\.\d+){1,3}$'){$version=[string]$cached.version}
                    }
                }catch{}
                if(-not $version){
                    try{$reported=(& $executable --version 2>$null | Select-Object -First 1);if($reported -match '(\d+(?:\.\d+){1,3})'){$version=$Matches[1]}}catch{}
                    if($version){
                        try{
                            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $cachePath))
                            [IO.File]::WriteAllText($cachePath,(ConvertTo-Json -Compress -InputObject @{executable=$executable;length=$file.Length;modifiedUtcTicks=$file.LastWriteTimeUtc.Ticks;version=$version}),[Text.UTF8Encoding]::new($false))
                        }catch{}
                    }
                }
            }
        }
        $valid=[bool]($executable -and $version)
        return [pscustomobject]@{Name=$Name;DisplayName=$component.displayName;Installed=$valid;Valid=$valid;Version=$version;Executable=$executable;Versions=@();ProjectUrl=$component.projectUrl;License=$component.license;External=$true}
    }
    $state=Get-DeckIntegrationState $SuiteRoot
    $entry=$state.components.$Name
    $path=if($entry -and $entry.version){Join-Path $SuiteRoot ("integrations/packages/{0}/{1}/{2}" -f $Name,$entry.version,$component.executable)}else{$null}
    $valid=[bool]($path -and (Test-Path -LiteralPath $path -PathType Leaf))
    if($valid -and $entry.sha256){$valid=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq [string]$entry.sha256}
    if($valid -and $Name -eq 'codegraph'){$valid=Test-Path -LiteralPath (Join-Path (Split-Path -Parent $path) 'onnxruntime.dll') -PathType Leaf}
    $versions=@(Get-ChildItem -LiteralPath (Join-Path $SuiteRoot "integrations/packages/$Name") -Directory -ErrorAction SilentlyContinue | Where-Object {$_.Name -notlike '.stage-*'} | Sort-Object LastWriteTimeUtc -Descending | ForEach-Object Name)
    return [pscustomobject]@{Name=$Name;DisplayName=$component.displayName;Installed=$valid;Valid=$valid;Version=if($entry){[string]$entry.version}else{''};Executable=$path;Versions=$versions;ProjectUrl=$component.projectUrl;License=$component.license}
}
function Get-DeckIntegrationExpectedHash([string]$ChecksumPath,[string]$AssetName) {
    $text=[IO.File]::ReadAllText($ChecksumPath)
    $escaped=[regex]::Escape($AssetName)
    if($text -match "(?im)^\s*([a-f0-9]{64})\s+(?:\*|\s)?$escaped\s*$"){return $Matches[1].ToUpperInvariant()}
    if($text -match '(?im)^\s*([a-f0-9]{64})\s*$'){return $Matches[1].ToUpperInvariant()}
    throw "Published checksum did not contain $AssetName."
}
function Invoke-DeckIntegrationDownload([string]$Uri,[string]$Path) {
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Path -Headers @{'User-Agent'='CodexDeck-managed-integrations';'Accept'='application/octet-stream'} -TimeoutSec 90
}
function Resolve-DeckGithubRelease([string]$Repository) {
    Invoke-RestMethod -UseBasicParsing -Uri ("https://api.github.com/repos/{0}/releases/latest" -f $Repository) -Headers @{'User-Agent'='CodexDeck-managed-integrations';'Accept'='application/vnd.github+json'} -TimeoutSec 30
}
function Get-DeckBrowserHarnessLatestVersion {
    $release=Invoke-RestMethod -UseBasicParsing -Uri 'https://pypi.org/pypi/browser-harness/json' -TimeoutSec 30
    $version=[string]$release.info.version
    if($version -notmatch '^\d+(?:\.\d+){1,3}$'){throw 'PyPI returned an unsupported Browser Harness version.'}
    return $version
}
function Install-DeckIntegration([string]$SuiteRoot,[ValidateSet('rtk','headroom','codegraph','browser_harness')][string]$Name,[switch]$Update) {
    $component=Get-DeckIntegrationComponent $SuiteRoot $Name
    if($Name -eq 'browser_harness'){
        $existing=Get-DeckIntegrationStatus $SuiteRoot $Name
        if($existing.Valid -and -not $Update){return $existing}
        $uv=Get-Command uv -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if(-not $uv){throw 'Browser Harness installation requires uv on PATH.'}
        $arguments=@('tool','install','--python','3.12')
        if($existing.Valid){$arguments+=@('--upgrade','--force')}
        $arguments+='browser-harness'
        & $uv.Source @arguments | Out-Null
        if($LASTEXITCODE -ne 0){throw 'uv could not install Browser Harness.'}
        $installed=Get-DeckIntegrationStatus $SuiteRoot $Name
        if(-not $installed.Valid){throw 'Browser Harness CLI was not found on PATH after installation. Open a new terminal and retry.'}
        if($Update -and $existing.Valid){Sync-DeckBrowserHarnessSkillSource $SuiteRoot -Refresh | Out-Null}
        return $installed
    }
    $packages=Join-Path $SuiteRoot "integrations/packages/$Name"; [void][IO.Directory]::CreateDirectory($packages)
    $version=''; $downloads=@{}
    if($component.provider -eq 'github'){
        $release=Resolve-DeckGithubRelease $component.repository
        $version=([string]$release.tag_name).TrimStart('v')
        foreach($asset in $release.assets){$downloads[[string]$asset.name]=[string]$asset.browser_download_url}
        foreach($required in @($component.asset,$component.checksumAsset,$component.supportAsset,$component.supportChecksumAsset | Where-Object {$_})){
            if(-not $downloads.ContainsKey([string]$required)){throw "Release $version is missing $required."}
        }
    }else{
        $release=Invoke-RestMethod -UseBasicParsing -Uri ("https://pypi.org/pypi/{0}/json" -f $component.package) -TimeoutSec 30
        $version=[string]$release.info.version
        $wheel=@($release.urls | Where-Object {$_.packagetype -eq 'bdist_wheel' -and $_.filename.EndsWith([string]$component.wheelPattern,[StringComparison]::OrdinalIgnoreCase)}) | Select-Object -First 1
        if(-not $wheel){throw "Headroom $version does not publish the expected signed Windows wheel."}
    }
    if($version -notmatch '^\d+(?:\.\d+){1,3}(?:[-+][a-zA-Z0-9.-]+)?$'){throw 'Upstream returned an unsafe version identifier.'}
    $final=Join-Path $packages $version
    if((Test-Path -LiteralPath $final -PathType Container) -and
       -not (Test-Path -LiteralPath (Join-Path $final $component.executable) -PathType Leaf)){
        Remove-Item -LiteralPath $final -Recurse -Force
    }
    if(-not (Test-Path -LiteralPath $final -PathType Container)){
        $stage=Join-Path $packages ('.stage-'+[guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($stage)
        try{
            if($Name -eq 'rtk'){
                $archive=Join-Path $stage $component.asset; $checksum=Join-Path $stage $component.checksumAsset
                Invoke-DeckIntegrationDownload $downloads[[string]$component.asset] $archive; Invoke-DeckIntegrationDownload $downloads[[string]$component.checksumAsset] $checksum
                $expected=Get-DeckIntegrationExpectedHash $checksum $component.asset
                if((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expected){throw 'RTK download failed checksum verification.'}
                $expanded=Join-Path $stage 'expanded'; Expand-Archive -LiteralPath $archive -DestinationPath $expanded
                $binary=Get-ChildItem -LiteralPath $expanded -Filter rtk.exe -File -Recurse | Select-Object -First 1
                if(-not $binary){throw 'RTK archive did not contain rtk.exe.'}
                Copy-Item -LiteralPath $binary.FullName -Destination (Join-Path $stage 'rtk.exe')
            }elseif($Name -eq 'codegraph'){
                foreach($pair in @(@($component.asset,$component.checksumAsset,'codegraph-server.exe'),@($component.supportAsset,$component.supportChecksumAsset,'onnxruntime.dll'))){
                    $source=Join-Path $stage $pair[0]; $checksum=Join-Path $stage $pair[1]
                    Invoke-DeckIntegrationDownload $downloads[[string]$pair[0]] $source; Invoke-DeckIntegrationDownload $downloads[[string]$pair[1]] $checksum
                    if((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne (Get-DeckIntegrationExpectedHash $checksum $pair[0])){throw "CodeGraph download failed checksum verification for $($pair[0])."}
                    if($pair[0] -ne $pair[2]){Move-Item -LiteralPath $source -Destination (Join-Path $stage $pair[2])}
                }
            }else{
                $wheelPath=Join-Path $stage $wheel.filename
                Invoke-DeckIntegrationDownload $wheel.url $wheelPath
                if((Get-FileHash -LiteralPath $wheelPath -Algorithm SHA256).Hash -ne ([string]$wheel.digests.sha256).ToUpperInvariant()){throw 'Headroom wheel failed PyPI checksum verification.'}
                $python=$null
                foreach($candidate in @('py.exe','python.exe')){try{$python=(Get-Command $candidate -ErrorAction Stop).Source;break}catch{}}
                if(-not $python){throw 'Headroom MCP requires Python 3.10 or newer.'}
                # Windows console entry points embed the venv path. Build at its
                # permanent location so activation survives the download stage.
                [void][IO.Directory]::CreateDirectory($final)
                $venv=Join-Path $final 'venv'
                if([IO.Path]::GetFileName($python) -ieq 'py.exe'){& $python -3 -m venv $venv}else{& $python -m venv $venv}
                if($LASTEXITCODE -ne 0){throw 'Could not create the private Headroom environment.'}
                $venvPython=Join-Path $venv 'Scripts/python.exe'
                & $venvPython -m pip install --disable-pip-version-check --no-input ($wheelPath+'[mcp]')
                if($LASTEXITCODE -ne 0){throw 'Headroom MCP dependency installation failed.'}
                Remove-Item -LiteralPath $wheelPath -Force
            }
            $expectedExecutable=Join-Path $(if($Name -eq 'headroom'){$final}else{$stage}) $component.executable
            if(-not (Test-Path -LiteralPath $expectedExecutable -PathType Leaf)){throw "$($component.displayName) executable was not installed."}
            if($Name -ne 'headroom'){[IO.Directory]::Move($stage,$final); $stage=$null}
        }catch{
            if($Name -eq 'headroom' -and [IO.Directory]::Exists($final)){[IO.Directory]::Delete($final,$true)}
            throw
        }finally{if($stage -and [IO.Directory]::Exists($stage)){[IO.Directory]::Delete($stage,$true)}}
    }
    $executable=Join-Path $final $component.executable
    if(-not (Test-Path -LiteralPath $executable -PathType Leaf)){throw "$($component.displayName) $version is incomplete."}
    $old=Get-DeckIntegrationState $SuiteRoot; $components=[ordered]@{}
    foreach($property in @($old.components.PSObject.Properties)){$components[$property.Name]=$property.Value}
    $previous=@(); if($components.Contains($Name)){$previous=@($components[$Name].history)+@([string]$components[$Name].version) | Where-Object {$_ -and $_ -ne $version} | Select-Object -Unique}
    $components[$Name]=[ordered]@{version=$version;sha256=(Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash;installedAt=[DateTimeOffset]::UtcNow.ToString('o');history=@($previous)}
    Write-DeckIntegrationState $SuiteRoot ([ordered]@{schema=1;components=$components})
    return Get-DeckIntegrationStatus $SuiteRoot $Name
}
function Restore-DeckIntegration([string]$SuiteRoot,[ValidateSet('rtk','headroom','codegraph','browser_harness')][string]$Name) {
    if($Name -eq 'browser_harness'){throw 'Browser Harness is installed outside Deck; use its own package manager to roll back.'}
    $status=Get-DeckIntegrationStatus $SuiteRoot $Name; $state=Get-DeckIntegrationState $SuiteRoot; $entry=$state.components.$Name
    $target=@($entry.history | Where-Object {$_ -and $_ -ne $entry.version -and (Test-Path -LiteralPath (Join-Path $SuiteRoot "integrations/packages/$Name/$_") -PathType Container)}) | Select-Object -First 1
    if(-not $target){throw 'No earlier installed version is available.'}
    $component=Get-DeckIntegrationComponent $SuiteRoot $Name; $executable=Join-Path $SuiteRoot "integrations/packages/$Name/$target/$($component.executable)"
    if(-not (Test-Path -LiteralPath $executable -PathType Leaf)){throw 'The earlier installation is incomplete.'}
    $entry.history=@(@([string]$entry.version)+@($entry.history | Where-Object {$_ -ne $target}) | Select-Object -Unique); $entry.version=[string]$target; $entry.sha256=(Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash
    Write-DeckIntegrationState $SuiteRoot $state
    return Get-DeckIntegrationStatus $SuiteRoot $Name
}
function Ensure-DeckIntegrationSelection([string]$SuiteRoot,$Settings) {
    $names=@(); if($Settings.ContextOptimizer -eq 'RTK'){$names+='rtk'}elseif($Settings.ContextOptimizer -eq 'Headroom'){$names+='headroom'}; if($Settings.CodeGraphEnabled){$names+='codegraph'}; if($Settings.BrowserHarnessEnabled){$names+='browser_harness'}
    foreach($name in $names){if(-not (Get-DeckIntegrationStatus $SuiteRoot $name).Valid){Install-DeckIntegration $SuiteRoot $name | Out-Null}}
}
function Get-DeckIntegrationWorkerCode([string]$SuiteRoot,[string[]]$Names,[switch]$Update) {
    $core=(Join-Path $SuiteRoot 'Deck.Core.ps1').Replace("'","''")
    $root=$SuiteRoot.Replace("'","''")
    $namesLiteral=@($Names | ForEach-Object { "'"+$_.Replace("'","''")+"'" }) -join ','
    $updateLiteral=if($Update){'$true'}else{'$false'}
    return "`$ErrorActionPreference='Stop'`n. '$core'`nforeach(`$name in @($namesLiteral)){Install-DeckIntegration '$root' `$name -Update:$updateLiteral | Out-Null}"
}
function Get-DeckBrowserHarnessVersionWorkerCode([string]$SuiteRoot) {
    $core=(Join-Path $SuiteRoot 'Deck.Core.ps1').Replace("'","''")
    return "`$ErrorActionPreference='Stop'`n. '$core'`nGet-DeckBrowserHarnessLatestVersion"
}
function Sync-DeckBrowserHarnessSkillSource([string]$SuiteRoot,[switch]$Refresh) {
    $source=Join-Path $SuiteRoot 'integrations/skills/browser-harness/SKILL.md'
    if((Test-Path -LiteralPath $source -PathType Leaf) -and -not $Refresh){return $source}
    $status=Get-DeckIntegrationStatus $SuiteRoot browser_harness
    if(-not $status.Valid){throw 'Browser Harness CLI is unavailable.'}
    $content=(& $status.Executable skill 2>$null) -join "`n"
    if($LASTEXITCODE -ne 0 -or $content -notmatch '(?m)^name:\s*browser-harness\s*$'){throw 'Browser Harness did not return a valid skill.'}
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $source))
    $temporary=$source+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllText($temporary,$content+"`n",[Text.UTF8Encoding]::new($false))
        if([IO.File]::Exists($source)){[IO.File]::Replace($temporary,$source,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temporary,$source)}
    }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
    return $source
}
function Sync-DeckBrowserHarnessSkill([string]$SuiteRoot,[string]$AccountDirectory,[bool]$Enabled) {
    $target=Join-Path $AccountDirectory 'skills/browser-harness'
    $sourceDirectory=Join-Path $SuiteRoot 'integrations/skills/browser-harness'
    $managed=Test-DeckBundledSkillLink $target $sourceDirectory
    if(-not $Enabled){if($managed){[IO.Directory]::Delete($target)};return}
    if(Test-Path -LiteralPath $target){return}
    $source=Sync-DeckBrowserHarnessSkillSource $SuiteRoot
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
    [void](New-Item -ItemType Junction -Path $target -Target (Split-Path -Parent $source))
}
function Get-DeckIntegrationLaunch([string]$SuiteRoot,$Settings) {
    $arguments=@(); $sections=@(); $environment=@{}
    if($Settings.ContextOptimizer -eq 'RTK'){
        $status=Get-DeckIntegrationStatus $SuiteRoot rtk; if(-not $status.Valid){throw 'RTK is enabled but not installed. Open Deck Settings and install it.'}
        $node=(Get-Command node.exe -ErrorAction Stop).Source; $hook=Join-Path $SuiteRoot 'Deck.RtkHook.cjs'
        $command='"'+$node+'" "'+$hook+'"'; $hookConfig=@(@{matcher='^Bash$';hooks=@(@{type='command';command=$command;command_windows=$command;timeout=5;statusMessage='Optimizing shell output with RTK'})})
        $arguments+=@('-c','features.hooks=true','-c',('hooks.PreToolUse='+(ConvertTo-DeckTomlValue $hookConfig)))
        $environment.CODEX_DECK_RTK_EXE=$status.Executable; $environment.RTK_TELEMETRY_DISABLED='1'
    }elseif($Settings.ContextOptimizer -eq 'Headroom'){
        $status=Get-DeckIntegrationStatus $SuiteRoot headroom; if(-not $status.Valid){throw 'Headroom MCP is enabled but not installed. Open Deck Settings and install it.'}
        $workspace=Join-Path $SuiteRoot 'integrations/headroom-workspaces'; [void][IO.Directory]::CreateDirectory($workspace)
        $definition=@{command=$status.Executable;args=@('mcp','serve');env=@{HEADROOM_WORKSPACE_DIR=$workspace};startup_timeout_sec=20;tool_timeout_sec=120}
        $arguments+=@('-c',('mcp_servers.deck_headroom='+(ConvertTo-DeckTomlValue $definition)))
        $sections+='Deck Context Optimizer: For large tool output or data that would otherwise fill the prompt, use deck_headroom compression and retain the returned retrieval ID. Retrieve exact source material when fidelity is needed.'
    }
    if($Settings.CodeGraphEnabled){
        $status=Get-DeckIntegrationStatus $SuiteRoot codegraph; if(-not $status.Valid){throw 'CodeGraph is enabled but not installed. Open Deck Settings and install it.'}
        $profile=if($Settings.CodeGraphProfile -in @('core','graph','all')){$Settings.CodeGraphProfile}else{'core'}
        $definition=@{command=$status.Executable;args=@('--mcp','--profile',$profile);startup_timeout_sec=30;tool_timeout_sec=120}
        $arguments+=@('-c',('mcp_servers.deck_codegraph='+(ConvertTo-DeckTomlValue $definition)))
        $sections+='Deck Code Intelligence: Prefer deck_codegraph for repository discovery and relationship queries when it avoids broad file reads or repeated searches. Verify exact source before editing.'
    }
    return [pscustomobject]@{Arguments=@($arguments);InstructionSections=@($sections);Environment=$environment}
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
