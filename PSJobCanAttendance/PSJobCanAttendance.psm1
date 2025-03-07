﻿# The location of the file that we'll store the Access Token SecureString
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
        $message = $message + "These credential is being cached into $script:JCCredentialPath. To clear caching, call Clear-JobCanAuthentication."
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

    $Date.ToString('yyyy-MM-dd(ddd) HH:mm:ss K', $script:LocaleEN)
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


function Set-JobCanOtpProvider {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [scriptblock]
        $OtpProvider
    )
    if ($PSCmdlet.ShouldProcess("set otp provider. '$OtpProvider'")) {
        $script:OtpProvider = $OtpProvider
    }
}

function Clear-JobCanOtpProvider {
    [CmdletBinding()]
    param()
    $script:OtpProvider = $null
}

function ConvertFrom-SecureStringAsPlainText {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory,
            ValueFromPipeline)]
        [SecureString]
        $SecureString
    )
    if ((Get-Command ConvertFrom-SecureString).Parameters['AsPlainText']) {
        return ConvertFrom-SecureString -SecureString $SecureString -AsPlainText
    }
    # NOTE: This is a workaround for Windows PowerShell.
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    $PlainText = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    return $PlainText
}

function Connect-JobCanCloudAttendance {
    [CmdletBinding()]
    param(
    )
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
                'user[password]' = $script:JCCredential.Password | ConvertFrom-SecureStringAsPlainText
                'app_key' = 'atd'
                'commit' = 'Login'
            }
        }
        try {
            $Res = Invoke-WebRequest @LoginParams
            $AuthToken = Find-AuthToken -Content $Res.Content -Id edit_user
            Write-Verbose $AuthToken
            $OtpRequired = [boolean]($res.Content | Where-Object { $_ -match '"user_otp_attempt"' })
        }
        catch {
            Write-Error "Failed to login $Login. $_"
            throw
        }

        if ($OtpRequired) {
            $LoginParams = @{
                Method = 'Post'
                Uri = $Login
                WebSession = $script:MySession
                Body = @{
                    'authenticity_token' = $token
                    'user[otp_attempt]' = if ($script:OtpProvider) {
                        $script:OtpProvider.Invoke()
                    }
                    else {
                        Read-Host -Prompt 'Two-Factor Authentication: '
                    }
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
        $Lines = $Content -split 'jbc-text-reset' -split 'tfoot'
        $Match = $Lines | Select-String -Pattern 'year=(?<yyyy>\d{4})&month=(?<mm>\d{1,2})&day=(?<dd>\d{1,2})".+?</a></td><td></td><td>.*?</td>(<td>(?<start>\d{2}:\d{2})?</td><td>(?<end>\d{2}:\d{2})?</td>){0,1}.*?<div data-toggle="tooltip".+?>(<a.+?><font.+?>(?<status>\w)){0,1}'
        $Result = @{}
        $Match | ForEach-Object {
            $mg = $_.Matches.Groups
            $Year , $Month , $Day , $Start , $End , $Status = @(
                'yyyy', 'mm', 'dd', 'start', 'end', 'status'
            ) | ForEach-Object {
                $mg | Where-Object -Property name -EQ $_ | Select-Object -ExpandProperty Value
            }
            $Record = [PSCustomObject]@{
                Date = Get-Date -Year $Year -Month $Month -Day $Day -Hour 0 -Minute 0 -Second 0
                Start = $Start
                End = $End
                Status = $Status
            }
            $Result.Add($Record.Date, $Record)
        }
        return $Result
    }
}

function Get-AttendanceRecord {
    [CmdletBinding()]
    param (
        [Parameter(
            Position = 0,
            ValueFromPipeline
        )]
        [ValidateNotNullOrEmpty()]
        [DateTime]
        $Date = (Get-Date)
    )

    begin {
        Write-Verbose ($script:MySession | Out-String)
        Write-Verbose ($script:JCSession | Out-String)
    }

    process {
        $Year, $Month = $Date.Year, $Date.Month.ToString('00')
        $MyPage = "https://ssl.jobcan.jp/employee/attendance?year=$Year&month=$Month"
        $Params = @{
            Method = 'Get'
            Uri = $MyPage
            WebSession = $script:MySession
        }
        Write-Verbose ($Params | Out-String)
        try {
            $Res = Invoke-WebRequest @Params
            Write-Host "Succeed to get content. $(Get-DateForDisplay)"
            if (!$Res) {
                Write-Error "Failed to get content from  $Attendances."
                return
            }
            $Records = Find-AttendanceRecord -Content $Res.Content
            return $Records
        }
        catch {
            Write-Error 'Failed to get time record.'
            throw
        }
    }
}

function Test-CanRecord {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('work_start', 'work_end', 'rest_start', 'rest_end')]
        $TimeRecordEvent
    )
    process {
        $Today = (Get-Date).Day
        $Records = Get-AttendanceRecord
        switch ($TimeRecordEvent) {
            'work_start' {
                return -not [boolean] $Records[$Today].Start
            }
            default {
                # work_end, rest_start, rest_end
                return ([boolean] $Records[$Today].Start) -and (-not [boolean] $Records[$Today].End)
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
            Write-Host "Succeed to send time record. $TimeRecordEvent $(Get-DateForDisplay)"
        }
        catch {
            Write-Error "Failed to send time record. $TimeRecorder. $TimeRecordEvent"
            throw
        }
    }
}

