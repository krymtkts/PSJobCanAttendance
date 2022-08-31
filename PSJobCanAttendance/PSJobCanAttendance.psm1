# The location of the file that we'll store the Access Token SecureString
# which cannot/should not roam with the user.
[string] $script:JCCredentialPath = [System.IO.Path]::Combine(
    [System.Environment]::GetFolderPath('LocalApplicationData'),
    'krymtkts',
    'PSJobCanAttendance',
    'credential')

$script:LocaleEN = New-Object System.Globalization.CultureInfo('en-US') #English (US) Locale

class JCCredentialStore {
    [string] $EmailOrStaffCode
    [SecureString] $Password
    JCCredentialStore(
        [string] $EmailOrStaffCode,
        [SecureString] $Password
    ) {
        $this.EmailOrStaffCode = $EmailOrStaffCode
        $this.Password = $Password
    }
}

$script:JCCredential = $null
$script:JCSession = $null
$script:MySession = $null

function Set-JobCanAuthentication {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [PSCredential] $Credential
    )

    if (-not $Credential) {
        $message = 'Please provide your JobCan user and password.'
        if ($PsCmdlet.ParameterSetName -eq 'Cache') {
            $message = $message + 'These credential is being cached across PowerShell sessions. To clear caching, call Clear-JobCanAuthentication.'
        }
        $Credential = Get-Credential -Message $message
    }
    $script:JCCredential = [JCCredentialStore]::new(
        $Credential.UserName, $Credential.Password)

    $store = @{
        EmailOrStaffCode = $Credential.UserName;
        Password = $Credential.Password | ConvertFrom-SecureString;
    }

    if ($PSCmdlet.ShouldProcess($script:JCCredentialPath)) {
        New-Item -Path $script:JCCredentialPath -Force | Out-Null
        $store | ConvertTo-Json -Compress | Set-Content -Path $script:JCCredentialPath -Force
    }
}

function Restore-JobCanAuthentication {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
    )

    if ($script:JCCredential) {
        return
    }
    $content = Get-Content -Path $script:JCCredentialPath -ErrorAction Ignore
    if ([String]::IsNullOrEmpty($content)) {
        Set-JobCanAuthentication
    }
    else {
        try {
            $cred = $content | ConvertFrom-Json
            $script:JCCredential = [JCCredentialStore]::new(
                $cred.EmailOrStaffCode, ($cred.PassWord | ConvertTo-SecureString)
            )
            return
        }
        catch {
            Write-Error 'Invalid SecureString stored for this module. Use Set-JobCanAuthentication to update it.'
        }
    }
}

function Clear-JobCanAuthentication {
    [CmdletBinding(SupportsShouldProcess)]
    param(
    )

    $script:JCCredential = $null
    Remove-Item -Path $script:JCCredentialPath -Force -ErrorAction SilentlyContinue
}

function Get-DateForDisplay {
    [CmdletBinding()]
    param (
        [Parameter(HelpMessage = 'The value of date time to format.')]
        [DateTime]
        $Date = (Get-Date)
    )

    $Date.ToLocalTime().ToString('yyyy-MM-dd(ddd) HH:mm:ss K', $script:LocaleEN)
}


function Find-AuthToken {
    [CmdletBinding()]
    [OutputType([String])]
    param (
        [Parameter(Mandatory)]
        [String]
        $Content,
        [Parameter(Mandatory)]
        [String]
        $Id
    )

    process {
        $Match = $res.Content -split "`n" | Select-String -Pattern "`"${Id}`".+authenticity_token.+value=`"(?<token>\S+)`""
        $Token = $Match[0].Matches.Groups[1].Value
        if (!$Token) {
            throw 'Cannot scrape csrf token.'
        }
        return $Token
    }
}

function Get-RecordTime {
    process {
        $Now = Get-Date -AsUTC
        [PSCustomObject]@{
            Raw = $Now
            Date = $Now.ToString('MM/dd/yyyy')
            RecordTime = $Now.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        }
    }
}

