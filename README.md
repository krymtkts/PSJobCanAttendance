# PSJobCanAttendance

[![PowerShell Gallery](https://img.shields.io/powershellgallery/v/PSJobCanAttendance)](https://www.powershellgallery.com/packages/PSJobCanAttendance)
[![PowerShell Gallery](https://img.shields.io/powershellgallery/dt/PSJobCanAttendance)](https://www.powershellgallery.com/packages/PSJobCanAttendance)

PSJobCanAttendance は、ジョブカン勤怠管理を CLI で操作するための PowerShell module です。

[利用規約｜ジョブカン勤怠管理](https://jobcan.ne.jp/aup)

本ツールはスクレイピングにより各操作を実現しているので、ジョブカン勤怠管理それ自体の変更により、急に期待通りに動かなくなることがあり得ます。

PowerShell 7 と Windows PowerShell 5.1 で動作確認済みです。

(恐らく日本国内にしか少ない需要もないと思われるので日本語で書く)

## インストール

PowerShell Gallery から入手するか、 repository を clone するなどして直に手に入れることができます。
推奨は PowerShell Gallery です。

### PowerShell Gallery から入手する

[PowerShell Gallery | PSJobCanAttendance](https://www.powershellgallery.com/packages/PSJobCanAttendance/)

```powershell
# PowerShellGet 2.x
Install-Module -Name PSJobCanAttendance

# PowerShellGet 3.0
Install-PSResource -Name PSJobCanAttendance
```

### `Module` フォルダに配置する

この repository を PowerShell の `Module` フォルダ配下に clone してください。

`Module` フォルダは `$PSHOME\Modules` や `$HOME\Documents\PowerShell\Modules` 等です。

## できること

- 出勤・退勤の打刻
- 打刻修正
- 勤怠実績の一覧

## 使い方

```powershell
# はじめに接続情報を登録します
# ここで登録しなくても、ジョブカンにアクセスするコマンドを実行したときに、登録情報の入力が求められます
Set-JobCanAuthentication
# OTP を自動で取得するための設定
# op コマンド(1Password)を利用している場合の例
Set-JobCanOtpProvider -otpProvider {op item get $itemName --otp}

# 当月の勤怠実績を一覧します
Get-JobCanAttendance
# 指定した年月の勤怠実績を一覧します(日は無視されます)
# -Date option は datetime なので日付文字列からの暗黙的な変換を期待でき簡素に記述できます
Get-JobCanAttendance -Date '2022-08-01'
7,8 | % {Get-Date -Month $_} | Get-JobCanAttendance

# 出勤します
Send-JobCanBeginningWork -AditGroupId 10
# 退勤します
Send-JobCanFinishingWork -AditGroupId 10
# 出勤・退勤共に二重打刻の防止機能があります

# 時刻だけが異なる編集を一括登録できます
@(12..16;20..22) | %{Get-Date "2022-09-$($_) 08:15:00+0900"} | Edit-JobCanAttendances -TimeRecordEvent work_start -AditGroupId 10

# 時刻とイベントが異なる編集を一括登録できます
# 以下は、 3 月の休んだ日(10 日 と 20 日)と土日を除外した日の出勤と休憩時間を登録する例です
# 提供されている utility function を組み合わせると実装が容易になります
$ThisMonth = Get-Date '2024-12-01'
$Holidays = @(
    '2024-12-10'
    '2024-12-30'
) | Get-Date
# 出勤と休憩を記録します
$ThisMonth | Get-DaysInMonth -ExcludeDates $Holidays | ForEach-Object {
    $_ | New-JobCanAttendanceRecord -TimeRecordEvent work_start -Hour 8 -Minute 0
    $_ | New-JobCanAttendanceRecord -TimeRecordEvent rest_start -Hour 12 -Minute 0
    $_ | New-JobCanAttendanceRecord -TimeRecordEvent rest_end -Hour 13 -Minute 0
} | Edit-JobCanAttendance -AditGroupId 10 -Verbose

# ジョブカン勤怠管理は日本の商習慣に合わせて 30 時間制どころか 48 時まで入力できます
# PSJobCanAttendance ではそこまで長時間の入力は現実的にないと想定し、退勤と休憩で 30 時間制への変換をサポートします
# 例えば 2025-02-28 03:00 の退勤は 2025-02-27 27:00 として記録されます
'2025-02-28 03:00' | Get-Date | Edit-JobCanAttendance -AditGroupId 10 -TimeRecordEvent work_end
```

### 接続情報の初期化

入力した接続情報は `$env:LOCALAPPDATA/krymtkts/PSJobCanAttendance/credential` に保存されます。
パスワードのみ [SecureString](https://learn.microsoft.com/ja-jp/powershell/module/microsoft.powershell.security/convertto-securestring?view=powershell-7.4#1) として保存されます。
保存された接続情報を初期化するには、以下のコマンドを実行します。

```powershell
# 接続情報の初期化
Clear-JobCanAuthentication
```

## やろうとしていること

- 実績の削除
- グループが 1 つの場合に group_id の入力をなくす
