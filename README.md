# PSJobCanAttendance

[![PowerShell Gallery](https://img.shields.io/powershellgallery/dt/PSJobCanAttendance?style=flat-square)](https://www.powershellgallery.com/packages/PSJobCanAttendance)

PSJobCanAttendance は、ジョブカン勤怠管理を CLI で操作するためのツールです。

[利用規約｜ジョブカン勤怠管理](https://jobcan.ne.jp/aup)

本ツールはスクレイピングにより各操作を実現しているので、ジョブカン勤怠管理それ自体の変更により、急に期待通りに動かなくなることがあり得ます。

PowerShell v7 でのみ動作確認済みです。

(恐らく日本国内にしか少ない需要もないと思われるので日本語で書く)

## インストール

### `Module` フォルダに配置する

この repository を PowerShell の `Module` フォルダ配下に clone してください。

`Module` フォルダは `$PSHOME\Modules` や `$HOME\Documents\PowerShell\Modules` 等です。

## できること

- 出勤・退勤の打刻
- 打刻修正

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
# 出勤します
Send-JobCanBeginningWork -AditGroupId 10
# 退勤します
Send-JobCanFinishingWork -AditGroupId 10
# 出勤・退勤共に二重打刻の防止機能があります

# 時刻以外が同一の編集であれば一括編集できます
@(12..16;20..22) | %{get-date "2022-09-$($_) 08:15:00+0900"} | Edit-JobCanAttendances -TimeRecordEvent work_start -AditGroupId 10
```

### 接続情報の初期化

入力した接続情報は `$env:APPDATA/krymtkts/PSJobCanAttendance/credential` に保存されます。
パスワードのみ Secure String として保存されます。
保存された接続情報を初期化するには、以下のコマンドを実行します。

```powershell
# 接続情報の初期化
Clear-JobCanAuthentication
```

## やろうとしていること

- 実績の削除
- グループが 1 つの場合に group_id の入力をなくす
- 当月以外の勤怠実績の一覧