function Connect-JobCanCloudAttendance {
    [CmdletBinding()]
    param()
    begin {
        if ($script:JCCredential) {
            Write-Host 'Trying to connect JobCan Attendance...'
        }
        else {
            throw 'No credential found. run Set-JobCanAuthentication to set login information of JobCan.'
        }
    }

    end {
        $Login = 'https://id.jobcan.jp/users/sign_in'
        $NewSessionParams = @{
            Method = 'Get'
            Uri = $Login
            SessionVariable = 'script:MySession'
        }
        Write-Verbose ($NewSessionParams | Out-String)
        try {
            $Res = Invoke-WebRequest @NewSessionParams
            $AuthToken = Find-AuthToken -Content $Res.Content -Id new_user
            Write-Verbose $AuthToken
        }
        catch {
            Write-Error "Failed to connect $Login . $_"
            Write-Verbose ($NewSessionParams | Out-String)
            throw
        }

        $LoginParams = @{
            Method = 'Post'
            Uri = $Login
            WebSession = $script:MySession
            Body = @{
                'authenticity_token' = $AuthToken
                'user[email]' = $script:JCCredential.EmailOrStaffCode
                'user[password]' = $script:JCCredential.Password | ConvertFrom-SecureString -AsPlainText
                'app_key' = 'atd'
                'commit' = 'Login'
            }
        }
        try {
            $Res = Invoke-WebRequest @LoginParams
            $AuthToken = Find-AuthToken -Content $Res.Content -Id edit_user
            Write-Verbose $AuthToken
        }
        catch {
            Write-Error "Failed to login $Login. $_"
            throw
        }

        $LoginParams = @{
            Method = 'Post'
            Uri = $Login
            WebSession = $script:MySession
            Body = @{
                'authenticity_token' = $token
                'user[otp_attempt]' = Read-Host -Prompt 'Two-Factor Authentication: '
                'commit' = 'Authenticate'
            }
        }
        try {
            $Res = Invoke-WebRequest @LoginParams
        }
        catch {
            Write-Error "Failed to login $Login. $_"
            throw
        }

        if ($Res.Content -match 'アカウント情報') {
            Write-Host "Login succeed. $(Get-DateForDisplay)"
        }
        else {
            throw "Login failed. $(Get-DateForDisplay)"
        }

        $Params = @{
            Method = 'Get'
            Uri = 'https://ssl.jobcan.jp/jbcoauth/login'
            WebSession = $MySession
        }
        try {
            $Res = Invoke-WebRequest @Params
        }
        catch {
            Write-Error "Failed to login $Login. $_"
            throw
        }
    }
}

function Find-AttendanceRecord {
    [CmdletBinding()]
    [OutputType([Hashtable])]
    param (
        [Parameter(Mandatory)]
        [String]
        $Content
    )

    process {
        $TBody = $Content -split "`n" | Select-String -Pattern 'tbody'
        if (-not $TBody) {
            throw 'No attendance found.'
        }
        Write-Verbose ($TBody | Out-String)
        $Times = $TBody -split 'jbc-text-reset' | ForEach-Object { ([regex]'(?<month>\d\d)/(?<day>\d\d)\((月|火|水|木|金|土|日)\)</a></td><td></td><td>11:00～15:00</td><td>(?<start>\d\d:\d\d)</td><td>(?<end>\d\d:\d\d)</td>').Matches($_) }
        if (-not $Times) {
            throw 'Cannot scrape attendance time entries.'
        }
        $Result = @{}
        $Times | ForEach-Object {
            $Result.Add("$($Time.Groups['month'])/$($Time.Groups['day'])", [PSCustomObject]@{
                    Start = $Time.Groups['start']
                    End = $Time.Groups['end']
                })
        }
        return $Result
    }
}

function Get-AttendanceRecord {
    [CmdletBinding()]
    param (
    )

    begin {
        Write-Verbose ($script:MySession | Out-String)
        Write-Verbose ($script:JCSession | Out-String)
    }

    process {
        $MyPage = 'https://ssl.jobcan.jp/employee/attendance'
        $Params = @{
            Method = 'Get'
            Uri = $MyPage
            WebSession = $script:MySession
        }
        Write-Verbose ($Params | Out-String)
        try {
            $Res = Invoke-WebRequest @Params
            Write-Host "Succeed to get content. $(Get-DateForDisplay (Get-Date))"
            if (!$Res) {
                Write-Error "Failed to get content from  $Attendances."
                return
            }
            $Records = Find-AttendanceRecord -Content $Res.Content
            return $Records
        }
        catch {
            Write-Error 'Failed to send time record.'
            throw
        }
    }
}

function Test-CanRecord {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('clock_in', 'clock_out')]
        $TimeRecordEvent
    )
    process {
        $Today = (Get-Date).Day
        $Records = Get-AttendanceRecord
        switch ($TimeRecordEvent) {
            'clock_in' {
                return -not [boolean] $Records[$Today].Start
            }
            'clock_out' {
                return -not [boolean] $Records[$Today].End
            }
        }
    }
}

