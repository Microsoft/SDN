#
# Copyright 2019 (c) Microsoft Corporation.
# Licensed under the MIT license.
#

$Global:BaseDir = "c:\k"
$Global:GithubSDNRepository = 'Microsoft/SDN'
$Global:GithubSDNBranch = 'master'
$Global:NetworkName = "cbr0"
$Global:NetworkMode = "l2bridge"
$Global:DockerImageTag = "1809"
$Global:Configuration = @{}
$Global:MasterUsername = "localadmin"
$Global:NanoserverImage = "mcr.microsoft.com/windows/nanoserver:1809"
$Global:ServercoreImage = "mcr.microsoft.com/windows/servercore:ltsc2019"
$Global:Cri = "dockerd"

function GetKubeConfig()
{
    return [io.Path]::Combine($Global:BaseDir, "config");
}

function KubeConfigExists()
{
    return Test-Path $(GetKubeConfig)
}

function DownloadKubeConfig($Master, $User=$Global:MasterUsername)
{
    $kc = GetKubeConfig
    Write-Host "Downloading Kubeconfig from ${Master}:~/.kube/config to $kc"
    scp -o StrictHostKeyChecking=no ${User}@${Master}:~/.kube/config $kc
}

function GetLogDir()
{
    return [io.Path]::Combine($Global:BaseDir, "logs");
}

function GetCniPath()
{
    return [io.Path]::Combine($Global:BaseDir, "cni");
}

function GetCniConfigPath()
{
    return [io.Path]::Combine($(GetCniPath), "config");
}

function GetCniConfig()
{
    return [io.Path]::Combine($(GetCniConfigPath), "cni.conf");
}

function GetKubeadmConfig()
{
    return [io.Path]::Combine($Global:BaseDir, ".kubeadmconfig")
}

function GetFlannelNetConf()
{
    return [io.Path]::Combine($Global:BaseDir, "net-conf.json")
}

function HasKubeadmConfig()
{
    $kc = $(GetKubeAdmConfig)
    return (Test-Path $kc)
}

function WriteKubeadmConfig()
{
    $Global:ClusterConfiguration | ConvertTo-Json -Depth 10 | Out-File -FilePath $(GetKubeAdmConfig) 
}

#  
# Reads Kube
#
#
function ReadKubeadmConfig()
{
    if (HasKubeadmConfig)
    {
        $Global:ClusterConfiguration = ConvertFrom-Json ((Get-Content $(GetKubeAdmConfig)) | out-string)
        LoadGlobals
    }
}

function InitHelper()
{
    LoadGlobals
    ValidateConfig
    CreateDirectory $(GetLogDir)
    Install-7Zip
}

function LoadGlobals()
{
    $Global:GithubSDNRepository = $Global:ClusterConfiguration.Install.Source.SDNRepo
    $Global:GithubSDNBranch = $Global:ClusterConfiguration.Install.Source.SDNBranch
    $Global:BaseDir = $Global:ClusterConfiguration.Install.Destination
    $Global:MasterUsername = $Global:ClusterConfiguration.Kubernetes.Master.Username
    $Global:MasterIp = $Global:ClusterConfiguration.Kubernetes.Master.IpAddress
    $Global:NanoserverImage = $Global:ClusterConfiguration.Cri.Images.Nanoserver
    $Global:ServercoreImage = $Global:ClusterConfiguration.Cri.Images.ServerCore
    $Global:Cni = $Global:ClusterConfiguration.Cni.Name
    $Global:Release = $Global:ClusterConfiguration.Kubernetes.Source.Release
    $Global:InterfaceName = $Global:ClusterConfiguration.Cni.InterfaceName
    $Global:NetworkPlugin =$Global:ClusterConfiguration.Cni.Plugin.Name
    $Global:Cri = $Global:ClusterConfiguration.Cri.Name
    $Global:ClusterCIDR = $Global:ClusterConfiguration.Kubernetes.Network.ClusterCidr
    $Global:ServiceCIDR = $Global:ClusterConfiguration.Kubernetes.Network.ServiceCidr

    $Global:KubeproxyGates = $Global:ClusterConfiguration.Kubernetes.KubeProxy.Gates
    $Global:DsrEnabled = $false;
    if ($Global:ClusterConfiguration.Kubernetes.KubeProxy -and $Global:ClusterConfiguration.Kubernetes.KubeProxy.Gates -contains "WinDSR=true")
    {
        $Global:DsrEnabled = $true;
    }

    if ((Get-NetAdapter -InterfaceAlias "vEthernet ($Global:InterfaceName)" -ErrorAction SilentlyContinue))   
    {
        $Global:ManagementIp = Get-InterfaceIpAddress -InterfaceName "vEthernet ($Global:InterfaceName)"
        $Global:ManagementSubnet = Get-MgmtSubnet -InterfaceName "vEthernet ($Global:InterfaceName)"
    }
    elseif ((Get-NetAdapter -InterfaceAlias "$Global:InterfaceName" -ErrorAction SilentlyContinue))        
    {
        $Global:ManagementIp = Get-InterfaceIpAddress -InterfaceName "$Global:InterfaceName"
        $Global:ManagementSubnet = Get-MgmtSubnet -InterfaceName "$Global:InterfaceName"
    }
    else {
        throw "$Global:InterfaceName doesn't exist"
    }
}

function ValidateConfig()
{
    if ($Global:Cni -ne "flannel")
    {
        throw "$Global:Cni not yet supported"
    }
    
    if ($Global:NetworkPlugin -ne "vxlan" -and $Global:NetworkPlugin -ne "bridge")
    {
        throw "$Global:NetworkPlugin is not yet supported"
    }

    if ($Global:Cri -ne "dockerd" -and $Global:Cri -ne "containerd")
    {
        throw "$Global:Cri is not yet supported"
    }
}

function PrintConfig()
{
    ######################################################################################################################

    Write-Host "############################################"
    Write-Host "User Input "
    Write-Host "Destination       : $Global:BaseDir"
    Write-Host "Master            : $Global:MasterIp"
    Write-Host "InterfaceName     : $Global:InterfaceName"
    Write-Host "Cri               : $Global:Cri"
    Write-Host "Cni               : $Global:Cni"
    Write-Host "NetworkPlugin     : $Global:NetworkPlugin" 
    Write-Host "Release           : $Global:Release"
    Write-Host "MasterIp          : $Global:MasterIp"
    Write-Host "ManagementIp      : $Global:ManagementIp"
    Write-Host "ManagementSubnet  : $Global:ManagementSubnet"
    Write-Host "############################################"

    ######################################################################################################################
}

function Cleanup()
{
    
}


###################################################################################################

function Expand-GZip($infile, $outfile = ($infile -replace '\.gz$',''))
{
    # From https://social.technet.microsoft.com/Forums/en-US/5aa53fef-5229-4313-a035-8b3a38ab93f5/unzip-gz-files-using-powershell?forum=winserverpowershell
    $input = New-Object System.IO.FileStream $inFile, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read)
    $output = New-Object System.IO.FileStream $outFile, ([IO.FileMode]::Create), ([IO.FileAccess]::Write), ([IO.FileShare]::None)
    $gzipStream = New-Object System.IO.Compression.GzipStream $input, ([IO.Compression.CompressionMode]::Decompress)
    try {
        if (!$input -or !$output -or !$gzipStream)
        {
            throw "Failed to Unzip the archive"
        }
        $buffer = New-Object byte[](1024)
        while($true){
            $read = $gzipstream.Read($buffer, 0, 1024)
            if ($read -le 0){break}
            $output.Write($buffer, 0, $read)
        }
    } finally {
        $gzipStream.Close()
        $output.Close()
        $input.Close()
    }
}

function Install-7Zip()
{
    # ask to install 7zip, if it's not already installed
    if (-not (Get-Command Expand-7Zip -ErrorAction Ignore)) {
        Install-Package -Scope CurrentUser -Force 7Zip4PowerShell -Verbose
        if(-not $?) {
            Write-Error "Failed to install package"
            Exit 1
        }
    }
}

function DownloadAndExtractTarGz($url, $dstPath)
{
    $tmpTarGz = New-TemporaryFile | Rename-Item -NewName { $_ -replace 'tmp$', 'tar.gz' } -PassThru
    $tmpTar = New-TemporaryFile | Rename-Item -NewName { $_ -replace 'tmp$', 'tar' } -PassThru
    DownloadFile -Url $url -Destination $tmpTarGz.FullName -Force
    #Invoke-WebRequest $url -o $tmpTarGz.FullName
    Expand-GZip $tmpTarGz.FullName $tmpTar.FullName
    Expand-7Zip $tmpTar.FullName $dstPath
    Remove-Item $tmpTarGz.FullName,$tmpTar.FullName
}

