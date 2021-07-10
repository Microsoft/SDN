# --------------------------------------------------------------
#  Copyright Â© Microsoft Corporation.  All Rights Reserved.
#  Microsoft Corporation (or based on where you live, one of its affiliates) licenses this sample code for your internal testing purposes only.
#  Microsoft provides the following sample code AS IS without warranty of any kind. The sample code arenot supported under any Microsoft standard support program or services.
#  Microsoft further disclaims all implied warranties including, without limitation, any implied warranties of merchantability or of fitness for a particular purpose.
#  The entire risk arising out of the use or performance of the sample code remains with you.
#  In no event shall Microsoft, its authors, or anyone else involved in the creation, production, or delivery of the code be liable for any damages whatsoever
#  (including, without limitation, damages for loss of business profits, business interruption, loss of business information, or other pecuniary loss)
#  arising out of the use of or inability to use the sample code, even if Microsoft has been advised of the possibility of such damages.
# ---------------------------------------------------------------
<#
.SYNOPSIS 
    Deploys and configures the Microsoft SDN infrastructure from VMM, 
    including creation of the network controller VMs.  Then the VMs and Hyper-V hosts are configured to be 
    used by the Network Controller.  When this script completes the SDN 
    infrastructure is ready to be fully used for workload deployments with some exception to configure
    SLB and gateway depending upon your Data Center needs
.EXAMPLE
    .\VMMExpress -ConfigurationDataFile .\MyConfig.psd1
    Reads in the configuration from a PSD1 file that contains a hash table 
    of settings data.
.EXAMPLE
    .\VMMExpress -ConfigurationData $MyConfigurationData
    Uses the hash table that is passed in as the configuration data.  This 
    parameter set is useful when programatically generating the 
    configuration data. The generated config file should be similar to 
    fabricconfig.psd1
.NOTES
    Prerequisites:
    * All Hyper-V hosts must have Hyper-V enabled 
    * All Hyper-V hosts must be joined to Active Directory.
    * All Hyper-V host must be part of a single host group
    * VMM Library should have the VHD or VHDX used for creating infrastructural VMs.
    * The physical network must be preconfigured for the necessary subnets and 
    VLANs as defined in the configuration data.
    
#>

[CmdletBinding(DefaultParameterSetName="NoParameters")]
param(
    [Parameter(Mandatory=$true,ParameterSetName="ConfigurationFile")]
    [String] $ConfigurationDataFile=$null,
    [Parameter(Mandatory=$true,ParameterSetName="ConfigurationData")]
    [object] $ConfigurationData=$null
)


$Logfile  = split-path $pwd
$Logfile  = $Logfile + "\scripts\VMMExpresslogfile.log"

Function LogWrite
{
   Param (
		[string] $logstring
	)

	write-verbose $logstring
	Add-content $Logfile -value $logstring
}

# Function to check and verify that all the required parameters are specified
# in case of missing parameter it throws exception and the execution stops.
function checkParameters
{
	param([Object] $ConfigData)
	
	
	# check that the input VHD is present in VMM library
	if ($ConfigData.VHDName -eq "") 
	{
		LogWrite "Error :VHD Name can not be blank . This is required for creating NC infrastructure VMs" 
		exit -1
	}
	elseif( $ConfigData.VHDName.length -gt 64)
	{
		LogWrite "Error :Cannot validate argument on parameter 'VHDName'. The character length of the $($ConfigData.VHDName.length) argument is too long. Shorten the character length of the argument so it is fewer than or equal to 64 characters" 
		exit -1
	}
	else
	{
	    $Vhd = Get-SCVirtualHardDisk -Name $ConfigData.VHDName
		if($Vhd.count -eq 0)
		{
			LogWrite "Error : Specified VHD does not exist in VMM library." 
			exit -1
		}
		elseif($Vhd.count -gt 1)
		{
			LogWrite "Error : More than 1 VHD exists with this name" 
			exit -1
		}
	}	
	# check the product Key
	if($ConfigData.ProductKey -eq "")
	{
		LogWrite " WARNING: The product Key is blank. Specify the Product key by logging into the infrastructure VM while is it being configured" 
	}
	#check the generation
	if(($ConfigData.Generation -eq "") -or (($ConfigData.Generation -ne "Gen1") -and ($ConfigData.Generation -ne "Gen2")))
	{
	    LogWrite " Error: Generation must have a value Gen1 or Gen2" 
		exit -1
	}
	#Check deployment type parameter
	if($ConfigData.DeploymentType -ne "Standalone" -and $ConfigData.DeploymentType -ne "Production")
	{
		LogWrite " Error: Deployment Type must have a value Standalone or Production" 
		exit -1
	}
	#Check the Host group 
	if($ConfigData.NCHostGroupName -eq "")
	{
		LogWrite " Error: NCHostGroup Can not be blank" 
		exit -1
	}
	else
	{
		$hostGroup = Get-SCVMHostGroup -Name $ConfigData.NCHostGroupName
		if($hostGroup.count -eq 0)
		{
			LogWrite " Error: The specified NCHostGroup does not exist " 
			exit -1
		}
		
	}
	
	#validate the Domain credentials
	$username = $node.ManagementDomainUser
    $password = $node.ManagementDomainUserPassword

    # Get current domain using logged-on user's credentials
    $CurrentDomain = "LDAP://" + ([ADSI]"").distinguishedName
    $domain = New-Object System.DirectoryServices.DirectoryEntry($CurrentDomain,$UserName,$Password)

    if ($domain.name -eq $null)
    {
        LogWrite "Authentication failed - please verify your username and password."
        exit -1 #terminate the script.
    }
    else
    {
        LogWrite "Successfully authenticated with domain $($domain.name)"
    }
	
	if(![String]::IsNullOrEmpty($node.StorageClassification))
	{
		$StorageClassification = Get-SCStorageClassification -VMMServer localhost | where {$_.Name -eq $node.StorageClassification}
		
		if($StorageClassification.Count -eq 0)
		{
		    LogWrite "Storage Classification : $($node.StorageClassification) does not exist"
			exit -1
		}
	}
	#Check existing ManagementVMNetwork and Logical Switch deployment 
	
	if($ConfigData.IsManagementVMNetworkExisting -eq $true)
	{
	    
	    if($ConfigData.ManagementVMNetwork -eq "")
		{
			LogWrite "Error: Existing VM Network Name can not be blank if IsManagementVMNetworkExisting = true " 
			exit -1
		}
		LogWrite " VMNetwork Name : [$($ConfigData.ManagementVMNetwork)] "
		try{
	    $existingVMNetwork = Get-SCVMNetwork -Name $ConfigData.ManagementVMNetwork
		
		}
		catch
		{
		  LogWrite "Error getting Management network"
		}
		
		if($existingVMNetwork.count -eq 0 -or $existingVMNetwork.count -gt 1)
		{
			LogWrite " Error: Existing VM Network either does not exist or there are multiple VMNetwork with same name " 
			exit -1
		}
     
	}
	
	if($ConfigData.IsLogicalSwitchDeployed -eq $true)
	{
	   	if($ConfigData.LogicalSwitch -eq "")
		{
		  LogWrite " Error: Existing Logical switch name can not be blank if IsLogicalSwitchDeployed = true  "
		  exit -1
		}
		$logicalswitch = Get-SCLogicalSwitch -Name $ConfigData.LogicalSwitch
		
		if($logicalswitch.count -eq 0 -or $logicalswitch.count -gt 1)
		{
			LogWrite " Error: Existing Logical switch either does not exist or there are multiple LogicalSwitch with same name " 
			exit -1
		}
		else
		{
		     # The Logical Switch should either be deployed on all the host in host group or non
			$Hosts = @(Get-SCVMHost | where {$_.VMHostGroup -eq $ConfigData.NCHostGroupName})
            
			foreach($VMHost in $Hosts){
                #get the virtual switch on this host. The virtual switch name should be same as logical switch
				$virtualNetwork = Get-SCVirtualNetwork -VMHost $VMHost | where {$_.LogicalSwitch.Name -eq $ConfigData.LogicalSwitch } 
				if($virtualNetwork.count -eq 0)
				{
				    LogWrite " Error: Logical Switch is not deployed on Host : [$($VMHost.Name)] " 
			        exit -1
				}	
            }
		}		
	}		
}