function Send-TimeRecord {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('work_start', 'work_end', 'rest_start', 'rest_end')]
        $TimeRecordEvent,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $AditGroupId,
        [Parameter()]
        [int]
        $NightShift = 0,
        [Parameter()]
        [string]
        $Notice = ''
    )

    begin {
        Write-Verbose ($script:MySession | Out-String)
        Write-Verbose ($script:JCSession | Out-String)
    }

    process {
        $MyPage = 'https://ssl.jobcan.jp/employee'
        $NewSessionParams = @{
            Method = 'Get'
            Uri = $MyPage
            WebSession = $script:MySession
        }
        Write-Verbose ($NewSessionParams | Out-String)
        try {
            $Res = Invoke-WebRequest @NewSessionParams
            $Match = $Res.Content -split "`n" | Select-String -Pattern "name=`"token`".+value=`"(?<token>\S+)`">"
            $Token = $Match[0].Matches.Groups[1].Value
            Write-Verbose $Token
        }
        catch {
            Write-Error "Failed to connect $MyPage. $_"
            throw
        }
        $TimeRecorder = 'https://ssl.jobcan.jp/employee/index/adit'
        $Now = Get-RecordTime

        $Body = @{
            'is_yakin' = $NightShift
            'adit_item' = $TimeRecordEvent
            'notice' = $Notice
            'token' = $Token
            'adit_group_id' = $AditGroupId
            '_' = '' # ?
        }
        $LoginParams = @{
            Method = 'Post'
            Uri = $TimeRecorder
            WebSession = $MySession
            Body = $Body
        }
        Write-Verbose ($LoginParams | Out-String)
        Write-Verbose ($Body | Out-String)
        try {
            $Res = Invoke-WebRequest @LoginParams
            Write-Host "Succeed to send time record. $TimeRecordEvent $(Get-DateForDisplay $Now.Raw)"
        }
        catch {
            Write-Error "Failed to send time record. $TimeRecorder. $TimeRecordEvent"
            throw
        }
    }
}

function Send-BeginningWork {
    begin {
        Write-Host 'try to begin work.'
    }

    process {
        Restore-JobCanAuthentication
        Connect-JobCanCloudAttendance
        $Recordable = Test-CanRecord work_start
        if ($Recordable) {
            Send-TimeRecord -TimeRecordEvent work_start
        }
    }

    end {
        if ($Recordable) {
            Write-Host 'began work!! 😪'
        }
        else {
            Write-Host "Cannot record. It's already begun. 😅"
        }
    }
}

function Send-FinishingWork {
    begin {
        Write-Host 'try to finish work.'
    }

    process {
        Restore-JobCanAuthentication
        Connect-JobCanCloudAttendance
        $Recordable = Test-CanRecord work_end
        if ($Recordable) {
            Send-TimeRecord -TimeRecordEvent work_end
        }
    }

    end {
        if ($Recordable) {
            Write-Host 'finished work!! 🍻'
        }
        else {
            Write-Host 'Cannot record. It was already over. 😅'
        }
    }
}

function Send-BeginningRest {
    begin {
        Write-Host 'try to begin rest.'
    }

    process {
        Restore-JobCanAuthentication
        Connect-JobCanCloudAttendance
        $Recordable = Test-CanRecord rest_start
        if ($Recordable) {
            Send-TimeRecord -TimeRecordEvent rest_start
        }
    }

    end {
        if ($Recordable) {
            Write-Host 'began rest!! 😪'
        }
        else {
            Write-Host "Cannot record. It's already begun. 😅"
        }
    }
}

function Send-FinishingRest {
    begin {
        Write-Host 'try to finish rest.'
    }

    process {
        Restore-JobCanAuthentication
        Connect-JobCanCloudAttendance
        $Recordable = Test-CanRecord rest_end
        if ($Recordable) {
            Send-TimeRecord -TimeRecordEvent rest_end
        }
    }

    end {
        if ($Recordable) {
            Write-Host 'finished rest!! 😭'
        }
        else {
            Write-Host 'Cannot record. It was already over. 😅'
        }
    }
}

function Get-JobCanAttendance {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param (
    )

    begin {
        Write-Host 'try to get attendances.'
    }

    process {
        Restore-JobCanAuthentication
        Connect-JobCanCloudAttendance
        $Records = Get-AttendanceRecord
        $Keys = $Records.Keys | Sort-Object
        $Result = @()
        foreach ($Date in $Keys) {
            $Result += [PSCustomObject]@{
                Date = $Date
                Start = $Records[$Date].Start
                End = $Records[$Date].End
            }
        }
        $Result
    }
}
