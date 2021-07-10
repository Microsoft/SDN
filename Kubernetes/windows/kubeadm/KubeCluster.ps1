#
# Copyright 2019 (c) Microsoft Corporation.
# Licensed under the MIT license.
#
Param(
    #[switch] $init, No support for Windows Master
    [parameter(Mandatory = $false,HelpMessage="Print the help")]
    [switch] $help,
    [parameter(Mandatory = $false,HelpMessage="Install pre-requisites")]
    [switch] $InstallPrerequisite,
    [parameter(Mandatory = $false,HelpMessage="Join the windows node to the master")]
    [switch] $join,
    [parameter(Mandatory = $false,HelpMessage="Reset this windows node and cleanup everything")]
    [switch] $reset,
    [parameter(Mandatory = $true,HelpMessage="Path to input configuration json ")] 
    $ConfigFile
)

function Usage()
{
    $bin = $PSCommandPath 
    Get-Help $bin -Detailed

    $usage = "
    Usage: 
		$bin [-help] [-reset] [-join -cni <flannel/kubenet> -networkplugin <bridge/vxlan>] [-destination <InstallDestination>] [-release KUBE_RELEASE]

	Examples:
        $bin -help                                                           print this help
        $bin -reset                                                          reset the kubernetes cluster
        $bin -join -cni flannel -networkplugin bridge -release 1.14.0        joins the windows node to existing cluster     
        $bin -join -cni flannel -networkplugin vxlan  -release 1.14.0        joins the windows node to existing cluster
        $bin -join -ConfigFile kubecluster.json                              joins the windows node to existing cluster
    "

    Write-Host $usage
}

function ReadKubeclusterConfig($ConfigFile)
{
    # Read the configuration and initialize default values if not found
    $Global:ClusterConfiguration = ConvertFrom-Json ((GetFileContent $ConfigFile -ErrorAction Stop) | out-string)
    if (!$Global:ClusterConfiguration.Install)
    {
        $Global:ClusterConfiguration | Add-Member -MemberType NoteProperty -Name Install -Value @{ 
            Destination = "$env:HOMEDRIVE\$env:HOMEPATH\kubeadm";
            Source = @{
                SDNRepo = "Microsoft/SDN";
                SDNBranch = "master";
            } 
        }
    }

    if (!$Global:ClusterConfiguration.Install.Source)
    {
        $Global:ClusterConfiguration.Install | Add-Member -MemberType NoteProperty -Name Source -Value @{ 
            SDNRepo = "Microsoft/SDN"; 
            SDNBranch = "master"; 
        }
    }

    if (!$Global:ClusterConfiguration.Kubernetes)
    {
        throw "Master information missing in the configuration file"
    }
    if (!$Global:ClusterConfiguration.Kubernetes.Source)
    {
        $Global:ClusterConfiguration.Kubernetes | Add-Member -MemberType NoteProperty -Name Source -Value @{
            Release = "1.15.5";
        }
    }
    if (!$Global:ClusterConfiguration.Kubernetes.Master)
    {
        throw "Master information missing in the configuration file"
    }

    if (!$Global:ClusterConfiguration.Kubernetes.Network)
    {
        $Global:ClusterConfiguration.Kubernetes | Add-Member -MemberType NoteProperty -Name Network -Value @{
            ServiceCidr = "10.96.0.0/12";
            ClusterCidr = "10.244.0.0/16";
        }
    }

    if (!$Global:ClusterConfiguration.Cni)
    {
        $Global:ClusterConfiguration | Add-Member -MemberType NoteProperty -Name Cni -Value @{
            Name = "flannel";
            Plugin = @{
                Name = "vxlan";
            };
            InterfaceName = "Ethernet";
        }
    }

    if ($Global:ClusterConfiguration.Cni.Plugin.Name -eq "vxlan")
    {
        if (!$Global:ClusterConfiguration.Kubernetes.KubeProxy)
        {
            $Global:ClusterConfiguration.Kubernetes | Add-Member -MemberType NoteProperty -Name KubeProxy -Value @{
                    Gates = "WinOverlay=true";
            }
        }
    }

    if (!$Global:ClusterConfiguration.Cri)
    {
        $Global:ClusterConfiguration | Add-Member -MemberType NoteProperty -Name Cri -Value @{
            Name = "dockerd";
            Images = @{
                Nanoserver = "mcr.microsoft.com/windows/nanoserver:1809";
                ServerCore = "mcr.microsoft.com/windows/servercore:ltsc2019";
            }
        }
    }

    if ($Global:ClusterConfiguration.Cri.Name -eq "containerd")
    {
        if (!$Global:ClusterConfiguration.Cri.DownloadUrls) {
            $Global:ClusterConfiguration.Cri | Add-Member -MemberType NoteProperty -Name DownloadUrls -Value @{
                ContainerD = "https://github.com/nagiesek/cri/releases/download/windows/containerd.exe";
                Ctr = "https://github.com/nagiesek/cri/releases/download/windows/ctr.exe";
                ContainerdShim = "https://github.com/nagiesek/cri/releases/download/windows/containerd-shim-runhcs-v1.exe";
                # RunHcs - not needed?
            }
        }
    }
}