function OnBoardNetworkController
{
    param([Object] $node,
	[Object] $ManagementSubnet,
        [string] $VMName)
 
    LogWrite "VMName while onboarding NC : [$VMName]"
    $VMName = $VMName.Trim()
	$runAsAccount = Get-SCRunAsAccount -Name "NC_MgmtAdminRAA"
	$configurationProvider = Get-SCConfigurationProvider -Name "Microsoft Network Controller"
	$vmHostGroup = @()
	$vmHostGroup += Get-SCVMHostGroup -Name $node.NCHostGroupName
	$certificates = @()
	if ($node.DeploymentType -eq "Production")
	{
	 
		$certificates += Get-SCCertificate -ComputerName $node.RestName -TCPPort 443
	}
	else
	{
		 $certificates += Get-SCCertificate -ComputerName $VMName -TCPPort 443
	}
	$ConnectionString = "serverurl=https://"
	if ($node.DeploymentType -eq "Production")
	{
		 $ConnectionString += $node.RestName
	}
	else
	{
		 $ConnectionString += $VMName		
	     $ConnectionString += "/;SouthBoundIPAddress="
		 $vm = Get-SCVirtualMachine -Name $VMName
		 $IPv4Address = $vm.VirtualNetworkAdapters[0].IPv4Addresses
		 $ConnectionString += $IPv4Address
	}
	$ConnectionString += ";servicename=NC"
	LogWrite "COnnection String :" $ConnectionString
	$NC = Add-SCNetworkService -Name "Network Controller" -RunAsAccount $runAsAccount -ConfigurationProvider $configurationProvider -VMHostGroup $vmHostGroup -ConnectionString $ConnectionString -Certificate $certificates -ProvisionSelfSignedCertificatesForNetworkService $node.IsCertSelfSigned
}

function importServiceTemplate
{
    param([Object] $node) 
	#identify the name of service template
	$serviceTemplateLocation = Split-Path -Path $pwd
			$serviceTemplateLocation = $serviceTemplateLocation + "\Templates\NC\"
	$ServiceTemplateName = "Network Controller "
	if($node.DeploymentType -eq "Standalone")
	{
		$ServiceTemplateName = $ServiceTemplateName + "Standalone "
	}
	if($node.DeploymentType -eq "Production")
	{
		$ServiceTemplateName = $ServiceTemplateName + "Production "
	}   
	
	if($node.Generation -eq "Gen1")
	{
		$ServiceTemplateName = $ServiceTemplateName + "Generation 1 VM.xml"
	}
	if($node.Generation -eq "Gen2")
	{
		$ServiceTemplateName = $ServiceTemplateName + "Generation 2 VM.xml"
	}    
	$PackagePath = $serviceTemplateLocation + $ServiceTemplateName
	
	#Get the package
	$package = Get-SCTemplatePackage -Path $PackagePath
	
	#Get the package mapping
	$allMappings = New-SCPackageMapping -TemplatePackage $package
	
	#start mapping the resources
	
	#MAP the VHD
	LogWrite "Mapping VHD to template package"
	if($node.Generation -eq "Gen1")
	{
	$mapping = $allMappings | where {$_.PackageId -eq "Winserver.vhd"}
	}
	else
	{
	$mapping = $allMappings | where {$_.PackageId -eq "Winserver.vhdx"}
	}
	$resource = Get-SCVirtualHardDisk -Name $node.VHDName
	Set-SCPackageMapping -PackageMapping $mapping -TargetObject $resource
	
	#MAP NCsetup.cr
	$VMMLibrary = $node.VMMLibrary
	#$VMMLibrary = Get-SCLibraryShare
	$NCsetupPath = $serviceTemplateLocation + "NCSetup.cr\"
	Import-SCLibraryPhysicalResource -SourcePath $NCsetupPath -SharePath $VMMLibrary -OverwriteExistingFiles
	
	LogWrite "Mapping NCSetup.cr to template package"
	$mapping = $allMappings | where {$_.PackageId -eq "NCSetup.cr"}
	$resource = Get-SCCustomResource -Name "NCSetup.cr"
	Set-SCPackageMapping -PackageMapping $mapping -TargetObject $resource 
	
	#MAP ServerCertificate.cr
	$NCsetupPath = $serviceTemplateLocation + "ServerCertificate.cr\"
	Import-SCLibraryPhysicalResource -SourcePath $NCsetupPath -SharePath $VMMLibrary -OverwriteExistingFiles
	
	LogWrite "Mapping ServerCertificate.cr to template package"
	$mapping = $allMappings | where {$_.PackageId -eq "ServerCertificate.cr"}
	$resource = Get-SCCustomResource -Name "ServerCertificate.cr"
	Set-SCPackageMapping -PackageMapping $mapping -TargetObject $resource
	
	#MAP TrustedRootCertificate.cr
	$NCsetupPath = $serviceTemplateLocation + "TrustedRootCertificate.cr\"
	Import-SCLibraryPhysicalResource -SourcePath $NCsetupPath -SharePath $VMMLibrary -OverwriteExistingFiles
	
	LogWrite "Mapping TrustedRootCertificate.cr to template package"
	$mapping = $allMappings | where {$_.PackageId -eq "TrustedRootCertificate.cr"}
	$resource = Get-SCCustomResource -Name "TrustedRootCertificate.cr"
	Set-SCPackageMapping -PackageMapping $mapping -TargetObject $resource
	
	#Import the service TemplatePackage
	$serviceTemplate = Import-SCTemplate -TemplatePackage $package -Name "NC Deployment service Template" -PackageMapping $allMappings -Release "1.0" -SettingsIncludePrivate

        #update the computer Name 
        if($node.IPv4AddressType -ne "")
        {
            $VirtualNetworkAdapter = Get-SCVirtualNetworkAdapter -ALL | where {$_.Name -eq "Windows Server Network Controller"}
            Set-SCVirtualNetworkAdapter -VirtualNetworkAdapter $VirtualNetworkAdapter -IPv4AddressType $node.IPv4AddressType
        }

        $Template = Get-SCVMTemplate -ALL | where {$_.ComputerName -eq "NC-VM##"}
        $ComputerNamePattern = $node.ComputerNamePrefix + "-NCVM##"
		$higlyAvailable = $false
		if($node.HighlyAvailableVMs -eq $true)
		{
		    $higlyAvailable = $true
			$VirtualDiskDrive = Get-SCVirtualDiskDrive -Template $Template
                	$StorageClassificationName = "Local Storage"
			if($node.StorageClassification -ne "")
			{
			    $StorageClassificationName = $node.StorageClassification
			
			}   
            $StorageClassification = Get-SCStorageClassification -VMMServer localhost | where {$_.Name -eq  $StorageClassificationName}

            Set-SCVirtualDiskDrive -VirtualDiskDrive $VirtualDiskDrive  -StorageClassification $StorageClassification 
		}
		    
        Set-SCVMTemplate -Template $Template -ComputerName $ComputerNamePattern -ProductKey $node.ProductKey -HighlyAvailable $higlyAvailable
}