function DownloadAndExtractZip($url, $dstPath)
{
    $tmpZip = New-TemporaryFile | Rename-Item -NewName { $_ -replace 'tmp$', 'zip' } -PassThru
    Invoke-WebRequest $url -o $tmpZip.FullName
    Expand-Archive $tmpZip.FullName $dstPath
    Remove-Item $tmpZip.FullName
}
function Assert-FileExists($file) {
    if(-not (Test-Path $file)) {
        Write-Error "$file is missing, build and place the binary before continuing."
        Exit 1
    }
}
function DownloadFile()
{
    param(
    [parameter(Mandatory = $true)] $Url,
    [parameter(Mandatory = $true)] $Destination,
    [switch] $Force
    )

    if (!$Force.IsPresent -and (Test-Path $Destination))
    {
        Write-Host "[DownloadFile] File $Destination already exists."
        return
    }

    $secureProtocols = @() 
    $insecureProtocols = @([System.Net.SecurityProtocolType]::SystemDefault, [System.Net.SecurityProtocolType]::Ssl3) 
    foreach ($protocol in [System.Enum]::GetValues([System.Net.SecurityProtocolType])) 
    { 
        if ($insecureProtocols -notcontains $protocol) 
        { 
            $secureProtocols += $protocol 
        } 
    } 
    [System.Net.ServicePointManager]::SecurityProtocol = $secureProtocols
    
    try {
        (New-Object System.Net.WebClient).DownloadFile($Url,$Destination)
        Write-Host "Downloaded [$Url] => [$Destination]"
    } catch {
        Write-Error "Failed to download $Url"
	    throw
    }
}

function CleanupOldNetwork($NetworkName, $ClearDocker = $true)
{
    $hnsNetwork = Get-HnsNetwork | ? Name -EQ $NetworkName.ToLower()

    if ($hnsNetwork)
    {
        if($ClearDocker) {
            # Cleanup all containers
            CleanupContainers
        }

        Write-Host "Cleaning up old HNS network found"
        Write-Host ($hnsNetwork | ConvertTo-Json -Depth 10) 
        Remove-HnsNetwork $hnsNetwork
    }
}

function CleanupPolicyList()
{
    $out = Get-HnsPolicyList 
    if ($out)
    {
        $out | Remove-HnsPolicyList
    }

}
function CreateExternalNetwork
{
    Param([ValidateSet("l2bridge", "overlay",IgnoreCase = $true)] 
    [parameter(Mandatory = $true)] $NetworkMode,
    [parameter(Mandatory = $true)] $InterfaceName)

    if ($NetworkMode -eq "l2bridge")
    {
        if(!(Get-HnsNetwork | ? Name -EQ "External"))
        {
            # Create a L2Bridge network to trigger a vSwitch creation. Do this only once as it causes network blip
            New-HNSNetwork -Type $NetworkMode -AddressPrefix "192.168.255.0/30" -Gateway "192.168.255.1" -Name "External" -AdapterName "$InterfaceName"
        }
    }
    elseif ($NetworkMode -eq "overlay")
    {
        # Open firewall for Overlay traffic
        New-NetFirewallRule -Name OverlayTraffic4789UDP -Description "Overlay network traffic UDP" -Action Allow -LocalPort 4789 -Enabled True -DisplayName "Overlay Traffic 4789 UDP" -Protocol UDP -ErrorAction SilentlyContinue
        # Create a Overlay network to trigger a vSwitch creation. Do this only once
        if(!(Get-HnsNetwork | ? Name -EQ "External"))
        {
            New-HNSNetwork -Type $NetworkMode -AddressPrefix "192.168.255.0/30" -Gateway "192.168.255.1" -Name "External" -AdapterName "$InterfaceName" -SubnetPolicies @(@{Type = "VSID"; VSID = 9999; }) 
        }
    }
}

function RemoveExternalNetwork
{
    $network = (Get-HnsNetwork | ? Name -EQ "External")
    if ($network)
    {
        $network | remove-hnsnetwork
    }

}
function WaitForNetwork($NetworkName)
{
    $startTime = Get-Date
    $waitTimeSeconds = 60

    # Wait till the network is available
    while ($true)
    {
        $timeElapsed = $(Get-Date) - $startTime
        if ($($timeElapsed).TotalSeconds -ge $waitTimeSeconds)
        {
            throw "Fail to create the network[($NetworkName)] in $waitTimeSeconds seconds"
        }
        if ((Get-HnsNetwork | ? Name -EQ $NetworkName.ToLower()))
        {
            break;
        }
        Write-Host "Waiting for the Network ($NetworkName) to be created by flanneld"
        Start-Sleep 5
    }
}

function IsNodeRegistered()
{
    kubectl.exe get nodes/$($(hostname).ToLower())
    return (!$LASTEXITCODE)
}

function WaitForNodeRegistration($TimeoutSeconds)
{
    $startTime = Get-Date
    while ($true)
    {
        $timeElapsed = $(Get-Date) - $startTime
        if ($($timeElapsed).TotalSeconds -ge $TimeoutSeconds)
        {
            throw "Fail to register node with master] in $TimeoutSeconds seconds"
        }
        if (IsNodeRegistered)
        {
            break;
        }
        Write-Host "Waiting for the node [$(hostname)] to be registered with $Global:MasterIp"
        Start-Sleep 1
    }
}


function WaitForServiceRunningState($ServiceName, $TimeoutSeconds)
{
    $startTime = Get-Date
    while ($true)
    {
        Write-Host "Waiting for service [$ServiceName] to be running"
        $timeElapsed = $(Get-Date) - $startTime
        if ($($timeElapsed).TotalSeconds -ge $TimeoutSeconds)
        {
            throw "Service [$ServiceName] failed to stay in Running state in $TimeoutSeconds seconds"
        }
        if ((Get-Service $ServiceName).Status -eq "Running")
        {
            break;
        }
        Start-Service -Name $ServiceName -ErrorAction SilentlyContinue | Out-Null
        Start-Sleep 1
    }
}



function DownloadCniBinaries($NetworkMode, $CniPath)
{
    Write-Host "Downloading CNI binaries for $NetworkMode to $CniPath"
    CreateDirectory $CniPath\config
    DownloadAndExtractTarGz "https://github.com/containernetworking/plugins/releases/download/v0.8.2/cni-plugins-windows-amd64-v0.8.2.tgz" "$CniPath"

    if ($Global:Cri -eq "containerd")
    {
        # TODO: containerd - URL parameters needed
        DownloadFile -Url "https://github.com/microsoft/windows-container-networking/raw/master/example/flannel_$NetworkMode.conf" -Destination $CniPath\config\cni.conf
        DownloadFile  "https://github.com/microsoft/windows-container-networking/releases/download/v0.2.0/windows-container-networking-cni-amd64-v0.2.0.zip" -Destination "$env:TEMP\windows-container-networking-cni-amd64-v0.2.0.zip"
        Expand-Archive -Path "$env:TEMP\windows-container-networking-cni-amd64-v0.2.0.zip" -DestinationPath $CniPath -Force
    }
    else {
        DownloadFile -Url "https://github.com/$Global:GithubSDNRepository/raw/$Global:GithubSDNBranch/Kubernetes/flannel/$NetworkMode/cni/config/cni.conf" -Destination $CniPath\config\cni.conf
    }
}


function DownloadFlannelBinaries()
{
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string] $Release = "0.11.0",
        [string] $Destination = "c:\flannel"
    )

    Write-Host "Downloading Flannel binaries"
    DownloadFile -Url  "https://github.com/coreos/flannel/releases/download/v${Release}/flanneld.exe" -Destination $Destination\flanneld.exe 
}

function GetKubeFlannelPath()
{
    return "c:\etc\kube-flannel"
}

