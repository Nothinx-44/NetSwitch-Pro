#Requires -Version 5.1
<#
.SYNOPSIS
    NetSwitch Pro v1.3.0 - Gestionnaire de profils reseau IP
.AUTHOR
    Nothinx-44  |  https://github.com/Nothinx-44/NetSwitch-Pro
.CHANGELOG
    v1.3.0 - Persistance rollback sur disque, timeout apply 10s, logs structures, architecture modulaire, IPv6 desactive systematiquement
#>

# ==============================================================
#  AUTO-ELEVATION UAC
# ==============================================================
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
        Read-Host "Appuyez sur Entree pour fermer"
    }
    break
}

# ==============================================================
#  CONSTANTES
# ==============================================================
$Script:Ver              = '1.3.0'
$Script:GHOwner          = 'Nothinx-44'
$Script:GHRepo           = 'NetSwitch-Pro'
$Script:DataDir          = Join-Path $env:APPDATA 'NetSwitchPro'
$Script:DataFile         = Join-Path $Script:DataDir 'clients.json'
$Script:HistoryFile      = Join-Path $Script:DataDir 'history.json'
$Script:GroupsFile       = Join-Path $Script:DataDir 'groups.json'
$Script:LastConfigFile   = Join-Path $Script:DataDir 'last_config.json'
$Script:LogFile          = Join-Path $Script:DataDir 'debug.log'
$Script:CurrentID        = $null
$Script:EditMode         = 'new'
$Script:Refreshing       = $false
$Script:ReallyClosing    = $false
$Script:TrayIcon         = $null
$Script:MainWindow       = $null
$Script:UpdateUrl        = $null
$Script:UpdateZipUrl     = $null
$Script:UpdateVer        = $null
$Script:UpdateTimer      = $null
$Script:UpdatePS         = $null
$Script:UpdateRS         = $null
$Script:UpdateHandle     = $null
$Script:DlTimer          = $null
$Script:DlPS             = $null
$Script:DlRS             = $null
$Script:DlHandle         = $null
$Script:Groups           = [System.Collections.Generic.List[string]]::new()
$Script:CollapsedGroups  = [System.Collections.Generic.HashSet[string]]::new()
$Script:SelectedClientID = $null
$Script:LastConfig       = $null

# Migration depuis l'ancien dossier
$Script:OldDataDir = Join-Path $env:APPDATA 'IPSwitch'
if ((Test-Path $Script:OldDataDir) -and -not (Test-Path $Script:DataDir)) {
    try { Copy-Item -Path $Script:OldDataDir -Destination $Script:DataDir -Recurse -Force } catch { }
}
if (-not (Test-Path $Script:DataDir)) {
    New-Item -ItemType Directory -Path $Script:DataDir -Force | Out-Null
}

# ==============================================================
#  MODULES
# ==============================================================
. "$PSScriptRoot\lib\Logger.ps1"
. "$PSScriptRoot\lib\Helpers.ps1"
. "$PSScriptRoot\lib\Persistence.ps1"
. "$PSScriptRoot\lib\Network.ps1"
. "$PSScriptRoot\lib\Tray.ps1"
. "$PSScriptRoot\lib\Updater.ps1"
. "$PSScriptRoot\lib\UI.ps1"

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
                                    <TextBlock Grid.Column="1" Text="&#x25BC;" FontSize="9"
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
                                    Content="&#x2192; DHCP"
                                    Style="{StaticResource BtnSmall}"
                                    Padding="10,5"
                                    Foreground="#00CFFF"
                                    BorderBrush="#0A3A5A"
                                    ToolTip="Appliquer DHCP sur la carte selectionnee (IPv6 desactive)"/>
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

                    <Border DockPanel.Dock="Top" Height="1"
                            Background="#1A4A1A" Margin="10,0,10,2"/>

                    <!-- Export / Import -->
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
                                <TextBlock x:Name="NicInfoBar" FontSize="11"
                                           Margin="2,5,0,0" TextWrapping="Wrap"
                                           Visibility="Collapsed"/>
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
                            <StackPanel Grid.Column="0" Orientation="Horizontal">
                                <Button x:Name="BtnDelete" Content="Supprimer"
                                        Style="{StaticResource BtnDanger}"
                                        Visibility="Collapsed"/>
                                <Button x:Name="BtnDuplicate" Content="Dupliquer"
                                        Style="{StaticResource BtnSecondary}"
                                        Margin="8,0,0,0" Visibility="Collapsed"
                                        ToolTip="Creer une copie de ce profil client"/>
                            </StackPanel>
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
                           Text="  &#x21A9; Rollback" ToolTip="Restaurer la configuration precedente"/>
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
if (-not $window) { throw [System.Exception]::new('XamlReader a renvoye null') }
$Script:MainWindow = $window

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
#  INITIALISATION
# ==============================================================
$Script:VersionLabel.Text = "v$($Script:Ver)"

