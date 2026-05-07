#Requires -Version 5.1
<#
.SYNOPSIS
    NetSwitch Pro v1.2.0 - Gestionnaire de profils reseau IP
.AUTHOR
    Nothinx-44  |  https://github.com/Nothinx-44/NetSwitch-Pro
.CHANGELOG
 
#>

# ==============================================================
#  AUTO-ELEVATION UAC
# ==============================================================
# Auto-elevation geree par le manifest PS2EXE (-RequireAdmin)
# Verification de securite uniquement (ne devrait jamais etre faux)
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    [System.Windows.Forms.MessageBox]::Show(
        "NetSwitch Pro necessite des droits administrateur.`nRelancez en tant qu'administrateur.",
        'NetSwitch Pro', 'OK', 'Warning') | Out-Null
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# -- Filet de securite global : capture toute erreur de demarrage ---------
$Script:ErrorLog = Join-Path $env:APPDATA 'NetSwitchPro\startup_error.log'
trap {
    $msg = "ERREUR DEMARRAGE NetSwitch Pro v$(if($Script:Ver){$Script:Ver}else{'?'})`n" +
           "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n`n" +
           "$($_.Exception.GetType().Name): $($_.Exception.Message)`n`n" +
           "Ligne: $($_.InvocationInfo.ScriptLineNumber)`n" +
           "$($_.InvocationInfo.Line.Trim())"
    try {
        $dir = Split-Path $Script:ErrorLog -Parent
        if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
        $msg | Out-File $Script:ErrorLog -Encoding UTF8 -Append
        [System.Windows.Forms.MessageBox]::Show(
            $msg, 'NetSwitch Pro - Erreur de demarrage', 'OK', 'Error') | Out-Null
    } catch {
        Write-Host $msg -ForegroundColor Red
        Write-Host "Log: $Script:ErrorLog" -ForegroundColor Yellow
        Read-Host "Appuyez sur Entree pour fermer"
    }
    break
}

# ==============================================================
#  CONSTANTES
# ==============================================================
$Script:Ver           = '1.2.0'
$Script:GHOwner       = 'Nothinx-44'
$Script:GHRepo        = 'NetSwitch-Pro'
$Script:DataDir       = Join-Path $env:APPDATA 'NetSwitchPro'
$Script:DataFile      = Join-Path $Script:DataDir 'clients.json'
$Script:HistoryFile   = Join-Path $Script:DataDir 'history.json'
$Script:CurrentID     = $null
$Script:EditMode      = 'new'
$Script:Refreshing    = $false
$Script:ReallyClosing = $false   # tray : fermeture reelle vs minimisation
$Script:TrayIcon      = $null
$Script:MainWindow    = $null     # reference globale a la fenetre WPF pour les closures tray
# Update - en $Script: pour eviter le GC des closures timer
$Script:UpdateUrl     = $null
$Script:UpdateZipUrl  = $null
$Script:UpdateVer     = $null
$Script:UpdateTimer   = $null
$Script:UpdatePS      = $null
$Script:UpdateRS      = $null
$Script:UpdateHandle  = $null
$Script:DlTimer       = $null
$Script:DlPS          = $null
$Script:DlRS          = $null
$Script:DlHandle      = $null
$Script:GroupsFile       = Join-Path $Script:DataDir 'groups.json'
$Script:Groups           = [System.Collections.Generic.List[string]]::new()
$Script:CollapsedGroups  = [System.Collections.Generic.HashSet[string]]::new()
$Script:SelectedClientID = $null
$Script:LastConfig       = $null   # sauvegarde avant apply pour rollback

# Migration des donnees depuis l'ancien dossier (premiere execution apres renommage)
$Script:OldDataDir = Join-Path $env:APPDATA 'IPSwitch'
if ((Test-Path $Script:OldDataDir) -and -not (Test-Path $Script:DataDir)) {
    try { Copy-Item -Path $Script:OldDataDir -Destination $Script:DataDir -Recurse -Force } catch { }
}
if (-not (Test-Path $Script:DataDir)) {
    New-Item -ItemType Directory -Path $Script:DataDir -Force | Out-Null
}

# ==============================================================
#  PALETTE AVATARS
# ==============================================================
$Script:Palette = @(
    '#00FF41','#39FF14','#00C32E','#00FF85',
    '#7FFF00','#00FA9A','#32CD32','#ADFF2F','#00E676','#76FF03'
)

# ==============================================================
#  HELPERS GENERAUX
# ==============================================================
function Get-AvatarColor([string]$n) {
    if (-not $n) { return '#888888' }
    $Script:Palette[[Math]::Abs($n.GetHashCode()) % $Script:Palette.Count]
}

function New-Brush([string]$hex) {
    $col = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
    [System.Windows.Media.SolidColorBrush]::new($col)
}

function New-Client {
    param([string]$ID,[string]$Name,[string]$NIC,[bool]$DHCP,
          [string]$IP,[string]$Mask,[string]$Gateway,
          [string]$DNS1,[string]$DNS2,[string]$Notes,[string]$Group)
    $col  = Get-AvatarColor $Name
    $init = if ($Name -and $Name.Length) { $Name.Substring(0,1).ToUpper() } else { '?' }
    $sum  = if ($IP) { $IP } else { '--' }
    [PSCustomObject]@{
        ID=if($ID){$ID}else{[Guid]::NewGuid().ToString()}
        Name=$Name; NIC=$NIC; DHCP=$DHCP
        IP=$IP; Mask=$Mask; Gateway=$Gateway
        DNS1=$DNS1; DNS2=$DNS2; Notes=$Notes
        Group=$Group
        AvatarColor=$col; Initial=$init; IPSummary=$sum
    }
}