function InstallFlannelD()
{
    param(
    [Parameter(Mandatory = $false, Position = 0)]
    [string] $Destination = "c:\flannel",
    [Parameter(Mandatory = $true)][string] $InterfaceIpAddress
    )
    
    Write-Host "Installing FlannelD Service"
    $logDir = [io.Path]::Combine($(GetLogDir), "flanneld");
    CreateDirectory $logDir
    $log = [io.Path]::Combine($logDir, "flanneldsvc.log");

    DownloadFile -Url  "https://github.com/$Global:GithubSDNRepository/raw/$Global:GithubSDNBranch/Kubernetes/flannel/$Global:NetworkMode/net-conf.json" -Destination $(GetFlannelNetConf)
    CreateDirectory $(GetKubeFlannelPath)
    copy $Global:BaseDir\net-conf.json $(GetKubeFlannelPath)

    $flanneldArgs = @(
        "$Destination\flanneld.exe",
        "--kubeconfig-file=$(GetKubeConfig)",
        "--iface=$InterfaceIpAddress",
        "--ip-masq=1",
        "--kube-subnet-mgr=1"
    )

    $service = Get-Service FlannelD -ErrorAction SilentlyContinue
    if (!$service)
    {
        $nodeName = (hostname).ToLower()
        CreateService -ServiceName FlannelD -CommandLine $flanneldArgs `
            -LogFile "$log" -EnvVaribles @{NODE_NAME = "$nodeName";}    
    }
}

function UnInstallFlannelD()
{
    RemoveService -ServiceName FlannelD
    Remove-Item $(GetKubeFlannelPath) -Force -ErrorAction SilentlyContinue
}

function StartFlanneld()
{
    $service = Get-Service -Name FlannelD -ErrorAction SilentlyContinue
    if (!$service)
    {
        throw "FlannelD service not installed"
    }
    Start-Service FlannelD -ErrorAction Stop
    WaitForServiceRunningState -ServiceName FlannelD  -TimeoutSeconds 30
}

function GetSourceVip($NetworkName)
{
    $sourceVipJson = [io.Path]::Combine($Global:BaseDir,  "sourceVip.json")
    $sourceVipRequest = [io.Path]::Combine($Global:BaseDir,  "sourceVipRequest.json")

    $hnsNetwork = Get-HnsNetwork | ? Name -EQ $NetworkName.ToLower()
    $subnet = $hnsNetwork.Subnets[0].AddressPrefix

    $ipamConfig = @"
        {"cniVersion": "0.2.0", "name": "vxlan0", "ipam":{"type":"host-local","ranges":[[{"subnet":"$subnet"}]],"dataDir":"/var/lib/cni/networks"}}
"@

    $ipamConfig | Out-File $sourceVipRequest

    pushd  
    $env:CNI_COMMAND="ADD"
    $env:CNI_CONTAINERID="dummy"
    $env:CNI_NETNS="dummy"
    $env:CNI_IFNAME="dummy"
    $env:CNI_PATH=$(GetCniPath) #path to host-local.exe

    cd $env:CNI_PATH
    Get-Content $sourceVipRequest | .\host-local.exe | Out-File $sourceVipJson
    $sourceVipJSONData = Get-Content $sourceVipJson | ConvertFrom-Json 

    Remove-Item env:CNI_COMMAND
    Remove-Item env:CNI_CONTAINERID
    Remove-Item env:CNI_NETNS
    Remove-Item env:CNI_IFNAME
    Remove-Item env:CNI_PATH
    popd

    return $sourceVipJSONData.ip4.ip.Split("/")[0]
}

function Get-InterfaceIpAddress()
{
    Param (
        [Parameter(Mandatory=$false)] [String] $InterfaceName = "Ethernet"
    )
    return (Get-NetIPAddress -InterfaceAlias "$InterfaceName" -AddressFamily IPv4).IPAddress
}

function ConvertTo-DecimalIP
{
  param(
    [Parameter(Mandatory = $true, Position = 0)]
    [Net.IPAddress] $IPAddress
  )
  $i = 3; $DecimalIP = 0;
  $IPAddress.GetAddressBytes() | % {
    $DecimalIP += $_ * [Math]::Pow(256, $i); $i--
  }

  return [UInt32]$DecimalIP
}

function ConvertTo-DottedDecimalIP
{
  param(
    [Parameter(Mandatory = $true, Position = 0)]
    [Uint32] $IPAddress
  )

    $DottedIP = $(for ($i = 3; $i -gt -1; $i--)
    {
      $Remainder = $IPAddress % [Math]::Pow(256, $i)
      ($IPAddress - $Remainder) / [Math]::Pow(256, $i)
      $IPAddress = $Remainder
    })

    return [String]::Join(".", $DottedIP)
}

function ConvertTo-MaskLength
{
  param(
    [Parameter(Mandatory = $True, Position = 0)]
    [Net.IPAddress] $SubnetMask
  )
    $Bits = "$($SubnetMask.GetAddressBytes() | % {
      [Convert]::ToString($_, 2)
    } )" -replace "[\s0]"
    return $Bits.Length
}


function Get-MgmtSubnet
{
    Param (
        [Parameter(Mandatory=$false)] [String] $InterfaceName = "Ethernet"
    )
    $na = Get-NetAdapter -InterfaceAlias "$InterfaceName"  -ErrorAction Stop
    $addr = (Get-NetIPAddress -InterfaceAlias "$InterfaceName" -AddressFamily IPv4).IPAddress
    $mask = (Get-WmiObject Win32_NetworkAdapterConfiguration | ? InterfaceIndex -eq $($na.ifIndex)).IPSubnet[0]
    $mgmtSubnet = (ConvertTo-DecimalIP $addr) -band (ConvertTo-DecimalIP $mask)
    $mgmtSubnet = ConvertTo-DottedDecimalIP $mgmtSubnet
    return "$mgmtSubnet/$(ConvertTo-MaskLength $mask)"
}

function Get-MgmtDefaultGatewayAddress
{
    Param (
        [Parameter(Mandatory=$false)] [String] $InterfaceName = "Ethernet"
    )
    $na = Get-NetAdapter | ? Name -Like "vEthernet ($InterfaceName*"
    return  (Get-NetRoute -InterfaceAlias $na.ifAlias -DestinationPrefix "0.0.0.0/0").NextHop
}

function CreateDirectory($Path)
{
    if (!(Test-Path $Path))
    {
        md $Path
    }
}

function
Update-NetConfig
{
    Param(
        $NetConfig,
        $clusterCIDR,
        $NetworkName,
        [ValidateSet("l2bridge", "overlay",IgnoreCase = $true)] 
        [parameter(Mandatory = $true)] $NetworkMode
    )
    $jsonSampleConfig = '{
        "Network": "10.244.0.0/16",
        "Backend": {
          "name": "cbr0",
          "type": "host-gw"
        }
      }
    '
    $configJson =  ConvertFrom-Json $jsonSampleConfig
    $configJson.Network = $clusterCIDR
    $configJson.Backend.name = $NetworkName
    $configJson.Backend.type = "host-gw"

    if ($NetworkMode -eq "overlay")
    {
        $configJson.Backend.type = "vxlan"
    }
    if (Test-Path $NetConfig) {
        Clear-Content -Path $NetConfig
    }
    $outJson = (ConvertTo-Json $configJson -Depth 20)
    Add-Content -Path $NetConfig -Value $outJson
    Write-Host "Generated net-conf Config [$outJson]"
}

function
Update-CNIConfig
{
    Param(
        $CNIConfig,
        $clusterCIDR,
        $KubeDnsServiceIP,
        $serviceCIDR,
        $InterfaceName,
        $NetworkName,
        [ValidateSet("l2bridge", "overlay",IgnoreCase = $true)] [parameter(Mandatory = $true)] $NetworkMode
    )
    if ($NetworkMode -eq "l2bridge")
    {
        $jsonSampleConfig = '{
            "cniVersion": "0.2.0",
            "name": "<NetworkMode>",
            "type": "flannel",
            "capabilities": {
                "dns" : true
            },
            "delegate": {
               "type": "win-bridge",
                "policies" : [
                  {
                    "Name" : "EndpointPolicy", "Value" : { "Type" : "OutBoundNAT", "ExceptionList": [ "<ClusterCIDR>", "<ServerCIDR>", "<MgmtSubnet>" ] }
                  },
                  {
                    "Name" : "EndpointPolicy", "Value" : { "Type" : "ROUTE", "DestinationPrefix": "<ServerCIDR>", "NeedEncap" : true }
                  },
                  {
                    "Name" : "EndpointPolicy", "Value" : { "Type" : "ROUTE", "DestinationPrefix": "<MgmtIP>/32", "NeedEncap" : true }
                  }
                ]
              }
          }'
              #Add-Content -Path $CNIConfig -Value $jsonSampleConfig
          
              $configJson =  ConvertFrom-Json $jsonSampleConfig
              $configJson.name = $NetworkName
              $configJson.delegate.type = "win-bridge"
          
              $configJson.delegate.policies[0].Value.ExceptionList[0] = $clusterCIDR
              $configJson.delegate.policies[0].Value.ExceptionList[1] = $serviceCIDR
              $configJson.delegate.policies[0].Value.ExceptionList[2] = $Global:ManagementSubnet
          
              $configJson.delegate.policies[1].Value.DestinationPrefix  = $serviceCIDR
              $configJson.delegate.policies[2].Value.DestinationPrefix  = ($Global:ManagementIp + "/32")
    }
    elseif ($NetworkMode -eq "overlay")
    {
        $jsonSampleConfig = '{
            "cniVersion": "0.2.0",
            "name": "<NetworkMode>",
            "type": "flannel",
            "capabilities": {
                "dns" : true
            },
            "delegate": {
               "type": "win-overlay",
                "Policies" : [
                  {
                    "Name" : "EndpointPolicy", "Value" : { "Type" : "OutBoundNAT", "ExceptionList": [ "<ClusterCIDR>", "<ServerCIDR>" ] }
                  },
                  {
                    "Name" : "EndpointPolicy", "Value" : { "Type" : "ROUTE", "DestinationPrefix": "<ServerCIDR>", "NeedEncap" : true }
                  }
                ]
              }
          }'
              #Add-Content -Path $CNIConfig -Value $jsonSampleConfig
          
              $configJson =  ConvertFrom-Json $jsonSampleConfig
              $configJson.name = $NetworkName
              $configJson.type = "flannel"
              $configJson.delegate.type = "win-overlay"
          
              $configJson.delegate.Policies[0].Value.ExceptionList[0] = $clusterCIDR
              $configJson.delegate.Policies[0].Value.ExceptionList[1] = $serviceCIDR
          
              $configJson.delegate.Policies[1].Value.DestinationPrefix  = $serviceCIDR
    }
    
    if (Test-Path $CNIConfig) {
        Clear-Content -Path $CNIConfig
    }

    $outJson = (ConvertTo-Json $configJson -Depth 20)
    Write-Host "Generated CNI Config [$outJson]"

    Add-Content -Path $CNIConfig -Value $outJson
}

function
Update-ContainerdCNIConfig
{
    Param(
        $CNIConfig,
        $clusterCIDR,
        $KubeDnsServiceIP,
        $serviceCIDR,
        $InterfaceName,
        $NetworkName,
        [ValidateSet("l2bridge", "overlay",IgnoreCase = $true)] [parameter(Mandatory = $true)] $NetworkMode
    )
    if ($NetworkMode -eq "l2bridge")
    {
        $jsonSampleConfig = '{
            "cniVersion": "0.2.0",
            "name": "<NetworkMode>",
            "type": "flannel",
            "capabilities": {
                "portMappings": true,
                "dns" : true
            },
            "delegate": {
               "type": "sdnbridge",
                "AdditionalArgs" : [
                  {
                    "Name" : "EndpointPolicy", "Value" : { "Type" : "OutBoundNAT", "Settings" : { "Exceptions": [ "<ClusterCIDR>", "<ServerCIDR>", "<MgmtSubnet>" ] } }
                  },
                  {
                    "Name" : "EndpointPolicy", "Value" : { "Type" : "SDNROUTE", "Settings" : { "DestinationPrefix": "<ServerCIDR>", "NeedEncap" : true } }
                  },
                  {
                    "Name" : "EndpointPolicy", "Value" : { "Type" : "SDNROUTE", "Settings" : {  "DestinationPrefix": "<MgmtIP>/32", "NeedEncap" : true } }
                  }
                ]
              }
          }'

        $configJson =  ConvertFrom-Json $jsonSampleConfig
        $configJson.name = $NetworkName
        $configJson.delegate.type = "sdnbridge"

        $configJson.delegate.AdditionalArgs[0].Value.Settings.Exceptions[0] = $clusterCIDR
        $configJson.delegate.AdditionalArgs[0].Value.Settings.Exceptions[1] = $serviceCIDR
        $configJson.delegate.AdditionalArgs[0].Value.Settings.Exceptions[2] = $Global:ManagementSubnet
    
        $configJson.delegate.AdditionalArgs[1].Value.Settings.DestinationPrefix  = $serviceCIDR
        $configJson.delegate.AdditionalArgs[2].Value.Settings.DestinationPrefix  = ($Global:ManagementIp + "/32")
    }
    elseif ($NetworkMode -eq "overlay")
    {
        $jsonSampleConfig = '{
            "cniVersion": "0.2.0",
            "name": "<NetworkMode>",
            "type": "flannel",
            "capabilities": {
                "portMappings": true,
                "dns" : true
            },
            "delegate": {
               "type": "sdnoverlay",
                "AdditionalArgs" : [
                  {
                    "Name" : "EndpointPolicy", "Value" : { "Type" : "OutBoundNAT", "Settings" : { "Exceptions": [ "<ClusterCIDR>", "<ServerCIDR>" ] } }
                  },
                  {
                    "Name" : "EndpointPolicy", "Value" : { "Type" : "SDNROUTE", "Settings" : { "DestinationPrefix": "<ServerCIDR>", "NeedEncap" : true } }
                  }
                ]
              }
          }'
        #Add-Content -Path $CNIConfig -Value $jsonSampleConfig
    
        $configJson =  ConvertFrom-Json $jsonSampleConfig
        $configJson.name = $NetworkName
        $configJson.type = "flannel"
        $configJson.delegate.type = "sdnoverlay"
        
        #TODO containerd - schema bad
        $configJson.delegate.Policies[0].Value.Exceptions[0] = $clusterCIDR
        $configJson.delegate.Policies[0].Value.Exceptions[1] = $serviceCIDR
    
        $configJson.delegate.Policies[1].Value.DestinationPrefix  = $serviceCIDR
    }
    
    if (Test-Path $CNIConfig) {
        Clear-Content -Path $CNIConfig
    }

    $outJson = (ConvertTo-Json $configJson -Depth 20)
    Write-Host "Generated CNI Config [$outJson]"

    Add-Content -Path $CNIConfig -Value $outJson
}


function KillProcessByName($ProcessName)
{
    taskkill /im $ProcessName /f
}

function AllowFirewall($ProcessName)
{
    New-NetFirewallRule -DisplayName $ProcessName -Direction Inbound -Program $ProcessName -Action Allow
}

function RemoveFirewall($ProcessName)
{
    Remove-NetFirewallRule -DisplayName $ProcessName -ErrorAction SilentlyContinue
}

function CleanupContainers()
{
    docker ps -aq | foreach {docker rm $_ -f} 
}

function GetKubeletArguments()
{
    param
    (
        [parameter(Mandatory=$true)] [string] $KubeConfig,
        [parameter(Mandatory=$true)] [string] $KubeletConfig,
        [parameter(Mandatory=$true)] [string] $LogDir,
        [parameter(Mandatory=$true)] [string] $CniDir,
        [parameter(Mandatory=$true)] [string] $CniConf,
        [parameter(Mandatory=$true)] [string] $KubeDnsServiceIp,
        [parameter(Mandatory=$true)] [string] $NodeIp,
        [parameter(Mandatory = $false)] $KubeletFeatureGates = "",
        [parameter(Mandatory = $false)] [switch] $IsContainerd = $false
    )

    # TODO: containerd - windows 1903+ - parameterize pod-infra-container-image and default to premade image on MCR
    $kubeletArgs = @(
        $((get-command kubelet.exe -ErrorAction Stop).Source),
        "--node-labels=node-role.kubernetes.io/agent=,kubernetes.io/role=agent",
        "--hostname-override=$(hostname)",
        '--v=6',
        '--pod-infra-container-image=kubeletwin/pause',
        '--resolv-conf=""',
        '--enable-debugging-handlers', # Comment for Config
        "--cluster-dns=$KubeDnsServiceIp", # Comment for Config
        '--cluster-domain=cluster.local', # Comment for Config
        "--kubeconfig=$KubeConfig",
        '--hairpin-mode=promiscuous-bridge', # Comment for Config
        '--image-pull-progress-deadline=20m',
        '--cgroups-per-qos=false',
        "--log-dir=$LogDir",
        '--logtostderr=false',
        '--enforce-node-allocatable=""',
        '--network-plugin=cni',
        "--cni-bin-dir=$CniDir",
        "--cni-conf-dir=$CniConf",
        "--node-ip=$NodeIp"
    )

    if ($KubeletFeatureGates -ne "")
    {
        $kubeletArgs += "--feature-gates=$KubeletFeatureGates"
    }

    if ($IsContainerd) 
    {
       $kubeletArgs += @("--container-runtime=remote", "--container-runtime-endpoint=npipe:////./pipe/containerd-containerd")
    }

    $KubeletConfiguration = @{
        Kind = "KubeletConfiguration";
        apiVersion = "kubelet.config.k8s.io/v1beta1";
        ClusterDNS = @($KubeDnsServiceIp);
        ClusterDomain = "cluster.local";
        EnableDebuggingHandlers = $true;
        #ResolverConfig = "";
        HairpinMode = "promiscuous-bridge";
        # CgroupsPerQOS = $false;
        # EnforceNodeAllocatable = @("")
    }


    ConvertTo-Json -Depth 10 $KubeletConfiguration | Out-File -FilePath $KubeletConfig

    #$kubeletArgs += "--config=$KubeletConfig"  # UnComment for Config

    return $kubeletArgs
}

function GetProxyArguments()
{
    param
    (
        [parameter(Mandatory=$true)] [string] $KubeConfig,
        [parameter(Mandatory=$true)] [string] $KubeProxyConfig,
        [parameter(Mandatory=$true)] [string] $LogDir,
        [parameter(Mandatory=$false)] [switch] $IsDsr,
        [parameter(Mandatory=$true)] [string] $NetworkName,
        [parameter(Mandatory=$false)] [string] $SourceVip,
        [parameter(Mandatory=$true)] [string] $ClusterCIDR,
        [parameter(Mandatory = $false)] $ProxyFeatureGates = ""
    )

    $proxyArgs = @(
        (get-command kube-proxy.exe -ErrorAction Stop).Source,
        "--hostname-override=$(hostname)" # Comment for config
        '--v=4'
        '--proxy-mode=kernelspace'
        "--kubeconfig=$KubeConfig" # Comment for config
        "--network-name=$NetworkName" # Comment for config
        "--cluster-cidr=$ClusterCIDR" # Comment for config
        "--log-dir=$LogDir"
        '--logtostderr=false'
    )

    if ($ProxyFeatureGates -ne "")
    {
        $proxyArgs += "--feature-gates=$ProxyFeatureGates"
    }

    $KubeproxyConfiguration = @{
        Kind = "KubeProxyConfiguration";
        apiVersion = "kubeproxy.config.k8s.io/v1alpha1";
        hostnameOverride = $(hostname);
        clusterCIDR = $ClusterCIDR;
        clientConnection = @{
            kubeconfig = $KubeConfig
        };
        winkernel = @{
            enableDSR = ($ProxyFeatureGates -match "WinDSR=true");
            networkName = $NetworkName;
        };
    }

    if ($ProxyFeatureGates -match "WinDSR=true")
    {
        $proxyArgs +=  "--enable-dsr=true" # Comment for config
    }

    if ($SourceVip)
    {
        $proxyArgs +=  "--source-vip=$SourceVip" # Comment out for config

        $KubeproxyConfiguration.winkernel += @{
            sourceVip = $SourceVip;
        }
    }
    ConvertTo-Json -Depth 10 $KubeproxyConfiguration | Out-File -FilePath $KubeProxyConfig
    #$proxyArgs += "--config=$KubeProxyConfig" # UnComment for Config
    
    return $proxyArgs
}

function InstallKubelet()
{
    param
    (
        [parameter(Mandatory=$true)] [string] $KubeConfig,
        [parameter(Mandatory=$true)] [string] $CniDir,
        [parameter(Mandatory=$true)] [string] $CniConf,
        [parameter(Mandatory=$true)] [string] $KubeDnsServiceIp,
        [parameter(Mandatory=$true)] [string] $NodeIp,
        [parameter(Mandatory = $false)] $KubeletFeatureGates = "",
        [parameter(Mandatory = $false)] [switch] $IsContainerd = $false
    )

    Write-Host "Installing Kubelet Service"
    $kubeletConfig = [io.Path]::Combine($Global:BaseDir, "kubelet.conf")
    $logDir = [io.Path]::Combine($(GetLogDir), "kubelet")
    CreateDirectory $logDir 
    $log = [io.Path]::Combine($logDir, "kubeletsvc.log");

    # TODO - move away from service wrapper
    $kubeletArgs = GetKubeletArguments -KubeConfig $KubeConfig  `
                    -KubeletConfig $kubeletConfig `
                    -CniDir $CniDir -CniConf $CniConf   `
                    -KubeDnsServiceIp $KubeDnsServiceIp `
                    -NodeIp $NodeIp -KubeletFeatureGates $KubeletFeatureGates `
                    -LogDir $logDir -IsContainerd:$IsContainerd

    CreateService -ServiceName Kubelet -CommandLine $kubeletArgs -LogFile "$log"

    # Open firewall for 10250. Required for kubectl exec pod <>
    if (!(Get-NetFirewallRule -Name KubeletAllow10250 -ErrorAction SilentlyContinue ))
    {
        New-NetFirewallRule -Name KubeletAllow10250 -Description "Kubelet Allow 10250" -Action Allow -LocalPort 10250 -Enabled True -DisplayName "KubeletAllow10250" -Protocol TCP -ErrorAction Stop
    }
}

function UninstallKubelet()
{
    Write-Host "Uninstalling Kubelet Service"
    # close firewall for 10250
    $out = (Get-NetFirewallRule -Name KubeletAllow10250 -ErrorAction SilentlyContinue )
    if ($out)
    {
        Remove-NetFirewallRule $out
    }

    RemoveService -ServiceName Kubelet
}

function StartKubelet()
{
    $srv = Get-Service Kubelet -ErrorAction SilentlyContinue
    if (!$srv)
    {
        throw "Kubelet Service not installed"
    }

    if ($srv.Status -ne "Running")
    {
        Start-Service Kubelet -ErrorAction Stop
        WaitForServiceRunningState -ServiceName Kubelet  -TimeoutSeconds 5
    }
}

function InstallKubeProxy()
{
    param
    (
        [parameter(Mandatory=$true)] [string] $KubeConfig,
        [parameter(Mandatory=$false)] [switch] $IsDsr,
        [parameter(Mandatory=$true)] [string] $NetworkName,
        [parameter(Mandatory=$false)] [string] $SourceVip,
        [parameter(Mandatory=$true)] [string] $ClusterCIDR,
        [parameter(Mandatory = $false)] $ProxyFeatureGates = ""
    )

    $kubeproxyConfig = [io.Path]::Combine($Global:BaseDir, "kubeproxy.conf")
    $logDir = [io.Path]::Combine($(GetLogDir), "kube-proxy")
    CreateDirectory $logDir
    $log = [io.Path]::Combine($logDir, "kubproxysvc.log");

    # TODO - move away from service wrapper
    Write-Host "Installing Kubeproxy Service"
    $proxyArgs = GetProxyArguments -KubeConfig $KubeConfig  `
                    -KubeProxyConfig $kubeproxyConfig `
                    -IsDsr:$IsDsr.IsPresent -NetworkName $NetworkName   `
                    -SourceVip $SourceVip `
                    -ClusterCIDR $ClusterCIDR `
                    -ProxyFeatureGates $ProxyFeatureGates `
                    -LogDir $logDir
    
    CreateService -ServiceName Kubeproxy -CommandLine $proxyArgs `
        -LogFile "$log" 
}

function UninstallKubeProxy()
{
    Write-Host "Uninstalling Kubeproxy Service"
    RemoveService -ServiceName Kubeproxy
}
function StartKubeProxy()
{
    $service = Get-Service Kubeproxy -ErrorAction SilentlyContinue
    if (!$service)
    {
        throw "Kubeproxy service not installed"
    }
    if ($srv.Status -ne "Running")
    {
        Start-Service Kubeproxy -ErrorAction Stop
        WaitForServiceRunningState -ServiceName Kubeproxy  -TimeoutSeconds 5
    }
}

function RunLocally([string[]]$command)
{
    Write-Host "Starting $($command | Out-String)"
    $binary = ($command | Select -First 1)
    $arguments = ($command | select -Skip 1)
    if ($arguments)
    {
        Start-Process -FilePath $binary  -ArgumentList $arguments -NoNewWindow
    }
    else
    {
        Start-Process -FilePath $binary  -NoNewWindow
    }
}

function CreateService()
{
    param
    (
        [parameter(Mandatory=$true)] [string] $ServiceName,
        [parameter(Mandatory=$true)] [string[]] $CommandLine,
        [parameter(Mandatory=$true)] [string] $LogFile,
        [parameter(Mandatory=$false)] [Hashtable] $EnvVaribles = $null
    )
    $binary = CreateSCMService -ServiceName $ServiceName -CommandLine $CommandLine -LogFile $LogFile -EnvVaribles $EnvVaribles

    New-Service -name $ServiceName -binaryPathName $binary `
        -displayName $ServiceName -startupType Automatic    `
        -Description "$ServiceName Kubernetes Service" 

    Write-Host @" 
    ++++++++++++++++++++++++++++++++
    Successfully created the service
    ++++++++++++++++++++++++++++++++
    Service [$ServiceName]
    Cmdline [$binary] 
    Env     [$($EnvVaribles | ConvertTo-Json -Depth 10)]
    Log     [$LogFile]
    ++++++++++++++++++++++++++++++++
"@
}

function CreateSCMService()
{
    param
    (
        [parameter(Mandatory=$true)] [string] $ServiceName,
        [parameter(Mandatory=$true)] [string[]] $CommandLine,
        [parameter(Mandatory=$true)] [string] $LogFile,
        [parameter(Mandatory=$false)] [Hashtable] $EnvVaribles = $null
    )
    $Binary = $CommandLine[0].Replace("\", "\\");
    $Arguments = ($CommandLine | Select -Skip 1).Replace("\", "\\").Replace('"', '\"')
    $SvcBinary = "$Global:BaseDir\${ServiceName}Svc.exe"
    $LogFile = $LogFile.Replace("\", "\\")

    $envSrc = "";
    if ($EnvVaribles)
    {
        foreach ($key in $EnvVaribles.Keys)
        {
            $value = $EnvVaribles[$key];
            $envSrc += @"
            m_process.StartInfo.EnvironmentVariables["$key"] = "$value";
"@
        }
    }

    Write-Host "Create a SCMService Binary for [$ServiceName] [$CommandLine] => [$SvcBinary]"
    # reference: https://msdn.microsoft.com/en-us/magazine/mt703436.aspx
    $svcSource = @"
        using System;
        using System.IO;
        using System.ServiceProcess;
        using System.Diagnostics;
        using System.Runtime.InteropServices;
        using System.ComponentModel;

        public enum ServiceType : int {                                       
            SERVICE_WIN32_OWN_PROCESS = 0x00000010,
            SERVICE_WIN32_SHARE_PROCESS = 0x00000020,
        };                                                                    
        
        public enum ServiceState : int {                                      
            SERVICE_STOPPED = 0x00000001,
            SERVICE_START_PENDING = 0x00000002,
            SERVICE_STOP_PENDING = 0x00000003,
            SERVICE_RUNNING = 0x00000004,
            SERVICE_CONTINUE_PENDING = 0x00000005,
            SERVICE_PAUSE_PENDING = 0x00000006,
            SERVICE_PAUSED = 0x00000007,
        };                                                                    
          
        [StructLayout(LayoutKind.Sequential)]
        public struct ServiceStatus {
            public ServiceType dwServiceType;
            public ServiceState dwCurrentState;
            public int dwControlsAccepted;
            public int dwWin32ExitCode;
            public int dwServiceSpecificExitCode;
            public int dwCheckPoint;
            public int dwWaitHint;
        };     

        public class ScmService_$ServiceName : ServiceBase {
            private ServiceStatus m_serviceStatus;
            private Process m_process;
            private StreamWriter m_writer = null;
            public ScmService_$ServiceName() {
                ServiceName = "$ServiceName";
                CanStop = true;
                CanPauseAndContinue = false;
                
                m_writer = new StreamWriter("$LogFile");
                Console.SetOut(m_writer);
                Console.WriteLine("$Binary $ServiceName()");
            }

            ~ScmService_$ServiceName() {
                if (m_writer != null) m_writer.Dispose();
            }

            [DllImport("advapi32.dll", SetLastError=true)]
            private static extern bool SetServiceStatus(IntPtr handle, ref ServiceStatus serviceStatus);

            protected override void OnStart(string [] args) {
                EventLog.WriteEntry(ServiceName, "OnStart $ServiceName - $Binary $Arguments");
                m_serviceStatus.dwServiceType = ServiceType.SERVICE_WIN32_OWN_PROCESS; // Own Process
                m_serviceStatus.dwCurrentState = ServiceState.SERVICE_START_PENDING;
                m_serviceStatus.dwWin32ExitCode = 0;
                m_serviceStatus.dwWaitHint = 2000;
                SetServiceStatus(ServiceHandle, ref m_serviceStatus);

                try
                {
                    m_process = new Process();
                    m_process.StartInfo.UseShellExecute = false;
                    m_process.StartInfo.RedirectStandardOutput = true;
                    m_process.StartInfo.RedirectStandardError = true;
                    m_process.StartInfo.FileName = "$Binary";
                    m_process.StartInfo.Arguments = "$Arguments";
                    m_process.EnableRaisingEvents = true;
                    m_process.OutputDataReceived  += new DataReceivedEventHandler((s, e) => { Console.WriteLine(e.Data); });
                    m_process.ErrorDataReceived += new DataReceivedEventHandler((s, e) => { Console.WriteLine(e.Data); });

                    m_process.Exited += new EventHandler((s, e) => { 
                        Console.WriteLine("$Binary exited unexpectedly " + m_process.ExitCode);
                        if (m_writer != null) m_writer.Flush();
                        m_serviceStatus.dwCurrentState = ServiceState.SERVICE_STOPPED;
                        SetServiceStatus(ServiceHandle, ref m_serviceStatus);
                    });

                    $envSrc;
                    m_process.Start();
                    m_process.BeginOutputReadLine();
                    m_process.BeginErrorReadLine();
                    m_serviceStatus.dwCurrentState = ServiceState.SERVICE_RUNNING;
                    Console.WriteLine("OnStart - Successfully started the service ");
                } 
                catch (Exception e)
                {
                    Console.WriteLine("OnStart - Failed to start the service : " + e.Message);
                    m_serviceStatus.dwCurrentState = ServiceState.SERVICE_STOPPED;
                }
                finally
                {
                    SetServiceStatus(ServiceHandle, ref m_serviceStatus);
                    if (m_writer != null) m_writer.Flush();
                }
            }

            protected override void OnStop() {
                Console.WriteLine("OnStop $ServiceName");
                try 
                {
                    m_serviceStatus.dwCurrentState = ServiceState.SERVICE_STOPPED;
                    if (m_process != null)
                    {
                        m_process.Kill();
                        m_process.WaitForExit();
                        m_process.Close();
                        m_process.Dispose();
                        m_process = null;
                    }
                    Console.WriteLine("OnStop - Successfully stopped the service ");
                } 
                catch (Exception e)
                {
                    Console.WriteLine("OnStop - Failed to stop the service : " + e.Message);
                    m_serviceStatus.dwCurrentState = ServiceState.SERVICE_RUNNING;
                }
                finally
                {
                    SetServiceStatus(ServiceHandle, ref m_serviceStatus);
                    if (m_writer != null) m_writer.Flush();
                }
            }

            public static void Main() {
                System.ServiceProcess.ServiceBase.Run(new ScmService_$ServiceName());
            }
        }
"@

    Add-Type -TypeDefinition $svcSource -Language CSharp `
        -OutputAssembly $SvcBinary -OutputType ConsoleApplication   `
        -ReferencedAssemblies "System.ServiceProcess" -Debug:$false

    return $SvcBinary
}

function RemoveService()
{
    param
    (
        [parameter(Mandatory=$true)] [string] $ServiceName
    )
    $src = Get-Service -Name $ServiceName  -ErrorAction SilentlyContinue
    if ($src) {
        Stop-Service $src
        sc.exe delete $src;

        $wsrv = gwmi win32_service | ? Name -eq $ServiceName

        # Remove the temp svc binary
    }
}

function RegisterContainerDService()
{
    Param(
        $ContainerdPath = "containerd"
    )
    Assert-FileExists (Join-Path $Global:BaseDir\$ContainerdPath containerd.exe)

    Write-Host "Installing containerd as a service"

    $logDir = [io.Path]::Combine($(GetLogDir), "containerd");
    CreateDirectory $logDir
    $log = [io.Path]::Combine($logDir, "containerdsvc.log");

    $cdbinary = Join-Path $Global:BaseDir\$containerdPath containerd.exe
    $svc = Get-Service -Name containerd -ErrorAction SilentlyContinue

    $containerdArgs = @(
        "$cdbinary",
        "-config $Global:BaseDir\$ContainerdPath\config.toml"
    )

    $service = Get-Service ContainerD -ErrorAction SilentlyContinue
    # TODO - containerd - move away from service wrapper
    if (!$service)
    {
        $nodeName = (hostname).ToLower()
        CreateService -ServiceName ContainerD -CommandLine $containerdArgs `
            -LogFile "$log"    
    }
}

