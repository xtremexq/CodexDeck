param(
    [switch]$ClaudeDefaultsEdit,
    [string]$ClaudeDefaultsSuiteRoot=$PSScriptRoot
)

function Get-DeckClaudeDefaultsPath([string]$SuiteRoot) {
    return Join-Path $SuiteRoot 'deck/claude/default-settings.json'
}

function Get-DeckClaudeGlobalInstructionsPath([string]$SuiteRoot) {
    return Join-Path $SuiteRoot 'deck/claude/global-instructions.md'
}

function Get-DeckClaudeContextPolicyPath([string]$SuiteRoot) {
    return Join-Path $SuiteRoot 'deck/claude/context-policy.json'
}

function Get-DeckClaudeNativeImportPath([string]$SuiteRoot) {
    return Join-Path $SuiteRoot 'deck/claude/native-import'
}

function Get-DeckClaudeNativeImportDefaultsPath([string]$SuiteRoot) {
    return Join-Path (Get-DeckClaudeNativeImportPath $SuiteRoot) 'defaults.json'
}

function Get-DeckClaudeContextPolicy([string]$SuiteRoot) {
    $path=Get-DeckClaudeContextPolicyPath $SuiteRoot
    $saved=Read-DeckClaudeSettingsFile $path 'Claude context policy'
    $sources=@('user')
    if($null -eq $saved.PSObject.Properties['ProjectSettings'] -or [bool]$saved.ProjectSettings){$sources+='project'}
    if($null -eq $saved.PSObject.Properties['LocalSettings'] -or [bool]$saved.LocalSettings){$sources+='local'}
    $mode=if($saved.InstructionFilesMode -in @('claude-md-or-agents-md','claude-md-and-agents-md','claude-md','managed-only')){[string]$saved.InstructionFilesMode}else{'claude-md-or-agents-md'}
    $nativeClaudeMd=Join-Path (Join-Path $env:USERPROFILE '.claude') 'CLAUDE.md'
    $excludes=@(if($saved.PSObject.Properties['ClaudeMdExcludes']){foreach($item in @($saved.ClaudeMdExcludes)){if($item -is [string] -and -not [string]::IsNullOrWhiteSpace($item)){$item.Trim()}}})
    if($nativeClaudeMd -notin $excludes){$excludes+=,$nativeClaudeMd}
    return [pscustomobject]@{
        SettingSources=$sources
        ProjectSettings=($sources -contains 'project')
        LocalSettings=($sources -contains 'local')
        InstructionFilesMode=$mode
        ClaudeMdExcludes=$excludes
        AutoMemoryEnabled=if($null -eq $saved.PSObject.Properties['AutoMemoryEnabled']){$true}else{[bool]$saved.AutoMemoryEnabled}
        SkillsAndCommandsEnabled=if($null -eq $saved.PSObject.Properties['SkillsAndCommandsEnabled']){$true}else{[bool]$saved.SkillsAndCommandsEnabled}
        BundledSkillsEnabled=if($null -eq $saved.PSObject.Properties['BundledSkillsEnabled']){$true}else{[bool]$saved.BundledSkillsEnabled}
        McpEnabled=if($null -eq $saved.PSObject.Properties['McpEnabled']){$true}else{[bool]$saved.McpEnabled}
        SafeMode=if($null -eq $saved.PSObject.Properties['SafeMode']){$false}else{[bool]$saved.SafeMode}
    }
}

function Set-DeckClaudeContextPolicy([string]$SuiteRoot,$Policy) {
    if(-not (Test-DeckClaudeJsonObject $Policy)){throw 'Claude context policy must be a JSON object.'}
    $mode=[string]$Policy.InstructionFilesMode
    if($mode -notin @('claude-md-or-agents-md','claude-md-and-agents-md','claude-md','managed-only')){throw 'Choose a supported Claude instruction file mode.'}
    $excludes=@(foreach($entry in @($Policy.ClaudeMdExcludes)){if($entry -is [string] -and -not [string]::IsNullOrWhiteSpace($entry)){ $entry=$entry.Trim(); if($entry.Length -gt 2048 -or $entry.Contains("`0")){throw 'Claude MD exclude patterns must be under 2048 characters.'}; $entry }})
    $nativeClaudeMd=Join-Path (Join-Path $env:USERPROFILE '.claude') 'CLAUDE.md'
    if($nativeClaudeMd -notin $excludes){$excludes+=,$nativeClaudeMd}
    if(@($excludes | Select-Object -Unique).Count -ne $excludes.Count){$excludes=@($excludes | Select-Object -Unique)}
    if($excludes.Count -gt 200){throw 'Use at most 200 Claude MD exclude patterns.'}
    $value=[pscustomobject]@{
        ProjectSettings=[bool]$Policy.ProjectSettings
        LocalSettings=[bool]$Policy.LocalSettings
        InstructionFilesMode=$mode
        ClaudeMdExcludes=$excludes
        AutoMemoryEnabled=[bool]$Policy.AutoMemoryEnabled
        SkillsAndCommandsEnabled=[bool]$Policy.SkillsAndCommandsEnabled
        BundledSkillsEnabled=[bool]$Policy.BundledSkillsEnabled
        McpEnabled=[bool]$Policy.McpEnabled
        SafeMode=[bool]$Policy.SafeMode
    }
    Write-DeckClaudeTextAtomically (Get-DeckClaudeContextPolicyPath $SuiteRoot) (ConvertTo-Json -InputObject $value -Depth 20)
    return $value
}

function Get-DeckClaudeContextSettings($Policy) {
    $instructionMode=[string]$Policy.InstructionFilesMode
    $pluginIds=@('cc-plugin-agents-md@builtin','agents-md@builtin')
    $pluginConfigs=[ordered]@{}
    foreach($pluginId in $pluginIds){$pluginConfigs[$pluginId]=[pscustomobject]@{options=[pscustomobject]@{instructionFiles=$instructionMode}}}
    $settings=[ordered]@{
        pluginConfigs=[pscustomobject]$pluginConfigs
        autoMemoryEnabled=[bool]$Policy.AutoMemoryEnabled
        disableBundledSkills=(-not [bool]$Policy.BundledSkillsEnabled)
    }
    if(@($Policy.ClaudeMdExcludes).Count){$settings.claudeMdExcludes=@($Policy.ClaudeMdExcludes)}
    return [pscustomobject]$settings
}

function Get-DeckClaudeNativeImportDefaults([string]$SuiteRoot) {
    return Read-DeckClaudeSettingsFile (Get-DeckClaudeNativeImportDefaultsPath $SuiteRoot) 'Claude native import defaults'
}