function GetVMName
{
    # Get the VM Name which VMM will be applying for NC VM
	param([object] $node)
	
	$VMName = ""
	$VMNumericValue = 1
	
	for($VMNumericValue = 1; $VMNumericValue -le 99 ; $VMNumericValue++)
	{
	    $VMName = $node.ComputerNamePrefix + "-NCVM"
		if($VMNumericValue -lt 10)
		{
			$VMName = $VMName + "0"
			$VMName = $VMName + $VMNumericValue
		}
		else
		{
			$VMName = $VMName + $VMNumericValue
		}
		$VMName = $VMName +"."
                $VMName = $VMName + $node.ManagementDomainFDQN
		$VM = Get-SCVirtualMachine -Name $VMName
		if ($VM.count -eq 0){break}
	}
        
        LogWrite "Trimmed VMName:[$VMName]"
        return [string]$VMName

}

function generateSelfSignedCertificate
{
    param([object] $node)
		
	LogWrite " Generating the self signed certificate "
	$certFriendlyName = "NC certificate"
	
	# Get the VM Name which VMM will be applying for NC VM
	$VMName1 = GetVMName $node
	$VMName = $VMName1.ToString()
	$VMName = $VMName.Trim()
	if($node.DeploymentType -eq "Standalone")
	{
		$dnsName = $VMName
	}   
	if ($node.DeploymentType -eq "Production")
	{
		#$dnsName = $ManagementSubnet.ReservedIPset
		$dnsName = $node.RestName
	}
	#else
	#    LogWrite "Certificate can not be generated"
	
	$generatedCert = New-SelfSignedCertificate -KeyUsageProperty All -Provider "Microsoft Strong cryptographic provider" -FriendlyName $certFriendlyName -DnsName $dnsName
	
	#Export the pfx cert file
	LogWrite "Exporting the certificate"
	$certPassword = ConvertTO-SecureString -String $node.ServerCertificatePassword -Force -AsPlainText
	$certPath = "cert:\LocalMachine\My\" + $generatedCert.Thumbprint

	LogWrite " Certificate Path : $($certPath)" 
	
	#The File path parameter should be path of downloaded service template servercertificate.cr folder for NC
	$Exportedcert = Export-pfxCertificate  -Cert $certPath  -FilePath "..\Templates\NC\ServerCertificate.cr\ServerCert.pfx" -Password $certPassword
	
	#Export the cert for SLB
	$Exportedcert = Export-Certificate -Cert $certPath  -FilePath "..\Templates\NC\NCCertificate.cr\MCCert.cer"
        
}

function configureAndDeployService
{
    param([object]$node,
          [object]$ManagementVMNetwork,
          [object]$ManagementSubnet
		  )
		
	LogWrite "Starting Service Template Configuration"
	
	# Get the host group on which the service is to be deployed
	$ServiceHostGroup = Get-SCVMHostGroup -Name $node.NCHostGroupName
	
	#Get the service template
	$serviceTemplate = Get-SCServiceTemplate -Name "NC Deployment service Template"
	
	#Create a new service configuration
	$serviceConfig = New-ScServiceConfiguration -ServiceTemplate $serviceTemplate -Name "NC" -VMHostGroup $ServiceHostGroup

	#update the Management Network in Service Config
    LogWrite " getting Management Network [$LogicalNetworkCreated]"
	#$ManagementNetwork = Get-SCVMNetwork -Name "NC_Management"
	if($node.ManagementVMNetwork -eq "")
	{
		$ManagementVMNetwork = Get-SCVMNetwork -Name "NC_Management"
	}
	else
	{
		$ManagementVMNetwork = Get-SCVMNetwork -Name $node.ManagementVMNetwork
	}
	
	Get-SCServiceSetting -ServiceConfiguration $ServiceConfig -Name "Management" |Set-SCServiceSetting  -value $ManagementVMNetwork.ID

	#update the service configuration to apply placement. If there is any error,Lets stop
	$ServiceUpdate = Update-SCServiceConfiguration -ServiceConfiguration $ServiceConfig
	if($ServiceUpdate.deploymenterrorlist -ne $null)
	{       
		LogWrite "Placement failed for Service Deployment"
		exit -1
	}
	
	#set the service template settings
  
    LogWrite "Getting the service setting"
	Get-SCServiceSetting -ServiceConfiguration $ServiceConfig -Name "ClientSecurityGroup" |Set-SCServiceSetting  -value $node.ClientSecurityGroupName
  
	# Create the Local Admin Run As Account
    LogWrite "Creating Account"
	$localAdminCredPassword = ConvertTo-SecureString -String $node.LocalAdminPassword -Force -AsPlainText
	$localAdminCred = New-Object System.Management.Automation.PSCredential (".\Administrator", $localAdminCredPassword)
	$localAdminRAA = New-SCRunAsAccount -Name "NC_LocalAdminRAA" -Credential $localAdminCred -NoValidation
	Get-SCServiceSetting -ServiceConfiguration $ServiceConfig -Name "LocalAdmin" |Set-SCServiceSetting  -value $localAdminRAA                        
  
	# Create the Local Admin Run As Account
	$MgmtDomainCredPassword = ConvertTo-SecureString -String $node.ManagementDomainUserPassword -Force -AsPlainText
	$MgmtDomainCred = New-Object System.Management.Automation.PSCredential ($node.ManagementDomainUser, $MgmtDomainCredPassword)
	$MgmtAdminRAA = New-SCRunAsAccount -Name "NC_MgmtAdminRAA" -Credential $MgmtDomainCred
	Get-SCServiceSetting -ServiceConfiguration $ServiceConfig -Name "MgmtDomainAccount" |Set-SCServiceSetting  -value $MgmtAdminRAA             
	Get-SCServiceSetting -ServiceConfiguration $ServiceConfig -Name "MgmtDomainAccountName" |Set-SCServiceSetting  -value $node.ManagementDomainUser
	$domainpwd = ConvertTo-SecureString -String $node.ManagementDomainUserPassword -Force -AsPlainText
	Get-SCServiceSetting -ServiceConfiguration $ServiceConfig -Name "MgmtDomainAccountPassword" |Set-SCServiceSetting  -Securevalue $domainpwd
	Get-SCServiceSetting -ServiceConfiguration $ServiceConfig -Name "MgmtDomainFQDN" |Set-SCServiceSetting  -value $node.ManagementDomainFDQN
	Get-SCServiceSetting -ServiceConfiguration $ServiceConfig -Name "MgmtSecurityGroup" |Set-SCServiceSetting  -value $node.ManagementSecurityGroupName
	$certpassword = ConvertTo-SecureString -string $node.ServerCertificatePassword -Force -AsPlainText 
	Get-SCServiceSetting -ServiceConfiguration $ServiceConfig -Name "ServerCertificatePassword" |Set-SCServiceSetting  -Securevalue $certpassword
	
	if ($node.DeploymentType -eq "Production")
	{
	    Get-SCServiceSetting -ServiceConfiguration $ServiceConfig -Name "RestEndPoint" |Set-SCServiceSetting  -value $node.RestName
	}
	
	#create Instance of the service
    try{
        $sc= New-SCService -ServiceConfiguration $ServiceConfig
    }
    catch
    {
        undoNCDeployment $node
    }
}