function LoadPsm1($Path)
{
    $tmpPath = [io.Path]::Combine([System.IO.Path]::GetTempPath(), [io.path]::GetFileName($Path))
    wget $Path -o $tmpPath
    ipmo $tmpPath  -DisableNameChecking
    Remove-Item $tmpPath
}

###############################################################################################
# Download pre-req scripts
$BaseDir = [System.IO.Path]::GetTempPath()
if (!(Test-Path $BaseDir))
{
    mkdir -p $BaseDir
}
$_GithubSDNRepository = 'Microsoft/SDN'
$_GithubSDNBranch = "master"
if ((Test-Path env:GITHUB_SDN_REPOSITORY) -and ($env:GITHUB_SDN_REPOSITORY -ne ''))
{
    $_GithubSDNRepository = $env:GITHUB_SDN_REPOSITORY
}

if ((Test-Path env:GITHUB_SDN_BRANCH) -and ($env:GITHUB_SDN_BRANCH -ne ''))
{
    $_GithubSDNBranch = $env:GITHUB_SDN_BRANCH
}

LoadPsm1 -Path "https://raw.githubusercontent.com/$_GithubSDNRepository/$_GithubSDNBranch/Kubernetes/windows/helper.v2.psm1"
LoadPsm1 -Path "https://raw.githubusercontent.com/$_GithubSDNRepository/$_GithubSDNBranch/Kubernetes/windows/hns.psm1"

ReadKubeclusterConfig -ConfigFile $ConfigFile
InitHelper
PrintConfig
WriteKubeadmConfig


# Initialize internal network modes of windows corresponding to 
# the plugin used in the cluster
$Global:NetworkName = "cbr0"
$Global:NetworkMode = "l2bridge"
if ($Global:NetworkPlugin -eq "vxlan")
{
    $Global:NetworkMode = "overlay"
    $Global:NetworkName = "vxlan0"
}
######################################################################################################################

# Handle --help
if ($help.IsPresent)
{
    Usage
    exit
}

# Handle --InstallPrerequisite
if ($InstallPrerequisite.IsPresent)
{
    InstallContainersRole
    #InstallHypervRole
    $defaultValue = "Y"
    if (!(Test-Path $env:HOMEDRIVE/$env:HOMEPATH/.ssh/id_rsa.pub))
    {
        $res = Read-Host "Do you wish to generate a SSH Key & Add it to the Linux Master [Y/n] - Default [Y] : "
        if ($res -eq '' -or $res -eq 'Y'  -or $res -eq 'y')
        {
            ssh-keygen.exe
        }
    }

    $pubKey = Get-Content $env:HOMEDRIVE/$env:HOMEPATH/.ssh/id_rsa.pub
    Write-Host "Execute the below cmd in Linux Master($Global:MasterIp) to add this Windows Node's public key to its authorized keys"
    
    Write-Host "touch ~/.ssh/authorized_keys"
    Write-Host "echo $pubKey >> ~/.ssh/authorized_keys"

    $res = Read-Host "Continue to Reboot the host [Y/n] - Default [Y] : "
    if ($res -eq '' -or $res -eq 'Y'  -or $res -eq 'y')
    {
        Restart-Computer -Force
    }

    exit
}

