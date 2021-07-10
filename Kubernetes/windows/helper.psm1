function Expand-GZip($infile, $outfile = ($infile -replace '\.gz$',''))
{
    # From https://social.technet.microsoft.com/Forums/en-US/5aa53fef-5229-4313-a035-8b3a38ab93f5/unzip-gz-files-using-powershell?forum=winserverpowershell
    $input = New-Object System.IO.FileStream $inFile, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read)
    $output = New-Object System.IO.FileStream $outFile, ([IO.FileMode]::Create), ([IO.FileAccess]::Write), ([IO.FileShare]::None)
    $gzipStream = New-Object System.IO.Compression.GzipStream $input, ([IO.Compression.CompressionMode]::Decompress)

    $buffer = New-Object byte[](1024)
    while($true){
        $read = $gzipstream.Read($buffer, 0, 1024)
        if ($read -le 0){break}
        $output.Write($buffer, 0, $read)
    }

    $gzipStream.Close()
    $output.Close()
    $input.Close()
}

function DownloadAndExtractTarGz($url, $dstPath)
{
    $tmpTarGz = New-TemporaryFile | Rename-Item -NewName { $_ -replace 'tmp$', 'tar.gz' } -PassThru
    $tmpTar = New-TemporaryFile | Rename-Item -NewName { $_ -replace 'tmp$', 'tar' } -PassThru

    Invoke-WebRequest $url -o $tmpTarGz.FullName
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
    [parameter(Mandatory = $false)] $proxy
    )

    if (Test-Path $Destination)
    {
        Write-Host "File $Destination already exists."
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
    
    if($proxy){
        try {
            $WebClient = New-Object System.Net.WebClient
            $WebProxy = New-Object System.Net.WebProxy($proxy,$true)
            $WebClient.Proxy = $WebProxy
            $WebClient.DownloadFile($Url,$Destination)
            Write-Host "Downloaded $Url=>$Destination"
        } catch {
            Write-Error "Failed to download $Url"
            throw
        }
    }
    else{
        try {
            (New-Object System.Net.WebClient).DownloadFile($Url,$Destination)
            Write-Host "Downloaded $Url=>$Destination"
        } catch {
            Write-Error "Failed to download $Url"
            throw
        }
    }
}

function CleanupOldNetwork($NetworkName, $ClearDocker = $true)
{
    $hnsNetwork = Get-HnsNetwork | ? Name -EQ $NetworkName.ToLower()

    if ($hnsNetwork)
    {
        if($ClearDocker) {
            # Cleanup all containers
            docker ps -aq | foreach {docker rm $_ -f} 
        }

        Write-Host "Cleaning up old HNS network found"
        Write-Host ($hnsNetwork | ConvertTo-Json -Depth 10) 
        Remove-HnsNetwork $hnsNetwork
    }
}

function CreateExternalNetwork
{
    Param([ValidateSet("l2bridge", "overlay",IgnoreCase = $true)] [parameter(Mandatory = $true)] $NetworkMode)

    if ($NetworkMode -eq "l2bridge")
    {
        if(!(Get-HnsNetwork | ? Name -EQ "External"))
        {
            # Create a L2Bridge network to trigger a vSwitch creation. Do this only once as it causes network blip
            New-HNSNetwork -Type $NetworkMode -AddressPrefix "192.168.255.0/30" -Gateway "192.168.255.1" -Name "External" -Verbose
        }
    }
    elseif ($NetworkMode -eq "overlay")
    {
        # Open firewall for Overlay traffic
        New-NetFirewallRule -Name OverlayTraffic4789UDP -Description "Overlay network traffic UDP" -Action Allow -LocalPort 4789 -Enabled True -DisplayName "Overlay Traffic 4789 UDP" -Protocol UDP -ErrorAction SilentlyContinue
        # Create a Overlay network to trigger a vSwitch creation. Do this only once
        if(!(Get-HnsNetwork | ? Name -EQ "External"))
        {
            New-HNSNetwork -Type $NetworkMode -AddressPrefix "192.168.255.0/30" -Gateway "192.168.255.1" -Name "External" -SubnetPolicies @(@{Type = "VSID"; VSID = 9999; })  -Verbose
        }
    }
}
function WaitForNetwork($NetworkName)
{
    # Wait till the network is available
    while( !(Get-HnsNetwork -Verbose | ? Name -EQ $NetworkName.ToLower()) )
    {
        Write-Host "Waiting for the Network to be created"
        Start-Sleep 1
    }
}

function IsNodeRegistered()
{
    c:\k\kubectl.exe --kubeconfig=c:\k\config get nodes/$($(hostname).ToLower())
    return (!$LASTEXITCODE)
}