function undoNCDeployment
{
	param([Object] $node)
	
    if ($NetworkControllerOnBoarder -eq $false)
    {
        # Remove the network service
        $NS = Get-SCNetworkService -All | where {$_.Name -eq "Network Controller"}
        if($NS.count -gt 0)
        {
            Remove-SCNetworkService -NetworkService $NS
        }
        
        #Remove the NC service instance
        $SCService = get-SCService -Name "NC"
        if($SCService.count -gt 0)
        {
            Remove-SCService -Service $SCService
        }
        
        #Remove service Template
        $ServiceTemplate = Get-SCServiceTemplate -Name "NC Deployment service Template"
        if($ServiceTemplate.count -gt 0)
        {
            Remove-SCServiceTemplate -ServiceTemplate $ServiceTemplate
        }       

        #Remove Virtual switches from all the Hosts
        if($node.IsLogicalSwitchDeployed -eq $false)
        {
            $Hosts = @(Get-SCVMHost | where {$_.VMHostGroup -eq $node.NCHostGroupName})
            
            if($Hosts.count > 0)
            {	
                foreach($VMHost in $Hosts){
                    $virtualSwitch = Get-SCVirtualNetwork -Name "NC_LogicalSwitch" -VMHost $VMHost
                    if($virtualSwitch.count -gt 0)
                    {
                        Remove-SCVirtualNetwork -VirtualNetwork $virtualSwitch
                        Set-SCVMHost -VMHost $VMHost
                    }
                }
            }
            
            #Remove Management Network IP Pool
            $Ippool = Get-SCStaticIPAddressPool -Name "NC_Management_IPAddressPool_0"
            if($Ippool.count -gt 0)
            {
                Remove-SCStaticIPAddressPool -StaticIPAddressPool $Ippool
            }
                
            #Remove Logical Switch
            $LS = Get-SCLogicalSwitch -Name "NC_LogicalSwitch"
            if($LS.count -gt 0)
            {
                Remove-SCLogicalSwitch -LogicalSwitch $LS 
            }
            
            #Remove uplink
            $Uplink = Get-SCNativeUplinkPortProfile -Name $node.UplinkPortProfile
            if($Uplink.count -gt 0)
            {
                Remove-SCNativeUplinkPortProfile -NativeUplinkPortProfile $Uplink
            }

            #Remove Management VM Network
            $VMNetwork = Get-SCVMNetwork -Name "NC_Management"
            Remove-SCVMNetwork -VMNetwork $VMNetwork
            
            #Remove Logical Network
                #Remove Network Definition
            $logicalNetwork = Get-SCLogicalNetwork -Name "NC_Management"
            if($logicalNetwork.count -gt 0)
            {
                Set-SCLogicalNetwork -Name "NC_Management" -Description "" -LogicalNetwork $logicalNetwork -RunAsynchronously -EnableNetworkVirtualization $false -UseGRE $false -LogicalNetworkDefinitionIsolation $false
                $logicalNetworkDefinition = Get-SCLogicalNetworkDefinition -Name "NC_Management_0"
                if($logicalNetworkDefinition.count -gt 0)
                {
                	Remove-SCLogicalNetworkDefinition -LogicalNetworkDefinition $logicalNetworkDefinition
                }        
                Remove-SCLogicalNetwork -LogicalNetwork $logicalNetwork	
            }
        }
		#Remove Run AS Accounts
        $RA = Get-SCRunAsAccount -Name "NC_MgmtAdminRAA"
        if($RA.count -gt 0)
        {
            Remove-SCRunAsAccount -RunAsAccount $RA
        }
        
        $RA = Get-SCRunAsAccount -Name "NC_LocalAdminRAA"
        if($RA.count -gt 0)
        {
            Remove-SCRunAsAccount -RunAsAccount $RA
        }
    }
}

function createLogicalNetwork
{
    param([Object] $node,
          [object] $ln,
          [boolean] $ManagedByNC
          )
    
    
	if($ManagedByNC -eq $true)
	{
		#Wait for issue where creation can run before network controller returns
		$NetController = $null
		$i=1
		while (!$NetController) {
			sleep 10
			LogWrite "Obtaining Network Controller for logical network creation - attempt $i"
			$NetController = Get-SCVirtualSwitchExtensionManager -All | where {$_.Name -eq "Network Controller"}
			$i++
			if ($i -gt 20) { 
				LogWrite "Error obtaining network controller"
				break 
			}
		}
		
		if($ln.Name -eq "PublicVIP")
		{
		    $LogicalNetworkCreated = New-SCLogicalNetwork -Name $ln.Name -LogicalNetworkDefinitionIsolation $false -EnableNetworkVirtualization $false -UseGRE $false -IsPVLAN $false -NetworkController $NetController -PublicIPNetwork
		}
		elseif($ln.Name -eq "PrivateVIP" -or $ln.Name -eq "GREVIP")	
		{
			$LogicalNetworkCreated = New-SCLogicalNetwork -Name $ln.Name -LogicalNetworkDefinitionIsolation $false -EnableNetworkVirtualization $false -UseGRE $false -IsPVLAN $false -NetworkController $NetController
		}
	    elseif($ln.Name -eq "HNVPA")
		{
			$LogicalNetworkCreated = New-SCLogicalNetwork -Name $ln.Name -LogicalNetworkDefinitionIsolation $false -EnableNetworkVirtualization $true -UseGRE $true -IsPVLAN $false -NetworkController $NetController 
		}
		else
		{
			$LogicalNetworkCreated = New-SCLogicalNetwork -Name $ln.Name -LogicalNetworkDefinitionIsolation $false -EnableNetworkVirtualization $false -UseGRE $false -IsPVLAN $false -NetworkController $NetController 
		}
	}
	else
	{
		$LogicalNetworkCreated = New-SCLogicalNetwork -Name $ln.Name -LogicalNetworkDefinitionIsolation $false -EnableNetworkVirtualization $false -UseGRE $false -IsPVLAN $false
	}			
    LogWrite "Getting the Host group with Name [$node.NCHostGroupName]"
    $allHostGroups = @()
    $allHostGroups += Get-SCVMHostGroup -Name $node.NCHostGroupName

    LogWrite "Creating VLAN subnet for subnet [$node.LogicalNetworkIPSubnet] and VLAN Id [$node.LogicalNetworkVLAN]"
    $allSubnetVLAN = @()
    $allSubnetVLAN += New-SCSubnetVLAN -Subnet $ln.subnets[0].AddressPrefix -VLanID $ln.subnets[0].VLANID
    $VLANId = $ln.subnets[0].VLANID

    LogWrite "Creating new Logical Network Definition"
    $LNDName = $ln.Name + "_0"    
    $createdLND = New-SCLogicalNetworkDefinition -Name $LNDName -LogicalNetwork $LogicalNetworkCreated -VMHostGroup $allHostGroups -SubnetVLan $allSubnetVLAN

    LogWrite " create a VMNetwork with the same name as Logical Network"
    if($ln.Name -ne "HNVPA")
    {
    $ManagementVMNetwork = New-SCVMNetwork -Name $ln.Name -IsolationType "NoIsolation" -LogicalNetwork $LogicalNetworkCreated
    }

    LogWrite "Management Logical Network Deployment completed succssfully"

    #Create IP Pool for the created Management Logical Network
    $subnet = $ln.subnets[0]
    $ManagementSubnet = $subnet
    $allGateways =@()
    $allGateways += New-SCDefaultGateway -IPAddress $subnet.Gateways -Automatic

    if($subnet.DNS.count -eq 0)
    {
        LogWrite " DNS setttings are mandatory for NC deployment to succeed"
        return -1
    }
                    
    $IPAddressPoolName = $ln.Name + "_IPAddressPool_0"

    if($ln.Name -eq "NC_Management")
    {
        $staticIP = New-SCStaticIPAddressPool -Name $IPAddressPoolName -LogicalNetworkDefinition $createdLND -Subnet $subnet.AddressPrefix -IPAddressRangeStart $subnet.PoolStart -IPAddressRangeEnd $subnet.PoolEnd -DefaultGateway $allGateways -DNSServer $subnet.DNS -IPAddressReservedSet $subnet.ReservedIPset
    }
    elseif($ln.Name -eq "PublicVIP" -or $ln.Name -eq "PrivateVIP" -or $ln.Name -eq "GREVIP" )
    {
       $VIPAddressSet = ""
       $VIPAddressSet += $subnet.PoolStart 
       $VIPAddressSet += "-" 
       $VIPAddressSet += $subnet.PoolEnd
	   $staticIP = New-SCStaticIPAddressPool -Name $IPAddressPoolName -LogicalNetworkDefinition $createdLND -Subnet $subnet.AddressPrefix -IPAddressRangeStart $subnet.PoolStart -IPAddressRangeEnd $subnet.PoolEnd -DefaultGateway $allGateways -DNSServer $subnet.DNS -VIPAddressSet $VIPAddressSet
	}
    else
    {
        $staticIP = New-SCStaticIPAddressPool -Name $IPAddressPoolName -LogicalNetworkDefinition $createdLND -Subnet $subnet.AddressPrefix -IPAddressRangeStart $subnet.PoolStart -IPAddressRangeEnd $subnet.PoolEnd -DefaultGateway $allGateways -DNSServer $subnet.DNS
    }

    LogWrite " Created Logical Network : $LogicalNetworkCreated"
    return $LogicalNetworkCreated
}