function Get-DeckClaudeNativeImportPreview([string]$NativeClaudeHome=(Join-Path $env:USERPROFILE '.claude')) {
    $nativeHomePath=[IO.Path]::GetFullPath($NativeClaudeHome)
    if(-not (Test-Path -LiteralPath $nativeHomePath -PathType Container)){return [pscustomobject]@{Home=$nativeHomePath;StatusLine=$null;StatusLineScript=$null;MemoryProjects=@();InstructionPath=(Join-Path $nativeHomePath 'CLAUDE.md');InstructionLength=0}}
    $homeItem=Get-Item -LiteralPath $nativeHomePath -Force
    if($homeItem.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The native Claude config directory must be a regular directory.'}
    $settingsPath=Join-Path $nativeHomePath 'settings.json';$statusLine=$null;$statusLineScript=$null
    if(Test-Path -LiteralPath $settingsPath -PathType Leaf){
        $settings=Read-DeckClaudeSettingsFile $settingsPath 'Native Claude settings'
        if($settings.PSObject.Properties['statusLine'] -and (Test-DeckClaudeJsonObject $settings.statusLine)){
            $statusLine=$settings.statusLine
            $command=[string]$statusLine.command
            $match=[regex]::Match($command,'(?i)(?:^|\s)(?:bash|sh)\s+~/.claude/([^\s"'']+)')
            if($match.Success -and $match.Groups[1].Value -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$'){$candidate=Join-Path $nativeHomePath $match.Groups[1].Value;if(Test-Path -LiteralPath $candidate -PathType Leaf){$file=Get-Item -LiteralPath $candidate -Force;if(-not ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){$statusLineScript=$candidate}}}
        }
    }
    $projectsRoot=Join-Path $nativeHomePath 'projects';$memoryProjects=[Collections.Generic.List[object]]::new()
    if(Test-Path -LiteralPath $projectsRoot -PathType Container){
        $rootItem=Get-Item -LiteralPath $projectsRoot -Force
        if(-not ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)){
            foreach($project in Get-ChildItem -LiteralPath $projectsRoot -Directory -Force){
                if($project.Attributes -band [IO.FileAttributes]::ReparsePoint -or $project.Name -notmatch '^[A-Za-z0-9._-]{1,120}$'){continue}
                $memory=Join-Path $project.FullName 'memory'
                if(-not (Test-Path -LiteralPath $memory -PathType Container)){continue}
                $memoryItem=Get-Item -LiteralPath $memory -Force
                if($memoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
                $files=@(Get-ChildItem -LiteralPath $memory -File -Force | Where-Object {$_.Name -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,119}\.md$' -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)} | Sort-Object Name | ForEach-Object {[pscustomobject]@{Project=$project.Name;Name=$_.Name;Length=$_.Length;Path=$_.FullName}})
                if($files.Count){$memoryProjects.Add([pscustomobject]@{Project=$project.Name;Files=$files})}
            }
        }
    }
    $instructionPath=Join-Path $nativeHomePath 'CLAUDE.md';$instructionLength=0
    if(Test-Path -LiteralPath $instructionPath -PathType Leaf){$instruction=Get-Item -LiteralPath $instructionPath -Force;if(-not ($instruction.Attributes -band [IO.FileAttributes]::ReparsePoint)){$instructionLength=$instruction.Length}}
    return [pscustomobject]@{Home=$nativeHomePath;StatusLine=$statusLine;StatusLineScript=$statusLineScript;MemoryProjects=$memoryProjects.ToArray();InstructionPath=$instructionPath;InstructionLength=$instructionLength}
}

function Get-DeckClaudeAccountsForImport([string]$SuiteRoot) {
    $accountsRoot=Join-Path $SuiteRoot 'accounts'
    if(-not (Test-Path -LiteralPath $accountsRoot -PathType Container)){return @()}
    $rows=[Collections.Generic.List[object]]::new()
    foreach($directory in Get-ChildItem -LiteralPath $accountsRoot -Directory -Force){
        if($directory.Name -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,39}$' -or $directory.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
        $metadataPath=Join-Path $directory.FullName 'deck-account.json';$isClaude=$directory.Name -match '^(?i:claude)-'
        if(Test-Path -LiteralPath $metadataPath -PathType Leaf){try{$metadata=Read-DeckClaudeSettingsFile $metadataPath 'Account metadata';$isClaude=$metadata.Harness -eq 'Claude'}catch{$isClaude=$false}}
        if(-not $isClaude){continue}
        $profile=Join-Path $directory.FullName 'claude';$signedIn=Test-Path -LiteralPath (Join-Path $profile '.credentials.json') -PathType Leaf
        $rows.Add([pscustomobject]@{Name=$directory.Name;Profile=$profile;SignedIn=[bool]$signedIn})
    }
    return $rows.ToArray()
}

function Assert-DeckClaudeManagedPath([string]$Path,[string]$Root) {
    $full=[IO.Path]::GetFullPath($Path);$base=[IO.Path]::GetFullPath($Root).TrimEnd('\')
    if(-not $full.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Claude import path escaped its managed directory.'}
    $current=$base
    $baseItem=Get-Item -LiteralPath $base -Force -ErrorAction SilentlyContinue
    if($baseItem -and ($baseItem.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Claude import root cannot be a link.'}
    $relative=$full.Substring($base.Length).TrimStart('\')
    foreach($part in $relative.Split('\')){
        if(-not $part){continue};$current=Join-Path $current $part
        if(Test-Path -LiteralPath $current){$item=Get-Item -LiteralPath $current -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Claude import paths cannot include links.'}}
    }
    return $full
}

function Write-DeckClaudeImportBytes([string]$Path,[byte[]]$Bytes,[string]$ProfileRoot) {
    [void](Assert-DeckClaudeManagedPath $Path $ProfileRoot)
    $parent=Split-Path -Parent $Path
    [void][IO.Directory]::CreateDirectory($parent)
    [void](Assert-DeckClaudeManagedPath $Path $ProfileRoot)
    $backupRoot=Join-Path $ProfileRoot 'backups/claude-native-import'
    $relative=$Path.Substring([IO.Path]::GetFullPath($ProfileRoot).TrimEnd('\').Length).TrimStart('\')
    if(Test-Path -LiteralPath $Path -PathType Leaf){
        $backup=Join-Path (Join-Path $backupRoot ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))) $relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $backup))
        [IO.File]::Copy($Path,$backup,$false)
    }
    $temporary=Join-Path $parent ('.claude-import-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try{
        [IO.File]::WriteAllBytes($temporary,$Bytes)
        if(Test-Path -LiteralPath $Path -PathType Leaf){$discard=Join-Path $parent ('.claude-import-replaced-'+[guid]::NewGuid().ToString('N')+'.tmp');[IO.File]::Replace($temporary,$Path,$discard);if(Test-Path -LiteralPath $discard){[IO.File]::Delete($discard)}}else{[IO.File]::Move($temporary,$Path)}
    }finally{if(Test-Path -LiteralPath $temporary -PathType Leaf){[IO.File]::Delete($temporary)}}
}

function Set-DeckClaudeStatusLineImport([string]$ProfileRoot,$StatusLine,[byte[]]$ScriptBytes) {
    if(-not (Test-DeckClaudeJsonObject $StatusLine) -or [string]::IsNullOrWhiteSpace([string]$StatusLine.command)){throw 'Native statusline configuration is incomplete.'}
    $scriptMatch=[regex]::Match([string]$StatusLine.command,'(?i)(?:^|\s)(?:bash|sh)\s+~/.claude/([^\s"'']+)')
    if(-not $scriptMatch.Success -or $scriptMatch.Groups[1].Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$' -or -not $ScriptBytes){throw 'The native statusline script must use a supported ~/.claude/<file> path.'}
    $isolatedStatusLine=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $StatusLine -Compress -Depth 30)
    $scriptName=$scriptMatch.Groups[1].Value
    $scriptPath=Join-Path $ProfileRoot $scriptName
    Write-DeckClaudeImportBytes $scriptPath $ScriptBytes $ProfileRoot
    $statusLinePath=([IO.Path]::GetFullPath($scriptPath) -replace '\\','/')
    $isolatedStatusLine.command=[regex]::Replace([string]$isolatedStatusLine.command,'(?i)~/.claude/'+[regex]::Escape($scriptName),'"'+$statusLinePath+'"')
    $settingsPath=Join-Path $ProfileRoot 'settings.json'
    $settings=Read-DeckClaudeSettingsFile $settingsPath 'Claude account settings'
    $settings | Add-Member -MemberType NoteProperty -Name statusLine -Value $isolatedStatusLine -Force
    Write-DeckClaudeImportBytes $settingsPath ([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $settings -Compress -Depth 100))) $ProfileRoot
}

function Invoke-DeckClaudeNativeImport([string]$SuiteRoot,[string[]]$Accounts,[string[]]$MemorySelections,[switch]$IncludeStatusLine,[string]$NativeClaudeHome=(Join-Path $env:USERPROFILE '.claude'),[switch]$SetNewAccountDefault,[switch]$EnableNewAccountDefault) {
    $preview=Get-DeckClaudeNativeImportPreview $NativeClaudeHome
    $selection=[Collections.Generic.List[object]]::new()
    foreach($memorySelection in @($MemorySelections)){
        $parts=$memorySelection -split '\|',2
        if($parts.Count -ne 2 -or $parts[0] -notmatch '^[A-Za-z0-9._-]{1,120}$' -or $parts[1] -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,119}\.md$'){throw 'Invalid Claude memory selection.'}
        $source=Join-Path $preview.Home ('projects/'+$parts[0]+'/memory/'+$parts[1])
        $sourceItem=Get-Item -LiteralPath $source -Force -ErrorAction Stop
        if($sourceItem.PSIsContainer -or $sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Claude memory imports must be regular files.'}
        $selection.Add([pscustomobject]@{Project=$parts[0];Name=$parts[1];Path=$source})
    }
    $statusBytes=$null
    if($IncludeStatusLine){
        if(-not $preview.StatusLine -or -not $preview.StatusLineScript){throw 'Native Claude does not have a portable statusline command and script to import.'}
        $statusItem=Get-Item -LiteralPath $preview.StatusLineScript -Force
        if($statusItem.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The native statusline script must be a regular file.'}
        $statusBytes=[IO.File]::ReadAllBytes($preview.StatusLineScript)
    }
    $available=@(Get-DeckClaudeAccountsForImport $SuiteRoot)
    $results=[Collections.Generic.List[string]]::new()
    foreach($account in @($Accounts | Select-Object -Unique)){
        $target=@($available | Where-Object Name -eq $account | Select-Object -First 1)
        if(-not $target.Count){throw "Not a Claude Deck account: $account"}
        $profile=[IO.Path]::GetFullPath($target[0].Profile);[void][IO.Directory]::CreateDirectory($profile)
        if($IncludeStatusLine){Set-DeckClaudeStatusLineImport $profile $preview.StatusLine $statusBytes}
        foreach($entry in $selection){
            $profileRoot=$profile
            $destination=Join-Path $profile ('projects/'+$entry.Project+'/memory/'+$entry.Name)
            $bytes=[IO.File]::ReadAllBytes($entry.Path)
            Write-DeckClaudeImportBytes $destination $bytes $profileRoot
        }
        $marker=[pscustomobject]@{Version=1;ImportedAt=[DateTimeOffset]::UtcNow.ToString('o');StatusLine=[bool]$IncludeStatusLine;Memories=@($selection | ForEach-Object {$_.Project+'/'+$_.Name})}
        Write-DeckClaudeImportBytes (Join-Path $profile 'native-context-import.json') ([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $marker -Compress))) $profile
        $results.Add($account)
    }
    if($SetNewAccountDefault){
        $templateRoot=Get-DeckClaudeNativeImportPath $SuiteRoot
        $template=[pscustomobject]@{Version=1;Enabled=[bool]$EnableNewAccountDefault;EnabledAtUtc=if($EnableNewAccountDefault){[DateTimeOffset]::UtcNow.ToString('o')}else{$null};NativeHome=$preview.Home;StatusLine=if($IncludeStatusLine){$preview.StatusLine}else{$null};StatusLineScript=$null;Memories=@($selection | ForEach-Object {[pscustomobject]@{Project=$_.Project;Name=$_.Name}})}
        if($EnableNewAccountDefault){
            [void][IO.Directory]::CreateDirectory($templateRoot)
            if($IncludeStatusLine){$scriptName=[regex]::Match([string]$preview.StatusLine.command,'(?i)(?:^|\s)(?:bash|sh)\s+~/.claude/([^\s"'']+)').Groups[1].Value; $templateScript=Join-Path $templateRoot $scriptName;[IO.File]::WriteAllBytes($templateScript,$statusBytes);$template.StatusLineScript=$scriptName}
            foreach($entry in $selection){$templateFile=Join-Path $templateRoot ('projects/'+$entry.Project+'/memory/'+$entry.Name);[void][IO.Directory]::CreateDirectory((Split-Path -Parent $templateFile));[IO.File]::WriteAllBytes($templateFile,[IO.File]::ReadAllBytes($entry.Path))}
        }
        Write-DeckClaudeTextAtomically (Get-DeckClaudeNativeImportDefaultsPath $SuiteRoot) (ConvertTo-Json -InputObject $template -Depth 30)
    }
    return [pscustomobject]@{Accounts=$results.ToArray();StatusLine=[bool]$IncludeStatusLine;Memories=$selection.Count;NewAccountDefault=if($SetNewAccountDefault){[bool]$EnableNewAccountDefault}else{$null}}
}

function Sync-DeckClaudeNativeDefaults([string]$SuiteRoot,[string]$Account) {
    $defaults=Get-DeckClaudeNativeImportDefaults $SuiteRoot
    if(-not $defaults.Enabled){return $false}
    $directory=Join-Path $SuiteRoot ('accounts/'+$Account);$profile=Join-Path $directory 'claude'
    if(-not (Test-Path -LiteralPath $directory -PathType Container)){return $false}
    $accountDirectory=Get-Item -LiteralPath $directory -Force
    $enabledAtUtc=if($defaults.EnabledAtUtc -is [DateTime]){([DateTime]$defaults.EnabledAtUtc).ToUniversalTime()}else{[DateTimeOffset]::Parse([string]$defaults.EnabledAtUtc,[Globalization.CultureInfo]::InvariantCulture).UtcDateTime}
    if($accountDirectory.CreationTimeUtc -lt $enabledAtUtc){return $false}
    [void][IO.Directory]::CreateDirectory($profile)
    $markerPath=Join-Path $profile 'native-context-import.json'
    if(Test-Path -LiteralPath $markerPath -PathType Leaf){return $false}
    if($defaults.StatusLine -and $defaults.StatusLineScript){
        $scriptPath=Join-Path (Get-DeckClaudeNativeImportPath $SuiteRoot) ([string]$defaults.StatusLineScript)
        if(Test-Path -LiteralPath $scriptPath -PathType Leaf){$bytes=[IO.File]::ReadAllBytes($scriptPath);Set-DeckClaudeStatusLineImport $profile $defaults.StatusLine $bytes}
    }
    $memoryCount=0
    foreach($entry in @($defaults.Memories)){
        if($entry.Project -notmatch '^[A-Za-z0-9._-]{1,120}$' -or $entry.Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,119}\.md$'){continue}
        $source=Join-Path (Get-DeckClaudeNativeImportPath $SuiteRoot) ('projects/'+$entry.Project+'/memory/'+$entry.Name)
        if(-not (Test-Path -LiteralPath $source -PathType Leaf)){continue}
        $destination=Join-Path $profile ('projects/'+$entry.Project+'/memory/'+$entry.Name)
        if(-not (Test-Path -LiteralPath $destination -PathType Leaf)){Write-DeckClaudeImportBytes $destination ([IO.File]::ReadAllBytes($source)) $profile;$memoryCount++}
    }
    $marker=[pscustomobject]@{Version=1;ImportedAt=[DateTimeOffset]::UtcNow.ToString('o');StatusLine=[bool]$defaults.StatusLine;Memories=$memoryCount;Source='new-account-default'}
    Write-DeckClaudeImportBytes $markerPath ([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $marker -Compress))) $profile
    return $true
}

function Test-DeckClaudeJsonObject($Value) {
    return $Value -is [System.Management.Automation.PSCustomObject] -or $Value -is [Collections.IDictionary]
}

function Read-DeckClaudeSettingsFile([string]$Path,[string]$Label='Claude settings') {
    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){return [pscustomobject]@{}}
    $item=Get-Item -LiteralPath $Path -Force
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "$Label must be a regular file."}
    try{$value=[IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop}catch{throw "$Label contains invalid JSON: $($_.Exception.Message)"}
    if(-not (Test-DeckClaudeJsonObject $value)){throw "$Label must contain a JSON object."}
    return $value
}

function Get-DeckClaudeDefaultSettings([string]$SuiteRoot) {
    $settings=Read-DeckClaudeSettingsFile (Get-DeckClaudeDefaultsPath $SuiteRoot) 'Claude global defaults'
    $context=Get-DeckClaudeContextSettings (Get-DeckClaudeContextPolicy $SuiteRoot)
    return Merge-DeckClaudeSettings $settings $context
}

function Merge-DeckClaudeSettingsValue($Base,$Override,[string]$Key='') {
    if((Test-DeckClaudeJsonObject $Base) -and (Test-DeckClaudeJsonObject $Override)){
        $merged=[ordered]@{}
        foreach($property in $Base.PSObject.Properties){
            $overrideProperty=$Override.PSObject.Properties[$property.Name]
            if($overrideProperty){$merged[$property.Name]=Merge-DeckClaudeSettingsValue $property.Value $overrideProperty.Value $property.Name}
            else{$merged[$property.Name]=$property.Value}
        }
        foreach($property in $Override.PSObject.Properties){if(-not $Base.PSObject.Properties[$property.Name]){$merged[$property.Name]=$property.Value}}
        return [pscustomobject]$merged
    }
    if($Base -is [array] -and $Override -is [array]){
        if($Key -in @('fallbackModel','modelPicker')){return ,$Override}
        $items=[Collections.Generic.List[object]]::new();$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($item in @($Base)+@($Override)){
            $signature=ConvertTo-Json -InputObject $item -Compress -Depth 100
            if($seen.Add($signature)){$items.Add($item)}
        }
        return ,$items.ToArray()
    }
    return $Override
}

function Merge-DeckClaudeSettings($Defaults,$AccountSettings,$SessionSettings=$null) {
    $merged=if(Test-DeckClaudeJsonObject $Defaults){$Defaults}else{[pscustomobject]@{}}
    if(Test-DeckClaudeJsonObject $AccountSettings){$merged=Merge-DeckClaudeSettingsValue $merged $AccountSettings}
    if(Test-DeckClaudeJsonObject $SessionSettings){$merged=Merge-DeckClaudeSettingsValue $merged $SessionSettings}
    return $merged
}

function Get-DeckClaudeSettingsArgument([string[]]$Arguments) {
    $clean=[Collections.Generic.List[string]]::new();$settings=$null;$found=$false
    for($i=0;$i -lt $Arguments.Count;$i++){
        $argument=[string]$Arguments[$i]
        if($argument -eq '--settings'){
            if($found -or $i+1 -ge $Arguments.Count){throw 'Use one Claude --settings value per launch.'}
            $found=$true;$i++;$value=[string]$Arguments[$i]
        }elseif($argument.StartsWith('--settings=',[StringComparison]::Ordinal)){
            if($found){throw 'Use one Claude --settings value per launch.'}
            $found=$true;$value=$argument.Substring('--settings='.Length)
        }else{$clean.Add($argument);continue}
        if(-not $value.TrimStart().StartsWith('{',[StringComparison]::Ordinal) -and (Test-Path -LiteralPath $value -PathType Leaf)){$settings=Read-DeckClaudeSettingsFile ([IO.Path]::GetFullPath($value)) 'Claude session settings'}
        else{
            try{$settings=$value | ConvertFrom-Json -ErrorAction Stop}catch{throw 'Claude --settings must be a JSON object or a readable JSON file.'}
            if(-not (Test-DeckClaudeJsonObject $settings)){throw 'Claude --settings must contain a JSON object.'}
        }
    }
    return @{Found=$found;Settings=$settings;Arguments=$clean.ToArray()}
}

function Test-DeckClaudeSessionLaunch([string[]]$Arguments) {
    if(-not $Arguments.Count){return $true}
    if($Arguments[0] -match '^(?i:auth|doctor|update|mcp|plugin|plugins|agents|attach|logs|daemon|gateway|install|uninstall|version)$'){return $false}
    if($Arguments[0] -in @('--help','-h','--version','-v')){return $false}
    return $true
}

function Assert-DeckClaudeDefaultsNoSecrets($Settings) {
    if(-not $Settings.PSObject.Properties['env']){return}
    $environment=$Settings.env
    if(-not (Test-DeckClaudeJsonObject $environment)){throw 'Claude global defaults env must be a JSON object.'}
    foreach($property in $environment.PSObject.Properties){
        if($property.Name -match '(?i)(API.?KEY|AUTH.?TOKEN|OAUTH.?TOKEN|ACCESS.?TOKEN|REFRESH.?TOKEN|SECRET|PRIVATE.?KEY|ACCESS.?KEY|PASSWORD|CREDENTIAL|SESSION.?TOKEN|BEARER.?TOKEN|(^|_)TOKEN($|_))' -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)){
            throw "Claude global defaults cannot store credentials in env.$($property.Name). Put credentials in the individual Claude account instead."
        }
    }
}

function Write-DeckClaudeTextAtomically([string]$Path,[string]$Text) {
    $directory=Split-Path -Parent $Path
    [void][IO.Directory]::CreateDirectory($directory)
    if(Test-Path -LiteralPath $Path){
        $item=Get-Item -LiteralPath $Path -Force
        if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Claude defaults must be regular files.'}
    }
    $temporary=Join-Path $directory ('.claude-deck-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try{
        [IO.File]::WriteAllText($temporary,$Text,[Text.UTF8Encoding]::new($false))
        if(Test-Path -LiteralPath $Path){
            $backup=$Path+'.bak-deck-'+[guid]::NewGuid().ToString('N')
            [IO.File]::Replace($temporary,$Path,$backup)
        }else{[IO.File]::Move($temporary,$Path)}
    }finally{if(Test-Path -LiteralPath $temporary){[IO.File]::Delete($temporary)}}
}

function Show-DeckClaudeDefaults([string]$SuiteRoot,$Owner=$null,[switch]$TestUI) {
    Add-Type -AssemblyName PresentationFramework
    $instructionsPath=Get-DeckClaudeGlobalInstructionsPath $SuiteRoot
    $settingsPath=Get-DeckClaudeDefaultsPath $SuiteRoot
    $contextPath=Get-DeckClaudeContextPolicyPath $SuiteRoot
    $initialInstructions=if(Test-Path -LiteralPath $instructionsPath -PathType Leaf){[IO.File]::ReadAllText($instructionsPath)}else{''}
    $initialSettings=Read-DeckClaudeSettingsFile $settingsPath 'Claude global defaults'
    $initialSettingsText=ConvertTo-Json -InputObject $initialSettings -Depth 100
    $contextPolicy=Get-DeckClaudeContextPolicy $SuiteRoot
    $savedImportDefaults=Get-DeckClaudeNativeImportDefaults $SuiteRoot
    $native=Get-DeckClaudeNativeImportPreview
    $claudeAccounts=@(Get-DeckClaudeAccountsForImport $SuiteRoot)
    $state=@{
        InstructionsExists=Test-Path -LiteralPath $instructionsPath -PathType Leaf
        InstructionsText=$initialInstructions
        SettingsExists=Test-Path -LiteralPath $settingsPath -PathType Leaf
        SettingsText=if(Test-Path -LiteralPath $settingsPath -PathType Leaf){[IO.File]::ReadAllText($settingsPath)}else{''}
        ContextExists=Test-Path -LiteralPath $contextPath -PathType Leaf
        ContextText=if(Test-Path -LiteralPath $contextPath -PathType Leaf){[IO.File]::ReadAllText($contextPath)}else{''}
    }
    $dialog=[Windows.Window]::new();$dialog.Title='Codex Deck / Claude Global Defaults and Context';$dialog.Width=980;$dialog.Height=760;$dialog.MinWidth=800;$dialog.MinHeight=600
    $dialog.Background='#101315';$dialog.Foreground='#EAF0FA';$dialog.WindowStartupLocation='CenterScreen'
    if($Owner){$dialog.Owner=$Owner;$dialog.WindowStartupLocation='CenterOwner';$dialog.Resources.MergedDictionaries.Add($Owner.Resources)}
    $dock=[Windows.Controls.DockPanel]::new();$dock.Margin='18';$dialog.Content=$dock
    $note=[Windows.Controls.TextBlock]::new();$note.Text='Claude accounts use isolated config homes. This screen controls Deck defaults, fresh-session context sources, and selective imports from your native Claude install. Native authentication and credentials are never imported. Deck Global Instructions are appended to Claude sessions; this is separate from Codex Global Rules.';$note.TextWrapping='Wrap';$note.Margin='0,0,0,12';[Windows.Controls.DockPanel]::SetDock($note,'Top');[void]$dock.Children.Add($note)
    $buttons=[Windows.Controls.WrapPanel]::new();$buttons.HorizontalAlignment='Right';$buttons.Margin='0,12,0,0';[Windows.Controls.DockPanel]::SetDock($buttons,'Bottom');[void]$dock.Children.Add($buttons)
    $saveInstructions=[Windows.Controls.Button]::new();$saveInstructions.Content='Save instructions';$saveInstructions.Padding='12,8';$saveInstructions.Margin='0,0,8,0';[void]$buttons.Children.Add($saveInstructions)
    $saveSettings=[Windows.Controls.Button]::new();$saveSettings.Content='Save settings defaults';$saveSettings.Padding='12,8';$saveSettings.Margin='0,0,8,0';[void]$buttons.Children.Add($saveSettings)
    $saveContext=[Windows.Controls.Button]::new();$saveContext.Content='Save context policy';$saveContext.Padding='12,8';$saveContext.Margin='0,0,8,0';[void]$buttons.Children.Add($saveContext)
    $importButton=[Windows.Controls.Button]::new();$importButton.Content='Import selected native items';$importButton.Padding='12,8';[void]$buttons.Children.Add($importButton)
    $errorText=[Windows.Controls.TextBlock]::new();$errorText.Foreground='#F17D8D';$errorText.TextWrapping='Wrap';$errorText.Margin='0,0,0,8';[Windows.Controls.DockPanel]::SetDock($errorText,'Bottom');[void]$dock.Children.Add($errorText)
    $tabs=[Windows.Controls.TabControl]::new();[void]$dock.Children.Add($tabs)
    $instructionsTab=[Windows.Controls.TabItem]::new();$instructionsTab.Header='Global instructions'
    $instructionsEditor=[Windows.Controls.TextBox]::new();$instructionsEditor.Text=$initialInstructions;$instructionsEditor.AcceptsReturn=$true;$instructionsEditor.AcceptsTab=$true;$instructionsEditor.TextWrapping='Wrap';$instructionsEditor.VerticalScrollBarVisibility='Auto';$instructionsEditor.HorizontalScrollBarVisibility='Auto';$instructionsEditor.FontFamily='Consolas';$instructionsEditor.FontSize=14;$instructionsEditor.Background='#192232';$instructionsEditor.Foreground='#EAF0FA';$instructionsTab.Content=$instructionsEditor;[void]$tabs.Items.Add($instructionsTab)
    $settingsTab=[Windows.Controls.TabItem]::new();$settingsTab.Header='Global settings defaults'
    $settingsEditor=[Windows.Controls.TextBox]::new();$settingsEditor.Text=$initialSettingsText;$settingsEditor.AcceptsReturn=$true;$settingsEditor.AcceptsTab=$true;$settingsEditor.TextWrapping='NoWrap';$settingsEditor.VerticalScrollBarVisibility='Auto';$settingsEditor.HorizontalScrollBarVisibility='Auto';$settingsEditor.FontFamily='Consolas';$settingsEditor.FontSize=14;$settingsEditor.Background='#192232';$settingsEditor.Foreground='#EAF0FA';$settingsTab.Content=$settingsEditor;[void]$tabs.Items.Add($settingsTab)
    $contextTab=[Windows.Controls.TabItem]::new();$contextTab.Header='Fresh conversation context'
    $contextScroll=[Windows.Controls.ScrollViewer]::new();$contextScroll.VerticalScrollBarVisibility='Auto';$contextPanel=[Windows.Controls.StackPanel]::new();$contextPanel.Margin='10';$contextScroll.Content=$contextPanel;$contextTab.Content=$contextScroll
    $contextIntro=[Windows.Controls.TextBlock]::new();$contextIntro.Text="Choose which supported Claude Code sources can contribute to new sessions. The settings below apply to current and new Deck Claude accounts. Claude's built-in system prompt and content returned by tools are controlled by Claude and the active session, so Deck cannot list those byte-for-byte.";$contextIntro.TextWrapping='Wrap';$contextIntro.Margin='0,0,0,12';[void]$contextPanel.Children.Add($contextIntro)
    $settingsLabel=[Windows.Controls.TextBlock]::new();$settingsLabel.Text='Settings sources';$settingsLabel.FontWeight='Bold';$settingsLabel.Margin='0,4,0,6';[void]$contextPanel.Children.Add($settingsLabel)
    $projectSettings=[Windows.Controls.CheckBox]::new();$projectSettings.Content='Load project settings';$projectSettings.IsChecked=[bool]$contextPolicy.ProjectSettings;$projectSettings.Margin='0,0,0,5';$projectSettings.ToolTip='Includes project settings such as project hooks, MCP servers, plugins, environment values, and project rules.';[void]$contextPanel.Children.Add($projectSettings)
    $localSettings=[Windows.Controls.CheckBox]::new();$localSettings.Content='Load local project settings';$localSettings.IsChecked=[bool]$contextPolicy.LocalSettings;$localSettings.Margin='0,0,0,10';$localSettings.ToolTip='Includes local settings for this account and project.';[void]$contextPanel.Children.Add($localSettings)
    $instructionLabel=[Windows.Controls.TextBlock]::new();$instructionLabel.Text='Instruction files';$instructionLabel.FontWeight='Bold';$instructionLabel.Margin='0,2,0,6';[void]$contextPanel.Children.Add($instructionLabel)
    $instructionMode=[Windows.Controls.ComboBox]::new();$instructionMode.MinWidth=300;$instructionMode.HorizontalAlignment='Left';$instructionMode.Margin='0,0,0,5'
    foreach($choice in @(@('claude-md-or-agents-md','CLAUDE.md, or AGENTS.md when no CLAUDE.md takes precedence'),@('claude-md-and-agents-md','Load both CLAUDE.md and AGENTS.md'),@('claude-md','Load CLAUDE.md only'),@('managed-only','Exclude user/project/local instruction files and rules; keep managed instructions and auto-memory'))){$item=[Windows.Controls.ComboBoxItem]::new();$item.Content=$choice[1];$item.Tag=$choice[0];[void]$instructionMode.Items.Add($item);if($choice[0] -eq $contextPolicy.InstructionFilesMode){$instructionMode.SelectedItem=$item}}
    [void]$contextPanel.Children.Add($instructionMode)
    $instructionHelp=[Windows.Controls.TextBlock]::new();$instructionHelp.Text='Native user instructions are isolated from Deck accounts. The native global CLAUDE.md path is always excluded below, so it will not reappear in Deck sessions.';$instructionHelp.TextWrapping='Wrap';$instructionHelp.Margin='0,0,0,8';[void]$contextPanel.Children.Add($instructionHelp)
    $excludesLabel=[Windows.Controls.TextBlock]::new();$excludesLabel.Text='Additional CLAUDE.md exclusions (one absolute path or glob per line)';$excludesLabel.Margin='0,2,0,4';[void]$contextPanel.Children.Add($excludesLabel)
    $excludesEditor=[Windows.Controls.TextBox]::new();$excludesEditor.Text=(@($contextPolicy.ClaudeMdExcludes) -join "`r`n");$excludesEditor.AcceptsReturn=$true;$excludesEditor.TextWrapping='NoWrap';$excludesEditor.VerticalScrollBarVisibility='Auto';$excludesEditor.Height=90;$excludesEditor.FontFamily='Consolas';$excludesEditor.Background='#192232';$excludesEditor.Foreground='#EAF0FA';$excludesEditor.Margin='0,0,0,10';[void]$contextPanel.Children.Add($excludesEditor)
    $autoMemory=[Windows.Controls.CheckBox]::new();$autoMemory.Content='Load and update Claude auto-memory';$autoMemory.IsChecked=[bool]$contextPolicy.AutoMemoryEnabled;$autoMemory.Margin='0,0,0,5';[void]$contextPanel.Children.Add($autoMemory)
    $skillsEnabled=[Windows.Controls.CheckBox]::new();$skillsEnabled.Content='Load skills and slash commands';$skillsEnabled.IsChecked=[bool]$contextPolicy.SkillsAndCommandsEnabled;$skillsEnabled.Margin='0,0,0,5';[void]$contextPanel.Children.Add($skillsEnabled)
    $bundledSkills=[Windows.Controls.CheckBox]::new();$bundledSkills.Content="Load Claude's bundled skills";$bundledSkills.IsChecked=[bool]$contextPolicy.BundledSkillsEnabled;$bundledSkills.Margin='0,0,0,5';[void]$contextPanel.Children.Add($bundledSkills)
    $mcpEnabled=[Windows.Controls.CheckBox]::new();$mcpEnabled.Content='Load MCP servers';$mcpEnabled.IsChecked=[bool]$contextPolicy.McpEnabled;$mcpEnabled.Margin='0,0,0,5';$mcpEnabled.ToolTip='When off, Deck starts Claude with strict MCP configuration and removes per-launch MCP config arguments.';[void]$contextPanel.Children.Add($mcpEnabled)
    $safeMode=[Windows.Controls.CheckBox]::new();$safeMode.Content='Use Claude safe mode';$safeMode.IsChecked=[bool]$contextPolicy.SafeMode;$safeMode.Margin='0,0,0,5';$safeMode.ToolTip='Safe mode disables customizations including statusline, plugins, hooks, MCP, skills, instruction files, and auto-memory for those sessions.';[void]$contextPanel.Children.Add($safeMode)
    $safeModeNote=[Windows.Controls.TextBlock]::new();$safeModeNote.Text='Safe mode also hides the imported statusline and memory for that launch. Use the source controls above when you want a smaller context but still want your selected memories or statusline.';$safeModeNote.TextWrapping='Wrap';$safeModeNote.Margin='0,0,0,10';[void]$contextPanel.Children.Add($safeModeNote)
    [void]$tabs.Items.Add($contextTab)
    $importTab=[Windows.Controls.TabItem]::new();$importTab.Header='Import from native Claude'
    $importScroll=[Windows.Controls.ScrollViewer]::new();$importScroll.VerticalScrollBarVisibility='Auto';$importPanel=[Windows.Controls.StackPanel]::new();$importPanel.Margin='10';$importScroll.Content=$importPanel;$importTab.Content=$importScroll
    $sourceNote=[Windows.Controls.TextBlock]::new();$sourceNote.Text='Source: '+$native.Home+' . The native CLAUDE.md is '+$(if($native.InstructionLength -eq 0){'empty'}else{'present but will not be imported'})+'. Only the selected statusline config/script and memory markdown files are copied; global prompts, settings, plugins, and credentials are left alone.';$sourceNote.TextWrapping='Wrap';$sourceNote.Margin='0,0,0,10';[void]$importPanel.Children.Add($sourceNote)
    $statusLineImport=[Windows.Controls.CheckBox]::new();$statusLineImport.Content=if($native.StatusLineScript){'Import native statusline ('+[IO.Path]::GetFileName($native.StatusLineScript)+')'}else{'Native statusline script was not found'};$statusLineImport.IsChecked=[bool]($native.StatusLine -and $native.StatusLineScript);$statusLineImport.IsEnabled=[bool]($native.StatusLine -and $native.StatusLineScript);$statusLineImport.Margin='0,0,0,8';[void]$importPanel.Children.Add($statusLineImport)
    $targetLabel=[Windows.Controls.TextBlock]::new();$targetLabel.Text='Import into signed-in Claude Deck accounts';$targetLabel.FontWeight='Bold';$targetLabel.Margin='0,2,0,5';[void]$importPanel.Children.Add($targetLabel)
    $targetControls=[Collections.Generic.List[object]]::new()
    foreach($account in $claudeAccounts){$target=[Windows.Controls.CheckBox]::new();$target.Content=$account.Name+$(if($account.SignedIn){' (signed in)'}else{' (not signed in)'});$target.Tag=$account.Name;$target.IsChecked=[bool]$account.SignedIn;$target.Margin='0,0,0,4';$targetControls.Add($target);[void]$importPanel.Children.Add($target)}
    if(-not $claudeAccounts.Count){$emptyAccounts=[Windows.Controls.TextBlock]::new();$emptyAccounts.Text='No Claude Deck accounts found yet.';$emptyAccounts.Margin='0,0,0,8';[void]$importPanel.Children.Add($emptyAccounts)}
    $memoryLabel=[Windows.Controls.TextBlock]::new();$memoryLabel.Text='Native project auto-memory files';$memoryLabel.FontWeight='Bold';$memoryLabel.Margin='0,8,0,5';[void]$importPanel.Children.Add($memoryLabel)
    $memoryControls=[Collections.Generic.List[object]]::new()
    foreach($project in $native.MemoryProjects){$projectLabel=[Windows.Controls.TextBlock]::new();$projectLabel.Text=('{0} ({1} files)' -f $project.Project,$project.Files.Count);$projectLabel.FontWeight='SemiBold';$projectLabel.Margin='0,4,0,4';[void]$importPanel.Children.Add($projectLabel);foreach($file in $project.Files){$memoryCheck=[Windows.Controls.CheckBox]::new();$memoryCheck.Content=('{0} · {1} bytes' -f $file.Name,$file.Length);$memoryCheck.Tag=($file.Project+'|'+$file.Name);$memoryCheck.IsChecked=$true;$memoryCheck.Margin='14,0,0,4';$memoryControls.Add($memoryCheck);[void]$importPanel.Children.Add($memoryCheck)}}
    if(-not @($native.MemoryProjects).Count){$noMemory=[Windows.Controls.TextBlock]::new();$noMemory.Text='No native project memory files were found.';$noMemory.Margin='0,0,0,8';[void]$importPanel.Children.Add($noMemory)}
    $newAccountDefault=[Windows.Controls.CheckBox]::new();$newAccountDefault.Content='Also use the selected files as defaults for Claude accounts created after enabling this option';$newAccountDefault.IsChecked=[bool]$savedImportDefaults.Enabled;$newAccountDefault.Margin='0,14,0,5';$newAccountDefault.ToolTip='New accounts created after enabling this option receive these files on their first launch. Existing account customizations are not overwritten.';[void]$importPanel.Children.Add($newAccountDefault)
    [void]$tabs.Items.Add($importTab)
    $writeText={
        param([string]$Path,[string]$Text)
        $directory=Split-Path -Parent $Path
        [void][IO.Directory]::CreateDirectory($directory)
        if(Test-Path -LiteralPath $Path){
            $item=Get-Item -LiteralPath $Path -Force
            if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Claude defaults must be regular files.'}
        }
        $temporary=Join-Path $directory ('.claude-deck-'+[guid]::NewGuid().ToString('N')+'.tmp')
        try{
            [IO.File]::WriteAllText($temporary,$Text,[Text.UTF8Encoding]::new($false))
            if(Test-Path -LiteralPath $Path){$backup=$Path+'.bak-deck-'+[guid]::NewGuid().ToString('N');[IO.File]::Replace($temporary,$Path,$backup)}
            else{[IO.File]::Move($temporary,$Path)}
        }finally{if(Test-Path -LiteralPath $temporary){[IO.File]::Delete($temporary)}}
    }.GetNewClosure()
    $validateSettings={
        param($Settings)
        if(-not $Settings.PSObject.Properties['env']){return}
        $environment=$Settings.env
        if(-not ($environment -is [System.Management.Automation.PSCustomObject] -or $environment -is [Collections.IDictionary])){throw 'Claude global defaults env must be a JSON object.'}
        foreach($property in $environment.PSObject.Properties){
            if($property.Name -match '(?i)(API.?KEY|AUTH.?TOKEN|OAUTH.?TOKEN|ACCESS.?TOKEN|REFRESH.?TOKEN|SECRET|PRIVATE.?KEY|ACCESS.?KEY|PASSWORD|CREDENTIAL|SESSION.?TOKEN|BEARER.?TOKEN|(^|_)TOKEN($|_))' -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)){
                throw "Claude global defaults cannot store credentials in env.$($property.Name). Put credentials in the individual Claude account instead."
            }
        }
    }.GetNewClosure()
    $saveInstructions.Add_Click({
        try{
            $errorText.Text=''
            $currentExists=Test-Path -LiteralPath $instructionsPath -PathType Leaf
            $current=if($currentExists){[IO.File]::ReadAllText($instructionsPath)}else{''}
            if($currentExists -ne [bool]$state.InstructionsExists -or ($currentExists -and $current -cne $state.InstructionsText)){throw 'Claude global instructions changed in another editor. Reopen before saving.'}
            if($instructionsEditor.Text -cne $state.InstructionsText){& $writeText $instructionsPath $instructionsEditor.Text;$state.InstructionsExists=$true;$state.InstructionsText=$instructionsEditor.Text}
        }catch{$errorText.Text=$_.Exception.Message}
    }.GetNewClosure())
    $saveSettings.Add_Click({
        try{
            $errorText.Text=''
            $currentExists=Test-Path -LiteralPath $settingsPath -PathType Leaf
            $current=if($currentExists){[IO.File]::ReadAllText($settingsPath)}else{''}
            if($currentExists -ne [bool]$state.SettingsExists -or ($currentExists -and $current -cne $state.SettingsText)){throw 'Claude global settings changed in another editor. Reopen before saving.'}
            $value=$settingsEditor.Text | ConvertFrom-Json -ErrorAction Stop
            if(-not ($value -is [System.Management.Automation.PSCustomObject] -or $value -is [Collections.IDictionary])){throw 'Claude global settings defaults must be a JSON object.'}
            & $validateSettings $value
            $json=ConvertTo-Json -InputObject $value -Depth 100
            & $writeText $settingsPath $json
            $state.SettingsExists=$true;$state.SettingsText=$json
        }catch{$errorText.Text=$_.Exception.Message}
    }.GetNewClosure())
    $saveContext.Add_Click({
        try{
            $errorText.Text=''
            $currentExists=Test-Path -LiteralPath $contextPath -PathType Leaf
            $current=if($currentExists){[IO.File]::ReadAllText($contextPath)}else{''}
            if($currentExists -ne [bool]$state.ContextExists -or ($currentExists -and $current -cne $state.ContextText)){throw 'Claude context policy changed in another editor. Reopen before saving.'}
            if(-not $instructionMode.SelectedItem){throw 'Choose an instruction file mode.'}
            $patterns=@($excludesEditor.Text -split "`r?`n" | ForEach-Object {$_.Trim()} | Where-Object {$_})
            $nativeClaudeMd=Join-Path (Join-Path $env:USERPROFILE '.claude') 'CLAUDE.md'
            if($nativeClaudeMd -notin $patterns){$patterns+=,$nativeClaudeMd}
            if($patterns.Count -gt 200){throw 'Use at most 200 Claude MD exclude patterns.'}
            foreach($pattern in $patterns){if($pattern.Length -gt 2048 -or $pattern.Contains("`0")){throw 'Claude MD exclude patterns must be under 2048 characters.'}}
            $policyValue=[pscustomobject]@{ProjectSettings=[bool]$projectSettings.IsChecked;LocalSettings=[bool]$localSettings.IsChecked;InstructionFilesMode=[string]$instructionMode.SelectedItem.Tag;ClaudeMdExcludes=$patterns;AutoMemoryEnabled=[bool]$autoMemory.IsChecked;SkillsAndCommandsEnabled=[bool]$skillsEnabled.IsChecked;BundledSkillsEnabled=[bool]$bundledSkills.IsChecked;McpEnabled=[bool]$mcpEnabled.IsChecked;SafeMode=[bool]$safeMode.IsChecked}
            $policyJson=ConvertTo-Json -InputObject $policyValue -Depth 20
            & $writeText $contextPath $policyJson
            $state.ContextExists=$true;$state.ContextText=[IO.File]::ReadAllText($contextPath);$excludesEditor.Text=@($patterns) -join "`r`n"
        }catch{$errorText.Text=$_.Exception.Message}
    }.GetNewClosure())
    $importButton.Add_Click({
        try{
            $errorText.Text=''
            $targets=@($targetControls | Where-Object {$_.IsChecked} | ForEach-Object {[string]$_.Tag})
            $memories=@($memoryControls | Where-Object {$_.IsChecked} | ForEach-Object {[string]$_.Tag})
            $imported=Invoke-DeckClaudeNativeImport $SuiteRoot $targets $memories -IncludeStatusLine:([bool]$statusLineImport.IsChecked) -SetNewAccountDefault -EnableNewAccountDefault:([bool]$newAccountDefault.IsChecked)
            $errorText.Foreground='#77D2A4';$errorText.Text=('Imported statusline: {0}; memory files: {1}; accounts: {2}; new-account default: {3}' -f $imported.StatusLine,$imported.Memories,(@($imported.Accounts) -join ', '),$imported.NewAccountDefault)
        }catch{$errorText.Foreground='#F17D8D';$errorText.Text=$_.Exception.Message}
    }.GetNewClosure())
    if($TestUI){return @{Dialog=$dialog;Instructions=$instructionsEditor;Settings=$settingsEditor;SaveInstructions=$saveInstructions;SaveSettings=$saveSettings;SaveContext=$saveContext;Import=$importButton;Error=$errorText;Context=@{ProjectSettings=$projectSettings;LocalSettings=$localSettings;InstructionMode=$instructionMode;ClaudeMdExcludes=$excludesEditor;AutoMemory=$autoMemory;SkillsAndCommands=$skillsEnabled;BundledSkills=$bundledSkills;Mcp=$mcpEnabled;SafeMode=$safeMode};NativeStatusLine=$statusLineImport;MemoryControls=$memoryControls.ToArray();TargetAccounts=$targetControls.ToArray();NewAccountDefault=$newAccountDefault;Paths=@{Instructions=$instructionsPath;Settings=$settingsPath;Context=$contextPath;NativeHome=$native.Home}}}
    [void]$dialog.ShowDialog()
}

function Open-DeckClaudeDefaults([string]$SuiteRoot,$Owner=$null) {
    $scriptPath=Join-Path $SuiteRoot 'Deck.ClaudeDefaults.ps1'
    if(-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)){throw 'Claude defaults editor missing. Reinstall Codex Deck.'}
    if($Owner){return Show-DeckClaudeDefaults $SuiteRoot $Owner}
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList ('-NoProfile -STA -ExecutionPolicy Bypass -File "'+$scriptPath+'" -ClaudeDefaultsEdit -ClaudeDefaultsSuiteRoot "'+$SuiteRoot+'"') | Out-Null
}

if($ClaudeDefaultsEdit){Show-DeckClaudeDefaults $ClaudeDefaultsSuiteRoot}