# Validation IP : octets 0-255
function Test-IPFormat([string]$ip) {
    if ($ip -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { return $false }
    foreach ($o in $ip.Split('.')) { if ([int]$o -gt 255) { return $false } }
    return $true
}

# Conversion masque pointille -> longueur prefixe CIDR
function Convert-MaskToPrefix([string]$mask) {
    try {
        $bin = ($mask.Split('.') | ForEach-Object { [Convert]::ToString([int]$_, 2).PadLeft(8,'0') }) -join ''
        return ($bin.ToCharArray() | Where-Object { $_ -eq '1' }).Count
    } catch { return 24 }
}

# Conversion longueur prefixe CIDR -> masque pointille
function Convert-PrefixToMask([int]$prefix) {
    if ($prefix -lt 0 -or $prefix -gt 32) { return '255.255.255.0' }
    $octets = @(0, 0, 0, 0)
    $full   = [Math]::Floor($prefix / 8)
    $rem    = $prefix % 8
    for ($i = 0; $i -lt $full; $i++) { $octets[$i] = 255 }
    if ($full -lt 4 -and $rem -gt 0) { $octets[$full] = 256 - [Math]::Pow(2, 8 - $rem) }
    $octets -join '.'
}

# ==============================================================
#  PERSISTANCE JSON - CLIENTS
# ==============================================================
function Import-Clients {
    $list = [System.Collections.Generic.List[PSCustomObject]]::new()
    if (Test-Path $Script:DataFile) {
        try {
            (Get-Content $Script:DataFile -Raw | ConvertFrom-Json) | ForEach-Object {
                $d1 = if ($_.DNS1) { $_.DNS1 } else { '' }
                $d2 = if ($_.DNS2) { $_.DNS2 } else { '' }
                $grp = if ($_.Group) { $_.Group } else { 'General' }
                $list.Add((New-Client $_.ID $_.Name $_.NIC ([bool]$_.DHCP) `
                           $_.IP $_.Mask $_.Gateway $d1 $d2 $_.Notes $grp))
            }
        } catch { }
    }
    $list
}

# ConvertTo-Json -InputObject garantit un tableau JSON meme avec 1 element
function Export-Clients([object]$clients) {
    $data = @($clients | Select-Object ID,Name,NIC,DHCP,IP,Mask,Gateway,DNS1,DNS2,Notes,Group)
    $tmp = "$Script:DataFile.tmp"
    ConvertTo-Json -InputObject $data -Depth 4 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $Script:DataFile -Force
}

function Import-Groups {
    $Script:Groups = [System.Collections.Generic.List[string]]::new()
    # Lire groups.json : iteration directe sur le resultat de ConvertFrom-Json (pas de @() = pas de double-enveloppement)
    if (Test-Path $Script:GroupsFile) {
        try {
            $parsed = Get-Content $Script:GroupsFile -Raw | ConvertFrom-Json
            # $parsed est Object[] (2+ items) ou String (1 item seul)
            $list = if ($parsed -is [array]) { $parsed } else { @($parsed) }
            foreach ($s in $list) {
                $str = [string]$s
                if ($str -and $str.Trim() -and $str.Length -le 80 -and -not $Script:Groups.Contains($str)) {
                    $Script:Groups.Add($str)
                }
            }
        } catch { }
    }
    if ($Script:Groups.Count -eq 0) { $Script:Groups.Add('General') }
    # NOTE: les clients dont le Group n'existe pas sont reassignes au 1er groupe dans la section init
}

function Export-Groups {
    $tmp = "$Script:GroupsFile.tmp"
    # .ToArray() garanti : @() peut envelopper List comme element unique
    ConvertTo-Json -InputObject $Script:Groups.ToArray() | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $Script:GroupsFile -Force
}

function Show-InputDialog([string]$prompt, [string]$title, [string]$default = '') {
    [xml]$dlgXml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Height="150" Width="370" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner"
        Background="#0D0D0D" FontFamily="Consolas">
    <StackPanel Margin="18,14,18,14">
        <TextBlock x:Name="Prompt" Foreground="#C8FFC8" Margin="0,0,0,8" FontSize="13"/>
        <TextBox x:Name="InputBox" Background="#050F05" Foreground="#C8FFC8"
                 BorderBrush="#2A5A2A" BorderThickness="1" Padding="7,5"
                 FontFamily="Consolas" FontSize="13" CaretBrush="#00FF41"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
            <Button x:Name="BtnOk" Content="OK" Width="72" Margin="0,0,8,0"
                    Background="#00FF41" Foreground="#000000" FontWeight="SemiBold"
                    BorderThickness="0" Padding="0,6" Cursor="Hand"/>
            <Button x:Name="BtnCancel" Content="Annuler" Width="72"
                    Background="#0A150A" Foreground="#00FF41"
                    BorderBrush="#2A5A2A" BorderThickness="1" Padding="0,6" Cursor="Hand"/>
        </StackPanel>
    </StackPanel>
</Window>
'@
    $reader = [System.Xml.XmlNodeReader]::new($dlgXml)
    $dlg = [System.Windows.Markup.XamlReader]::Load($reader)
    $dlg.Title = $title
    $dlg.Owner = $Script:MainWindow
    $dlg.FindName('Prompt').Text = $prompt
    $inputBox = $dlg.FindName('InputBox')
    $inputBox.Text = $default
    $dlg.FindName('BtnOk').Add_Click({ $dlg.DialogResult = $true; $dlg.Close() })
    $dlg.FindName('BtnCancel').Add_Click({ $dlg.DialogResult = $false; $dlg.Close() })
    $dlg.Add_ContentRendered({ $inputBox.SelectAll(); $inputBox.Focus() })
    $dlg.Add_KeyDown({ param($s,$e); if ($e.Key -eq 'Return') { $dlg.DialogResult=$true; $dlg.Close() } elseif ($e.Key -eq 'Escape') { $dlg.DialogResult=$false; $dlg.Close() } })
    if ($dlg.ShowDialog()) { return $inputBox.Text.Trim() }
    return $null
}

function Refresh-GroupCombo {
    $cur = $Script:CmbGroup.SelectedItem
    $Script:CmbGroup.Items.Clear()
    foreach ($g in $Script:Groups) { [void]$Script:CmbGroup.Items.Add($g) }
    if ($cur -and $Script:CmbGroup.Items.Contains($cur)) { $Script:CmbGroup.SelectedItem = $cur }
    elseif ($Script:CmbGroup.Items.Count -gt 0) { $Script:CmbGroup.SelectedIndex = 0 }
}

# ==============================================================
#  PERSISTANCE JSON - HISTORIQUE
# ==============================================================
function Load-History {
    if (Test-Path $Script:HistoryFile) {
        try { return @(Get-Content $Script:HistoryFile -Raw | ConvertFrom-Json) }
        catch { }
    }
    return @()
}

function Add-HistoryEntry([PSCustomObject]$client) {
    $entry = [PSCustomObject]@{
        Timestamp  = (Get-Date).ToString('o')    # ISO 8601
        ClientName = $client.Name
        NIC        = $client.NIC
        Mode       = if ($client.DHCP) { 'DHCP' } else { 'Statique' }
        IP         = if ($client.DHCP) { 'DHCP' } else { $client.IP }
    }
    $history = [System.Collections.Generic.List[PSCustomObject]]::new()
    $history.Add($entry)
    Load-History | Select-Object -First 19 | ForEach-Object { $history.Add($_) }
    $tmp = "$Script:HistoryFile.tmp"
    ConvertTo-Json -InputObject @($history) -Depth 3 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $Script:HistoryFile -Force
}

# ==============================================================
#  RESEAU
# ==============================================================
function Get-NICList {
    @(Get-NetAdapter | Sort-Object Name | Select-Object -ExpandProperty Name)
}

# Lecture config IP complete d'une NIC (texte pour affichage)
function Get-NICCurrentInfo([string]$nicName) {
    try {
        $addr = Get-NetIPAddress -InterfaceAlias $nicName -AddressFamily IPv4 `
                -ErrorAction Stop | Select-Object -First 1
        $gw   = Get-NetRoute -InterfaceAlias $nicName -DestinationPrefix '0.0.0.0/0' `
                -ErrorAction Stop | Select-Object -First 1
        $dns  = (Get-DnsClientServerAddress -InterfaceAlias $nicName `
                -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses
        $txt  = "IP : $($addr.IPAddress)/$($addr.PrefixLength)"
        if ($gw)  { $txt += '   GW : ' + $gw.NextHop }
        if ($dns) { $txt += '   DNS : ' + ($dns -join ', ') }
        return @{ Text=$txt; OK=$true }
    } catch { return @{ Text='Carte deconnectee ou introuvable'; OK=$false } }
}

# Lecture config IP complete d'une NIC (structure pour import formulaire)
function Get-NICFullConfig([string]$nicName) {
    try {
        $addr = Get-NetIPAddress -InterfaceAlias $nicName -AddressFamily IPv4 `
                -ErrorAction SilentlyContinue | Select-Object -First 1
        $gw   = Get-NetRoute -InterfaceAlias $nicName -DestinationPrefix '0.0.0.0/0' `
                -ErrorAction SilentlyContinue | Select-Object -First 1
        $dns  = (Get-DnsClientServerAddress -InterfaceAlias $nicName `
                -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
        return @{
            IP      = if ($addr) { $addr.IPAddress } else { '' }
            Mask    = if ($addr) { Convert-PrefixToMask $addr.PrefixLength } else { '' }
            Gateway = if ($gw)  { $gw.NextHop } else { '' }
            DNS1    = if ($dns -and $dns.Count -gt 0) { $dns[0] } else { '' }
            DNS2    = if ($dns -and $dns.Count -gt 1) { $dns[1] } else { '' }
        }
    } catch { return $null }
}

# Application d'un profil IP via netsh
function Save-ConfigBackup([string]$nicName) {
    $cfg = Get-NICFullConfig $nicName
    if ($cfg) {
        $Script:LastConfig = [PSCustomObject]@{ NIC=$nicName; IP=$cfg.IP; Mask=$cfg.Mask; Gateway=$cfg.Gateway; DNS1=$cfg.DNS1; DNS2=$cfg.DNS2 }
    }
}

function Invoke-Rollback {
    if (-not $Script:LastConfig) { return }
    $r = $Script:LastConfig
    $ok = $false
    if ($r.IP) {
        $fake = New-Client '' 'rollback' $r.NIC $false $r.IP $r.Mask $r.Gateway $r.DNS1 $r.DNS2 '' 'General'
        $ok = Invoke-ApplyProfile $fake
    } else {
        try { Set-NetIPInterface -InterfaceAlias $r.NIC -Dhcp Enabled -ErrorAction Stop
              Set-DnsClientServerAddress -InterfaceAlias $r.NIC -ResetServerAddresses -ErrorAction Stop
              $ok = $true } catch { $ok = $false }
    }
    if ($ok) {
        $Script:LastConfig = $null
        $Script:RollbackLabel.Visibility = 'Collapsed'
        Set-Status "Config restauree sur $($r.NIC)." '#00FF41'
        Update-NicInfoBar ($Script:CmbNIC.SelectedItem)
    } else {
        Set-Status "Echec rollback sur $($r.NIC)." '#FF3333'
    }
}

function Invoke-ApplyProfile([PSCustomObject]$c) {
    try {
        $n = $c.NIC
        $prefix = Convert-MaskToPrefix $c.Mask
        # Nettoyer l'ancienne config avant d'appliquer
        Remove-NetIPAddress -InterfaceAlias $n -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
        Remove-NetRoute     -InterfaceAlias $n -DestinationPrefix '0.0.0.0/0' -Confirm:$false -ErrorAction SilentlyContinue
        Set-NetIPInterface  -InterfaceAlias $n -Dhcp Disabled -ErrorAction Stop
        New-NetIPAddress    -InterfaceAlias $n -IPAddress $c.IP -PrefixLength $prefix `
                            -DefaultGateway $c.Gateway -ErrorAction Stop | Out-Null
        if ($c.DNS1) {
            $dns = @($c.DNS1); if ($c.DNS2) { $dns += $c.DNS2 }
            Set-DnsClientServerAddress -InterfaceAlias $n -ServerAddresses $dns -ErrorAction Stop
        } else {
            Set-DnsClientServerAddress -InterfaceAlias $n -ResetServerAddresses -ErrorAction Stop
        }
        return $true
    } catch { return $false }
}

# ==============================================================
#  EXPORT / IMPORT FICHIER CLIENTS
# ==============================================================
function Export-ClientsFile {
    $dlg            = [System.Windows.Forms.SaveFileDialog]::new()
    $dlg.Title      = 'Exporter les profils clients'
    $dlg.Filter     = 'Fichier JSON (*.json)|*.json|Tous les fichiers (*.*)|*.*'
    $dlg.FileName   = "NetSwitchPro_clients_$(Get-Date -Format 'yyyyMMdd').json"
    if ($dlg.ShowDialog() -eq 'OK') {
        try {
            Copy-Item $Script:DataFile $dlg.FileName -Force
            Set-Status "Profils exportes : $($dlg.FileName)" '#107C10'
        } catch {
            Set-Status "Erreur export : $_" '#C50F1F'
        }
    }
}

function Import-ClientsFile {
    $dlg        = [System.Windows.Forms.OpenFileDialog]::new()
    $dlg.Title  = 'Importer des profils clients'
    $dlg.Filter = 'Fichier JSON (*.json)|*.json|Tous les fichiers (*.*)|*.*'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    try {
        $imported = @(Get-Content $dlg.FileName -Raw | ConvertFrom-Json)
        $added = 0; $skipped = 0
        foreach ($c in $imported) {
            if ($Script:Clients | Where-Object { $_.ID -eq $c.ID }) { $skipped++; continue }
            $d1  = if ($c.DNS1)  { $c.DNS1  } else { '' }
            $d2  = if ($c.DNS2)  { $c.DNS2  } else { '' }
            $grp = if ($c.Group) { $c.Group } else { $Script:Groups[0] }
            $Script:Clients.Add((New-Client $c.ID $c.Name $c.NIC ([bool]$c.DHCP) `
                                 $c.IP $c.Mask $c.Gateway $d1 $d2 $c.Notes $grp))
            $added++
        }
        Export-Clients $Script:Clients
        Refresh-List
        $msg = "$added client(s) importe(s)"
        if ($skipped -gt 0) { $msg += ", $skipped ignore(s) (ID deja existant)" }
        Set-Status $msg '#107C10'
    } catch {
        Set-Status "Erreur import : $_" '#C50F1F'
    }
}

# ==============================================================
#  AUTO-UPDATE - Verification (GitHub Releases)
# ==============================================================
function Start-UpdateCheck {
    $Script:UpdateRS = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $Script:UpdateRS.Open()
    $Script:UpdateRS.SessionStateProxy.SetVariable('o', $Script:GHOwner)
    $Script:UpdateRS.SessionStateProxy.SetVariable('r', $Script:GHRepo)
    $Script:UpdateRS.SessionStateProxy.SetVariable('v', $Script:Ver)

    $Script:UpdatePS = [PowerShell]::Create()
    $Script:UpdatePS.Runspace = $Script:UpdateRS
    [void]$Script:UpdatePS.AddScript({
        try {
            $rel = Invoke-RestMethod `
                -Uri "https://api.github.com/repos/$o/$r/releases/latest" `
                -Headers @{ 'User-Agent' = "NetSwitchPro/$v" } `
                -UseBasicParsing -TimeoutSec 8
            $lv = $rel.tag_name -replace '^v', ''
            if ([version]$lv -gt [version]$v) {
                # Extraction de l'URL comme string pure avant de franchir la frontiere runspace
                $zipUrl = ($rel.assets |
                    Where-Object { $_.name -like '*.zip' } |
                    Select-Object -First 1 -ExpandProperty browser_download_url)
                return @{ OK=$true; Ver=[string]$lv; PageUrl=[string]$rel.html_url; ZipUrl=[string]$zipUrl }
            }
        } catch { }
        return @{ OK=$false }
    })
    $Script:UpdateHandle = $Script:UpdatePS.BeginInvoke()

    $Script:UpdateTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $Script:UpdateTimer.Interval = [TimeSpan]::FromMilliseconds(400)
    $Script:UpdateTimer.Add_Tick({
        if (-not $Script:UpdateHandle.IsCompleted) { return }
        $Script:UpdateTimer.Stop()
        try {
            $res = $Script:UpdatePS.EndInvoke($Script:UpdateHandle)[0]
            if ($res -and $res.OK) {
                $Script:UpdateVer    = $res.Ver
                $Script:UpdateUrl    = $res.PageUrl
                $Script:UpdateZipUrl = $res.ZipUrl
                $Script:UpdateLabel.Text       = "  v$($Script:UpdateVer) disponible"
                $Script:UpdateLabel.Visibility = 'Visible'
            }
        } catch { } finally {
            try { $Script:UpdatePS.Dispose() } catch { }
            try { $Script:UpdateRS.Dispose() } catch { }
        }
    })
    $Script:UpdateTimer.Start()
}

# ==============================================================
#  AUTO-UPDATE - Installation (telechargement non-bloquant)
# ==============================================================
function Install-Update {
    if (-not $Script:UpdateZipUrl) {
        [System.Windows.MessageBox]::Show(
            "Aucun fichier ZIP dans la release GitHub.`nRendez-vous sur la page de release.",
            'NetSwitch Pro', 'OK', 'Warning')
        return
    }
    $Script:UpdateLabel.IsEnabled = $false
    Set-Status 'Telechargement en cours...' '#0078D4'

    $dlDest = "$env:TEMP\NetSwitchPro_update.zip"
    $Script:DlRS = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $Script:DlRS.Open()
    $Script:DlRS.SessionStateProxy.SetVariable('url',  $Script:UpdateZipUrl)
    $Script:DlRS.SessionStateProxy.SetVariable('dest', $dlDest)

    $Script:DlPS = [PowerShell]::Create()
    $Script:DlPS.Runspace = $Script:DlRS
    [void]$Script:DlPS.AddScript({
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
    })
    $Script:DlHandle = $Script:DlPS.BeginInvoke()

    $Script:DlTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $Script:DlTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $Script:DlTimer.Add_Tick({
        if (-not $Script:DlHandle.IsCompleted) { return }
        $Script:DlTimer.Stop()
        $dlOk = $true
        try   { $Script:DlPS.EndInvoke($Script:DlHandle) | Out-Null }
        catch { $dlOk = $false; Set-Status "Erreur telechargement : $_" '#C50F1F' }
        finally {
            try { $Script:DlPS.Dispose() } catch { }
            try { $Script:DlRS.Dispose() } catch { }
        }
        if (-not $dlOk) { $Script:UpdateLabel.IsEnabled = $true; return }
        try {
            $tmpDir  = "$env:TEMP\NetSwitchPro_update"
            if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
            Expand-Archive $dlDest $tmpDir -Force
            # MyCommand.Path = chemin exe compile ou ps1 selon le contexte
            $selfPath = $MyInvocation.MyCommand.Path
            $here     = Split-Path $selfPath -Parent
            $isExe    = $selfPath -match '\.exe$'
            $restart  = if ($isExe) { "`"$selfPath`"" } `
                        else { "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$selfPath`"" }
            $oemEnc = [System.Text.Encoding]::GetEncoding(
                [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
            $bat = "@echo off`r`n" +
                   "timeout /t 2 /nobreak >nul`r`n" +
                   "robocopy `"$tmpDir`" `"$here`" /E /IS /IT /IM /COPYALL >nul`r`n" +
                   "start `"`" $restart`r`n" +
                   "rd /s /q `"$tmpDir`" >nul 2>&1`r`n" +
                   "del `"%~f0`""
            [System.IO.File]::WriteAllText("$env:TEMP\NetSwitchPro_upd.bat", $bat, $oemEnc)
            Start-Process cmd.exe -ArgumentList "/c `"$env:TEMP\NetSwitchPro_upd.bat`"" -WindowStyle Hidden
            $Script:ReallyClosing = $true
            [System.Windows.Application]::Current.Shutdown()
        } catch {
            Set-Status "Erreur installation : $_" '#C50F1F'
            $Script:UpdateLabel.IsEnabled = $true
        }
    })
    $Script:DlTimer.Start()
}

# ==============================================================
#  ICONE SYSTRAY
# ==============================================================
function New-AppIcon {
    $bmp = [System.Drawing.Bitmap]::new(32, 32)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $blue = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(0, 120, 212))
    $g.FillEllipse($blue, 1, 1, 30, 30)
    $font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $sf   = [System.Drawing.StringFormat]::new()
    $sf.Alignment     = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $g.DrawString('IP', $font, [System.Drawing.Brushes]::White,
        [System.Drawing.RectangleF]::new(0, 0, 32, 32), $sf)
    $g.Dispose(); $font.Dispose(); $blue.Dispose(); $sf.Dispose()
    $hicon = $bmp.GetHicon()
    $bmp.Dispose()
    [System.Drawing.Icon]::FromHandle($hicon)
}

function Initialize-TrayIcon {
    $Script:TrayIcon              = [System.Windows.Forms.NotifyIcon]::new()
    $Script:TrayIcon.Icon         = New-AppIcon
    $Script:TrayIcon.Text         = "$($Script:Ver)"
    $Script:TrayIcon.Visible      = $true

    # Double-clic sur l'icone : afficher la fenetre
    $Script:TrayIcon.Add_DoubleClick({
        $Script:MainWindow.Show()
        $Script:MainWindow.WindowState = 'Normal'
        $Script:MainWindow.Activate()
    })

    Update-TrayMenu
}

function Update-TrayMenu {
    $menu = [System.Windows.Forms.ContextMenuStrip]::new()

    # En-tete (non cliquable)
    $header          = $menu.Items.Add("$($Script:Ver)")
    $header.Enabled  = $false
    $header.Font     = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())

    # Clients (tri alphabetique)
    $sorted = @($Script:Clients | Sort-Object Name)
    if ($sorted.Count -eq 0) {
        $none         = $menu.Items.Add('Aucun client configure')
        $none.Enabled = $false
    } else {
        foreach ($c in $sorted) {
            $label   = if ($c.DHCP) { "$($c.Name)  [DHCP]" } else { "$($c.Name)  [$($c.IP)]" }
            $item    = $menu.Items.Add($label)
            $capturedClient = $c   # capture explicite pour la closure
            $item.Add_Click({
                Save-ConfigBackup $capturedClient.NIC
                $ok = Invoke-ApplyProfile $capturedClient
                $tipText = if ($ok) { "Profil '$($capturedClient.Name)' applique sur $($capturedClient.NIC)." }
                           else     { "Echec de l'application de '$($capturedClient.Name)'." }
                $tipIcon = if ($ok) { [System.Windows.Forms.ToolTipIcon]::Info }
                           else     { [System.Windows.Forms.ToolTipIcon]::Error }
                if ($ok) { Add-HistoryEntry $capturedClient }
                $Script:TrayIcon.ShowBalloonTip(3000, 'NetSwitch Pro', $tipText, $tipIcon)
                # Mise a jour de la statusbar si la fenetre est visible
                if ($Script:MainWindow -and $Script:MainWindow.IsVisible) {
                    if ($ok) {
                        Set-Status "Tray : '$($capturedClient.Name)' applique sur $($capturedClient.NIC)." '#107C10'
                        Update-LastApplied
                        $selNic = $Script:CmbNIC.SelectedItem
                        if ($selNic -eq $capturedClient.NIC) { Update-NicInfoBar $capturedClient.NIC }
                    } else {
                        Set-Status "Tray : echec sur $($capturedClient.NIC)." '#C50F1F'
                    }
                }
            })
        }
    }

    [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())

    # Ouvrir la fenetre
    $openItem = $menu.Items.Add('Ouvrir NetSwitch Pro')
    $openItem.Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $openItem.Add_Click({
        $Script:MainWindow.Show()
        $Script:MainWindow.WindowState = 'Normal'
        $Script:MainWindow.Activate()
    })

    # Quitter
    $quitItem = $menu.Items.Add('Quitter')
    $quitItem.Add_Click({
        $Script:ReallyClosing = $true
        $Script:TrayIcon.Visible = $false
        $Script:TrayIcon.Dispose()
        $Script:MainWindow.Close()
    })

    $Script:TrayIcon.ContextMenuStrip = $menu
}

# ==============================================================
#  XAML
# ==============================================================
[xml]$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="NetSwitch Pro" Height="680" Width="980"
    MinHeight="580" MinWidth="820"
    WindowStartupLocation="CenterScreen"
    Background="#0D0D0D" FontFamily="Consolas" FontSize="13"
    ResizeMode="CanResizeWithGrip">

    <Window.Resources>

        <Style x:Key="BtnPrimary" TargetType="Button">
            <Setter Property="Background"      Value="#00FF41"/>
            <Setter Property="Foreground"      Value="#000000"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding"         Value="16,8"/>
            <Setter Property="Cursor"          Value="Hand"/>
            <Setter Property="FontSize"        Value="13"/>
            <Setter Property="FontWeight"      Value="SemiBold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}"
                                CornerRadius="3" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#39FF14"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#00C32E"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="bd" Property="Background" Value="#1A2A1A"/>
                                <Setter Property="Foreground" Value="#3A5A3A"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="BtnSecondary" TargetType="Button">
            <Setter Property="Background"      Value="#0A150A"/>
            <Setter Property="Foreground"      Value="#00FF41"/>
            <Setter Property="BorderBrush"     Value="#2A5A2A"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding"         Value="12,6"/>
            <Setter Property="Cursor"          Value="Hand"/>
            <Setter Property="FontSize"        Value="13"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="3" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#1A2A1A"/>
                                <Setter TargetName="bd" Property="BorderBrush" Value="#00FF41"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="BtnSmall" TargetType="Button" BasedOn="{StaticResource BtnSecondary}">
            <Setter Property="Padding"   Value="8,4"/>
            <Setter Property="FontSize"  Value="11"/>
        </Style>

        <Style x:Key="BtnDanger" TargetType="Button">
            <Setter Property="Background"      Value="#0A0505"/>
            <Setter Property="Foreground"      Value="#FF3333"/>
            <Setter Property="BorderBrush"     Value="#4A1A1A"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding"         Value="12,6"/>
            <Setter Property="Cursor"          Value="Hand"/>
            <Setter Property="FontSize"        Value="13"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="3" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#1A0808"/>
                                <Setter TargetName="bd" Property="BorderBrush" Value="#FF3333"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="TxtModern" TargetType="TextBox">
            <Setter Property="Background"      Value="#050F05"/>
            <Setter Property="Foreground"      Value="#C8FFC8"/>
            <Setter Property="BorderBrush"     Value="#2A5A2A"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding"         Value="9,7"/>
            <Setter Property="FontSize"        Value="13"/>
            <Setter Property="FontFamily"      Value="Consolas"/>
            <Setter Property="CaretBrush"      Value="#00FF41"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border x:Name="bd" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="3">
                            <ScrollViewer x:Name="PART_ContentHost"
                                          Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsFocused" Value="True">
                                <Setter TargetName="bd" Property="BorderBrush" Value="#00FF41"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ClientItem" TargetType="ListBoxItem">
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="Background"      Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding"         Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ListBoxItem">
                        <Border x:Name="bd" Background="Transparent"
                                CornerRadius="7" Margin="6,2" Padding="8,7">
                            <ContentPresenter/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#0F1F0F"/>
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#1A3A1A"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Style ComboBox theme sombre matrix -->
        <Style TargetType="ComboBox">
            <Setter Property="Background"            Value="#050F05"/>
            <Setter Property="Foreground"            Value="#C8FFC8"/>
            <Setter Property="BorderBrush"           Value="#2A5A2A"/>
            <Setter Property="BorderThickness"       Value="1"/>
            <Setter Property="Padding"               Value="6,4"/>
            <Setter Property="FontFamily"            Value="Consolas"/>
            <Setter Property="FocusVisualStyle"      Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <Border x:Name="bd"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{TemplateBinding BorderThickness}"
                                    CornerRadius="3">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="22"/>
                                    </Grid.ColumnDefinitions>
                                    <ContentPresenter Grid.Column="0"
                                                      Content="{TemplateBinding SelectionBoxItem}"
                                                      ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                                      Margin="{TemplateBinding Padding}"
                                                      VerticalAlignment="Center"/>
                                    <TextBlock Grid.Column="1" Text="▼" FontSize="9"
                                               Foreground="#3A7A3A"
                                               HorizontalAlignment="Center"
                                               VerticalAlignment="Center"/>
                                </Grid>
                            </Border>
                            <Popup x:Name="PART_Popup"
                                   IsOpen="{TemplateBinding IsDropDownOpen}"
                                   Placement="Bottom"
                                   AllowsTransparency="True">
                                <Border Background="#050F05"
                                        BorderBrush="#2A5A2A"
                                        BorderThickness="1"
                                        CornerRadius="0,0,3,3"
                                        MaxHeight="{TemplateBinding MaxDropDownHeight}">
                                    <ScrollViewer>
                                        <ItemsPresenter/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                            <ToggleButton IsChecked="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}}"
                                          Focusable="False"
                                          OverridesDefaultStyle="True">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton">
                                        <Border Background="Transparent"/>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="BorderBrush" Value="#00FF41"/>
                            </Trigger>
                            <Trigger Property="IsDropDownOpen" Value="True">
                                <Setter TargetName="bd" Property="BorderBrush" Value="#00FF41"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Style items de la ComboBox -->
        <Style TargetType="ComboBoxItem">
            <Setter Property="Background"      Value="#050F05"/>
            <Setter Property="Foreground"      Value="#C8FFC8"/>
            <Setter Property="Padding"         Value="8,5"/>
            <Setter Property="FontFamily"      Value="Consolas"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBoxItem">
                        <Border x:Name="bd" Background="{TemplateBinding Background}"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#1A3A1A"/>
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#0F2A0F"/>
                                <Setter Property="Foreground" Value="#00FF41"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="46"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="30"/>
        </Grid.RowDefinitions>

        <!-- Barre de titre -->
        <Border Grid.Row="0" Background="#050F05" BorderBrush="#1A4A1A" BorderThickness="0,0,0,1">
            <DockPanel Margin="14,0">
                <TextBlock VerticalAlignment="Center" Foreground="#00FF41"
                           FontSize="16" FontWeight="Bold" Text="  NetSwitch Pro"
                           FontFamily="Consolas"/>
                <TextBlock x:Name="VersionLabel" DockPanel.Dock="Right"
                           VerticalAlignment="Center" Foreground="#3A7A3A"
                           FontSize="11" Margin="0,0,4,0"/>
            </DockPanel>
        </Border>

        <!-- Zone principale -->
        <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="262"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <!-- == SIDEBAR == -->
            <Border Grid.Column="0" Background="#080F08"
                    BorderBrush="#1A4A1A" BorderThickness="0,0,1,0">
                <DockPanel LastChildFill="True">

                    <!-- Bouton nouveau client -->
                    <Border DockPanel.Dock="Top" Padding="10,10,10,6">
                        <Button x:Name="BtnNewClient" Content="+ Nouveau client"
                                Style="{StaticResource BtnPrimary}"
                                HorizontalAlignment="Stretch"/>
                    </Border>

                    <!-- DHCP Rapide -->
                    <Border DockPanel.Dock="Top" Padding="10,0,10,8">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="6"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <ComboBox x:Name="CmbDHCPNic" Grid.Column="0" Height="30"
                                      FontFamily="Consolas" FontSize="11"
                                      Padding="6,0" BorderBrush="#2A5A2A"
                                      ToolTip="Carte reseau a passer en DHCP"/>
                            <Button x:Name="BtnApplyDHCP" Grid.Column="2"
                                    Content="→ DHCP"
                                    Style="{StaticResource BtnSmall}"
                                    Padding="10,5"
                                    Foreground="#00CFFF"
                                    BorderBrush="#0A3A5A"
                                    ToolTip="Appliquer DHCP sur la carte selectionnee (sans sauvegarder de profil)"/>
                        </Grid>
                    </Border>

                    <!-- Recherche -->
                    <Border DockPanel.Dock="Top" Padding="10,0,10,6">
                        <TextBox x:Name="SearchBox" Style="{StaticResource TxtModern}"
                                 Background="#050F05" FontSize="12"/>
                    </Border>

                    <!-- Compteur clients -->
                    <Border DockPanel.Dock="Top" Padding="16,0,10,2">
                        <TextBlock x:Name="ClientCount" FontSize="11" Foreground="#3A7A3A"/>
                    </Border>

                    <!-- Dernier profil applique -->
                    <Border DockPanel.Dock="Top" Padding="16,0,10,5">
                        <TextBlock x:Name="LastAppliedLabel" FontSize="10"
                                   Foreground="#2A5A2A" TextTrimming="CharacterEllipsis"/>
                    </Border>

                    <!-- Separateur haut -->
                    <Border DockPanel.Dock="Top" Height="1"
                            Background="#1A4A1A" Margin="10,0,10,2"/>

                    <!-- Export / Import - ancre en bas -->
                    <Border DockPanel.Dock="Bottom" Padding="10,6,10,8">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="6"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <Button Grid.Column="0" x:Name="BtnExport"
                                    Content="Exporter" Style="{StaticResource BtnSmall}"
                                    ToolTip="Sauvegarder les profils dans un fichier JSON"/>
                            <Button Grid.Column="2" x:Name="BtnImport"
                                    Content="Importer" Style="{StaticResource BtnSmall}"
                                    ToolTip="Fusionner des profils depuis un fichier JSON"/>
                        </Grid>
                    </Border>
                    <Border DockPanel.Dock="Bottom" Height="1"
                            Background="#1A4A1A" Margin="10,0"/>

                    <!-- Nouveau groupe -->
                    <Border DockPanel.Dock="Bottom" Padding="10,4,10,4">
                        <Button x:Name="BtnAddGroup" Content="+ Groupe"
                                Style="{StaticResource BtnSmall}"
                                HorizontalAlignment="Left"
                                Foreground="#3A9A3A"
                                ToolTip="Creer un nouveau groupe de clients"/>
                    </Border>

                    <!-- Liste groupes + clients -->
                    <ScrollViewer x:Name="ClientScrollViewer"
                                  VerticalScrollBarVisibility="Auto"
                                  HorizontalScrollBarVisibility="Disabled"
                                  Background="Transparent">
                        <StackPanel x:Name="ClientPanel" Background="Transparent"/>
                    </ScrollViewer>

                </DockPanel>
            </Border>

            <!-- == PANNEAU DE DETAIL == -->
            <Grid Grid.Column="1" Background="#0D0D0D">

                <!-- Etat vide -->
                <StackPanel x:Name="EmptyState"
                            VerticalAlignment="Center" HorizontalAlignment="Center">
                    <TextBlock Text="&gt;_" FontSize="52" FontFamily="Consolas"
                               HorizontalAlignment="Center" Foreground="#1A4A1A"/>
                    <TextBlock Text="Selectionnez un client"
                               FontSize="19" FontWeight="SemiBold" Foreground="#2A6A2A"
                               HorizontalAlignment="Center" Margin="0,14,0,0"
                               FontFamily="Consolas"/>
                    <TextBlock Text="ou creez-en un nouveau  +"
                               FontSize="12" Foreground="#1A4A1A"
                               HorizontalAlignment="Center" Margin="0,5,0,0"/>
                    <TextBlock Text="Double-clic sur un client = application directe"
                               FontSize="11" Foreground="#1A3A1A"
                               HorizontalAlignment="Center" Margin="0,3,0,0"/>
                    <TextBlock Text="L'icone dans le tray permet d'appliquer sans ouvrir l'appli"
                               FontSize="11" Foreground="#1A3A1A"
                               HorizontalAlignment="Center" Margin="0,2,0,0"/>
                </StackPanel>

                <!-- Formulaire -->
                <ScrollViewer x:Name="FormPanel" Visibility="Collapsed"
                              VerticalScrollBarVisibility="Auto"
                              HorizontalScrollBarVisibility="Disabled">
                    <Grid Margin="38,26,38,22">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="20"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="18"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="18"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="26"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <!-- Titre -->
                        <TextBlock Grid.Row="0" x:Name="FormTitle"
                                   FontSize="22" FontWeight="SemiBold" Foreground="#00FF41"
                                   FontFamily="Consolas"/>

                        <!-- Nom + Carte reseau -->
                        <Grid Grid.Row="2">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="20"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>

                            <StackPanel Grid.Column="0">
                                <TextBlock Text="Nom du client" FontSize="12"
                                           Foreground="#3A7A3A" Margin="0,0,0,5"/>
                                <TextBox x:Name="TxtName" Style="{StaticResource TxtModern}"/>
                                <TextBlock Text="Groupe" FontSize="12"
                                           Foreground="#3A7A3A" Margin="0,8,0,5"/>
                                <ComboBox x:Name="CmbGroup" Height="32"
                                          FontFamily="Consolas" FontSize="12"
                                          Padding="7,0" BorderBrush="#2A5A2A"
                                          ToolTip="Groupe du client"/>
                            </StackPanel>

                            <StackPanel Grid.Column="2">
                                <TextBlock Text="Carte reseau" FontSize="12"
                                           Foreground="#3A7A3A" Margin="0,0,0,5"/>
                                <ComboBox x:Name="CmbNIC" Height="36"
                                          FontFamily="Segoe UI" FontSize="13"
                                          Padding="8,0" BorderBrush="#D0D0D0"/>
                                <!-- Info IP courante de la NIC -->
                                <TextBlock x:Name="NicInfoBar" FontSize="11"
                                           Margin="2,5,0,0" TextWrapping="Wrap"
                                           Visibility="Collapsed"/>
                                <!-- Import config IP courante -->
                                <Button x:Name="BtnImportIP"
                                        Content="Importer config actuelle"
                                        Style="{StaticResource BtnSmall}"
                                        HorizontalAlignment="Left"
                                        Margin="0,6,0,0"
                                        ToolTip="Remplir le formulaire avec la configuration IP actuelle de cette carte"/>
                            </StackPanel>
                        </Grid>

                        <!-- Champs statiques : IP/Masque/GW + DNS -->
                        <StackPanel Grid.Row="4" x:Name="StaticFields">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="16"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="16"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <StackPanel Grid.Column="0">
                                    <TextBlock Text="Adresse IP" FontSize="12"
                                               Foreground="#3A7A3A" Margin="0,0,0,5"/>
                                    <TextBox x:Name="TxtIP" Style="{StaticResource TxtModern}"/>
                                </StackPanel>
                                <StackPanel Grid.Column="2">
                                    <TextBlock Text="Masque" FontSize="12"
                                               Foreground="#3A7A3A" Margin="0,0,0,5"/>
                                    <TextBox x:Name="TxtMask" Style="{StaticResource TxtModern}"/>
                                </StackPanel>
                                <StackPanel Grid.Column="4">
                                    <TextBlock Text="Passerelle" FontSize="12"
                                               Foreground="#3A7A3A" Margin="0,0,0,5"/>
                                    <TextBox x:Name="TxtGateway" Style="{StaticResource TxtModern}"/>
                                </StackPanel>
                            </Grid>
                            <Grid Margin="0,12,0,0">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="16"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="16"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <StackPanel Grid.Column="0">
                                    <TextBlock Text="DNS Primaire" FontSize="12"
                                               Foreground="#3A7A3A" Margin="0,0,0,5"/>
                                    <TextBox x:Name="TxtDNS1" Style="{StaticResource TxtModern}"/>
                                </StackPanel>
                                <StackPanel Grid.Column="2">
                                    <TextBlock Text="DNS Secondaire (optionnel)" FontSize="12"
                                               Foreground="#3A7A3A" Margin="0,0,0,5"/>
                                    <TextBox x:Name="TxtDNS2" Style="{StaticResource TxtModern}"/>
                                </StackPanel>
                            </Grid>
                        </StackPanel>

                        <!-- Notes -->
                        <StackPanel Grid.Row="6">
                            <TextBlock Text="Notes" FontSize="12"
                                       Foreground="#3A7A3A" Margin="0,0,0,5"/>
                            <TextBox x:Name="TxtNotes" Style="{StaticResource TxtModern}"
                                     Height="76" TextWrapping="Wrap"
                                     AcceptsReturn="True"
                                     VerticalScrollBarVisibility="Auto"/>
                        </StackPanel>

                        <!-- Boutons d'action -->
<Grid Grid.Row="8">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>

                            <!-- Gauche : Supprimer + Dupliquer -->
                            <StackPanel Grid.Column="0" Orientation="Horizontal">
                                <Button x:Name="BtnDelete" Content="Supprimer"
                                        Style="{StaticResource BtnDanger}"
                                        Visibility="Collapsed"/>
                                <Button x:Name="BtnDuplicate" Content="Dupliquer"
                                        Style="{StaticResource BtnSecondary}"
                                        Margin="8,0,0,0" Visibility="Collapsed"
                                        ToolTip="Creer une copie de ce profil client"/>
                            </StackPanel>

                            <!-- Droite : Enregistrer + Appliquer -->
                            <StackPanel Grid.Column="2" Orientation="Horizontal">
                                <Button x:Name="BtnSave"
                                        Content="Enregistrer  [Ctrl+S]"
                                        Style="{StaticResource BtnSecondary}"
                                        Margin="0,0,10,0"/>
                                <Button x:Name="BtnApply"
                                        Content="Appliquer maintenant  [Entree]"
                                        Style="{StaticResource BtnPrimary}"/>
                            </StackPanel>
                        </Grid>

                    </Grid>
                </ScrollViewer>
            </Grid>
        </Grid>

        <!-- Barre de statut -->
        <Border Grid.Row="2" Background="#050F05"
                BorderBrush="#1A4A1A" BorderThickness="0,1,0,0">
            <DockPanel Margin="14,0">
                <TextBlock x:Name="UpdateLabel" DockPanel.Dock="Right"
                           VerticalAlignment="Center" Foreground="#00FF41"
                           FontSize="12" FontWeight="SemiBold"
                           Cursor="Hand" Visibility="Collapsed"/>
                <TextBlock x:Name="RollbackLabel" DockPanel.Dock="Right"
                           VerticalAlignment="Center" Foreground="#FFB800"
                           FontSize="12" FontWeight="SemiBold" FontFamily="Consolas"
                           Cursor="Hand" Visibility="Collapsed" Margin="0,0,12,0"
                           Text="  ↩ Rollback" ToolTip="Restaurer la configuration precedente"/>
                <TextBlock x:Name="StatusLabel" VerticalAlignment="Center"
                           Foreground="#3A7A3A" FontSize="12" Text="Pret"
                           FontFamily="Consolas"/>
            </DockPanel>
        </Border>

    </Grid>
</Window>
'@

# ==============================================================
#  CHARGEMENT DE LA FENETRE + REFERENCES CONTROLES
# ==============================================================
$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)
if (-not $window) { throw [System.Exception]::new('XamlReader a renvoye null : echec chargement fenetre WPF') }
$Script:MainWindow = $window   # reference $Script: pour les closures tray (pas de probleme de scope)

$Script:VersionLabel     = $window.FindName('VersionLabel')
$Script:ClientPanel      = $window.FindName('ClientPanel')
$Script:CmbGroup         = $window.FindName('CmbGroup')
$Script:BtnAddGroup      = $window.FindName('BtnAddGroup')
$Script:SearchBox        = $window.FindName('SearchBox')
$Script:EmptyState       = $window.FindName('EmptyState')
$Script:FormPanel        = $window.FindName('FormPanel')
$Script:FormTitle        = $window.FindName('FormTitle')
$Script:TxtName          = $window.FindName('TxtName')
$Script:CmbNIC           = $window.FindName('CmbNIC')
$Script:TxtIP            = $window.FindName('TxtIP')
$Script:TxtMask          = $window.FindName('TxtMask')
$Script:TxtGateway       = $window.FindName('TxtGateway')
$Script:TxtDNS1          = $window.FindName('TxtDNS1')
$Script:TxtDNS2          = $window.FindName('TxtDNS2')
$Script:TxtNotes         = $window.FindName('TxtNotes')
$Script:BtnNewClient     = $window.FindName('BtnNewClient')
$Script:BtnSave          = $window.FindName('BtnSave')
$Script:BtnApply         = $window.FindName('BtnApply')
$Script:BtnDelete        = $window.FindName('BtnDelete')
$Script:BtnDuplicate     = $window.FindName('BtnDuplicate')
$Script:BtnImportIP      = $window.FindName('BtnImportIP')
$Script:CmbDHCPNic       = $window.FindName('CmbDHCPNic')
$Script:BtnApplyDHCP     = $window.FindName('BtnApplyDHCP')
$Script:BtnExport        = $window.FindName('BtnExport')
$Script:BtnImport        = $window.FindName('BtnImport')
$Script:StatusLabel      = $window.FindName('StatusLabel')
$Script:UpdateLabel      = $window.FindName('UpdateLabel')
$Script:RollbackLabel    = $window.FindName('RollbackLabel')
$Script:NicInfoBar       = $window.FindName('NicInfoBar')
$Script:ClientCount      = $window.FindName('ClientCount')
$Script:LastAppliedLabel = $window.FindName('LastAppliedLabel')

# ==============================================================
#  HELPERS UI
# ==============================================================
function Set-Status([string]$msg, [string]$color = '#3A7A3A') {
    $Script:StatusLabel.Text       = $msg
    $Script:StatusLabel.Foreground = New-Brush $color
}
function Show-EmptyState {
    $Script:EmptyState.Visibility = 'Visible'
    $Script:FormPanel.Visibility  = 'Collapsed'
}
function Show-Form {
    $Script:EmptyState.Visibility = 'Collapsed'
    $Script:FormPanel.Visibility  = 'Visible'
}

function Update-ClientCount {
    $n = $Script:Clients.Count
    $g = $Script:Groups.Count
    $Script:ClientCount.Text = switch ($n) {
        0       { "Aucun client | $g groupe$(if($g -gt 1){'s'})" }
        1       { "1 client | $g groupe$(if($g -gt 1){'s'})" }
        default { "$n clients | $g groupe$(if($g -gt 1){'s'})" }
    }
}

function Update-LastApplied {
    $history = Load-History
    if ($history -and $history.Count -gt 0) {
        $last = $history[0]
        try {
            $dt  = [datetime]::Parse($last.Timestamp)
            $Script:LastAppliedLabel.Text = "Dernier : $($last.ClientName) - $($dt.ToString('dd/MM HH:mm'))"
        } catch {
            $Script:LastAppliedLabel.Text = "Dernier : $($last.ClientName)"
        }
    } else {
        $Script:LastAppliedLabel.Text = ''
    }
}

# Tri alphabetique + compteur + menu tray
function Refresh-List([string]$filter = '') { Rebuild-ClientPanel $filter }

# Filtrage leger : masque/affiche les rows existantes sans reconstruire le panneau
function Update-ClientFilter([string]$filter) {  # Update = verbe approuve PS
    $Script:Refreshing = $true
    $isFiltering = $filter -and $filter -ne '   Rechercher...' -and $filter.Trim()
    $children = $Script:ClientPanel.Children
    $i = 0
    while ($i -lt $children.Count) {
        $header    = $children[$i]
        $container = if ($i+1 -lt $children.Count) { $children[$i+1] } else { $null }
        if ($header -is [System.Windows.Controls.Border] -and
            $container -is [System.Windows.Controls.StackPanel]) {
            $groupName   = [string]$header.Tag
            $visibleRows = 0
            foreach ($row in $container.Children) {
                if ($row -is [System.Windows.Controls.Border]) {
                    if ($isFiltering) {
                        $cid    = [string]$row.Tag
                        $client = $Script:Clients | Where-Object { $_.ID -eq $cid } | Select-Object -First 1
                        $show   = $client -and $client.Name -like "*$filter*"
                        $row.Visibility = if ($show) { 'Visible' } else { 'Collapsed' }
                        if ($show) { $visibleRows++ }
                    } else {
                        $row.Visibility = 'Visible'
                        $visibleRows++
                    }
                }
            }
            if ($isFiltering -and $visibleRows -eq 0) {
                $header.Visibility    = 'Collapsed'
                $container.Visibility = 'Collapsed'
            } else {
                $header.Visibility    = 'Visible'
                $container.Visibility = if (-not $Script:CollapsedGroups.Contains($groupName)) { 'Visible' } else { 'Collapsed' }
            }
            $i += 2
        } else { $i++ }
    }
    $Script:Refreshing = $false
}

function Rebuild-ClientPanel([string]$filter = '') {
    $Script:Refreshing = $true
    $Script:ClientPanel.Children.Clear()
    # ToArray() : snapshot immutable de la liste - evite les problemes d'iteration sur List[string] en WPF
    $groupsSnapshot = $Script:Groups.ToArray()
    $clientsSnapshot = $Script:Clients.ToArray()
    foreach ($groupName in $groupsSnapshot) {
        if (-not $groupName) { continue }
        $groupClients = @($clientsSnapshot |
            Where-Object { $_.Group -eq $groupName } |
            Where-Object { if ($filter -and $filter -ne '   Rechercher...') { $_.Name -like "*$filter*" } else { $true } } |
            Sort-Object Name)
        if ($filter -and $filter -ne '   Rechercher...' -and $groupClients.Count -eq 0) { continue }
        $isExpanded = -not $Script:CollapsedGroups.Contains($groupName)
        [void]$Script:ClientPanel.Children.Add((New-GroupHeader -Name $groupName -Count $groupClients.Count -Expanded $isExpanded))
        $cp = [System.Windows.Controls.StackPanel]::new()
        $cp.Visibility = if ($isExpanded) { 'Visible' } else { 'Collapsed' }
        $cp.Tag = "grp_$groupName"
        foreach ($c in $groupClients) { [void]$cp.Children.Add((New-ClientRow -Client $c)) }
        [void]$Script:ClientPanel.Children.Add($cp)
    }
    Update-ClientCount
    if ($Script:TrayIcon) { Update-TrayMenu }
    $Script:Refreshing = $false
}

function New-GroupHeader {
    param([string]$Name, [int]$Count, [bool]$Expanded)
    $border = [System.Windows.Controls.Border]::new()
    $border.Margin = [System.Windows.Thickness]::new(6,4,6,0)
    $border.Padding = [System.Windows.Thickness]::new(8,5,8,5)
    $border.Background = New-Brush '#0A1A0A'
    $border.BorderBrush = New-Brush '#1A4A1A'
    $border.BorderThickness = [System.Windows.Thickness]::new(1)
    $border.CornerRadius = [System.Windows.CornerRadius]::new(3)
    $border.Cursor = [System.Windows.Input.Cursors]::Hand
    $border.Tag = $Name
    $dp = [System.Windows.Controls.DockPanel]::new()
    $dp.LastChildFill = $true
    $rp = [System.Windows.Controls.StackPanel]::new()
    $rp.Orientation = 'Horizontal'
    [System.Windows.Controls.DockPanel]::SetDock($rp, 'Right')
    $capturedName = $Name
    $btnR = [System.Windows.Controls.Button]::new()
    $btnR.Content = '✎'; $btnR.Foreground = New-Brush '#5A9A5A'
    $btnR.Background = [System.Windows.Media.Brushes]::Transparent
    $btnR.BorderThickness = [System.Windows.Thickness]::new(0)
    $btnR.Cursor = [System.Windows.Input.Cursors]::Hand
    $btnR.Padding = [System.Windows.Thickness]::new(5,0,5,0); $btnR.FontSize = 13
    $btnR.ToolTip = "Renommer le groupe"
    $btnR.Add_Click(({ param($s,$e); $e.Handled=$true; Rename-Group $capturedName }).GetNewClosure())
    [void]$rp.Children.Add($btnR)
    $btnD = [System.Windows.Controls.Button]::new()
    $btnD.Content = '✕'; $btnD.Foreground = New-Brush '#AA3333'
    $btnD.Background = [System.Windows.Media.Brushes]::Transparent
    $btnD.BorderThickness = [System.Windows.Thickness]::new(0)
    $btnD.Cursor = [System.Windows.Input.Cursors]::Hand
    $btnD.Padding = [System.Windows.Thickness]::new(5,0,3,0); $btnD.FontSize = 13
    $btnD.ToolTip = "Supprimer le groupe"
    $btnD.Add_Click(({ param($s,$e); $e.Handled=$true; Delete-Group $capturedName }).GetNewClosure())
    [void]$rp.Children.Add($btnD)
    [void]$dp.Children.Add($rp)
    $lp = [System.Windows.Controls.StackPanel]::new()
    $lp.Orientation = 'Horizontal'; $lp.VerticalAlignment = 'Center'
    $arTB = [System.Windows.Controls.TextBlock]::new()
    $arTB.Text = if ($Expanded) { '▼ ' } else { '▶ ' }
    $arTB.Foreground = New-Brush '#00FF41'; $arTB.FontSize = 9; $arTB.VerticalAlignment = 'Center'
    [void]$lp.Children.Add($arTB)
    $nTB = [System.Windows.Controls.TextBlock]::new()
    $nTB.Text = $Name.ToUpper()
    $nTB.Foreground = New-Brush '#00FF41'; $nTB.FontWeight = 'SemiBold'
    $nTB.FontFamily = [System.Windows.Media.FontFamily]::new('Consolas')
    $nTB.FontSize = 11; $nTB.VerticalAlignment = 'Center'
    [void]$lp.Children.Add($nTB)
    $cTB = [System.Windows.Controls.TextBlock]::new()
    $cTB.Text = "  ($Count)"; $cTB.Foreground = New-Brush '#3A7A3A'
    $cTB.FontSize = 10; $cTB.VerticalAlignment = 'Center'
    [void]$lp.Children.Add($cTB)
    [void]$dp.Children.Add($lp)
    $border.Child = $dp
    # Toggle uniquement sur le panneau gauche (fleche+nom) - evite le conflit avec les boutons ✎ ✕
    $capturedToggle = $Name
    $lp.Cursor = [System.Windows.Input.Cursors]::Hand
    $lp.Add_MouseLeftButtonUp(({
        param($s,$e)
        $e.Handled = $true
        Toggle-Group $capturedToggle
    }).GetNewClosure())
    return $border
}

function New-ClientRow {
    param([PSCustomObject]$Client)
    $isSelected = ($Script:SelectedClientID -eq $Client.ID)
    $border = [System.Windows.Controls.Border]::new()
    $border.Margin = [System.Windows.Thickness]::new(6,1,6,0)
    $border.Padding = [System.Windows.Thickness]::new(8,6,8,6)
    $border.CornerRadius = [System.Windows.CornerRadius]::new(3)
    $border.Background = if ($isSelected) { New-Brush '#1A3A1A' } else { [System.Windows.Media.Brushes]::Transparent }
    $border.Cursor = [System.Windows.Input.Cursors]::Hand
    $border.Tag = $Client.ID
    $cid = $Client.ID
    $border.Add_MouseEnter({ if ($this.Tag -ne $Script:SelectedClientID) { $this.Background = New-Brush '#0F1F0F' } })
    $border.Add_MouseLeave({ if ($this.Tag -ne $Script:SelectedClientID) { $this.Background = [System.Windows.Media.Brushes]::Transparent } })
    $grid = [System.Windows.Controls.Grid]::new()
    $c1 = [System.Windows.Controls.ColumnDefinition]::new(); $c1.Width = [System.Windows.GridLength]::new(38)
    $c2 = [System.Windows.Controls.ColumnDefinition]::new(); $c2.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    [void]$grid.ColumnDefinitions.Add($c1); [void]$grid.ColumnDefinitions.Add($c2)
    $avBorder = [System.Windows.Controls.Border]::new()
    $avBorder.Width = 34; $avBorder.Height = 34
    $avBorder.CornerRadius = [System.Windows.CornerRadius]::new(17)
    $avBorder.Background = New-Brush $Client.AvatarColor
    [System.Windows.Controls.Grid]::SetColumn($avBorder, 0)
    $initTB = [System.Windows.Controls.TextBlock]::new()
    $initTB.Text = $Client.Initial; $initTB.Foreground = [System.Windows.Media.Brushes]::Black
    $initTB.FontWeight = 'Bold'; $initTB.FontSize = 14
    $initTB.HorizontalAlignment = 'Center'; $initTB.VerticalAlignment = 'Center'
    $avBorder.Child = $initTB
    [void]$grid.Children.Add($avBorder)
    $infoSP = [System.Windows.Controls.StackPanel]::new()
    $infoSP.Margin = [System.Windows.Thickness]::new(10,0,0,0); $infoSP.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($infoSP, 1)
    $nTB = [System.Windows.Controls.TextBlock]::new()
    $nTB.Text = $Client.Name; $nTB.Foreground = New-Brush '#C8FFC8'
    $nTB.FontWeight = 'SemiBold'; $nTB.FontSize = 13; $nTB.TextTrimming = 'CharacterEllipsis'
    [void]$infoSP.Children.Add($nTB)
    $ipTB = [System.Windows.Controls.TextBlock]::new()
    $ipTB.Text = $Client.IPSummary; $ipTB.Foreground = New-Brush '#5A9A5A'
    $ipTB.FontSize = 11; $ipTB.Margin = [System.Windows.Thickness]::new(0,2,0,0)
    [void]$infoSP.Children.Add($ipTB)
    [void]$grid.Children.Add($infoSP)
    $border.Child = $grid
    $capturedClient = $Client
    $capturedBorder = $border
    # Clic simple : selectionner le client
    $border.Add_MouseLeftButtonUp(({
        param($s,$e)
        try {
            foreach ($child in $Script:ClientPanel.Children) {
                if ($child -is [System.Windows.Controls.StackPanel]) {
                    foreach ($row in $child.Children) {
                        if ($row -is [System.Windows.Controls.Border] -and
                            $null -ne $row.Tag -and $row.Tag -ne $capturedClient.ID) {
                            $row.Background = [System.Windows.Media.Brushes]::Transparent
                        }
                    }
                }
            }
            $Script:SelectedClientID = $capturedClient.ID
            $capturedBorder.Background = New-Brush '#1A3A1A'
            Load-IntoForm $capturedClient
            Show-Form
            Set-Status "Client : $($capturedClient.Name)  |  Double-clic pour appliquer directement"
        } catch {
            Set-Status "ERREUR selection: $($_.Exception.Message)" '#FF3333'
        }
    }).GetNewClosure())
    # Double-clic : appliquer le profil directement
    $border.Add_PreviewMouseLeftButtonDown(({
        param($s,$e)
        try {
            if ($e.ClickCount -ge 2) {
                $e.Handled = $true
                $Script:SelectedClientID = $capturedClient.ID
                Set-Status "Application directe : $($capturedClient.Name) sur $($capturedClient.NIC)..." '#0078D4'
                Save-ConfigBackup $capturedClient.NIC
                $ok = Invoke-ApplyProfile $capturedClient
                if ($ok) {
                    Add-HistoryEntry $capturedClient
                    Update-LastApplied
                    $Script:RollbackLabel.Visibility = 'Visible'
                    Set-Status "'$($capturedClient.Name)' applique sur $($capturedClient.NIC)." '#00FF41'
                    Update-NicInfoBar $capturedClient.NIC
                } else {
                    Set-Status "Echec de l'application de '$($capturedClient.Name)'." '#FF3333'
                }
            }
        } catch {
            Set-Status "ERREUR dbl-clic: $($_.Exception.Message)" '#FF3333'
        }
    }).GetNewClosure())
    return $border
}

function Toggle-Group([string]$name) {
    if ($Script:CollapsedGroups.Contains($name)) { [void]$Script:CollapsedGroups.Remove($name) }
    else { [void]$Script:CollapsedGroups.Add($name) }
    Rebuild-ClientPanel ($Script:SearchBox.Text -replace '   Rechercher...', '')
}

function Add-Group {
    $name = Show-InputDialog "Nom du nouveau groupe :" "Nouveau groupe"
    if (-not $name) { return }
    if ($Script:Groups -contains $name) { Set-Status "Le groupe '$name' existe deja." '#FFCC00'; return }
    $Script:Groups.Add($name)
    Export-Groups
    Refresh-GroupCombo
    Rebuild-ClientPanel
    Set-Status "Groupe '$name' cree." '#00FF41'
}

function Rename-Group([string]$oldName) {
    $newName = Show-InputDialog "Nouveau nom du groupe :" "Renommer groupe" $oldName
    if (-not $newName -or $newName -eq $oldName) { return }
    if ($Script:Groups -contains $newName) { Set-Status "Le groupe '$newName' existe deja." '#FFCC00'; return }
    $idx = $Script:Groups.IndexOf($oldName)
    $Script:Groups[$idx] = $newName
    for ($i = 0; $i -lt $Script:Clients.Count; $i++) {
        if ($Script:Clients[$i].Group -eq $oldName) {
            $c = $Script:Clients[$i]
            $Script:Clients[$i] = New-Client $c.ID $c.Name $c.NIC $c.DHCP $c.IP $c.Mask $c.Gateway $c.DNS1 $c.DNS2 $c.Notes $newName
        }
    }
    Export-Groups; Export-Clients $Script:Clients
    Refresh-GroupCombo
    Rebuild-ClientPanel
    Set-Status "Groupe renomme : '$oldName' -> '$newName'." '#00FF41'
}

function Delete-Group([string]$name) {
    if ($Script:Groups.Count -le 1) {
        [System.Windows.MessageBox]::Show("Impossible de supprimer le seul groupe.", "Erreur", "OK", "Warning") | Out-Null; return
    }
    $inGroup = @($Script:Clients | Where-Object { $_.Group -eq $name })
    $targetGroup = $Script:Groups | Where-Object { $_ -ne $name } | Select-Object -First 1
    $msg = "Supprimer le groupe '$name' ?"
    if ($inGroup.Count -gt 0) { $msg += "`n$($inGroup.Count) client(s) seront deplaces vers '$targetGroup'." }
    $res = [System.Windows.MessageBox]::Show($msg, "Confirmer", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    if ($res -ne 'Yes') { return }
    for ($i = 0; $i -lt $Script:Clients.Count; $i++) {
        if ($Script:Clients[$i].Group -eq $name) {
            $c = $Script:Clients[$i]
            $Script:Clients[$i] = New-Client $c.ID $c.Name $c.NIC $c.DHCP $c.IP $c.Mask $c.Gateway $c.DNS1 $c.DNS2 $c.Notes $targetGroup
        }
    }
    if ($inGroup.Count -gt 0) { Export-Clients $Script:Clients }
    [void]$Script:Groups.Remove($name)
    Export-Groups
    [void]$Script:CollapsedGroups.Remove($name)
    Refresh-GroupCombo
    Rebuild-ClientPanel
    Set-Status "Groupe '$name' supprime." '#00FF41'
}

function Update-NicInfoBar([string]$nicName) {
    if (-not $nicName) { $Script:NicInfoBar.Visibility = 'Collapsed'; return }
    $info = Get-NICCurrentInfo $nicName
    $Script:NicInfoBar.Text       = $info.Text
    $Script:NicInfoBar.Foreground = if ($info.OK) { New-Brush '#107C10' } else { New-Brush '#C50F1F' }
    $Script:NicInfoBar.Visibility = 'Visible'
}

function Clear-Form {
    $Script:TxtName.Text    = ''
    $Script:TxtIP.Text      = ''
    $Script:TxtMask.Text    = ''
    $Script:TxtGateway.Text = ''
    $Script:TxtDNS1.Text    = ''
    $Script:TxtDNS2.Text    = ''
    $Script:TxtNotes.Text   = ''
    $Script:BtnDelete.Visibility    = 'Collapsed'
    $Script:BtnDuplicate.Visibility = 'Collapsed'
    $Script:NicInfoBar.Visibility   = 'Collapsed'
    if ($Script:CmbGroup.Items.Count -gt 0) { $Script:CmbGroup.SelectedIndex = 0 }
    $Script:FormTitle.Text = 'Nouveau client'
    $Script:CurrentID = $null
    $Script:EditMode  = 'new'
}

function Load-IntoForm([PSCustomObject]$c) {
    $Script:TxtName.Text    = $c.Name
    $Script:TxtIP.Text      = $c.IP
    $Script:TxtMask.Text    = $c.Mask
    $Script:TxtGateway.Text = $c.Gateway
    $Script:TxtDNS1.Text    = $c.DNS1
    $Script:TxtDNS2.Text    = $c.DNS2
    $Script:TxtNotes.Text   = $c.Notes

    # Avertissement NIC indisponible
    $available = Get-NICList
    if ($c.NIC -and ($available -notcontains $c.NIC)) {
        if (-not $Script:CmbNIC.Items.Contains($c.NIC)) {
            [void]$Script:CmbNIC.Items.Add($c.NIC)
        }
        Set-Status "La carte '$($c.NIC)' n'est pas disponible sur cet appareil." '#CA5010'
    }
    $Script:CmbNIC.SelectedItem = $c.NIC

    $Script:CmbGroup.SelectedItem = $c.Group
    $Script:BtnDelete.Visibility    = 'Visible'
    $Script:BtnDuplicate.Visibility = 'Visible'
    $Script:FormTitle.Text          = $c.Name
    $Script:CurrentID = $c.ID
    $Script:EditMode  = 'edit'
    Update-NicInfoBar $c.NIC
}

function Build-FormClient {
    $name  = $Script:TxtName.Text.Trim()
    $nic   = $Script:CmbNIC.SelectedItem
    $dhcp  = $false
    $ip    = $Script:TxtIP.Text.Trim()
    $mask  = $Script:TxtMask.Text.Trim()
    $gw    = $Script:TxtGateway.Text.Trim()
    $dns1  = $Script:TxtDNS1.Text.Trim()
    $dns2  = $Script:TxtDNS2.Text.Trim()
    $notes = $Script:TxtNotes.Text.Trim()

    if (-not $name) { Set-Status 'Le nom du client est requis.'            '#CA5010'; return $null }
    if (-not $nic)  { Set-Status 'Selectionnez une carte reseau.'          '#CA5010'; return $null }

    # Detection doublons
    if ($Script:Clients | Where-Object { $_.Name -eq $name -and $_.ID -ne $Script:CurrentID }) {
        Set-Status "Un client nomme '$name' existe deja."                  '#CA5010'; return $null
    }
    if (-not (Test-IPFormat $ip))   { Set-Status 'Adresse IP invalide (octets 0-255).'  '#CA5010'; return $null }
    if (-not (Test-IPFormat $mask)) { Set-Status 'Masque invalide.'                     '#CA5010'; return $null }
    if (-not (Test-IPFormat $gw))   { Set-Status 'Passerelle invalide.'                 '#CA5010'; return $null }
    if ($dns1 -and -not (Test-IPFormat $dns1)) { Set-Status 'DNS primaire invalide.'    '#CA5010'; return $null }
    if ($dns2 -and -not (Test-IPFormat $dns2)) { Set-Status 'DNS secondaire invalide.'  '#CA5010'; return $null }
    $group = if ($Script:CmbGroup.SelectedItem) { [string]$Script:CmbGroup.SelectedItem } else { $Script:Groups[0] }
    New-Client $Script:CurrentID $name $nic $dhcp $ip $mask $gw $dns1 $dns2 $notes $group
}

# Sauvegarde + rafraichissement + reselection
function Save-AndRefresh([PSCustomObject]$c) {
    if ($Script:EditMode -eq 'edit') {
        for ($i = 0; $i -lt $Script:Clients.Count; $i++) {
            if ($Script:Clients[$i].ID -eq $c.ID) { $Script:Clients[$i] = $c; break }
        }
    } else {
        $Script:Clients.Add($c)
    }
    Export-Clients $Script:Clients
    $Script:SelectedClientID = $c.ID
    Refresh-List ($Script:SearchBox.Text -replace '   Rechercher...', '')
    Load-IntoForm $c
}

# ==============================================================
#  INITIALISATION
# ==============================================================
$Script:VersionLabel.Text = "v$($Script:Ver)"
# Import-Clients retourne une List mais PowerShell l'enumere a l'assignation
# -> on reconstruit explicitement une List pour garder .Add() fonctionnel
$Script:Clients = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($item in @(Import-Clients)) { if ($item) { $Script:Clients.Add($item) } }

Import-Groups
Refresh-GroupCombo
# Assign missing groups to default (for loop = mutation fiable sur List)
for ($i = 0; $i -lt $Script:Clients.Count; $i++) {
    if (-not $Script:Clients[$i].Group) {
        $c = $Script:Clients[$i]
        $Script:Clients[$i] = New-Client $c.ID $c.Name $c.NIC $c.DHCP $c.IP $c.Mask $c.Gateway $c.DNS1 $c.DNS2 $c.Notes $Script:Groups[0]
    }
}

foreach ($n in (Get-NICList)) {
    [void]$Script:CmbNIC.Items.Add($n)
    [void]$Script:CmbDHCPNic.Items.Add($n)
}
if ($Script:CmbNIC.Items.Count -gt 0)     { $Script:CmbNIC.SelectedIndex = 0 }
if ($Script:CmbDHCPNic.Items.Count -gt 0) { $Script:CmbDHCPNic.SelectedIndex = 0 }

Refresh-List
Show-EmptyState
Update-LastApplied

$Script:SearchBox.Text       = '   Rechercher...'
$Script:SearchBox.Foreground = New-Brush '#2A5A2A'

Initialize-TrayIcon
Start-UpdateCheck

# ==============================================================
#  GESTIONNAIRES D'EVENEMENTS
# ==============================================================

# Recherche
$Script:SearchBox.Add_GotFocus({
    if ($Script:SearchBox.Text -eq '   Rechercher...') {
        $Script:SearchBox.Text       = ''
        $Script:SearchBox.Foreground = New-Brush '#C8FFC8'
    }
})
$Script:SearchBox.Add_LostFocus({
    if ([string]::IsNullOrEmpty($Script:SearchBox.Text)) {
        $Script:SearchBox.Text       = '   Rechercher...'
        $Script:SearchBox.Foreground = New-Brush '#2A5A2A'
    }
})
$Script:SearchBox.Add_TextChanged({
    if ($Script:Refreshing) { return }
    Update-ClientFilter $Script:SearchBox.Text
})

# Nouveau client
$Script:BtnNewClient.Add_Click({
    $Script:SelectedClientID = $null
    Clear-Form
    Show-Form
    $Script:TxtName.Focus() | Out-Null
    Set-Status 'Nouveau client - remplissez le formulaire.'
})


$Script:BtnAddGroup.Add_Click({ Add-Group })

# Rafraichissement NICs a l'ouverture de la combo
$Script:CmbNIC.Add_DropDownOpened({
    $cur = $Script:CmbNIC.SelectedItem
    $Script:CmbNIC.Items.Clear()
    foreach ($n in (Get-NICList)) { [void]$Script:CmbNIC.Items.Add($n) }
    if ($cur -and $Script:CmbNIC.Items.Contains($cur)) {
        $Script:CmbNIC.SelectedItem = $cur
    } elseif ($Script:CmbNIC.Items.Count -gt 0) {
        $Script:CmbNIC.SelectedIndex = 0
    }
})

# Info NIC au changement de selection
$Script:CmbNIC.Add_SelectionChanged({
    $sel = $Script:CmbNIC.SelectedItem
    if ($sel -and $Script:FormPanel.Visibility -eq 'Visible') {
        Update-NicInfoBar $sel
    }
})

# Enregistrer
$Script:BtnSave.Add_Click({
    try {
        $c = Build-FormClient
        if (-not $c) { return }
        Save-AndRefresh $c
        Set-Status "Client '$($c.Name)' enregistre." '#107C10'
    } catch {
        Set-Status "ERREUR Enregistrer L$($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)" '#C50F1F'
    }
})

# Appliquer : auto-save si nouveau + historique
$Script:BtnApply.Add_Click({
    try {
        $c = Build-FormClient
        if (-not $c) { return }
        if ($Script:EditMode -eq 'new') {
            $Script:Clients.Add($c)
            Export-Clients $Script:Clients
            $Script:SelectedClientID = $c.ID
            Refresh-List ($Script:SearchBox.Text -replace '   Rechercher...', '')
            Load-IntoForm $c
        }
        Set-Status "Application sur $($c.NIC)..." '#0078D4'
        $Script:MainWindow.Cursor = [System.Windows.Input.Cursors]::Wait
        Save-ConfigBackup $c.NIC
        $ok = Invoke-ApplyProfile $c
        $Script:MainWindow.Cursor = $null
        if ($ok) {
            Add-HistoryEntry $c
            Update-LastApplied
            Set-Status "Profil '$($c.Name)' applique sur $($c.NIC)." '#107C10'
            Update-NicInfoBar $c.NIC
            $Script:RollbackLabel.Visibility = 'Visible'
        } else {
            Set-Status "Echec sur $($c.NIC). Verifiez le nom de la carte et les droits admin." '#C50F1F'
        }
    } catch {
        Set-Status "ERREUR Appliquer L$($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)" '#C50F1F'
    }
})

# Supprimer
$Script:BtnDelete.Add_Click({
    $name = $Script:TxtName.Text.Trim()
    $res  = [System.Windows.MessageBox]::Show(
        "Supprimer definitivement '$name' ?",
        'Confirmer', [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning)
    if ($res -ne 'Yes') { return }
    $newList = [System.Collections.Generic.List[PSCustomObject]]::new()
    $Script:Clients | Where-Object { $_.ID -ne $Script:CurrentID } |
        ForEach-Object { $newList.Add($_) }
    $Script:Clients = $newList
    Export-Clients $Script:Clients
    $Script:SelectedClientID = $null
    Refresh-List
    Show-EmptyState
    Set-Status "Client '$name' supprime."
})

# Dupliquer un profil
$Script:BtnDuplicate.Add_Click({
    $src = $Script:Clients | Where-Object { $_.ID -eq $Script:CurrentID } | Select-Object -First 1
    if (-not $src) { return }
    # Trouver un nom libre
    $baseName = "Copie de $($src.Name)"
    $newName  = $baseName
    $counter  = 2
    while ($Script:Clients | Where-Object { $_.Name -eq $newName }) {
        $newName = "$baseName ($counter)"
        $counter++
    }
    # Prepopuler le formulaire en mode nouveau
    $Script:SelectedClientID = $null
    $Script:EditMode  = 'new'
    $Script:CurrentID = $null
    $Script:TxtName.Text    = $newName
    $Script:TxtIP.Text      = $src.IP
    $Script:TxtMask.Text    = $src.Mask
    $Script:TxtGateway.Text = $src.Gateway
    $Script:TxtDNS1.Text    = $src.DNS1
    $Script:TxtDNS2.Text    = $src.DNS2
    $Script:TxtNotes.Text   = $src.Notes
    $Script:CmbNIC.SelectedItem = $src.NIC
    $Script:BtnDelete.Visibility    = 'Collapsed'
    $Script:BtnDuplicate.Visibility = 'Collapsed'
    $Script:FormTitle.Text = "Nouveau client (copie)"
    Show-Form
    $Script:TxtName.Focus() | Out-Null
    $Script:TxtName.SelectAll()
    Set-Status "Copie de '$($src.Name)' - modifiez le nom puis enregistrez."
})

# Import config IP courante depuis la NIC selectionnee
$Script:BtnImportIP.Add_Click({
    $nic = $Script:CmbNIC.SelectedItem
    if (-not $nic) { Set-Status "Selectionnez d'abord une carte reseau." '#CA5010'; return }
    $cfg = Get-NICFullConfig $nic
    if (-not $cfg) { Set-Status "Impossible de lire la configuration de $nic." '#C50F1F'; return }
    $Script:TxtIP.Text      = if ($cfg.IP)      { $cfg.IP }      else { '' }
    $Script:TxtMask.Text    = if ($cfg.Mask)    { $cfg.Mask }    else { '' }
    $Script:TxtGateway.Text = if ($cfg.Gateway) { $cfg.Gateway } else { '' }
    $Script:TxtDNS1.Text    = if ($cfg.DNS1)    { $cfg.DNS1 }    else { '' }
    $Script:TxtDNS2.Text    = if ($cfg.DNS2)    { $cfg.DNS2 }    else { '' }
    Set-Status "Configuration importee depuis $nic." '#107C10'
})

# Export clients
$Script:BtnExport.Add_Click({ Export-ClientsFile })

# Import clients
$Script:BtnImport.Add_Click({ Import-ClientsFile })

# Rafraichissement CmbDHCPNic a l'ouverture
$Script:CmbDHCPNic.Add_DropDownOpened({
    $cur = $Script:CmbDHCPNic.SelectedItem
    $Script:CmbDHCPNic.Items.Clear()
    foreach ($n in (Get-NICList)) { [void]$Script:CmbDHCPNic.Items.Add($n) }
    if ($cur -and $Script:CmbDHCPNic.Items.Contains($cur)) {
        $Script:CmbDHCPNic.SelectedItem = $cur
    } elseif ($Script:CmbDHCPNic.Items.Count -gt 0) {
        $Script:CmbDHCPNic.SelectedIndex = 0
    }
})

# Appliquer DHCP directement sur la NIC selectionnee (sans sauvegarder de profil)
$Script:BtnApplyDHCP.Add_Click({
    $nic = $Script:CmbDHCPNic.SelectedItem
    if (-not $nic) { Set-Status "Selectionnez une carte reseau." '#CA5010'; return }
    $res = [System.Windows.MessageBox]::Show(
        "Appliquer DHCP sur '$nic' ?`nLa configuration IP statique actuelle sera remplacee.",
        'Confirmer DHCP', [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question)
    if ($res -ne 'Yes') { return }
    try {
        Set-NetIPInterface -InterfaceAlias $nic -Dhcp Enabled -ErrorAction Stop
        Set-DnsClientServerAddress -InterfaceAlias $nic -ResetServerAddresses -ErrorAction Stop
        Set-Status "DHCP applique sur $nic." '#107C10'
        Update-NicInfoBar $nic
    } catch {
        # Fallback netsh si les cmdlets echouent
        try {
            netsh interface ip set address name="$nic" source=dhcp | Out-Null
            netsh interface ip set dns name="$nic" source=dhcp | Out-Null
            Set-Status "DHCP applique sur $nic." '#107C10'
            Update-NicInfoBar $nic
        } catch {
            Set-Status "Echec DHCP sur $nic : $($_.Exception.Message)" '#C50F1F'
        }
    }
})

# Mise a jour disponible
$Script:RollbackLabel.Add_MouseLeftButtonUp({ Invoke-Rollback })

$Script:UpdateLabel.Add_MouseLeftButtonUp({
    $res = [System.Windows.MessageBox]::Show(
        "NetSwitch Pro v$($Script:UpdateVer) est disponible.`n`nInstaller maintenant ?`n(L'appli se ferme et redemarrage automatiquement.)",
        'Mise a jour', [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Information)
    if ($res -eq 'Yes') { Install-Update }
    else { Start-Process $Script:UpdateUrl }
})

# Raccourcis clavier : Ctrl+S = Enregistrer | Entree = Appliquer
# Rebuild complet quand la fenetre est affichee pour la premiere fois (garantit rendu correct des groupes)
$window.Add_Loaded({ Rebuild-ClientPanel })

$window.Add_PreviewKeyDown({
    param($sender, $e)
    if ($Script:FormPanel.Visibility -ne 'Visible') { return }
    $mods = [System.Windows.Input.Keyboard]::Modifiers
    if ($e.Key -eq [System.Windows.Input.Key]::S -and
        $mods -eq [System.Windows.Input.ModifierKeys]::Control) {
        $e.Handled = $true
        $Script:BtnSave.RaiseEvent(
            [System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
        return
    }
    if ($e.Key -eq [System.Windows.Input.Key]::Return -and
        $mods -eq [System.Windows.Input.ModifierKeys]::None) {
        $focused = [System.Windows.Input.FocusManager]::GetFocusedElement($Script:MainWindow)
        if ($focused -is [System.Windows.Controls.TextBox] -and $focused.AcceptsReturn) { return }
        $e.Handled = $true
        $Script:BtnApply.RaiseEvent(
            [System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    }
})

# Fermeture : minimiser dans le tray au lieu de quitter
$window.Add_Closing({
    param($sender, $e)
    if (-not $Script:ReallyClosing) {
        $e.Cancel = $true
        $Script:MainWindow.Hide()
        $Script:TrayIcon.ShowBalloonTip(
            2500, 'NetSwitch Pro',
            "NetSwitch Pro continue en arriere-plan.`nDouble-cliquez sur l'icone pour rouvrir.",
            [System.Windows.Forms.ToolTipIcon]::Info)
    } else {
        # Nettoyage runspaces
        if ($Script:UpdateTimer) { $Script:UpdateTimer.Stop() }
        if ($Script:DlTimer)     { $Script:DlTimer.Stop()     }
        try { if ($Script:UpdatePS) { $Script:UpdatePS.Dispose() } } catch { }
        try { if ($Script:UpdateRS) { $Script:UpdateRS.Dispose() } } catch { }
        try { if ($Script:DlPS)     { $Script:DlPS.Dispose()     } } catch { }
        try { if ($Script:DlRS)     { $Script:DlRS.Dispose()     } } catch { }
        if ($Script:TrayIcon) {
            $Script:TrayIcon.Visible = $false
            $Script:TrayIcon.Dispose()
        }
    }
})

# ==============================================================
#  LANCEMENT
# ==============================================================
[void]$window.ShowDialog()