function ConvertTo-30HourSystemDateTime() {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory,
            ValueFromPipelineByPropertyName)]
        [ValidateSet('work_start', 'work_end', 'rest_start', 'rest_end')]
        $TimeRecordEvent,
        [Parameter(Mandatory,
            Position = 0,
            ValueFromPipeline,
            ValueFromPipelineByPropertyName
        )]
        [ValidateNotNullOrEmpty()]
        [DateTime]
        $RecordTime
    )
    process {
        # NOTE: JobCan uses a 48-hour system.
        # NOTE: However, PSJobCanAttendance converts to a 30-hour system for human-health and simplicity.
        # NOTE: Also, start times do not require conversion.
        # NOTE: Converting shifts that start before 06:00 would cause logical inconsistencies.
        if ($TimeRecordEvent -eq 'work_start') {
            [PSCustomObject]@{
                Year = $RecordTime.Year
                Month = $RecordTime.Month
                Day = $RecordTime.Day
                Time = $RecordTime.ToString('HHmm')
            }
        }
        else {
            $reqDate = $RecordTime
            $reqHour = $RecordTime.Hour
            if ($RecordTime.Hour -lt 6) {
                $reqDate = $RecordTime.AddDays(-1)
                $reqHour += 24
            }

            [PSCustomObject]@{
                Year = $reqDate.Year
                Month = $reqDate.Month
                Day = $reqDate.Day
                Time = ('{0:D2}{1:D2}' -f $reqHour, $RecordTime.Minute)
            }
        }
    }
}