function createLogicalSwitchAndDeployOnHosts
{
    param ([object] $node,
           [object] $ManagementVMNetwork,
           [string] $LNDName,
           [Int] $VLANId)

    $logicalSwitchName = "NC_LogicalSwitch"
    LogWrite " creating logical switch [$logicalSwitchName]"
    
    #TODO: Handle the teaming aspect as well. Need to get the required parameters from user for this.
    $createdLogicalSwitch = New-SCLogicalSwitch -Name $logicalSwitchName -Description "This logical switch is used for SDN purpose" -EnableSriov $false -SwitchUplinkMode "EmbeddedTeam" -MinimumBandwidthMode "Weight"
    
    #Add uplink profile and VNic to the switch
    $LogicalNetworkDefinition = @()
    $LogicalNetworkDefinition += Get-SCLogicalNetworkDefinition -Name $LNDName
    $createdUpLinkProfile = New-SCNativeUplinkPortProfile -Name $node.UplinkPortProfile -Description " This uplink is used by Logical Switch for SDN" -LogicalNetworkDefinition $LogicalNetworkDefinition -EnableNetworkVirtualization $false -LBFOLoadBalancingAlgorithm "HostDefault" -LBFOTeamMode "SwitchIndependent"
    
    # set the uplink port profile to Logical Switch
    $uppSetVar = New-SCUplinkPortProfileSet -Name $createdUpLinkProfile.Name -LogicalSwitch $createdLogicalSwitch -NativeUplinkPortProfile $createdUpLinkProfile
    
    #Add VNic to the UpLink Port Profile
    if($VLANId -eq 0)
    {
       $VNic = New-SCLogicalSwitchVirtualNetworkAdapter -Name "NC_VNic" -UplinkPortProfileSet $uppSetVar -VMNetwork $ManagementVMNetwork -VLanEnabled $false -IsUsedForHostManagement $true -InheritsAddressFromPhysicalNetworkAdapter $true -IPv4AddressType "Dynamic" -IPv6AddressType "Dynamic"
    }
    else
    {
        $VNic = New-SCLogicalSwitchVirtualNetworkAdapter -Name "NC_VNic" -UplinkPortProfileSet $uppSetVar -VMNetwork $ManagementVMNetwork -VLanEnabled $true -VLANId $VLANId  -IsUsedForHostManagement $true -InheritsAddressFromPhysicalNetworkAdapter $true -IPv4AddressType "Dynamic" -IPv6AddressType "Dynamic"
    }
    
    # Deploy the Logical Switch on all host in the host group
		
    $Hosts = @(Get-SCVMHost | where {$_.VMHostGroup -eq $node.NCHostGroupName})

    foreach($VMHost in $Hosts){
		
        #Get network Adapter on this hots with VLANMode = Trunk and ConnectionState = connecetd. The
        #switch will be deployed on this physical NetworkAdapter
        $NetworkAdapter = @(Get-SCVMHostNetworkAdapter -VMHost $VMHost | where {$_.VLanMode -eq "Trunk" -and $_.ConnectionState -eq "Connected" -and $_.LogicalNetworkMap.count -eq 0})
        if($NetworkAdapter.count -eq 0)
        {
             LogWrite "Warning: There is no available Network Adapter for NC Virtual Switch on host : $VMHost " 
        }

        #Set the Network Adapter
        Set-SCVMHostNetworkAdapter -VMHostNetworkAdapter $NetworkAdapter[0] -UplinkPortProfileSet $uppSetVar

        #create new virtual Network
        New-SCVirtualNetwork -VMHost $VMHost -VMHostNetworkAdapters $NetworkAdapter[0] -LogicalSwitch $createdLogicalSwitch -DeployVirtualNetworkAdapters

        #Set the VMHost
        Set-SCVMHost -VMHost $VMHost
    }
    
    return $createdLogicalSwitch
}

function CreateLogicalNetworkWrapper
{
    param([object]$node,
	      [string]$LogicalNetworkType,
		  [boolean] $ManagedByNC)
		  
    foreach ($ln in $node.LogicalNetworks)
	{
		if($ln.Name -eq $LogicalNetworkType){
	
			LogWrite "Starting to create Management Logical Network [$LogicalNetworkType]"
			
			#Create the logical Network
			$LogicalNetworkCreated = createLogicalNetwork $node $ln $ManagedByNC
		}
	}
	return $LogicalNetworkCreated
}

function AssociateLogicalNetWithUPP
{
	param([string] $LogicalNetwork,
           [String] $UplinkPortProfile)
	
	#Get the LogicalNetwork
	$LogNet = Get-SCLogicalNetwork -Name $LogicalNetwork

    # Get the logical Network Definition
    $LogicalNetworkDefinition = Get-SCLogicalNetworkDefinition -LogicalNetwork 	$LogNet
	
	#Get the NC uplink port profile
	$uplink = Get-SCNativeUplinkPortProfile -Name $UplinkPortProfile
	
	#Set the uplink port profile
    Set-SCNativeUplinkPortProfile -NativeUplinkPortProfile $uplink -AddLogicalNetworkDefinition $LogicalNetworkDefinition
}