# Handle -Join
if ($Join.IsPresent)
{
    $kubeConfig = GetKubeConfig
    if (!(KubeConfigExists))
    {
        # Fetch KubeConfig from the master
        DownloadKubeConfig -Master $Global:MasterIp -User $Global:MasterUsername
        if (!(KubeConfigExists))
        {
            throw $kubeConfig + " does not exist. Cannot connect to the master cluster"
        }
    }

    InstallCRI $Global:Cri
    InstallKubernetesBinaries -Destination  $Global:BaseDir -Source $Global:ClusterConfiguration.Kubernetes.Source

    # Validate connectivity with Master API Server

    Write-Host "Trying to connect to the Kubernetes master"
    try {
        ReadKubeClusterInfo 
    } catch {
        throw "Unable to connect to the master. Reason [$_]"
    }

    $KubeDnsServiceIP = GetKubeDnsServiceIp
    $ClusterCIDR = GetClusterCidr
    $ServiceCIDR = GetServiceCidr
    
    Write-Host "####################################"
    Write-Host "Able to connect to the Master"
    Write-Host "Discovered the following"
    Write-Host "Cluster CIDR    : $ClusterCIDR"
    Write-Host "Service CIDR    : $ServiceCIDR"
    Write-Host "DNS ServiceIp   : $KubeDnsServiceIP"
    Write-Host "####################################"

    #
    # Install Services & Start in the below order
    # 1. Install CNI & Kubelet & Start Kubelet
    InstallCNI -Cni $Global:Cni -NetworkMode $Global:NetworkMode `
                  -ManagementIP $Global:ManagementIp `
                  -InterfaceName $Global:InterfaceName `
                  -CniPath $(GetCniPath)


    InstallKubelet -KubeConfig $KubeConfig -CniDir $(GetCniPath) `
                -CniConf $(GetCniConfigPath) -KubeDnsServiceIp $KubeDnsServiceIp `
                -NodeIp $Global:ManagementIp -KubeletFeatureGates $KubeletFeatureGates `
                -IsContainerd:$($Global:Cri -eq "containerd")
    StartKubelet

    WaitForNodeRegistration -TimeoutSeconds 10

    # 2. Install CNI & Start services
    if ($Global:Cni -eq "flannel")
    {
        CreateExternalNetwork -NetworkMode $Global:NetworkMode -InterfaceName $Global:InterfaceName
        sleep 20
        StartFlanneld 
        WaitForNetwork $Global:NetworkName
    }

    # 3. Install & Start Kubeproxy
    if ($Global:NetworkMode -eq "overlay")
    {
        $sourceVip = GetSourceVip -NetworkName $Global:NetworkName
        InstallKubeProxy -KubeConfig $(GetKubeConfig) `
                -NetworkName $Global:NetworkName -ClusterCIDR  $ClusterCIDR `
                -SourceVip $sourceVip `
                -IsDsr:$Global:DsrEnabled `
                -ProxyFeatureGates $Global:KubeproxyGates
    }
    else 
    {
        $env:KUBE_NETWORK=$Global:NetworkName
        InstallKubeProxy -KubeConfig $(GetKubeConfig) `
                -IsDsr:$Global:DsrEnabled `
                -NetworkName $Global:NetworkName -ClusterCIDR  $ClusterCIDR `
                -ProxyFeatureGates $Global:KubeproxyGates
    }
    
    StartKubeproxy

    DownloadTestScripts
    DownloadDebugScripts
    GetKubeNodes
    Write-Host "Node $(hostname) successfully joined the cluster"
    
    hnsdiag list all
}
# Handle -Reset
elseif ($Reset.IsPresent)
{
    ReadKubeadmConfig
    RemoveKubeNode
    # Initiate cleanup
    CleanupContainers
    CleanupOldNetwork $Global:NetworkName
    RemoveExternalNetwork
    CleanupPolicyList
    UninstallCNI $Global:Cni
    UninstallKubeProxy
    UninstallKubelet
    UninstallKubernetesBinaries -Destination  $Global:BaseDir
    UninstallCRI $Global:Cri
    Remove-Item $Global:BaseDir -ErrorAction SilentlyContinue
    Remove-Item $env:HOMEDRIVE\$env:HOMEPATH\.kube -ErrorAction SilentlyContinue
}