function Edit-TimeRecord {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory,
            ValueFromPipelineByPropertyName)]
        [ValidateSet('work_start', 'work_end', 'rest_start', 'rest_end')]
        $TimeRecordEvent,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $AditGroupId,
        [Parameter(Mandatory,
            Position = 0,
            ValueFromPipeline,
            ValueFromPipelineByPropertyName
        )]
        [ValidateNotNullOrEmpty()]
        [DateTime]
        $RecordTime,
        [Parameter()]
        [string]
        $Notice = ''
    )

    begin {
        Write-Verbose ($script:MySession | Out-String)
        Write-Verbose ($script:JCSession | Out-String)

        $ModifyPage = 'https://ssl.jobcan.jp/employee/adit/modify/'
        $NewSessionParams = @{
            Method = 'Get'
            Uri = $ModifyPage
            WebSession = $script:MySession
        }
        Write-Verbose ($NewSessionParams | Out-String)
        try {
            $Res = Invoke-WebRequest @NewSessionParams
            $Match = $res.Content -split "`n" | Select-String -Pattern "name=`"token`".+value=`"(?<token>\S+)`">"
            $Token = $Match[0].Matches.Groups[1].Value
            $Match = $res.Content -split "`n" | Select-String -Pattern "client_id`".+?value=`"(?<client_id>\S+)`""
            $ClientId = $Match[0].Matches.Groups[1].Value
            $Match = $res.Content -split "`n" | Select-String -Pattern "employee_id`".+?value=`"(?<employee_id>\S+)`""
            $EmployeeId = $Match[0].Matches.Groups[1].Value
            Write-Verbose $Token
            Write-Verbose $ClientId
            Write-Verbose $EmployeeId
        }
        catch {
            Write-Error "Failed to connect $ModifyPage. $_"
            throw
        }
    }

    process {
        $TimeRecorder = 'https://ssl.jobcan.jp/employee/adit/insert'
        $recTime = ConvertTo-30HourSystemDateTime -TimeRecordEvent $TimeRecordEvent -RecordTime $RecordTime
        $Body = @{
            'token' = $Token
            'year' = $recTime.Year
            'month' = $recTime.Month
            'day' = $recTime.Day
            'client_id' = $ClientId
            'employee_id' = $EmployeeId
            'adit_item' = $TimeRecordEvent
            'delete_minutes' = ''
            'time' = $recTime.Time
            'group_id' = $AditGroupId
            'notice' = $Notice
            '_' = '' # ?
        }
        $RecordParams = @{
            Method = 'Post'
            Uri = $TimeRecorder
            WebSession = $MySession
            Body = $Body
        }
        Write-Verbose ($RecordParams | Out-String)
        Write-Verbose ($Body | Out-String)
        try {
            $Res = Invoke-WebRequest @RecordParams
            Write-Host "Succeed to send time record. $TimeRecordEvent $($recTime.Year)-$($recTime.Month)-$($recTime.Day) $($recTime.Time)"
        }
        catch {
            Write-Error "Failed to send time record. $TimeRecorder. $TimeRecordEvent"
            throw
        }
    }
}