function ImportSLBServiceTemplate
{
	param ([object] $node)
	
	#identify the name of service template
	$serviceTemplateLocation = Split-Path -Path $pwd
	$serviceResourceLoation = $serviceTemplateLocation + "\Templates\NC\"
	$serviceTemplateLocation = $serviceTemplateLocation + "\Templates\SLB\"
	$ServiceTemplateName = "SLB Production "
	
	if($node.Generation -eq "Gen1")
	{
		$ServiceTemplateName = $ServiceTemplateName + "Generation 1 VM.xml"
	}
	if($node.Generation -eq "Gen2")
	{
		$ServiceTemplateName = $ServiceTemplateName + "Generation 2 VM.xml"
	}    
	$PackagePath = $serviceTemplateLocation + $ServiceTemplateName
	
	#Get the package
	$package = Get-SCTemplatePackage -Path $PackagePath
	
	#Get the package mapping
	$allMappings = New-SCPackageMapping -TemplatePackage $package
	
	#start mapping the resources
	
	#MAP the VHD
	LogWrite "Mapping VHD to template package"
	if($node.Generation -eq "Gen1")
	{
	$mapping = $allMappings | where {$_.PackageId -eq "Winserver.vhd"}
	}
	else
	{
	$mapping = $allMappings | where {$_.PackageId -eq "Winserver.vhdx"}
	}
	$resource = Get-SCVirtualHardDisk -Name $node.VHDName
	Set-SCPackageMapping -PackageMapping $mapping -TargetObject $resource
	
	#MAP NCCertificate.cr
	$VMMLibrary = $node.VMMLibrary
	#$VMMLibrary = Get-SCLibraryShare
	$NCsetupPath = $serviceResourceLoation + "\NCCertificate.cr\"
	Import-SCLibraryPhysicalResource -SourcePath $NCsetupPath -SharePath $VMMLibrary -OverwriteExistingFiles
	
	LogWrite "Mapping NCCertificate.cr to template package"
	$mapping = $allMappings | where {$_.PackageId -eq "NCCertificate.cr"}
	$resource = Get-SCCustomResource -Name "NCCertificate.cr"
	Set-SCPackageMapping -PackageMapping $mapping -TargetObject $resource 

	#MAP EdgeDeployment.cr
	$NCsetupPath = $serviceResourceLoation + "\EdgeDeployment.cr\"
	Import-SCLibraryPhysicalResource -SourcePath $NCsetupPath -SharePath $VMMLibrary -OverwriteExistingFiles
	
	LogWrite "Mapping EdgeDeployment.cr to template package"
	$mapping = $allMappings | where {$_.PackageId -eq "EdgeDeployment.cr"}
	$resource = Get-SCCustomResource -Name "EdgeDeployment.cr"
	Set-SCPackageMapping -PackageMapping $mapping -TargetObject $resource
	
	#Import the service TemplatePackage
	$serviceTemplate = Import-SCTemplate -TemplatePackage $package -Name "SLB Deployment service Template" -PackageMapping $allMappings -Release "1.0" -SettingsIncludePrivate
	
    $Template = Get-SCVMTemplate -ALL | where {$_.ComputerName -eq "muxvm###"}
    $ComputerNamePattern = $node.ComputerNamePrefix + "-MUXVM##"
	
	$higlyAvailable = $false
	if($node.HighlyAvailableVMs -eq $true)
	{
	    $higlyAvailable = $true
	    $VirtualDiskDrive = Get-SCVirtualDiskDrive -Template $Template 
            $StorageClassificationName = "Local Storage"
	    if($node.StorageClassification -ne "")
	    {
		$StorageClassificationName = $node.StorageClassification
		
	    }   
        $StorageClassification = Get-SCStorageClassification -VMMServer localhost | where {$_.Name -eq $StorageClassificationName}

        Set-SCVirtualDiskDrive -VirtualDiskDrive $VirtualDiskDrive  -StorageClassification $StorageClassification 
	}

    Set-SCVMTemplate -Template $Template -ComputerName $ComputerNamePattern -ProductKey $node.ProductKey -HighlyAvailable $higlyAvailable
}

function ConfigureAndDeploySLBService
{

    param([object] $node)
    
    LogWrite "Starting Service Template Configuration for SLB"
	
	# Get the host group on which the service is to be deployed
	$ServiceHostGroup = Get-SCVMHostGroup -Name $node.NCHostGroupName
	
	#Get the service template
	$serviceTemplate = Get-SCServiceTemplate -Name "SLB Deployment service Template"

    #Resolve the service Template
    Resolve-SCServiceTemplate -ServiceTemplate $serviceTemplate -update
	
	#Create a new service configuration
	$serviceConfig = New-ScServiceConfiguration -ServiceTemplate $serviceTemplate -Name "Software Load Balancer" -VMHostGroup $ServiceHostGroup
	
	# Set Management Network
    if($node.IsManagementVMNetworkExisting -eq $true)
    {
        $ManagementNetwork = Get-SCVMNetwork -Name $node.ManagementVMNetwork
    }
    else
    {
	    $ManagementNetwork = Get-SCVMNetwork -Name "NC_Management"
    }
	Get-SCServiceSetting -ServiceConfiguration $ServiceConfig -Name "ManagementNetwork" |Set-SCServiceSetting  -value $ManagementNetwork.ID
    
    # Set Transit Network
    $TransitNetwork = Get-SCVMNetwork -Name "Transit"
    Get-SCServiceSetting -ServiceConfiguration $ServiceConfig -Name "TransitNetwork" |Set-SCServiceSetting  -value $TransitNetwork.ID

	#update the service configuration to apply placement. If there is any error,Lets stop
	$ServiceUpdate = Update-SCServiceConfiguration -ServiceConfiguration $ServiceConfig
	if($ServiceUpdate.deploymenterrorlist -ne $null)
	{       
		LogWrite "Placement failed for Service Deployment"
		exit -1
	}
	
	#set the service template settings
      
	# Create the Local Admin Run As Account
    
	$localAdminRAA = Get-SCRunAsAccount -Name "NC_LocalAdminRAA" 
	Get-SCServiceSetting -ServiceConfiguration $ServiceConfig -Name "LocalAdmin" |Set-SCServiceSetting  -value $localAdminRAA                        
  
	# Create the Local Admin Run As Account
	$MgmtAdminRAA = Get-SCRunAsAccount -Name "NC_MgmtAdminRAA" 
	Get-SCServiceSetting -ServiceConfiguration $ServiceConfig -Name "MgmtDomainAccount" |Set-SCServiceSetting  -value $MgmtAdminRAA             
	Get-SCServiceSetting -ServiceConfiguration $ServiceConfig -Name "MgmtDomainFQDN" |Set-SCServiceSetting  -value $node.ManagementDomainFDQN
    Get-SCServiceSetting -ServiceConfiguration $ServiceConfig -Name "SelfSignedConfiguration" |Set-SCServiceSetting  -value $node.IsCertSelfSigned
	
	#create Instance of the service
	$sc= New-SCService -ServiceConfiguration $ServiceConfig

}

function DeploySLB
{
	param([object] $node)
	
    #Import SLB Service Template
	ImportSLBServiceTemplate $node
	
	#Configure and Deploy SLB
	ConfigureAndDeploySLBService $node
}

function OnboardSLB
{
	param([object] $node)
	
	$networkService = Get-SCNetworkService -Name "Network Controller"
	
	$fabricRole = Get-SCFabricRole -NetworkService $networkService | where {$_.RoleType -eq "LoadBalancer"}
	
	#get the last IP address of Private VIP
	$ippool = Get-SCStaticIPAddressPool -Name "PrivateVIP_IPAddressPool_0"
	$LBManagerIPAddress = $ippool.IPAddressRangeEnd
	
    $vipPools = @()
    $vipPools += Get-SCStaticIPAddressPool -Name "PrivateVIP_IPAddressPool_0"
    $vipPools += Get-SCStaticIPAddressPool -Name "PublicVIP_IPAddressPool_0"
   	$natIPExemptions = @()
	
	$fabricRoleConfiguration = New-SCLoadBalancerRoleConfiguration -LBManagerIPAddress $LBManagerIPAddress -NatIPExemptions $natIPExemptions -VipPools $vipPools
	
    $fabricRole = Set-SCFabricRole -FabricRole $fabricRole -LoadBalancerConfiguration $fabricRoleConfiguration
	
	# Get Service Instance 'SLB'
    $service = Get-SCService -Name "Software Load Balancer"
    # Get RunAs Account 'NC_MgmtAdminRAA'
    $runAsAccount = Get-SCRunAsAccount -Name "NC_MgmtAdminRAA"
    Add-SCFabricRoleResource -FabricRole $fabricRole -ServiceInstance $service -RunAsAccount $runAsAccount 
	
	
}

