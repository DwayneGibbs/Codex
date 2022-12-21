
function Enable-Codex {
    param (
        [string]$Chord = "ctrl+g",
        [switch]$Overwrite
    )

    foreach ($line in $defaultContext.Split("`n")) {
        $contextList.Add($line)
    }

    $handler = Get-PSReadLineKeyHandler -Chord $Chord
    if ($null -ne $handler -and -not $Overwrite) {
        throw "A key handler for '$Chord' already exists.  Use `-Overwrite` to overwrite."
    }

    Set-PSReadLineKeyHandler -Key $Chord -BriefDescription 'Codex' -LongDescription 'Enable retriving Codex completions based on a comment' -ScriptBlock {
        param($key, $arg)
        
        $line = $null
        $cursor = $null

        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)

        $output = Get-CodexCompletion -Line $line

        if ($null -eq $output) {
            $output = @('# No completion found')
        }

        $emptyCompletion = $true
        foreach ($str in $output) {
            $str = $str.Trim()
            if (![string]::IsNullOrEmpty($str)) {
                [Microsoft.PowerShell.PSConsoleReadLine]::AddLine()
                [Microsoft.PowerShell.PSConsoleReadLine]::Insert($str)
                $emptyCompletion = $false
            }
        }

        if ($emptyCompletion) {
            [Microsoft.PowerShell.PSConsoleReadLine]::AddLine()
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert('# An empty completion was returned')
        }
        else {
            $result = Test-Completion $output
            if ($null -ne $result) {
                [Microsoft.PowerShell.PSConsoleReadLine]::AddLine()
                [Microsoft.PowerShell.PSConsoleReadLine]::Insert($result)
            }
        }
    }
}

function Register-CodexOpenApiKey {
    param (
        [Parameter(Mandatory)]
        [securestring]$ApiKey,

        [switch]$Overwrite
    )

    if ($null -eq (Get-Module Microsoft.PowerShell.SecretManagement -ListAvailable)) {
        throw "Please install the Microsoft.PowerShell.SecretManagement module to use this cmdlet"
    }

    if ($null -ne (Get-Secret -Name $secretName -ErrorAction Ignore) -and -not $Overwrite) {
        throw "Secret '$secretName' already exists. Use `-Overwrite` to overwrite."
    }

    Test-OpenApiKey -ApiKey $ApiKey
    Set-Secret -Name CodexOpenApiKey -Secret $ApiKey
}

function Test-Completion {
    param (
        $Lines
    )

    $tokens = $null
    $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Lines, [ref]$tokens, [ref]$err)
    if ($err.Length -gt 0) {
        return "# This is not a valid PowerShell script"
    }

    $commands = $ast.FindAll({$true},$true) | Where-Object { $_ -is [System.Management.Automation.Language.CommandAst] } | ForEach-Object { $_.CommandElements[0].Value } | Sort-Object -Unique
    foreach ($command in $commands) {
        $c = Get-Command $command -ErrorAction Ignore
        if ($null -eq $c) {
            return "# '$command' not found on this system"
        }
    }
}

function Test-OpenApiKey {
    param (
        [Parameter(Mandatory)]
        [securestring]$ApiKey
    )

    try {
        Write-Progress -Activity "OpenAI Key" -Status "Validating..."
        $null = Invoke-RestMethod -Uri 'https://api.openai.com/v1/engines' -Authentication Bearer -Token $ApiKey
        Write-Progress -Activity "OpenAI Key" -Completed
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        throw "Failed to access OpenAI api [$statusCode]. Please check your OpenAI API key (https://beta.openai.com/account/api-keys) and Organization ID (https://beta.openai.com/account/org-settings)."
    }
}

$engine = 'code-davinci-002'
$secretName = 'CodexOpenApiKey'
$contextList = [System.Collections.Generic.List[string]]::new()
$defaultContext = @"
# how many GB is 367247884288 B?
(367247884288 / 1GB)
"@