$Script:Clients = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($item in @(Import-Clients)) { if ($item) { $Script:Clients.Add($item) } }

Import-Groups
Refresh-GroupCombo

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

# Restaure le dernier backup depuis le disque (survit aux redemarrages)
Load-LastConfigFromDisk
if ($Script:LastConfig) { $Script:RollbackLabel.Visibility = 'Visible' }

Refresh-List
Show-EmptyState
Update-LastApplied

$Script:SearchBox.Text       = '   Rechercher...'
$Script:SearchBox.Foreground = New-Brush '#2A5A2A'

Initialize-TrayIcon
Start-UpdateCheck
Write-Log "NetSwitch Pro v$($Script:Ver) demarre"

# ==============================================================
#  GESTIONNAIRES D'EVENEMENTS
# ==============================================================

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

$Script:BtnNewClient.Add_Click({
    $Script:SelectedClientID = $null
    Clear-Form
    Show-Form
    $Script:TxtName.Focus() | Out-Null
    Set-Status 'Nouveau client - remplissez le formulaire.'
})

$Script:BtnAddGroup.Add_Click({ Add-Group })

$Script:CmbNIC.Add_DropDownOpened({
    $cur = $Script:CmbNIC.SelectedItem
    $Script:CmbNIC.Items.Clear()
    foreach ($n in (Get-NICList)) { [void]$Script:CmbNIC.Items.Add($n) }
    if ($cur -and $Script:CmbNIC.Items.Contains($cur)) { $Script:CmbNIC.SelectedItem = $cur }
    elseif ($Script:CmbNIC.Items.Count -gt 0) { $Script:CmbNIC.SelectedIndex = 0 }
})

$Script:CmbNIC.Add_SelectionChanged({
    $sel = $Script:CmbNIC.SelectedItem
    if ($sel -and $Script:FormPanel.Visibility -eq 'Visible') { Update-NicInfoBar $sel }
})

$Script:BtnSave.Add_Click({
    try {
        $c = Build-FormClient
        if (-not $c) { return }
        Save-AndRefresh $c
        Set-Status "Client '$($c.Name)' enregistre." '#107C10'
    } catch {
        Write-Log "BtnSave: $($_.Exception.Message)" 'ERROR'
        Set-Status "ERREUR Enregistrer L$($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)" '#C50F1F'
    }
})

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
        $Script:MainWindow.Cursor = $null
        Write-Log "BtnApply: $($_.Exception.Message)" 'ERROR'
        Set-Status "ERREUR Appliquer L$($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)" '#C50F1F'
    }
})

