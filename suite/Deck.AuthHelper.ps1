param(
    [string]$SuiteRoot = $PSScriptRoot,
    [switch]$Edit,
    [switch]$Recover,
    [switch]$ShowBrowser,
    [switch]$BrowserHarness,
    [switch]$Force,
    [switch]$Batch,
    [string]$Account,
    [string]$Email,
    [string]$AttemptId,
    [string[]]$Accounts,
    [ValidateRange(1,8)][int]$Concurrency = 3
)

function Get-DeckAuthHelperPath([string]$Root) {
    return Join-Path $Root 'deck/auth-helper.dat'
}
function Get-DeckAuthHelperEntropy {
    return [Text.Encoding]::UTF8.GetBytes('CodexDeck/AuthHelper/1')
}
function Read-DeckAuthHelperText([string]$Root) {
    $path=Get-DeckAuthHelperPath $Root
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){return ''}
    Add-Type -AssemblyName System.Security
    $cipher=[Convert]::FromBase64String([IO.File]::ReadAllText($path).Trim())
    $plain=[Security.Cryptography.ProtectedData]::Unprotect($cipher,(Get-DeckAuthHelperEntropy),[Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Text.Encoding]::UTF8.GetString($plain)
}
function Write-DeckAuthHelperText([string]$Root,[string]$Text) {
    Add-Type -AssemblyName System.Security
    $plain=[Text.Encoding]::UTF8.GetBytes($Text)
    $cipher=[Security.Cryptography.ProtectedData]::Protect($plain,(Get-DeckAuthHelperEntropy),[Security.Cryptography.DataProtectionScope]::CurrentUser)
    $path=Get-DeckAuthHelperPath $Root
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    [IO.File]::WriteAllText($path,[Convert]::ToBase64String($cipher),[Text.UTF8Encoding]::new($false))
}
function Get-DeckAuthHelperStatusPath([string]$Root,[string]$Account) {
    return Join-Path $Root "deck/auth-helper/status/$Account.json"
}
function Set-DeckAuthHelperStatus([string]$Root,[string]$Account,[string]$Email,[string]$State,[string]$Message='',[string]$AuthFileStamp) {
    try {
        $path=Get-DeckAuthHelperStatusPath $Root $Account
        if(-not $PSBoundParameters.ContainsKey('AuthFileStamp')){$AuthFileStamp=Get-DeckAuthFileStamp $Root $Account}
        Write-DeckJson $path @{Version=1;Account=$Account;Email=$Email;State=$State;Message=$Message;At=[DateTimeOffset]::UtcNow.ToString('o');AuthFileStamp=$AuthFileStamp;HelperFileStamp=$(try{(Get-Item -LiteralPath (Get-DeckAuthHelperPath $Root) -ErrorAction Stop).LastWriteTimeUtc.Ticks.ToString()}catch{'0'});AttemptId=$script:AttemptId}
    } catch {}
}
function Get-DeckAuthHelperEntries([string]$Root) {
    $contents=Read-DeckAuthHelperText $Root
    if(-not $contents){return @()}
    $lineNumber=0
    foreach($line in ($contents -split "`r?`n")){
        $lineNumber++
        $entryLine=$line.Trim()
        if(-not $entryLine -or $entryLine.StartsWith('#')){continue}
        $parts=$entryLine.Split('|',3)
        if($parts.Count -ne 3){continue}
        $entryEmail=$parts[0].Trim().ToLowerInvariant()
        $password=$parts[1]
        $otp=$parts[2].Trim()
        if($entryEmail -notmatch '^[^|\s@]+@[^|\s@]+\.[^|\s@]+$' -or [string]::IsNullOrEmpty($password)){continue}
        [pscustomobject]@{Email=$entryEmail;Password=$password;Otp=$otp;Line=$lineNumber}
    }
}
function Find-DeckAuthHelperEntry([string]$Root,[string]$Email) {
    if([string]::IsNullOrWhiteSpace($Email)){return $null}
    return @(Get-DeckAuthHelperEntries $Root | Where-Object Email -ieq $Email | Select-Object -First 1)[0]
}
function Get-DeckAuthHelperEmail([string]$Root,[string]$Account) {
    try {
        $auth=Read-DeckJson (Join-Path $Root "accounts/$Account/auth.json")
        foreach($token in @($auth.tokens.id_token,$auth.tokens.access_token)){
            if(-not $token){continue}
            $part=$token.Split('.')[1].Replace('-','+').Replace('_','/')
            $part=$part.PadRight($part.Length+(4-$part.Length%4)%4,'=')
            $claims=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)) | ConvertFrom-Json
            foreach($candidate in @($claims.email,$claims.'https://api.openai.com/profile'.email,$claims.'https://api.openai.com/auth'.email)){
                if($candidate -and $candidate -match '^[^\s@]+@[^\s@]+\.[^\s@]+$'){return [string]$candidate}
            }
        }
    } catch {}
}
function Normalize-DeckAuthHelperAccountName([string]$Name) {
    if([string]::IsNullOrWhiteSpace($Name)){return $null}
    $value=$Name.Trim()
    if($value -match '^\d+$'){$value='account'+$value}
    if($value -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$' -or $value -match '^(?i:con|prn|aux|nul|com[0-9]|lpt[0-9])$'){return $null}
    return $value
}
function Get-DeckAuthHelperBatchTargets([string]$Root,[string[]]$RequestedAccounts) {
    $accountRoot=Join-Path $Root 'accounts'
    $raw=if(@($RequestedAccounts).Count){@($RequestedAccounts | ForEach-Object {[string]$_ -split '[,;\s]+' | Where-Object {$_}})}else{@(Get-ChildItem -LiteralPath $accountRoot -Directory -ErrorAction SilentlyContinue | Where-Object { -not (Test-Path -LiteralPath (Join-Path $_.FullName 'auth.json') -PathType Leaf) } | ForEach-Object Name)}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $targets=@()
    foreach($rawName in $raw){
        $name=Normalize-DeckAuthHelperAccountName ([string]$rawName)
        if(-not $name -or -not $seen.Add($name)){continue}
        $path=Join-Path $accountRoot $name
        if(-not (Test-Path -LiteralPath $path -PathType Container)){throw "Batch login target '$name' does not exist."}
        $targets+=$name
    }
    return @($targets)
}
function Write-DeckAuthHelperBatchStatus([string]$Root,[string]$State,[string]$Message='',[int]$ProcessId=0,[object[]]$Accounts=@()) {
    try { Write-DeckJson (Join-Path $Root 'deck/auth-helper/batch.json') @{Version=1;State=$State;Message=$Message;ProcessId=$ProcessId;Accounts=@($Accounts);At=[DateTimeOffset]::UtcNow.ToString('o')} } catch {}
}
function Start-DeckAuthHelperBatch([string]$Root,[string[]]$RequestedAccounts,[int]$Limit=2,[switch]$BrowserHarness) {
    $helper=Join-Path $Root 'Deck.AuthHelper.ps1'
    if(-not (Test-Path -LiteralPath $helper -PathType Leaf)){throw 'Deck Auth Helper is missing. Reinstall Codex Deck.'}
    if(-not (Get-Command Start-DeckBackgroundPowerShell -ErrorAction SilentlyContinue)){. (Join-Path $Root 'Deck.Core.ps1')}
    $targets=Get-DeckAuthHelperBatchTargets $Root $RequestedAccounts
    if(-not $targets.Count){throw 'No unsigned account profiles were found for batch login.'}
    $batchArgs=@('-Batch','-SuiteRoot',$Root,'-Concurrency',[Math]::Max(1,[Math]::Min(8,$Limit)))
    if($BrowserHarness){$batchArgs+=@('-BrowserHarness')}
    if(@($RequestedAccounts).Count){$batchArgs+=@('-Accounts');$batchArgs+=@($RequestedAccounts)}
    $process=Start-DeckBackgroundPowerShell $helper $batchArgs
    $batchPid=$process.Id; $process.Dispose()
    Write-DeckAuthHelperBatchStatus $Root 'started' 'Batch login is running in the background.' $batchPid $targets
    Write-Host ("Started background login for {0} account(s) with up to {1} Playwright workers. Status: {2}" -f $targets.Count,[Math]::Max(1,[Math]::Min(8,$Limit)),(Join-Path $Root 'deck/auth-helper/batch.json'))
}
function Invoke-DeckAuthHelperBatch([string]$Root,[string[]]$RequestedAccounts,[int]$Limit=2,[switch]$BrowserHarness) {
    $targets=Get-DeckAuthHelperBatchTargets $Root $RequestedAccounts
    $entries=@(Get-DeckAuthHelperEntries $Root)
    if(-not $entries.Count){throw 'The encrypted Auth Helper list is empty. Add one email|password|TOTP-secret entry per account first.'}
    $signedEmails=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($directory in @(Get-ChildItem -LiteralPath (Join-Path $Root 'accounts') -Directory -ErrorAction SilentlyContinue | Where-Object {Test-Path -LiteralPath (Join-Path $_.FullName 'auth.json') -PathType Leaf})){
        $email=Get-DeckAuthHelperEmail $Root $directory.Name
        if($email){[void]$signedEmails.Add($email)}
    }
    $available=@($entries | Where-Object {-not $signedEmails.Contains([string]$_.Email)})
    $scriptPath=Join-Path $Root 'Deck.AuthHelper.ps1'
    $running=New-Object System.Collections.ArrayList
    $mapped=@()
    $entryIndex=0
    foreach($account in $targets){
        $entry=if($entryIndex -lt $available.Count){$available[$entryIndex]}else{$null}
        $entryIndex++
        if(-not $entry){
            Set-DeckAuthHelperStatus $Root $account '' 'unmatched' 'No unused helper credential remains for this account.'
            continue
        }
        Remove-Item -LiteralPath (Get-DeckAuthHelperStatusPath $Root $account) -ErrorAction SilentlyContinue
        Set-DeckAuthHelperStatus $Root $account $entry.Email 'queued' 'Queued by Deck batch login.'
        while($running.Count -ge [Math]::Max(1,[Math]::Min(8,$Limit))){
            foreach($slot in @($running | ForEach-Object {$_})){
                if($slot.Process.HasExited){try{$slot.Process.Dispose()}catch{};[void]$running.Remove($slot)}
            }
            if($running.Count -ge [Math]::Max(1,[Math]::Min(8,$Limit))){Start-Sleep -Milliseconds 250}
        }
        $childArgs=@('-Recover','-SuiteRoot',$Root,'-Account',$account,'-Email',$entry.Email)
        if($BrowserHarness){$childArgs+=@('-BrowserHarness')}
        try{$child=Start-DeckBackgroundPowerShell $scriptPath $childArgs;[void]$running.Add([pscustomobject]@{Account=$account;Process=$child});$mapped+=[pscustomobject]@{Account=$account;Email=$entry.Email}}catch{Set-DeckAuthHelperStatus $Root $account $entry.Email 'failed' $_.Exception.Message}
    }
    while($running.Count){
        foreach($slot in @($running | ForEach-Object {$_})){
            if($slot.Process.HasExited){try{$slot.Process.Dispose()}catch{};[void]$running.Remove($slot)}
        }
        if($running.Count){Start-Sleep -Milliseconds 250}
    }
    Write-DeckAuthHelperBatchStatus $Root 'completed' 'Batch login workers finished.' 0 $targets
}
function ConvertTo-DeckAuthHelperArgument([AllowEmptyString()][string]$Value) {
    if($null -eq $Value){$Value=''}
    if($Value.Length -gt 0 -and $Value -notmatch '[\s"]'){return $Value}
    return '"'+($Value -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1')+'"'
}
function Invoke-DeckAuthHelperBrowserHarness([string]$Root,[string]$Url,[string]$Email,[string]$Password,[string]$Otp) {
    $oldUrl=$env:DECK_AUTH_URL; $oldEmail=$env:DECK_AUTH_EMAIL; $oldPassword=$env:DECK_AUTH_PASSWORD; $oldOtp=$env:DECK_AUTH_OTP; $oldTarget=$env:DECK_AUTH_TARGET; $oldTargetFile=$env:DECK_AUTH_TARGET_FILE
    try {
        $env:DECK_AUTH_URL=$Url; $env:DECK_AUTH_EMAIL=$Email; $env:DECK_AUTH_PASSWORD=$Password; $env:DECK_AUTH_OTP=$Otp
        $env:DECK_AUTH_TARGET_FILE=Join-Path $Root 'deck/auth-helper/browser-harness-tab.json'
        # Always create a fresh helper-owned target. A failed flow must never be
        # reused for another account, and no existing user tab is touched.
        $env:DECK_AUTH_TARGET=''
        $harnessCode=@'
import base64, hashlib, hmac, json, os, re, sys, time

url = os.environ["DECK_AUTH_URL"]
email = os.environ["DECK_AUTH_EMAIL"]
password = os.environ["DECK_AUTH_PASSWORD"]
otp_secret = os.environ.get("DECK_AUTH_OTP", "")
target_file = os.environ["DECK_AUTH_TARGET_FILE"]
target = os.environ.get("DECK_AUTH_TARGET", "")
if target:
    try:
        switch_tab(target)
        goto_url(url)
    except Exception:
        target = ""
if not target:
    created = cdp("Target.createTarget", url="about:blank", background=True)
    target = created.get("targetId") if isinstance(created, dict) else None
    if not target:
        raise RuntimeError("Chrome did not create a new background sign-in tab.")
    switch_tab(target)
    with open(target_file, "w", encoding="utf-8") as output:
        json.dump({"TargetId": target}, output)
    goto_url(url)
print("Deck sign-in opened in one new background Chrome tab.", flush=True)

def evaluate(expression):
    response = cdp("Runtime.evaluate", _response_timeout=20.0, expression=expression, returnByValue=True, awaitPromise=True)
    if response.get("exceptionDetails"):
        raise RuntimeError("Chrome could not inspect the sign-in page.")
    return response.get("result", {}).get("value")

def snapshot():
    raw = evaluate(r"""JSON.stringify((() => {
        const visible = e => { const s=getComputedStyle(e), r=e.getBoundingClientRect(); return s.display!=='none' && s.visibility!=='hidden' && r.width>0 && r.height>0; };
        return {url:location.href,title:document.title,body:(document.body?.innerText||'').replace(/\s+/g,' ').slice(0,500),
            inputs:[...document.querySelectorAll('input')].filter(visible).map(e=>({type:e.type||'',name:e.name||'',autocomplete:e.autocomplete||'',placeholder:e.placeholder||''})),
            options:[...document.querySelectorAll('label,[role=radio]')].filter(visible).map(e=>(e.innerText||e.getAttribute('aria-label')||'').trim()).filter(Boolean),
            buttons:[...document.querySelectorAll('button,[role=button],input[type=submit]')].filter(visible).map(e=>{const r=e.getBoundingClientRect();return {text:(e.innerText||e.value||e.getAttribute('aria-label')||'').trim().slice(0,90),type:e.type||'',x:r.x+r.width/2,y:r.y+r.height/2};})};
    })())""")
    return json.loads(raw) if isinstance(raw, str) else raw

def fill_one(selectors, value, label):
    last_error = None
    for selector in selectors:
        try:
            doc = cdp("DOM.getDocument", _response_timeout=20.0, depth=1)
            root_id = doc.get("root", {}).get("nodeId")
            field = cdp("DOM.querySelector", _response_timeout=20.0, nodeId=root_id, selector=selector)
            node_id = field.get("nodeId")
            if not node_id:
                continue
            expression = """(()=>{const e=document.querySelector(%s);if(!e)return false;const set=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;set.call(e,%s);e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));return e.value===%s;})()""" % (json.dumps(selector), json.dumps(value), json.dumps(value))
            if not evaluate(expression):
                raise RuntimeError("Chrome did not retain the typed value.")
            print(f"Entered the {label} field.", flush=True)
            return True
        except Exception as error:
            last_error = error
    reason = type(last_error).__name__ if last_error else "no matching input"
    raise RuntimeError(f"Browser-harness could not fill the {label} field ({reason}).")

def press_enter():
    try:
        press_key("Enter")
        return True
    except Exception:
        return False

def click_continue(state, allow_consent=False):
    buttons = sorted(state.get("buttons", []), key=lambda button: button.get("type", "") != "submit")
    for button in buttons:
        label = button.get("text", "").strip().lower()
        allowed = ("continue", "next", "submit", "authorize", "approve", "allow", "confirm")
        if any(word in label for word in allowed) and (allow_consent or not any(word in label for word in ("authorize", "approve", "allow"))):
            label = button.get("text", "")
            expression = """(()=>{const wanted=%s;const els=[...document.querySelectorAll('button,[role=button],input[type=submit]')];const e=els.find(x=>(x.innerText||x.value||x.getAttribute('aria-label')||'').trim()===wanted);if(!e)return false;e.click();return true;})()""" % json.dumps(label)
            if not evaluate(expression):
                continue
            return True
    return False

def make_totp(secret):
    normalized = re.sub(r"\s+", "", secret or "").replace("-", "").rstrip("=")
    if not normalized:
        raise RuntimeError("OpenAI requested an authenticator code, but the helper entry has no TOTP secret.")
    key = base64.b32decode((normalized + "=" * ((8-len(normalized)%8)%8)).upper(), casefold=True)
    counter = int(time.time() // 30).to_bytes(8, "big")
    digest = hmac.new(key, counter, hashlib.sha1).digest()
    offset = digest[-1] & 15
    return f"{(int.from_bytes(digest[offset:offset+4], 'big') & 0x7fffffff) % 1000000:06d}"

deadline = time.time() + 300
challenge_since = None
email_done = password_done = otp_done = False
email_submitted_at = None
while time.time() < deadline:
    try:
        state = snapshot()
    except Exception:
        time.sleep(0.6)
        continue
    page_url = state.get("url", "").lower()
    title = state.get("title", "").lower()
    body = state.get("body", "").lower()
    if page_url.startswith("http://127.0.0.1:") and "/auth/callback" in page_url:
        print("Deck received the OAuth callback.", flush=True)
        time.sleep(0.5)
        try:
            cdp("Target.closeTarget", _response_timeout=20.0, targetId=target)
        except Exception:
            pass
        break
    if "sign-in received. you can close this tab" in body or "successfully authorized" in body:
        print("Deck received the OAuth callback.", flush=True)
        time.sleep(0.5)
        try:
            cdp("Target.closeTarget", _response_timeout=20.0, targetId=target)
        except Exception:
            pass
        break
    if any(s in body for s in ("invalid password", "incorrect password", "wrong code", "too many attempts", "unusual activity")):
        raise RuntimeError("OpenAI rejected the sign-in details or requires an account check; stopped.")
    if "unexpected token" in body or "not valid json" in body:
        raise RuntimeError("OpenAI returned an invalid response after sign-in; stopped for a safe retry.")
    security_page = any(s in body or s in title for s in ("cloudflare", "verify you are human", "checking your browser", "just a moment", "security verification", "captcha"))
    if security_page:
        if challenge_since is None:
            challenge_since = time.time()
        elif time.time() - challenge_since > 180:
            raise RuntimeError("OpenAI still requires a security check in the background Chrome tab; stopped without solving it.")
        time.sleep(0.8)
        continue
    challenge_since = None
    if any(s in body for s in ("select a workspace", "choose a workspace", "select an organization", "choose an organization")):
        if click_continue(state, allow_consent=True):
            print("Continued with the already selected workspace.", flush=True)
            time.sleep(1.5)
            continue
        raise RuntimeError("OpenAI workspace selection did not expose a Continue action.")
    inputs = state.get("inputs", [])
    if not email_done and any(x.get("type") == "email" or x.get("autocomplete") == "username" or "email" in x.get("name", "").lower() for x in inputs):
        fill_one(["input[type='email']", "input[name='email']", "input[autocomplete='username']", "input[placeholder*='email' i]"], email, "email")
        email_done = True
        submitted = click_continue(state) or press_enter()
        if not submitted: raise RuntimeError("OpenAI email page did not expose a working Continue action.")
        email_submitted_at = time.time()
        print("Submitted the email step.", flush=True)
        time.sleep(1.5)
        continue
    if not password_done and any(x.get("type") == "password" or "current-password" in x.get("autocomplete", "") for x in inputs):
        fill_one(["input[type='password']", "input[name='password']", "input[autocomplete='current-password']"], password, "password")
        password_done = True
        submitted = click_continue(state) or press_enter()
        if not submitted: raise RuntimeError("OpenAI password page did not expose a working Continue action.")
        print("Submitted the password step.", flush=True)
        time.sleep(1.5)
        continue
    if not otp_done and any("one-time-code" in x.get("autocomplete", "") or "otp" in x.get("name", "").lower() or "authenticator" in x.get("name", "").lower() for x in inputs):
        fill_one(["input[autocomplete='one-time-code']", "input[name*='otp' i]", "input[name*='authenticator' i]", "input[name*='code' i]"], make_totp(otp_secret), "authenticator code")
        otp_done = True
        submitted = click_continue(state) or press_enter()
        if not submitted: raise RuntimeError("OpenAI authenticator page did not expose a working Continue action.")
        print("Submitted the authenticator step.", flush=True)
        time.sleep(1.5)
        continue
    if password_done or otp_done:
        if click_continue(state, allow_consent=True):
            time.sleep(0.8)
            continue
    if email_submitted_at and not password_done and not otp_done and any(x.get("type") == "email" for x in inputs) and time.time() - email_submitted_at > 12:
        raise RuntimeError("OpenAI did not advance after the email step; stopped instead of retrying against the same response.")
    if not email_done and not password_done and not otp_done and time.time() - (deadline - 300) > 15 and inputs:
        raise RuntimeError("OpenAI sign-in form did not expose a supported email field; stopped.")
    time.sleep(0.6)
else:
    raise RuntimeError("OpenAI sign-in did not finish before the five-minute timeout.")
'@
        $harnessOutput=@($harnessCode | & browser-harness 2>&1)
        if($LASTEXITCODE -ne 0){
            $detail=($harnessOutput | ForEach-Object {[string]$_}) -join ' '
            if($detail -match '(?i)security check|cloudflare|captcha|verify you are human'){throw 'OpenAI still requires a security check in the background Chrome tab; stopped without solving it.'}
            if($detail -match '(?i)invalid response|unexpected token|not valid json'){throw 'OpenAI returned an invalid response after sign-in; stopped for a safe retry.'}
            if($detail -match '(?i)did not advance after the email step'){throw 'OpenAI did not advance after the email step in the background tab.'}
            if($detail -match '(?i)could not fill the email field'){throw 'The background tab did not expose a usable email field.'}
            if($detail -match '(?i)could not fill the password field'){throw 'The background tab did not expose a usable password field.'}
            if($detail -match '(?i)authenticator|TOTP|one-time'){throw 'The background tab did not accept the authenticator step.'}
            if($detail -match '(?i)workspace selection'){throw 'The background tab did not expose the selected workspace Continue action.'}
            if($detail -match '(?i)timeout|did not finish'){throw 'The background sign-in timed out before OAuth completed.'}
            throw 'Browser-harness sign-in stopped before completing OAuth.'
        }
    } finally {
        $env:DECK_AUTH_URL=$oldUrl; $env:DECK_AUTH_EMAIL=$oldEmail; $env:DECK_AUTH_PASSWORD=$oldPassword; $env:DECK_AUTH_OTP=$oldOtp; $env:DECK_AUTH_TARGET=$oldTarget; $env:DECK_AUTH_TARGET_FILE=$oldTargetFile
    }
}
function Start-DeckAuthHelperBrowser([string]$Root,[string]$Account,[string]$Email,[string]$Password,[string]$Otp,[switch]$ShowBrowser,[switch]$BrowserHarness) {
    $scriptPath=Join-Path $Root 'Deck.AuthHelper.py'
    if(-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)){throw 'Deck Auth Helper browser worker is missing. Reinstall Codex Deck.'}
    $python=Get-Command python.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if(-not $python){$python=Get-Command py.exe -ErrorAction SilentlyContinue | Select-Object -First 1}
    if(-not $python){throw 'Deck Auth Helper requires Python with Playwright installed.'}
    $probeArgs=if([IO.Path]::GetFileName($python.Source) -ieq 'py.exe'){@('-3','-c','import playwright.sync_api')}else{@('-c','import playwright.sync_api')}
    & $python.Source @probeArgs *> $null
    if($LASTEXITCODE -ne 0){throw 'Deck Auth Helper requires the Python Playwright package. Install it with: py -3 -m pip install playwright'}
    $browser=if(Test-Path -LiteralPath (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe') -PathType Leaf){Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'}elseif(Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe') -PathType Leaf){Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'}else{''}
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$python.Source;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $pythonArgs=@('-u',$scriptPath)
    if([IO.Path]::GetFileName($python.Source) -ieq 'py.exe'){$pythonArgs=@('-3')+$pythonArgs}
    $info.Arguments=($pythonArgs | ForEach-Object {ConvertTo-DeckAuthHelperArgument ([string]$_)}) -join ' '
    $process=[Diagnostics.Process]::Start($info)
    $bridgePath=if($BrowserHarness){Join-Path $env:TEMP ('deck-auth-url-'+[guid]::NewGuid().ToString('N')+'.json')}else{''}
    try {
        $codexHome=Join-Path (Join-Path $Root 'accounts') $Account
        $payload=@{codex_home=$codexHome;email=$Email;password=$Password;otp=$Otp;browser_path=$browser;show_browser=[bool]$ShowBrowser;browser_harness=[bool]$BrowserHarness;bridge_path=$bridgePath} | ConvertTo-Json -Compress
        $stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync()
        $process.StandardInput.WriteLine($payload); $process.StandardInput.Close()
        if($BrowserHarness){
            $bridgeDeadline=[DateTime]::UtcNow.AddSeconds(30)
            while(-not (Test-Path -LiteralPath $bridgePath -PathType Leaf) -and -not $process.HasExited -and [DateTime]::UtcNow -lt $bridgeDeadline){Start-Sleep -Milliseconds 100}
            if(-not (Test-Path -LiteralPath $bridgePath -PathType Leaf)){
                if($process.HasExited){throw $(if($stderrTask.IsCompleted -and $stderrTask.Result.Trim()){$stderrTask.Result.Trim()}else{'Deck could not start its OAuth callback for Chrome sign-in.'})}
                throw 'Deck did not publish the Chrome sign-in URL.'
            }
            $bridge=Get-Content -LiteralPath $bridgePath -Raw | ConvertFrom-Json
            Invoke-DeckAuthHelperBrowserHarness $Root ([string]$bridge.url) $Email $Password $Otp
            $timeout=300000
        }else{$timeout=if($ShowBrowser){300000}else{150000}}
        if(-not $process.WaitForExit($timeout)){try{$process.Kill()}catch{};throw 'Playwright sign-in timed out.'}
        $errorText=$stderrTask.Result.Trim()
        if($process.ExitCode -ne 0){throw $(if($errorText){$errorText}else{'Playwright sign-in failed.'})}
    } finally { try{if(-not $process.HasExited){$process.Kill()}}catch{};try{$process.Dispose()}catch{};if($bridgePath){Remove-Item -LiteralPath $bridgePath -Force -ErrorAction SilentlyContinue} }
}
function Invoke-DeckAuthHelperRecovery([string]$Root,[string]$Account,[string]$Email,[switch]$ShowBrowser,[switch]$BrowserHarness,[switch]$Force) {
    if($Account -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,39}$'){return}
    $entry=Find-DeckAuthHelperEntry $Root $Email
    if(-not $entry){Set-DeckAuthHelperStatus $Root $Account $Email 'unmatched' 'No helper credential matches this routed email.';return}
    $authStamp=Get-DeckAuthFileStamp $Root $Account
    $helperStamp=try{(Get-Item -LiteralPath (Get-DeckAuthHelperPath $Root) -ErrorAction Stop).LastWriteTimeUtc.Ticks.ToString()}catch{'0'}
    $previous=Read-DeckJson (Get-DeckAuthHelperStatusPath $Root $Account)
    if(-not $ShowBrowser -and -not $BrowserHarness -and -not $Force -and $previous -and $previous.Email -ieq $Email -and [string]$previous.AuthFileStamp -eq $authStamp -and [string]$previous.HelperFileStamp -eq $helperStamp -and $previous.State -in @('unmatched','succeeded','failed')){return}
    $lockPath=Join-Path $Root "deck/auth-helper/$Account.lock"
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $lockPath))
    try{$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{return}
    try {
        Set-DeckAuthHelperStatus $Root $Account $entry.Email 'running' 'Starting Deck-managed OAuth login.'
        Start-DeckAuthHelperBrowser $Root $Account $entry.Email $entry.Password $entry.Otp -ShowBrowser:$ShowBrowser -BrowserHarness:$BrowserHarness
        $newEmail=Get-DeckAuthHelperEmail $Root $Account
        if($newEmail -and $newEmail -ieq $entry.Email){
            Remove-Item -LiteralPath (Join-Path $Root "deck/auth-issues/$Account.json") -ErrorAction SilentlyContinue
            Set-DeckAuthHelperStatus $Root $Account $entry.Email 'succeeded' 'Deck-managed sign-in completed.'
        }else{throw 'Deck login completed, but the installed profile email did not match the helper entry.'}
    } catch {
        Set-DeckAuthHelperStatus $Root $Account $entry.Email 'failed' $_.Exception.Message $authStamp
        try{Write-DeckJson (Join-Path $Root "deck/auth-issues/$Account.json") @{Version=1;Account=$Account;Code='oauth_invalid';DetectedAt=[DateTimeOffset]::UtcNow.ToString('o');AuthFileStamp=(Get-DeckAuthFileStamp $Root $Account)}}catch{}
    }
    finally {try{$lock.Dispose()}catch{}}
}
function Show-DeckAuthHelper([string]$Root,[switch]$TestUI) {
    Add-Type -AssemblyName PresentationFramework
    $path=Get-DeckAuthHelperPath $Root
    $originalStored=if(Test-Path -LiteralPath $path -PathType Leaf){[IO.File]::ReadAllText($path)}else{''}
    $original=if($originalStored){Read-DeckAuthHelperText $Root}else{"# One account per line: email|password|totp-secret`r`n# Deck encrypts this list for the current Windows user.`r`n# Keep it local. It is used only for automatic Deck reauthentication.`r`n"}
    $dialog=[Windows.Window]::new();$dialog.Title='Codex Deck / Auth Helper';$dialog.Width=760;$dialog.Height=540;$dialog.WindowStartupLocation='CenterScreen';$dialog.Background='#101315';$dialog.Foreground='#EAF0FA'
    $dock=[Windows.Controls.DockPanel]::new();$dock.Margin='18';$dialog.Content=$dock
    $note=[Windows.Controls.TextBlock]::new();$note.Text='One account per line: email|password|TOTP secret. Deck matches the routed account email and runs OAuth in a new background tab in your already open Chrome window through the browser harness. Keep this local and never commit it.';$note.TextWrapping='Wrap';$note.Margin='0,0,0,12';[Windows.Controls.DockPanel]::SetDock($note,'Top');[void]$dock.Children.Add($note)
    $save=[Windows.Controls.Button]::new();$save.Content='Save helper list';$save.Padding='12,8';$save.Margin='0,12,0,0';[Windows.Controls.DockPanel]::SetDock($save,'Bottom');[void]$dock.Children.Add($save)
    $errorLabel=[Windows.Controls.TextBlock]::new();$errorLabel.Foreground='#F17D8D';$errorLabel.TextWrapping='Wrap';[Windows.Controls.DockPanel]::SetDock($errorLabel,'Bottom');[void]$dock.Children.Add($errorLabel)
    $editor=[Windows.Controls.TextBox]::new();$editor.Text=$original;$editor.AcceptsReturn=$true;$editor.AcceptsTab=$true;$editor.TextWrapping='Wrap';$editor.VerticalScrollBarVisibility='Auto';$editor.FontFamily='Consolas';$editor.FontSize=14;$editor.Background='#192232';$editor.Foreground='#EAF0FA';[void]$dock.Children.Add($editor)
    $save.Add_Click({try{$current=if(Test-Path -LiteralPath $path){[IO.File]::ReadAllText($path)}else{''};if($current -cne $originalStored){throw 'The helper list changed outside this editor. Reopen it before saving.'};foreach($line in $editor.Text -split "`r?`n"){$text=$line.Trim();if(-not $text -or $text.StartsWith('#')){continue};$parts=$text.Split('|',3);if($parts.Count -ne 3 -or $parts[0] -notmatch '^[^|\s@]+@[^|\s@]+\.[^|\s@]+$' -or [string]::IsNullOrEmpty($parts[1])){throw 'Each entry must contain email|password|totp-secret.'}};if(Test-Path -LiteralPath $path){Copy-Item -LiteralPath $path -Destination ($path+'.bak-deck-'+[guid]::NewGuid().ToString('N'))};Write-DeckAuthHelperText $Root $editor.Text;Start-DeckAuthHelperForPendingIssues $Root;$dialog.Close()}catch{$errorLabel.Text=$_.Exception.Message}}.GetNewClosure())
    if($TestUI){return @{Dialog=$dialog;Editor=$editor;Save=$save;Error=$errorLabel}}
    [void]$dialog.ShowDialog()
}
function Start-DeckAuthHelperForPendingIssues([string]$Root) {
    if(-not (Get-Command Start-DeckAuthHelperRecoveryWorker -ErrorAction SilentlyContinue)){. (Join-Path $Root 'Deck.Core.ps1')}
    $directory=Join-Path $Root 'deck/auth-issues'
    if(-not [IO.Directory]::Exists($directory)){return}
    foreach($file in [IO.Directory]::EnumerateFiles($directory,'*.json')){
        $issue=Read-DeckJson $file
        if(-not $issue -or $issue.Code -notin @('token_revoked','oauth_invalid')){continue}
        $account=[IO.Path]::GetFileNameWithoutExtension($file)
        if($issue.AuthFileStamp -ne (Get-DeckAuthFileStamp $Root $account)){continue}
        $email=Get-DeckAuthHelperEmail $Root $account
        if($email -and (Find-DeckAuthHelperEntry $Root $email)){[void](Start-DeckAuthHelperRecoveryWorker $Root $account $email -Force)}
    }
}
if($Batch){. (Join-Path $SuiteRoot 'Deck.Core.ps1');Invoke-DeckAuthHelperBatch $SuiteRoot $Accounts $Concurrency -BrowserHarness:$BrowserHarness}
elseif($Recover){. (Join-Path $SuiteRoot 'Deck.Core.ps1');Invoke-DeckAuthHelperRecovery $SuiteRoot $Account $Email -ShowBrowser:$ShowBrowser -BrowserHarness:$BrowserHarness -Force:$Force}
elseif($Edit){Show-DeckAuthHelper $SuiteRoot}