function Get-CodexCompletion {
    param (
        [ValidateNotNullOrEmpty()]
        [string]$Line
    )

    $ApiKey = Get-Secret -Name $secretName -ErrorAction Ignore
    if ($null -eq $ApiKey) {
        throw "OpenAI API key not found. Please use Register-CodexOpenApiKey to register your OpenAI API key"
    }

    #$contextList.Add("\n\n" + $Line.Replace('"', '\"'))

    $trimList = $false
    do {
        if ($trimList) {
            $contextList.RemoveAt(0)
        }

        $context = $contextList.ToArray()
        [int]$tokenCount = $context[0].Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries).count + $contextList.Count - 1
        $trimList = $true
    }
    while ($tokenCount -gt 4096)
 
    $moderation = Get-ModerationClassification -Context $($context[0].ToString().Trim()) -ApiKey $ApiKey

    if($moderation.results.flagged -eq $true){
        $moderationModel = $moderation.model
        $categories = $moderation.results.categories | Get-Member -MemberType NoteProperty | Select-Object -Property Name
        $violatedCategories = $null
        $categories | ForEach-Object{
            $categoryName = $_.Name
            if($null -eq $violatedCategories -and $moderation.results.categories.$($categoryName) -eq $true){
                $violatedCategories = $categoryName
            }elseif($moderation.results.categories.$($categoryName) -eq $true){
                $violatedCategories = $violatedCategories + ", " + $categoryName
            }
        }
        Write-Warning "The model, $($moderationModel), has classified the content as having violated OpenAI's content policy in the following categories: $($categories)"
    }elseif($null -eq $moderation){
        Write-Warning "Content could not be validated on a moderation model."
    }else{

        #$body = @{ model="$($engine)"; prompt="$($context[0].ToString().Trim())"; temperature= 0; max_tokens=300; stop="#" } | ConvertTo-Json -Compress
        #$body = @{ model="code-davinci-002"; prompt="Say this is a test"; max_tokens=7; temperature=0; top_p=1; n=1; stream=false; logprobs=null; stop="\n" } | ConvertTo-Json -Compress 
        $body = @{ model="code-davinci-002"; prompt="Say this is a test"; max_tokens=7; temperature=0; } | ConvertTo-Json -Compress

        Write-Progress -Activity "Codex" -Status "Getting completion..."
        try {
            $completion = Invoke-RestMethod -Uri "https://api.openai.com/v1/completions" -ContentType 'application/json' -Authentication Bearer -Token $ApiKey -Body $body -Method Post
        }
        catch {
            Write-Error $_
            Write-Verbose -Verbose $body
        }

        Write-Progress -Activity "Codex" -Completed

        $response = $completion.Choices.Text

        if ($null -ne $response) {
            $contextList.Add($response.Trim().Replace("`n", "\n"))
            return $response
        }
        else {
            Write-Warning "Did not receive response from OpenAI"
        }
    }
}

function Get-ModerationClassification {
    param (
        [ValidateNotNullOrEmpty()]
        [string]$context,    
        
        [securestring]$ApiKey
    )


    if ($null -eq $ApiKey) {
        $ApiKey = Get-Secret -Name $secretName -ErrorAction Ignore
        if($null -eq $ApiKey){
            throw "OpenAI API key not found. Please use Register-CodexOpenApiKey to register your OpenAI API key"
        }
    }
    
    $body = @{input="$($context.Trim())"} | ConvertTo-Json -Compress

    Write-Progress -Activity "Codex" -Status "Getting moderation results..."
    try {
        $moderation = Invoke-RestMethod -Uri "https://api.openai.com/v1/moderations" -ContentType 'application/json' -Authentication Bearer -Token $ApiKey -Body $body -Method Post
    }
    catch {
        Write-Error $_
        Write-Verbose -Verbose $body
    }

    Write-Progress -Activity "Codex" -Completed
    
    if ($null -ne $moderation) {
        return $moderation
    }
    else {
        Write-Warning "Did not receive response from OpenAI when getting moderation classification."
    }
}