function IsContainerDUp()
{
    return get-childitem \\.\pipe\ | ?{ $_.name -eq "containerd-containerd" }
}

function StartContainerD()
{
    if(-not (IsContainerDUp)) {
        Write-Output "Starting containerd"
        Start-Service -Name "containerd"
        if(-not $?) {
            Write-Error "Unable to start containerd"
            Exit 1
        }
    }
}

function InstallLcow()
{
    Param(
        $Version = "v4.14.35-v0.3.9",
        $DestinationPath = "Linux Containers"
    )
    if(-not (Test-Path (Join-Path $Global:BaseDir\$DestinationPath kernel))) {
        DownloadAndExtractZip https://github.com/linuxkit/lcow/releases/download/$Version/release.zip  $Global:BaseDir\$DestinationPath
    }
}
function InstallContainerD()
{
    Param(
    $CrictlVersion = "v1.14.0",
    $RunhcsVersion = "v0.8.6",
    $DestinationPath = "containerd",
    $linuxSandboxImage = "k8s.gcr.io/pause:3.1",
    [Parameter(Mandatory=$true)] $downloadUrls
    )

    md $Global:BaseDir\$DestinationPath -ErrorAction SilentlyContinue
    # Add path to this PowerShell session immediately
    $env:path += ";$Global:BaseDir\$DestinationPath"
    # For persistent use after a reboot
    $existingMachinePath = [Environment]::GetEnvironmentVariable("Path",[System.EnvironmentVariableTarget]::Machine)
    [Environment]::SetEnvironmentVariable("Path", $existingMachinePath + ";$Global:BaseDir\$DestinationPath", [EnvironmentVariableTarget]::Machine)

    $cmd = get-command containerd.exe -ErrorAction SilentlyContinue
    if (!$cmd)
    {
        DownloadFile $downloadUrls.ContainerD -Destination "$Global:BaseDir\$DestinationPath\containerd.exe"
    }

    $cmd = get-command ctr.exe -ErrorAction SilentlyContinue
    if (!$cmd)
    {
        DownloadFile $downloadUrls.Ctr -Destination "$Global:BaseDir\$DestinationPath\ctr.exe"
    }

    $cmd = get-command crictl.exe -ErrorAction SilentlyContinue
    if (!$cmd)
    {
        DownloadAndExtractTarGz https://github.com/kubernetes-sigs/cri-tools/releases/download/$CrictlVersion/crictl-$CrictlVersion-windows-amd64.tar.gz $Global:BaseDir\$DestinationPath
        #TODO - containerd - move to generating template with containerd.exe config default instead of downloading it.
        #TODO - containerd - also align with runtimeHandlers used in test passes
        DownloadFile "https://github.com/nagiesek/cri/releases/download/windows/config.toml"  -Destination "$Global:BaseDir\$DestinationPath\config.toml"
        (Get-Content -Path "$Global:BaseDir\$DestinationPath\config.toml" -Raw).
            Replace('<INSTALLDIR>', $Global:BaseDir.Replace('\', '\\')).
            Replace('<CNIDIR>', $(GetCniPath).Replace('\', '\\')).
            Replace('<WINDOWSSANDBOXIMAGE>', $Global:NanoserverImage).
            Replace('<LINUXSANDBOXIMAGE>', $linuxSandboxImage) |
            Out-File -FilePath "$Global:BaseDir\$DestinationPath\config.toml" -Encoding ascii
        $Global:Configuration += @{
            InstallContainerd = $true;
        }
    }

    $cmd = get-command containerd-shim-runhcs-v1.exe -ErrorAction SilentlyContinue
    if (!$cmd)
    {
        DownloadFile $downloadUrls.ContainerdShim -Destination "$Global:BaseDir\$DestinationPath\containerd-shim-runhcs-v1.exe"
    }

    # TODO: containerd - remove unneeded code
    # $cmd = get-command runhcs.exe -ErrorAction SilentlyContinue
    # if (!$cmd)
    # {
    #     DownloadFile https://github.com/microsoft/hcsshim/releases/download/v0.8.6/runhcs.exe -Destination "$Global:BaseDir\$DestinationPath\runhcs.exe"
    # }
}


Function UpdateCrictlConfig() {
    # set crictl to access the configured container endpoint by default
    $crictlConfigDir = Join-Path  $env:USERPROFILE ".crictl"
    $crictlConfigPath = Join-Path $crictlConfigDir "crictl.yaml"

    if(Test-Path $crictlConfigPath) {
        return;
    }

    Write-Output "Updating crictl config"
    New-Item -ItemType Directory -Path $crictlConfigDir -Force > $null
@"
runtime-endpoint: npipe:\\\\.\pipe\containerd-containerd
image-endpoint: npipe:\\\\.\pipe\containerd-containerd
timeout: 0
debug: false
"@ | Out-File $crictlConfigPath
}
function UninstallContainerD()
{
    Param(
        $ContainerdPath = "containerd"
    )
    # If docker was already installed, do not uninstall it
    if ($Global:Configuration["InstallContainerd"] -eq $true)
    {
        RemoveService -ServiceName ContainerD
        Remove-Item $Global:BaseDir\$ContainerdPath
        # For persistent use after a reboot
        $existingMachinePath = [Environment]::GetEnvironmentVariable("Path",[System.EnvironmentVariableTarget]::Machine)
        $existingMachinePath = $existingMachinePath.Replace("$Global:BaseDir\$ContainerdPath", "")
        [Environment]::SetEnvironmentVariable("Path", $existingMachinePath, [EnvironmentVariableTarget]::Machine)
    }
}
function InstallDockerD()
{
    Param(
    [ValidateSet("docker")] [parameter(Mandatory = $false)] $Version = "docker",
    $DestinationPath
    ) 
    # Add path to this PowerShell session immediately
    $env:path += ";$env:ProgramFiles\Docker"
    # For persistent use after a reboot
    $existingMachinePath = [Environment]::GetEnvironmentVariable("Path",[System.EnvironmentVariableTarget]::Machine)
    [Environment]::SetEnvironmentVariable("Path", $existingMachinePath + ";$env:ProgramFiles\Docker", [EnvironmentVariableTarget]::Machine)

    $cmd = get-command docker.exe -ErrorAction SilentlyContinue
    if (!$cmd)
    {
        $dockerVersion = $Version
        DownloadFile  "https://master.dockerproject.org/windows/x86_64/${dockerVersion}.zip" -Destination "$env:TEMP\$dockerVersion.zip" 
        Expand-Archive -Path "$env:TEMP\$dockerVersion.zip" -DestinationPath $env:ProgramFiles -Force
        dockerd --register-service
        Start-Service Docker -ErrorAction Stop
        $Global:Configuration += @{
            InstallDocker = $true;
        }
        WriteKubeadmConfig
    }
}

function UninstallDockerD()
{
    # If docker was already installed, do not uninstall it
    if ($Global:Configuration["InstallDocker"] -eq $true)
    {
        RemoveService Docker
        Remove-Item $env:ProgramFiles\Docker
        # For persistent use after a reboot
        $existingMachinePath = [Environment]::GetEnvironmentVariable("Path",[System.EnvironmentVariableTarget]::Machine)
        $existingMachinePath = $existingMachinePath.Replace($env:ProgramFiles+ '\Docker;', "")
        [Environment]::SetEnvironmentVariable("Path", $existingMachinePath, [EnvironmentVariableTarget]::Machine)
    }
}

function InstallDockerImages()
{
    # Determine the tag
    $tag = $Global:DockerImageTag
    if (!(docker images $Global:NanoserverImage -q))
    {
        docker pull $Global:NanoserverImage
        if (!($LastExitCode -eq 0)) {
            throw "Failed to pull $Global:NanoserverImage"
        }
    }
    # TODO - container - windows 1903 - fix or remove as part of multiple OS version support
    #docker tag $Global:NanoserverImage mcr.microsoft.com/windows/nanoserver:latest
    if (!(docker images $Global:ServercoreImage -q))
    {
        docker pull $Global:ServercoreImage
        if (!($LastExitCode -eq 0)) {
            throw "Failed to pull $Global:ServercoreImage"
        }
    }
    # TODO - container - windows 1903 - fix or remove as part of multiple OS version support
    #docker tag $Global:ServercoreImage mcr.microsoft.com/windows/servercore:latest
    # docker tag $Global:ServercoreImage mcr.microsoft.com/windows/servercore:1809
}

function InstallPauseImage()
{
    # Prepare POD infra Images
    $infraPodImage=docker images kubeletwin/pause -q
    if (!$infraPodImage)
    {
        Write-Host "No infrastructure container image found. Building kubeletwin/pause image"
        pushd
        cd $Global:BaseDir
        # TODO - container - windows 1903 - fix or remove as part of multiple OS version support
        DownloadFile -Url "https://raw.githubusercontent.com/kubernetes-sigs/sig-windows-tools/master/cmd/wincat/Dockerfile" -Destination $Global:BaseDir\Dockerfile
        docker build -t kubeletwin/pause .
        popd
    }
}

function InstallKubernetesBinaries()
{
    Param(
    [parameter(Mandatory = $true)] $Source,
    $DestinationPath
    ) 

    $existingPath = [Environment]::GetEnvironmentVariable("Path", [System.EnvironmentVariableTarget]::Machine)

    # For current shell Path update
    $env:path += ";$DestinationPath\kubernetes\node\bin"
    # For Persistent across reboot
    [Environment]::SetEnvironmentVariable("Path", $existingPath + ";$DestinationPath\kubernetes\node\bin", [EnvironmentVariableTarget]::Machine)

    $env:KUBECONFIG = $(GetKubeConfig)
    [Environment]::SetEnvironmentVariable("KUBECONFIG", $(GetKubeConfig), [EnvironmentVariableTarget]::Machine)

    $Release = "1.14"
    if ($Source.Release)
    {
        $Release = $Source.Release
    }
    $Url = "https://dl.k8s.io/v${Release}/kubernetes-node-windows-amd64.tar.gz"
    if ($Source.Url)
    {
        $Url = $Source.Url
    }

    DownloadAndExtractTarGz -url $Url -dstPath $DestinationPath
}

function UninstallKubernetesBinaries()
{
    Param(
    $DestinationPath
    ) 
    Remove-Item Env:\KUBECONFIG -ErrorAction SilentlyContinue

    # For current shell Path update
    $existingPath = [Environment]::GetEnvironmentVariable("Path", [System.EnvironmentVariableTarget]::Machine)
    $existingPath = $existingPath.Replace($DestinationPath+'\kubernetes\node\bin;', "")
    # For Persistent across reboot
    [Environment]::SetEnvironmentVariable("Path", $existingPath, [EnvironmentVariableTarget]::Machine)
    Remove-Item $DestinationPath -Force -ErrorAction SilentlyContinue
}

function DownloadWinCniBinaries()
{
    Write-Host "Downloading CNI binaries"
    md $Global:BaseDir\cni\config -ErrorAction Ignore

    DownloadFile -Url "https://github.com/$Global:GithubSDNRepository/raw/$Global:GithubSDNBranch/Kubernetes/windows/cni/wincni.exe" -Destination $BaseDir\cni\wincni.exe
}

function InstallContainersRole()
{
    $feature = Get-WindowsFeature -Name Containers
    if (!$feature.Installed)
    {
        Install-WindowsFeature -Name Containers -IncludeAllSubFeature
    }
}

function InstallHypervRole()
{
    $feature = Get-WindowsFeature -Name Hyper-V
    if (!$feature.Installed)
    {
        Install-WindowsFeature -Name Hyper-V -IncludeAllSubFeature
    }
}

function DownloadDebugTools()
{

}

function ReadKubeClusterInfo()
{
    #$out = (kubectl.exe cluster-info dump)
    #$tmp = ($out |  findstr -i cluster-cidr)
    #$m = ($tmp | Select-String -Pattern '--cluster-cidr=(.*)",' -AllMatches).Matches
    #$ClusterCidr = ($m.Groups | select -Last 1).Value

    #$tmp = ($out |  findstr -i service-cluster-ip-range)
    #$m = ($tmp | Select-String -Pattern '--service-cluster-ip-range=(.*)",' -AllMatches).Matches
    #$ServiceCidr = ($m[0].Groups | select -Last 1).Value
    $KubeConfiguration = @{
        ClusterCIDR = GetClusterCidr;
        ServiceCIDR = GetServiceCidr;
        KubeDnsIp = GetKubeDnsServiceIp;
        NetworkName = $Global:NetworkName;
        NetworkMode = $Global:NetworkMode;
    }

    $Global:Configuration += @{
        Kube = $KubeConfiguration;
    }
    WriteKubeadmConfig
}

function GetKubeDnsServiceIp()
{
    $svc = ConvertFrom-Json $(kubectl.exe get services -n kube-system -o json | Out-String)
    $svc.Items | foreach { $i = $_; if ($i.Metadata.Name -match "dns") { return $i.spec.ClusterIP } }
}

function GetKubeNodes()
{
    kubectl.exe get nodes
}

function RemoveKubeNode()
{
    kubectl.exe delete node (hostname).ToLower()
}

function GetClusterCidr()
{
    return $Global:ClusterConfiguration.Kubernetes.Network.ClusterCidr
}

function GetServiceCidr()
{
    return $Global:ClusterConfiguration.Kubernetes.Network.ServiceCidr
}


function InstallCRI($cri)
{
    # Install CRI
    switch ($cri)
    {
        "dockerd" {
            # Setup Docker
            InstallDockerD
            InstallDockerImages
            InstallPauseImage
            break
        }

        "containerd" {

            InstallContainerD -downloadUrls $Global:ClusterConfiguration.Cri.DownloadUrls
            InstallLcow
            UpdateCrictlConfig
            RegisterContainerDService
            StartContainerD
            break
        }
    }
}

function UninstallCRI($cri)
{
    switch ($cri)
    {
        "dockerd" {
            UninstallDockerD
            break
        }

        "containerd" {
            UninstallContainerD
            break
        }
    }
}

function InstallCNI($cni, $NetworkMode, $ManagementIp, $CniPath, $InterfaceName)
{
    CreateDirectory $CniPath
    switch ($Cni)
    {
        "kubenet" {
            break
        }
    
        "flannel" {
            DownloadFlannelBinaries -Destination $Global:BaseDir
            DownloadCniBinaries -NetworkMode $NetworkMode -CniPath $CniPath
            InstallFlannelD -Destination $Global:BaseDir -InterfaceIpAddress $ManagementIp
            
            if ($Global:Cri -eq "containerd")
            {
            Update-ContainerdCNIConfig -CNIConfig (GetCniConfig) `
                -ClusterCIDR (GetClusterCidr) -KubeDnsServiceIP (GetKubeDnsServiceIp) `
                -ServiceCidr (GetServiceCidr) -InterfaceName $InterfaceName `
                -NetworkName $Global:NetworkName -NetworkMode $Global:NetworkMode
            }
            else
            {
            Update-CNIConfig -CNIConfig (GetCniConfig) `
                -ClusterCIDR (GetClusterCidr) -KubeDnsServiceIP (GetKubeDnsServiceIp) `
                -ServiceCidr (GetServiceCidr) -InterfaceName $InterfaceName `
                -NetworkName $Global:NetworkName -NetworkMode $Global:NetworkMode
            }

            Update-NetConfig -NetConfig (GetFlannelNetConf) `
                -ClusterCIDR (GetClusterCidr) `
                -NetworkName $Global:NetworkName -NetworkMode $Global:NetworkMode

            break
        }
    } 
}

function UninstallCNI($cni)
{
    switch ($Cni)
    {
        "kubenet" {
            break
        }
        "flannel" {
            UnInstallFlannelD
            break
        }
    } 
}

function GetFileContent($Path)
{
    if ((Test-Path $Path))
    {
        return Get-Content $Path
    }
    if ($Path.StartsWith("http"))
    {
        return (iwr $Path -ErrorAction Stop).Content
    }
}

function DownloadTestScripts()
{
    CreateDirectory $Global:BaseDir\test
    
    DownloadFile -Url "https://raw.githubusercontent.com/$Global:GithubSDNRepository/$Global:GithubSDNBranch/Kubernetes/windows/test/ValidateKubernetes.Pester.tests.ps1" -Destination $Global:BaseDir\test\ValidateKubernetes.Pester.tests.ps1
    DownloadFile -Url "https://raw.githubusercontent.com/$Global:GithubSDNRepository/$Global:GithubSDNBranch/Kubernetes/windows/test/ValidateKubernetesHelper.psm1" -Destination $Global:BaseDir\test\ValidateKubernetesHelper.psm1
}

function DownloadDebugScripts()
{
    CreateDirectory $Global:BaseDir\debug
    DownloadFile -Url "https://raw.githubusercontent.com/$Global:GithubSDNRepository/$Global:GithubSDNBranch/Kubernetes/windows/debug/collectlogs.ps1" -Destination $Global:BaseDir\debug\collectlogs.ps1
}

# List of all exports from this module
Export-ModuleMember DownloadFile
Export-ModuleMember CleanupOldNetwork
Export-ModuleMember IsNodeRegistered
Export-ModuleMember WaitForNetwork
Export-ModuleMember GetSourceVip
Export-ModuleMember Get-PodCIDR
Export-ModuleMember Get-PodCIDRs
Export-ModuleMember Get-PodEndpointGateway
Export-ModuleMember Get-PodGateway
Export-ModuleMember Get-MgmtDefaultGatewayAddress
Export-ModuleMember CreateDirectory
Export-ModuleMember Update-CNIConfig
Export-ModuleMember Update-NetConfig
Export-ModuleMember CreateExternalNetwork
Export-ModuleMember KillProcessByName
Export-ModuleMember AllowFirewall
Export-ModuleMember RemoveFirewall
Export-ModuleMember CleanupContainers
Export-ModuleMember Expand-GZip
Export-ModuleMember DownloadAndExtractTarGz
Export-ModuleMember DownloadAndExtractZip
Export-ModuleMember Assert-FileExists
Export-ModuleMember RunLocally
Export-ModuleMember StartKubelet
Export-ModuleMember StartFlanneld
Export-ModuleMember StartKubeproxy
Export-ModuleMember CreateService
Export-ModuleMember RemoveService
Export-ModuleMember InstallKubernetesBinaries
Export-ModuleMember UninstallKubernetesBinaries
Export-ModuleMember DownloadWinCniBinaries
Export-ModuleMember InstallDockerD
Export-ModuleMember UninstallDockerD
Export-ModuleMember InstallDockerImages
Export-ModuleMember InstallPauseImage
Export-ModuleMember InstallContainersRole
Export-ModuleMember InstallHypervRole
Export-ModuleMember ReadKubeClusterInfo
Export-ModuleMember GetKubeDnsServiceIp
Export-ModuleMember GetClusterCidr
Export-ModuleMember GetServiceCidr
Export-ModuleMember KubeConfigExists
Export-ModuleMember InstallKubeProxy
Export-ModuleMember UninstallKubeProxy
Export-ModuleMember InstallKubelet
Export-ModuleMember UninstallKubelet
Export-ModuleMember InstallCNI
Export-ModuleMember InstallCRI
Export-ModuleMember UninstallCNI
Export-ModuleMember UninstallCRI
Export-ModuleMember InitHelper
Export-ModuleMember GetKubeConfig
Export-ModuleMember DownloadKubeConfig
Export-ModuleMember GetCniPath
Export-ModuleMember GetCniConfigPath
Export-ModuleMember Get-InterfaceIpAddress
Export-ModuleMember Install-7Zip
Export-ModuleMember GetLogDir
Export-ModuleMember CreateSCMService
Export-ModuleMember HasKubeadmConfig
Export-ModuleMember WriteKubeadmConfig
Export-ModuleMember ReadKubeadmConfig
Export-ModuleMember RemoveExternalNetwork
Export-ModuleMember GetKubeNodes
Export-ModuleMember RemoveKubeNode
Export-ModuleMember GetFileContent
Export-ModuleMember PrintConfig
Export-ModuleMember WaitForNodeRegistration
Export-ModuleMember DownloadTestScripts
Export-ModuleMember DownloadDebugScripts
Export-ModuleMember CleanupPolicyList
Export-ModuleMember InstallContainerD
Export-ModuleMember RegisterContainerDService
Export-ModuleMember IsContainerDUp
Export-ModuleMember InstallLcow
Export-ModuleMember UninstallContainerD
Export-ModuleMember UpdateCrictlConfig
Export-ModuleMember StartContainerD