function RegisterNode($UseCRI = $false)
{
    if (!(IsNodeRegistered))
    {
        $argList = @("--hostname-override=$(hostname)","--pod-infra-container-image=kubeletwin/pause","--resolv-conf=""""", "--cgroups-per-qos=false", "--enforce-node-allocatable=""""","--kubeconfig=c:\k\config")
        if($UseCRI)
        {
            $argList += @("--container-runtime=remote", "--container-runtime-endpoint=npipe:////./pipe/containerd-containerd")
        }
        $process = Start-Process -FilePath c:\k\kubelet.exe -PassThru -ArgumentList $argList

        # Wait till the 
        while (!(IsNodeRegistered))
        {
            Write-Host "waiting to discover node registration status"
            Start-Sleep -sec 1
        }

        $process | Stop-Process | Out-Null
    }
    else 
    {
        Write-Host "Node $(hostname) already registered"
    }
}

function StartFlanneld($ipaddress, $NetworkName)
{
    CleanupOldNetwork $NetworkName

    # Start FlannelD, which would recreate the network.
    # Expect disruption in node connectivity for few seconds
    pushd 
    cd C:\flannel\
    [Environment]::SetEnvironmentVariable("NODE_NAME", (hostname).ToLower())
    start C:\flannel\flanneld.exe -ArgumentList "--kubeconfig-file=C:\k\config --iface=$ipaddress --ip-masq=1 --kube-subnet-mgr=1" -NoNewWindow
    popd

    WaitForNetwork $NetworkName
}

function GetSourceVip($ipaddress, $NetworkName)
{
    $hnsNetwork = Get-HnsNetwork | ? Name -EQ $NetworkName.ToLower()
    $subnet = $hnsNetwork.Subnets[0].AddressPrefix

    $ipamConfig = @"
        {"cniVersion": "0.2.0", "name": "vxlan0", "ipam":{"type":"host-local","ranges":[[{"subnet":"$subnet"}]],"dataDir":"/var/lib/cni/networks"}}
"@

    $ipamConfig | Out-File "C:\k\sourceVipRequest.json"

    $env:CNI_COMMAND="ADD"
    $env:CNI_CONTAINERID="dummy"
    $env:CNI_NETNS="dummy"
    $env:CNI_IFNAME="dummy"
    $env:CNI_PATH="c:\k\cni" #path to host-local.exe

    If(!(Test-Path c:/k/sourceVip.json)){
        Get-Content sourceVipRequest.json | .\cni\host-local.exe | Out-File sourceVip.json
    }

    Remove-Item env:CNI_COMMAND
    Remove-Item env:CNI_CONTAINERID
    Remove-Item env:CNI_NETNS
    Remove-Item env:CNI_IFNAME
    Remove-Item env:CNI_PATH
}

function Get-PodCIDR()
{
    return c:\k\kubectl.exe --kubeconfig=c:\k\config get nodes/$($(hostname).ToLower()) -o custom-columns=podCidr:.spec.podCIDR --no-headers
}

function Get-PodCIDRs()
{
    return c:\k\kubectl.exe  --kubeconfig=c:\k\config get nodes -o=custom-columns=Name:.status.nodeInfo.operatingSystem,PODCidr:.spec.podCIDR --no-headers
}

function Get-PodGateway($podCIDR)
{
    # Current limitation of Platform to not use .1 ip, since it is reserved
    return $podCIDR.substring(0,$podCIDR.lastIndexOf(".")) + ".1"
}

function Get-PodEndpointGateway($podCIDR)
{
    # Current limitation of Platform to not use .1 ip, since it is reserved
    return $podCIDR.substring(0,$podCIDR.lastIndexOf(".")) + ".2"
}

function Get-MgmtIpAddress()
{
    Param (
        [Parameter(Mandatory=$false)] [String] $InterfaceName = "Ethernet"
    )
    $na = Get-NetAdapter | ? Name -Like "vEthernet ($InterfaceName*" | ? Status -EQ Up
    return (Get-NetIPAddress -InterfaceAlias $na.ifAlias -AddressFamily IPv4).IPAddress
}