function importGatewayTemplate
{

	param ([object]$node)
	
	#identify the name of service template
	$serviceTemplateLocation = Split-Path -Path $pwd
			$serviceTemplateLocation = $serviceTemplateLocation + "\Templates\GW\"
	$ServiceTemplateName = "EdgeServiceTemplate_"
	
	if($node.Generation -eq "Gen1")
	{
		$ServiceTemplateName = $ServiceTemplateName + "Generation1.xml"
	}
	if($node.Generation -eq "Gen2")
	{
		$ServiceTemplateName = $ServiceTemplateName + "Generation2.xml"
	}    
	$PackagePath = $serviceTemplateLocation + $ServiceTemplateName
	
	#Get the package
	$package = Get-SCTemplatePackage -Path $PackagePath
	
	#Get the package mapping
	$allMappings = New-SCPackageMapping -TemplatePackage $package
	
	#start mapping the resources
	
	#MAP the VHD
	LogWrite "Mapping VHD to template package"
	if($node.Generation -eq "Gen1")
	{
	$mapping = $allMappings | where {$_.PackageId -eq "Winserver.vhd"}
	}
	else
	{
	$mapping = $allMappings | where {$_.PackageId -eq "Winserver.vhdx"}
	}
	$resource = Get-SCVirtualHardDisk -Name $node.VHDName
	Set-SCPackageMapping -PackageMapping $mapping -TargetObject $resource
	
		
	LogWrite "Mapping EdgeDeployment.cr to template package"
	$mapping = $allMappings | where {$_.PackageId -eq "EdgeDeployment.cr"}
	$resource = Get-SCCustomResource -Name "EdgeDeployment.cr"
	Set-SCPackageMapping -PackageMapping $mapping -TargetObject $resource
	
	#Import the service TemplatePackage
	$serviceTemplate = Import-SCTemplate -TemplatePackage $package -Name "Gateway Deployment service Template" -PackageMapping $allMappings -Release "1.0" -SettingsIncludePrivate
	
	$Template = Get-SCVMTemplate -ALL | where {$_.ComputerName -eq "GW-VM###"}
    $ComputerNamePattern = $node.ComputerNamePrefix + "-GW-VM##"
	
	$higlyAvailable = $false
	if($node.HighlyAvailableVMs -eq $true)
	{
	    $higlyAvailable = $true
	    $VirtualDiskDrive = Get-SCVirtualDiskDrive -Template $Template
            $StorageClassificationName = "Local Storage"
	    if($node.StorageClassification -ne "")
	    {
	       $StorageClassificationName = $node.StorageClassification
	 
	    }   
            $StorageClassification = Get-SCStorageClassification -VMMServer localhost | where {$_.Name -eq $StorageClassificationName}

            Set-SCVirtualDiskDrive -VirtualDiskDrive $VirtualDiskDrive  -StorageClassification $StorageClassification 
	}
    Set-SCVMTemplate -Template $Template -ComputerName $ComputerNamePattern -ProductKey $node.ProductKey -HighlyAvailable $higlyAvailable

	
}

function ConfigureAndDeployGatewayService
{

    param([object] $node)
    
    LogWrite "Starting Service Template Configuration for Gateway"
	
	# Get the host group on which the service is to be deployed
	$ServiceHostGroup = Get-SCVMHostGroup -Name $node.NCHostGroupName
	
	#Get the service template
	$serviceTemplate = Get-SCServiceTemplate -Name "Gateway Deployment service Template"

    #Resolve the service Template
    Resolve-SCServiceTemplate -ServiceTemplate $serviceTemplate -update

	
	#Create a new service configuration
	$serviceConfig = New-ScServiceConfiguration -ServiceTemplate $serviceTemplate -Name "Gateway Manager" -VMHostGroup $ServiceHostGroup

	
	# Set Management Network
    if($node.IsManagementVMNetworkExisting -eq $true)
    {
        $ManagementNetwork = Get-SCVMNetwork -Name $node.ManagementVMNetwork
    }
    else
    {
        $ManagementNetwork = Get-SCVMNetwork -Name "NC_Management"
    }
    
	Get-SCServiceSetting -ServiceConfiguration $ServiceConfig -Name "ManagementNetwork" |Set-SCServiceSetting  -value $ManagementNetwork.ID
        

	#update the service configuration to apply placement. If there is any error,Lets stop
	$ServiceUpdate = Update-SCServiceConfiguration -ServiceConfiguration $ServiceConfig
	if($ServiceUpdate.deploymenterrorlist -ne $null)
	{       

		LogWrite "Placement failed for Service Deployment"
		exit -1
	}
	
	#set the service template settings
      
	# Create the Local Admin Run As Account
    
	$localAdminRAA = Get-SCRunAsAccount -Name "NC_LocalAdminRAA" 
	Get-SCServiceSetting -ServiceConfiguration $ServiceConfig -Name "AdminAccount" |Set-SCServiceSetting  -value $localAdminRAA                        
  
	# Create the Local Admin Run As Account
	$MgmtAdminRAA = Get-SCRunAsAccount -Name "NC_MgmtAdminRAA" 
	Get-SCServiceSetting -ServiceConfiguration $ServiceConfig -Name "MgmtDomainAccount" |Set-SCServiceSetting  -value $MgmtAdminRAA             
	Get-SCServiceSetting -ServiceConfiguration $ServiceConfig -Name "MgmtDomainFQDN" |Set-SCServiceSetting  -value $node.ManagementDomainFDQN
    Get-SCServiceSetting -ServiceConfiguration $ServiceConfig -Name "SelfSignedConfiguration" |Set-SCServiceSetting  -value $node.IsCertSelfSigned
	
	#create Instance of the service
	$sc= New-SCService -ServiceConfiguration $ServiceConfig

}

function DeployGateway
{
	param([object]$node)
	
	#import Gateway template
	importGatewayTemplate $node
	
	#configure and deploy gateway
	ConfigureAndDeployGatewayService $node

}

function OnboardGateway
{
    param([object]$node)
    
    $networkService = Get-SCNetworkService -Name "Network Controller"
	
	$fabricRole = Get-SCFabricRole -NetworkService $networkService | where {$_.RoleType -eq "Gateway"}
	
	#get the last IP address of Private VIP
	$GREVIP = get-SCLogicalNetworkDefinition -Name "GREVIP_0"
	$subnetVlansGreVip = @()
    $subnetVlanGreVipIPv4 = New-SCSubnetVLan -Subnet $GREVIP[0].SubnetVLans[0].Subnet  -VLanID $GREVIP[0].SubnetVLans[0].VLanID
    $subnetVlansGreVip += $subnetVlanGreVipIPv4
    
    $ippool = Get-SCStaticIPAddressPool -Name "PublicVIP_IPAddressPool_0"
    $publicIPV4Address = Grant-SCIPAddress -PublicIPAddress -NetworkController $networkController -IPAddress $ippool.IPAddressRangeEnd
    $publicIPAddresses = @()
    $publicIPAddresses += $publicIPV4Address
	
	$fabricRoleConfiguration = New-SCGatewayRoleConfiguration -GatewayCapacityKbps 1024000 -PublicIPAddresses $publicIPAddresses -RedundantResourceCount 0 -GreVipSubnets $subnetVlansGreVip
	$fabricRole = Set-SCFabricRole -FabricRole $fabricRole -GatewayConfiguration $fabricRoleConfiguration

	# Get Service Instance 'SLB'
    $service = Get-SCService -Name "Gateway Manager"
    # Get RunAs Account 'NC_LocalAdminRAA'
    $runAsAccount = Get-SCRunAsAccount -Name "NC_LocalAdminRAA"
    $compTier = Get-SCComputerTier -Service $service
	
    $Transit = get-SCLogicalNetworkDefinition -Name "Transit_0"
    $subnetVlanIPv4 = New-SCSubnetVLan -Subnet  $Transit.SubnetVLans[0].Subnet -VLanID $Transit.SubnetVLans[0].VLanID
	
	foreach ($VM in $compTier.VMs)
	{
	   $vmFabricRoleResource = $fabricRole.ServiceVMs | where { $_.Resource -eq $VM }
	   Add-SCFabricRoleResource -FabricRole $fabricRole -VirtualMachine $VM -IPv4Subnet $subnetVlanIPv4 -RunAsAccount $runAsAccount
	
	}		

}