$Script:BtnDelete.Add_Click({
    $name = $Script:TxtName.Text.Trim()
    $res  = [System.Windows.MessageBox]::Show(
        "Supprimer definitivement '$name' ?",
        'Confirmer', [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning)
    if ($res -ne 'Yes') { return }
    $newList = [System.Collections.Generic.List[PSCustomObject]]::new()
    $Script:Clients | Where-Object { $_.ID -ne $Script:CurrentID } | ForEach-Object { $newList.Add($_) }
    $Script:Clients = $newList
    Export-Clients $Script:Clients
    $Script:SelectedClientID = $null
    Refresh-List
    Show-EmptyState
    Set-Status "Client '$name' supprime."
})

$Script:BtnDuplicate.Add_Click({
    $src = $Script:Clients | Where-Object { $_.ID -eq $Script:CurrentID } | Select-Object -First 1
    if (-not $src) { return }
    $baseName = "Copie de $($src.Name)"
    $newName  = $baseName; $counter = 2
    while ($Script:Clients | Where-Object { $_.Name -eq $newName }) {
        $newName = "$baseName ($counter)"; $counter++
    }
    $Script:SelectedClientID = $null; $Script:EditMode = 'new'; $Script:CurrentID = $null
    $Script:TxtName.Text    = $newName
    $Script:TxtIP.Text      = $src.IP
    $Script:TxtMask.Text    = $src.Mask
    $Script:TxtGateway.Text = $src.Gateway
    $Script:TxtDNS1.Text    = $src.DNS1
    $Script:TxtDNS2.Text    = $src.DNS2
    $Script:TxtNotes.Text   = $src.Notes
    $Script:CmbNIC.SelectedItem      = $src.NIC
    $Script:BtnDelete.Visibility     = 'Collapsed'
    $Script:BtnDuplicate.Visibility  = 'Collapsed'
    $Script:FormTitle.Text           = "Nouveau client (copie)"
    Show-Form
    $Script:TxtName.Focus() | Out-Null
    $Script:TxtName.SelectAll()
    Set-Status "Copie de '$($src.Name)' - modifiez le nom puis enregistrez."
})

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

$Script:BtnExport.Add_Click({ Export-ClientsFile })
$Script:BtnImport.Add_Click({ Import-ClientsFile })

$Script:CmbDHCPNic.Add_DropDownOpened({
    $cur = $Script:CmbDHCPNic.SelectedItem
    $Script:CmbDHCPNic.Items.Clear()
    foreach ($n in (Get-NICList)) { [void]$Script:CmbDHCPNic.Items.Add($n) }
    if ($cur -and $Script:CmbDHCPNic.Items.Contains($cur)) { $Script:CmbDHCPNic.SelectedItem = $cur }
    elseif ($Script:CmbDHCPNic.Items.Count -gt 0) { $Script:CmbDHCPNic.SelectedIndex = 0 }
})

$Script:BtnApplyDHCP.Add_Click({
    $nic = $Script:CmbDHCPNic.SelectedItem
    if (-not $nic) { Set-Status "Selectionnez une carte reseau." '#CA5010'; return }
    $res = [System.Windows.MessageBox]::Show(
        "Appliquer DHCP sur '$nic' ?`nLa configuration IP statique actuelle sera remplacee.`nIPv6 sera desactive.",
        'Confirmer DHCP', [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question)
    if ($res -ne 'Yes') { return }
    Save-ConfigBackup $nic
    try {
        Set-NetIPInterface -InterfaceAlias $nic -Dhcp Enabled -ErrorAction Stop
        Set-DnsClientServerAddress -InterfaceAlias $nic -ResetServerAddresses -ErrorAction Stop
        Disable-NICIPv6 $nic
        $Script:RollbackLabel.Visibility = 'Visible'
        Set-Status "DHCP applique sur $nic (IPv6 desactive)." '#107C10'
        Update-NicInfoBar $nic
    } catch {
        try {
            netsh interface ip set address name="$nic" source=dhcp | Out-Null
            netsh interface ip set dns name="$nic" source=dhcp | Out-Null
            Disable-NICIPv6 $nic
            $Script:RollbackLabel.Visibility = 'Visible'
            Set-Status "DHCP applique sur $nic (IPv6 desactive)." '#107C10'
            Update-NicInfoBar $nic
        } catch {
            Write-Log "BtnApplyDHCP: $($_.Exception.Message)" 'ERROR'
            Set-Status "Echec DHCP sur $nic : $($_.Exception.Message)" '#C50F1F'
        }
    }
})

$Script:RollbackLabel.Add_MouseLeftButtonUp({ Invoke-Rollback })

$Script:UpdateLabel.Add_MouseLeftButtonUp({
    $res = [System.Windows.MessageBox]::Show(
        "NetSwitch Pro v$($Script:UpdateVer) est disponible.`n`nInstaller maintenant ?`n(L'appli se ferme et redemarrage automatiquement.)",
        'Mise a jour', [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Information)
    if ($res -eq 'Yes') { Install-Update }
    else { Start-Process $Script:UpdateUrl }
})

$window.Add_Loaded({ Rebuild-ClientPanel })

$window.Add_PreviewKeyDown({
    param($s, $e)
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

$window.Add_Closing({
    param($s, $e)
    if (-not $Script:ReallyClosing) {
        $e.Cancel = $true
        $Script:MainWindow.Hide()
        $Script:TrayIcon.ShowBalloonTip(
            2500, 'NetSwitch Pro',
            "NetSwitch Pro continue en arriere-plan.`nDouble-cliquez sur l'icone pour rouvrir.",
            [System.Windows.Forms.ToolTipIcon]::Info)
    } else {
        if ($Script:UpdateTimer) { $Script:UpdateTimer.Stop() }
        if ($Script:DlTimer)     { $Script:DlTimer.Stop()     }
        try { if ($Script:UpdatePS) { $Script:UpdatePS.Dispose() } } catch {}
        try { if ($Script:UpdateRS) { $Script:UpdateRS.Dispose() } } catch {}
        try { if ($Script:DlPS)     { $Script:DlPS.Dispose()     } } catch {}
        try { if ($Script:DlRS)     { $Script:DlRS.Dispose()     } } catch {}
        if ($Script:TrayIcon) {
            $Script:TrayIcon.Visible = $false
            $Script:TrayIcon.Dispose()
        }
        Write-Log "NetSwitch Pro v$($Script:Ver) ferme"
    }
})

# ==============================================================
#  LANCEMENT
# ==============================================================
[void]$window.ShowDialog()