# builds the right options to call the kubelet with
# returns a custom object with a single member `Options`, which is an array of strings
function Kubelet-Options()
{
    Param (
        [parameter(Mandatory = $false)] [String] $KubeDnsServiceIP='10.96.0.10',
        [parameter(Mandatory = $false)] [String] $LogDir = 'C:\k'
    )

    $kubeletOptions = @(
        "--hostname-override=$($(hostname).ToLower())"
        '--v=6'
        '--pod-infra-container-image=mcr.microsoft.com/k8s/core/pause:1.2.0'
        '--resolv-conf=""'
        '--enable-debugging-handlers'
        "--cluster-dns=$KubeDnsServiceIp"
        '--cluster-domain=cluster.local'
        '--kubeconfig=c:\k\config'
        '--hairpin-mode=promiscuous-bridge'
        '--image-pull-progress-deadline=20m'
        '--cgroups-per-qos=false'
        "--log-dir=$LogDir"
        '--logtostderr=false'
        '--enforce-node-allocatable=""'
        '--network-plugin=cni'
        '--cni-bin-dir="c:\k\cni"'
        '--cni-conf-dir="c:\k\cni\config"'
        "--node-ip=$(Get-MgmtIpAddress)"
    )

    if (($kubeletVersionOutput = c:\k\kubelet.exe --version) -and $kubeletVersionOutput -match '^(?:kubernetes )?v?([0-9]+(?:\.[0-9]+){1,2})')
    {
        $kubeletVersion = [System.Version]$matches[1]
        Write-Host "Detected kubelet version $kubeletVersion"

        if ($kubeletVersion -lt [System.Version]'1.15')
        {
            # this flag got deprecated in version 1.15
            $kubeletOptions += '--allow-privileged=true'
        }
    }
    else
    {
        Write-Host 'Unable to determine kubelet version'
    }

    $result = '' | Select-Object -Property Options
    $result.Options = $kubeletOptions
    return $result
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
    $na = Get-NetAdapter | ? Name -Like "vEthernet ($InterfaceName*" | ? Status -EQ Up

    if (!$na) {
      throw "Failed to find a suitable network adapter, check your network settings."
    }
    $addr = (Get-NetIPAddress -InterfaceAlias $na.ifAlias -AddressFamily IPv4).IPAddress
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
        [ValidateSet("l2bridge", "overlay",IgnoreCase = $true)] [parameter(Mandatory = $true)] $NetworkMode
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
    Add-Content -Path $NetConfig -Value (ConvertTo-Json $configJson -Depth 20)
    Write-Host "Generated net-conf Config [$configJson]"
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
            "delegate": {
               "type": "win-bridge",
                "dns" : {
                  "Nameservers" : [ "10.96.0.10" ],
                  "Search": [ "svc.cluster.local" ]
                },
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
              $configJson.delegate.dns.Nameservers[0] = $KubeDnsServiceIP
              $configJson.delegate.dns.Search[0] = "svc.cluster.local"
          
              $configJson.delegate.policies[0].Value.ExceptionList[0] = $clusterCIDR
              $configJson.delegate.policies[0].Value.ExceptionList[1] = $serviceCIDR
              $configJson.delegate.policies[0].Value.ExceptionList[2] = Get-MgmtSubnet($InterfaceName)
          
              $configJson.delegate.policies[1].Value.DestinationPrefix  = $serviceCIDR
              $configJson.delegate.policies[2].Value.DestinationPrefix  = ((Get-MgmtIpAddress($InterfaceName)) + "/32")
    }
    elseif ($NetworkMode -eq "overlay")
    {
        $jsonSampleConfig = '{
            "cniVersion": "0.2.0",
            "name": "<NetworkMode>",
            "type": "flannel",
            "delegate": {
               "type": "win-overlay",
                "dns" : {
                  "Nameservers" : [ "11.0.0.10" ],
                  "Search": [ "default.svc.cluster.local" ]
                },
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
              $configJson.delegate.dns.Nameservers[0] = $KubeDnsServiceIp
              $configJson.delegate.dns.Search[0] = "svc.cluster.local"
          
              $configJson.delegate.Policies[0].Value.ExceptionList[0] = $clusterCIDR
              $configJson.delegate.Policies[0].Value.ExceptionList[1] = $serviceCIDR
          
              $configJson.delegate.Policies[1].Value.DestinationPrefix  = $serviceCIDR
    }
    
    if (Test-Path $CNIConfig) {
        Clear-Content -Path $CNIConfig
    }

    Write-Host "Generated CNI Config [$configJson]"

    Add-Content -Path $CNIConfig -Value (ConvertTo-Json $configJson -Depth 20)
}

Export-ModuleMember Expand-GZip
Export-ModuleMember DownloadAndExtractTarGz
Export-ModuleMember DownloadAndExtractZip
Export-ModuleMember Assert-FileExists
Export-ModuleMember DownloadFile
Export-ModuleMember CleanupOldNetwork
Export-ModuleMember IsNodeRegistered
Export-ModuleMember RegisterNode
Export-ModuleMember WaitForNetwork
Export-ModuleMember StartFlanneld
Export-ModuleMember GetSourceVip
Export-ModuleMember Get-MgmtSubnet
Export-ModuleMember Get-MgmtIpAddress
Export-ModuleMember Get-HnsMgmtIpAddress
Export-ModuleMember Get-PodCIDR
Export-ModuleMember Get-PodCIDRs
Export-ModuleMember Get-PodEndpointGateway
Export-ModuleMember Get-PodGateway
Export-ModuleMember Get-MgmtDefaultGatewayAddress
Export-ModuleMember CreateDirectory
Export-ModuleMember Update-CNIConfig
Export-ModuleMember Update-NetConfig
Export-ModuleMember CreateExternalNetwork
Export-ModuleMember Kubelet-Options