################################################################
#        Main Body to execute VMM Express                      #
################################################################

$ErrorActionPreference = "stop"

$NetworkControllerOnBoarder = $false
if ($psCmdlet.ParameterSetName -ne "NoParameters") {

    $global:stopwatch = [Diagnostics.Stopwatch]::StartNew()
	LogWrite "*****************************************************"
	LogWrite "*** $($(get-date -format u)) : New Deployment started ***"
	LogWrite "*****************************************************"
	
    switch ($psCmdlet.ParameterSetName) 
    {
        "ConfigurationFile" {
            LogWrite "Using configuration from file [$ConfigurationDataFile]"
            $configdata = [hashtable] (iex (gc $ConfigurationDataFile | out-string))
        }
        "ConfigurationData" {
            LogWritee "Using configuration passed in from parameter"
            $configdata = $configurationData 
        }
    }
		
	try{
		# Get the node parameter from configdata 
		$node =  $configdata.AllNodes[0]
        if($node.UplinkPortProfile -eq "")
        {
            $node.UplinkPortProfile  = "NC_Uplink"
        }
		
		 # Get the VMM server. The connection to VMM server will be made by this    
        LogWrite "Getting VMM server connection with VMM server [$(gc env:computername)]"
		$VMMServer = Get-SCVMMServer -ComputerName localhost
		
		#check that all parameters are specified
        LogWrite "Checking the Fabric Configuration Input Parameters"
		checkParameters $node 	   
		
		#####################################################
		#STAGE 1: Create Management Logical Network         #
		#####################################################
		
		#check if the management Network is created or not
		
          if($node.DeployNC -eq $true)
	  {
		$LNDName =''
		$ManagementVMNetwork
		$ManagementSubnet
		$LogicalNetworkCreated
		$VLANId
		
		if($node.IsManagementVMNetworkExisting -eq $false)
		{
			#Deploy Management Network and switch only if they are not deployed	
		 
            LogWrite "Logical Network and Logical Switch is not Pre-configured."
			foreach ($ln in $node.LogicalNetworks)
			{
				if($ln.Name -eq "NC_Management"){
			
					LogWrite "Starting to create Management Logical Network [$($node.LogicalNetworkName)]"
					
					#Create the logical Network
					$LogicalNetworkCreated = createLogicalNetwork $node $ln $false
					
					#Create IP Pool for the created Management Logical Network
					$subnet = $ln.subnets[0]
					$ManagementSubnet = $subnet	
				   
					#Logical Network Definition Name 
					$LNDName = $ln.Name + "_0"   

					# Get the Management VM NetworkAdapter
					$ManagementVMNetwork = Get-SCVMNetwork -Name $ln.Name 

					#Get the VLANID
					$VLANId = $ln.subnets[0].VLANID 
					LogWrite " Logical Network creation succeeded"                               
				}
			}
		
			#####################################################################
			#STAGE 2: Create the Logical switch. This logical switch should be  #
            #         deployed on all the Hosts in this host group              #
			#####################################################################
		    LogWrite "Creating Logical Switch and Deploying to all Hosts in Host Group : [$($node.NCHostGroupName)]"    
			$logicalSwitchCreated = createLogicalSwitchAndDeployOnHosts $node $ManagementVMNetwork $LNDName $VLANId
		}	
		
		##########################################################################   
		#STAGE 3: Prepare the certificates if it has to be self signed. And copy #
        #         the required certificate in correspoding *.cr folder           # 
		#         so that the service template could be imported successfully    #                                                                
		##########################################################################

        
        if($node.IsCertSelfSigned -eq $true)
        {
            LogWrite "Generating Self-Signed Certificate.."
            generateSelfSignedCertificate $node
        }
        else
        {
            LogWrite "You have decided to use CA certificate. Hope you Placed the Cert in \Templates\NC\TrustedRootCertificate.cr folder "
        }
        $VMName = GetVMName $node
        LogWrite "Recieved VMName : [$VMName]"        
        LogWrite "VmName : [$VMName]"
						
		################################################    
		#STAGE 4: Import the service template into VMM #
		################################################
		
		importServiceTemplate $node 
				
		#########################################################
		#STAGE 5 : Configure the service template and deploy    #
		#########################################################
		
		configureAndDeployService $node $ManagementVMNetwork $ManagementSubnet
				
		###########################################################################################
		# STAGE 6 : On Board NC                                                                   #
		###########################################################################################	

        #sleep for 2 min so that netwrok controller deployment stables
        Start-Sleep -s 120
        #onboard network controller		
		OnBoardNetworkController $node $ManagementSubnet $VMName
        $NetworkControllerOnBoarder = $true
        }
		#Onboard for 2 mins and then create HNVPA logical network Managed by NC
		Start-Sleep -s 120	

        ######################################################################
        # create other required logical networks which will be managed by NC #
        ######################################################################
 if($node.createNCManagedNetworks -eq $true)
		{
        
        #create HNVPA
        $LogicalNetworkType = "HNVPA"
		$HNVPA = CreateLogicalNetworkWrapper $node $LogicalNetworkType $true
        AssociateLogicalNetWithUPP $LogicalNetworkType $node.UplinkPortProfile

        #create Transit Logical Network and associate the Logical network definition to NC uplink
        $LogicalNetworkType = "Transit"
        $HNVPA = CreateLogicalNetworkWrapper $node $LogicalNetworkType $true		
        AssociateLogicalNetWithUPP $LogicalNetworkType $node.UplinkPortProfile
	
        #Create Private VIP Logical Network
        $LogicalNetworkType = "PrivateVIP"
        $HNVPA = CreateLogicalNetworkWrapper $node $LogicalNetworkType $true
        
        #Create GREVIP
        $LogicalNetworkType = "GREVIP"
        $HNVPA = CreateLogicalNetworkWrapper $node $LogicalNetworkType $true
	
        #Create Public VIP logical netwrok
        $LogicalNetworkType = "PublicVIP"
        $HNVPA = CreateLogicalNetworkWrapper $node $LogicalNetworkType $true	        
	}	
		###############################################################
		#  Deploy and onboard SLB
		################################################################
		
        if($node.DeploySLB -eq $true)
        {	
			# Deploy SLB
			DeploySLB $node
			
			#Onboard SLB
			OnboardSLB $node
		}
		
		###############################################################
		#  Deploy and onboard Gateway
		################################################################
		if( $node.DeployGW -eq $true )
		{
            #Deploy Gateway
			DeployGateway $node	

            #Onboard gateway            
			OnboardGateway $node  
        }		
		LogWrite "Deployment complete." 
		
    }
	catch
	{       
			LogWrite "The deployment was not successful." 
			LogWrite "Reason:  $($error[0])"    
			LogWrite "Cleaning up the system to get in previous state..."
			
			$originalError = $error[0]
            #cleanup the setup
			undoNCDeployment $node
			
			write-error $originalError
	}
    
} 