function Send-JobCanBeginningWork {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $AditGroupId
    )
    begin {
        Write-Host 'try to begin work.'
    }

    process {
        Restore-JobCanAuthentication
        Connect-JobCanCloudAttendance
        $Recordable = Test-CanRecord work_start
        if ($Recordable) {
            Send-TimeRecord -TimeRecordEvent work_start -AditGroupId $AditGroupId
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

function Send-JobCanFinishingWork {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $AditGroupId
    )
    begin {
        Write-Host 'try to finish work.'
    }

    process {
        Restore-JobCanAuthentication
        Connect-JobCanCloudAttendance
        $Recordable = Test-CanRecord work_end
        if ($Recordable) {
            Send-TimeRecord -TimeRecordEvent work_end -AditGroupId $AditGroupId
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

function Send-JobCanBeginningRest {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $AditGroupId
    )
    begin {
        Write-Host 'try to begin rest.'
    }

    process {
        Restore-JobCanAuthentication
        Connect-JobCanCloudAttendance
        $Recordable = Test-CanRecord rest_start
        if ($Recordable) {
            Send-TimeRecord -TimeRecordEvent rest_start -AditGroupId $AditGroupId
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

function Send-JobCanFinishingRest {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $AditGroupId
    )
    begin {
        Write-Host 'try to finish rest.'
    }

    process {
        Restore-JobCanAuthentication
        Connect-JobCanCloudAttendance
        $Recordable = Test-CanRecord rest_end
        if ($Recordable) {
            Send-TimeRecord -TimeRecordEvent rest_end -AditGroupId $AditGroupId
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

function Edit-JobCanAttendance {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory,
            ValueFromPipelineByPropertyName)]
        [ValidateSet('work_start', 'work_end', 'rest_start', 'rest_end')]
        $TimeRecordEvent,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $AditGroupId,
        [Parameter(Mandatory,
            Position = 0,
            ValueFromPipeline,
            ValueFromPipelineByPropertyName
        )]
        [ValidateNotNullOrEmpty()]
        [DateTime[]]
        $RecordTime,
        [Parameter()]
        [string]
        $Notice = ''
    )
    begin {
        Write-Host 'start editing.'
        Restore-JobCanAuthentication
        Connect-JobCanCloudAttendance
        $Params = @{
            AditGroupId = $AditGroupId
            Notice = $Notice
        }
    }

    process {
        $RecordTime | ForEach-Object { [PSCustomObject]@{
                TimeRecordEvent = $TimeRecordEvent
                RecordTime = $_
            }
        } | Edit-TimeRecord @Params
        $Completed = $true
    }

    end {
        if ($Completed) {
            Write-Host 'editing completed!! 👍'
        }
    }
}

function Get-JobCanAttendance {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param (
        [Parameter(
            Position = 0,
            ValueFromPipeline
        )]
        [DateTime]
        $Date
    )

    begin {
        Write-Host 'try to get attendances.'
        Restore-JobCanAuthentication
        Connect-JobCanCloudAttendance
        if (-not $Date) {
            $Date = Get-Date
        }
    }

    process {
        $Records = Get-AttendanceRecord -Date $Date
        $Result = @()
        $Records.Keys | Sort-Object | ForEach-Object {
            $Result += [PSCustomObject]@{
                Date = $_.ToString('yyyy-MM-dd')
                Start = $Records[$_].Start
                End = $Records[$_].End
                Status = $Records[$_].Status
            }
        } -End { $Result }
    }
}

# NOTE: Utility functions.

function Get-DaysInMonth {
    [CmdletBinding()]
    param(
        [Parameter(
            Position = 0,
            ValueFromPipeline
        )]
        [ValidateNotNull()]
        [datetime]
        $Date = (Get-Date),
        [Parameter()]
        [ValidateNotNull()]
        [datetime[]]$ExcludeDates = @(),
        [Parameter()]
        [ValidateNotNull()]
        [int[]]$ExcludeWeekDays = @(0, 6),
        [Parameter()]
        [ValidateNotNull()]
        [System.Globalization.Calendar]$Calendar = [System.Globalization.CultureInfo]::InvariantCulture.Calendar
    )
    process {
        $daysInMonth = $Calendar.GetDaysInMonth($Date.Year, $Date.Month)
        1..$daysInMonth | ForEach-Object {
            [datetime]::new($Date.Year, $Date.Month, $_)
        } | Where-Object {
            ($_.Date -NotIn $ExcludeDates) -and ($_.DayOfWeek -NotIn $ExcludeWeekDays)
        }
    }
}

#pragma warning disable PSUseShouldProcessForStateChangingFunctions
function New-JobCanAttendanceRecord {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'No state changing operation.')]
    param (
        [Parameter(Mandatory,
            ValueFromPipelineByPropertyName)]
        [ValidateSet('work_start', 'work_end', 'rest_start', 'rest_end')]
        [string]
        $TimeRecordEvent,
        [Parameter(Mandatory,
            Position = 0,
            ValueFromPipeline,
            ValueFromPipelineByPropertyName
        )]
        [ValidateNotNull()]
        [datetime]
        $Date,
        [Parameter(
            ValueFromPipelineByPropertyName
        )]
        [ValidateNotNull()]
        [int]
        $Hour,
        [Parameter(
            ValueFromPipelineByPropertyName
        )]
        [ValidateNotNull()]
        [int]
        $Minute
    )
    process {
        # NOTE: use redundant syntax to support Windows PowerShell.
        $h = if ($Hour -ne $null) { $Hour } else { $Date.Hour }
        $m = if ($Minute -ne $null) { $Minute } else { $Date.Minute }
        [PSCustomObject]@{
            TimeRecordEvent = $TimeRecordEvent
            RecordTime = Get-Date -Date $Date -Hour $h -Minute $m -Second 0
        }
    }
}
#pragma warning restore PSUseShouldProcessForStateChangingFunctions