Param(
    [string][parameter(Mandatory=$true, Position = 0)] $selfSignedSetup,
    [string][parameter(Mandatory=$false, Position = 1)] $ControllerDefaultSubjectName = "",
    [bool][parameter(Mandatory=$false,Position = 2)] $UseManagementAddress=$false,
	[string][parameter(Mandatory=$false,Position = 3)] $ControllerCertificateFolder="c:\MuxInstall\NCCertificate\"	
)

#------------------------------------------
# Logging helper functions
#------------------------------------------
Function PrettyTime()
{
    return "[" + (Get-Date -Format o) + "]"
}

Function Log($msg)
{
    Write-Verbose $( $(PrettyTime) + " " + $msg) -Verbose
}

function GetSubjectName([bool] $UseManagementAddress)
{
	if ($UseManagementAddress -eq $true)
	{
		# When IP Address is specified, we are currently looking just for IPv4 corpnet ip address
		# In the final design, only computer names will be used for subject names
		$corpIPAddresses = get-netIpAddress -AddressFamily IPv4 -PrefixOrigin Dhcp -ErrorAction Ignore
		if ($corpIPAddresses -ne $null -and $corpIPAddresses[0] -ne $null)
		{
			$mesg = [System.String]::Format("Using IP Address {0} for certificate subject name", $corpIPAddresses[0].IPAddress);
			Log $mesg
			return $corpIPAddresses[0].IPAddress
		}
		else
		{
			Log "Unable to find management IP address ";
		}
	}
	
	$hostFqdn = [System.Net.Dns]::GetHostByName(($env:computerName)).HostName;
	$mesg = [System.String]::Format("Using computer name {0} for certificate subject name", $hostFqdn);
	Log $mesg
    return $hostFqdn ;
}

function GenerateSelfSignedCertificate([string] $subjectName)
{
    $cryptographicProviderName = "Microsoft Base Cryptographic Provider v1.0";
    [int] $privateKeyLength = 1024;
    $sslServerOidString = "1.3.6.1.5.5.7.3.1";
	$SslNetworkControllerOidString = "1.3.6.1.4.1.311.95.1.1.1";
    [int] $validityPeriodInYear = 5;

    $name = new-object -com "X509Enrollment.CX500DistinguishedName.1"
    $name.Encode("CN=" + $SubjectName, 0)

	$mesg = [System.String]::Format("Generating certificate with subject Name {0}", $subjectName);
	Log $mesg


    #Generate Key
    $key = new-object -com "X509Enrollment.CX509PrivateKey.1"
    $key.ProviderName = $cryptographicProviderName
    $key.KeySpec = 1 #X509KeySpec.XCN_AT_KEYEXCHANGE
    $key.Length = $privateKeyLength
    $key.MachineContext = 1
    $key.ExportPolicy = 0 #X509PrivateKeyExportFlags.XCN_NCRYPT_ALLOW_EXPORT_NONE
    $key.Create()

    #Configure Eku
    $serverauthoid = new-object -com "X509Enrollment.CObjectId.1"
	$serverauthoid.InitializeFromValue($sslServerOidString)
	$networkcontrollerauthoid = new-object -com "X509Enrollment.CObjectId.1"
	$networkcontrollerauthoid.InitializeFromValue($SslNetworkControllerOidString)
    $ekuoids = new-object -com "X509Enrollment.CObjectIds.1"
    $ekuoids.add($serverauthoid)
	$ekuoids.add($networkcontrollerauthoid)
    $ekuext = new-object -com "X509Enrollment.CX509ExtensionEnhancedKeyUsage.1"
    $ekuext.InitializeEncode($ekuoids)

    # Set the hash algorithm to sha512 instead of the default sha1
    $hashAlgorithmObject = New-Object -ComObject X509Enrollment.CObjectId
    $hashAlgorithmObject.InitializeFromAlgorithmName( $ObjectIdGroupId.XCN_CRYPT_HASH_ALG_OID_GROUP_ID, $ObjectIdPublicKeyFlags.XCN_CRYPT_OID_INFO_PUBKEY_ANY, $AlgorithmFlags.AlgorithmFlagsNone, "SHA512")


    #Request Cert
    $cert = new-object -com "X509Enrollment.CX509CertificateRequestCertificate.1"

    $cert.InitializeFromPrivateKey(2, $key, "")
    $cert.Subject = $name
    $cert.Issuer = $cert.Subject
    $cert.NotBefore = (get-date).AddDays(-1)
    $cert.NotAfter = $cert.NotBefore.AddYears($validityPeriodInYear);
    $cert.X509Extensions.Add($ekuext)
    $cert.HashAlgorithm = $hashAlgorithmObject
    $cert.Encode()

    $enrollment = new-object -com "X509Enrollment.CX509Enrollment.1"
    $enrollment.InitializeFromRequest($cert)
    $certdata = $enrollment.CreateRequest(0)
    $enrollment.InstallResponse(2, $certdata, 0, "")

	Log "Successfully added cert to local machine store";
}

function GivePermissionToNetworkService($targetCert)
{
    $targetCertPrivKey = $targetCert.PrivateKey 
    $privKeyCertFile = Get-Item -path "$ENV:ProgramData\Microsoft\Crypto\RSA\MachineKeys\*"  | where {$_.Name -eq $targetCertPrivKey.CspKeyContainerInfo.UniqueKeyContainerName} 
    $privKeyAcl = (Get-Item -Path $privKeyCertFile.FullName).GetAccessControl("Access") 
    $permission = "NT AUTHORITY\NETWORK SERVICE","Read","Allow" 
    $accessRule = new-object System.Security.AccessControl.FileSystemAccessRule $permission 
    $privKeyAcl.AddAccessRule($accessRule) 
    Set-Acl $privKeyCertFile.FullName $privKeyAcl
}

#------------------------------------------
# Get the Certificate Chain based on below logic
# Find certificate havinf Network Controller EKU OID 1.3.6.1.4.1.311.95.1.1.1 and fqdn as subject name
# Prefer certificates that have a longer validity period (the expiration date is later.)
# If multiple certificates have same expiration date, prefer certificates that were issued more recently.
# If there is a tie, prefer shorter chains.
# If certificate with EKU OID not found then go for subject name
#------------------------------------------
Function GetCertChain
{
$hostFqdn = [System.Net.Dns]::GetHostByName(($env:computerName)).HostName;
$certSubjectName = "CN="+$hostFqdn;
try
{
    #replaces original code using VMM DLL that could crash sometimes causing random failures
	(dir Cert:\LocalMachine/my | where { $_.Subject -match $certsubjectname }).Thumbprint 
}
catch
{
	Log "Failed to get cert Chain.  Find certificates on the basis of subject name."
}
}
    

#------------------------------------------
# Adds the certificate at the given path to the local machine into the specified store.
#------------------------------------------
Function AddCertToLocalMachineStore($certFullPath, $storeName, $securePassword)
{
    $rootName = "LocalMachine"

    # create a representation of the certificate file
    $certificate = new-object System.Security.Cryptography.X509Certificates.X509Certificate2
    if($securePassword -eq $null)
    {
        $certificate.import($certFullPath)
    }
    else 
    {
        # https://msdn.microsoft.com/en-us/library/system.security.cryptography.x509certificates.x509keystorageflags(v=vs.110).aspx
        $certificate.import($certFullPath, $securePassword, "MachineKeySet,PersistKeySet")
    }
    
    # import into the store
    $store = new-object System.Security.Cryptography.X509Certificates.X509Store($storeName, $rootName)
    $store.open("MaxAllowed")
    $store.add($certificate)
    $store.close()
}

Function GetSubjectFqdnFromCertificatePath($certFullPath)
{
    # create a representation of the certificate file
    $certificate = new-object System.Security.Cryptography.X509Certificates.X509Certificate2
    $certificate.import($certFullPath)
    return GetSubjectFqdnFromCertificate $certificate ;
}

Function GetSubjectFqdnFromCertificate([System.Security.Cryptography.X509Certificates.X509Certificate2] $certificate)
{
    $mesg = [System.String]::Format("Parsing Subject Name {0} to get Subject Fqdn ", $certificate.Subject)
    Log $mesg
    $subjectFqdn = $certificate.Subject.Split('=')[1] ;
    return $subjectFqdn;
}

Function SetEncapOverheadPropertyOnNic($nic)
{
    #This is a default value that needs to be set as per SDN Express. For more explanation get in touch with platform team.
	$propValue = 160 
	$nicProperty = Get-NetAdapterAdvancedProperty -Name $nic.Name -AllProperties -RegistryKeyword *EncapOverhead -ErrorAction Ignore
    if($nicProperty -eq $null)
    {
       Log "The Encap Overhead property has not been added to the Nic yet. Adding the property setting";
       New-NetAdapterAdvancedProperty -Name $nic.Name -RegistryKeyword *EncapOverhead -RegistryValue $propValue
       Log "Added the Encap Overhead property to the Nic";
    }
    else
    {
	   $currentValue = $nicProperty.ValueData;
       Log "The Encap Overhead property has been added to the Nic. $currentValue. Setting it to the correct value";
       Set-NetAdapterAdvancedProperty -Name $nic.Name -AllProperties -RegistryKeyword *EncapOverhead -RegistryValue $propValue 
       Log "Changed the EncapOverhead property value";
    }
}

#$VerbosePreference = "Continue";
# For non-terminating errors force execution to stop and throw an exception
$ErrorActionPreference = "Stop";

$gpUpdateCount = 10
$gpUpdateSleepSec = 5 * 60

$certName = GetSubjectName($UseManagementAddress);
$certName = $certName.ToLower()
$certSubjectName = "CN="+$certName
$folderPath = 'C:\Temp\'
$certPath = $folderPath + $certName + '.cer'


$ErrorCode_Success = 0;
$ErrorCode_Failed = 1;

[System.Boolean]$selfSigned = $false
if (!([System.Boolean]::TryParse($selfSignedSetup, [ref] $selfSigned)))
{
    Log "Wrong SelfSignedSetup value. Only True or False allowed."
    Exit $ErrorCode_Failed;
}

if ($selfSigned)
{
    Log "Creating self signed certificate if not exists...";
	
	# Check if certificate with Oid Exist or not
	$certThumbprint = GetCertChain
    $cert = Get-ChildItem -Path Cert:\LocalMachine\My | Where { $_.Thumbprint -eq $certThumbprint }

	if ($cert -eq $null)
	{
		Log "certificate with NC Oid does not exists... Looking with subject Name";
		$certs = Get-ChildItem -Path Cert:\LocalMachine\My | Where {$_.Subject.ToLower() -eq $certSubjectName.ToLower() -and $_.Issuer.ToLower().Contains($certName)}
		if($certs -ne $null)
		{
			$cert = $certs[0];
		}

	}

    if ($cert -eq $null)
    {
	    #Bug: New-SelfSignedCertificate seems to be broken in current builds.
	
        #New-SelfSignedCertificate -DnsName $certName -CertStoreLocation Cert:LocalMachine\My
        GenerateSelfSignedCertificate $certName;
		Start-Sleep -Seconds 180
		# Add the self signed certifictate to trusted root store
		$certificates = Get-ChildItem -Path Cert:\LocalMachine\My | Where {$_.Subject.ToLower() -eq $certSubjectName.ToLower() -and $_.Issuer.ToLower().Contains($certName)}
		foreach ($c in $certificates)
		{
			$store = new-object System.Security.Cryptography.X509Certificates.X509Store("ROOT", "LocalMachine")
			$store.open("MaxAllowed")
			$store.add($c)
			$store.close()
		}    	
		# Check if certificate with Oid Exist or not
		$certThumbprint = GetCertChain
		$cert = Get-ChildItem -Path Cert:\LocalMachine\My | Where { $_.Thumbprint -eq $certThumbprint }

	    if ($cert -eq $null)
		{
			Log "certificate with NC Oid does not exists... Looking with subject Name";
			$certs = Get-ChildItem -Path Cert:\LocalMachine\My | Where {$_.Subject.ToLower() -eq $certSubjectName.ToLower() -and $_.Issuer.ToLower().Contains($certName)}
			if($certs -ne $null)
			{
				$cert = $certs[0];
			}
		}
		   
	}

    if ($cert -eq $null) 
    {
        Log "Certificate cannot be located after creation."
        Exit $ErrorCode_Failed;
    }
}
else
{
    Log "Checking for CA certificate...";

    $certName = (Get-WmiObject win32_computersystem).DNSHostName+"."+(Get-WmiObject win32_computersystem).Domain
    $certName = $certName.ToLower()

    for ($i = 0; $i -lt $gpUpdateCount; $i ++)
    {
        $certThumbprint = GetCertChain
		$cert = Get-ChildItem -Path Cert:\LocalMachine\My | Where { $_.Thumbprint -eq $certThumbprint }

		 if ($cert -ne $null) 
		 {
			break
		 }

        GPUpdate
        Start-Sleep -Seconds $gpUpdateSleepSec
    }

    if ($cert -eq $null) 
    {
			Log "certificate with NC Oid does not exists... Looking with subject Name";
			$certs = Get-ChildItem -Path Cert:\LocalMachine\My | Where {$_.Subject.ToLower() -eq $certSubjectName.ToLower()}
			if($certs -ne $null)
			{
				$cert = $certs[0];
			}
    }
	if ($cert -eq $null) 
    {
        Log "CA Certificate cannot be located."
        Exit $ErrorCode_Failed;
    }
}

$muxCertSubjectFqdn = GetSubjectFqdnFromCertificate $cert ;

Log "Exporting certificate to the file system and converting to Base64 string...";
try
{
    $pathExists = Test-Path -Path $folderPath
    if ($pathExists -eq $false)
    {
        New-Item -ItemType Directory -Path $folderPath
    }
    Export-Certificate -Type CERT -FilePath $certPath -Cert $cert
    $file = Get-Content $certPath -Encoding Byte
    $base64 = [System.Convert]::ToBase64String($file)
    Remove-Item -Path $certPath
}
catch
{
   Log "Caught an exception:";
   Log "    Exception Type: $($_.Exception.GetType().FullName)";
   Log "    Exception Message: $($_.Exception.Message)";
   Log "    Exception HResult: $($_.Exception.HResult)";
   Exit $ErrorCode_Failed;
}    

Log "Exporting certificate to registry store...";

try
{
    $certCount = [math]::floor($base64.Length / 1000)
    if ($base64.Length % 1000 -gt 0) {
        $certCount ++
    }

    Remove-ItemProperty -Path "HKLM:\Software\Microsoft\Virtual Machine\Guest" -Name GuestCertCount -ErrorAction Ignore
    New-ItemProperty -Path "HKLM:\Software\Microsoft\Virtual Machine\Guest" -Name GuestCertCount -PropertyType DWord -Value $certCount

    #Store complete cert in KVP
    for ($i = 1; $i -lt $certCount; $i ++)
    {
        Remove-ItemProperty -Path "HKLM:\Software\Microsoft\Virtual Machine\Guest" -Name $('GuestCert' + $i) -ErrorAction Ignore
        New-ItemProperty -Path "HKLM:\Software\Microsoft\Virtual Machine\Guest" -Name $('GuestCert' + $i) -PropertyType String -Value $base64.Substring(($i - 1)*1000, 1000)
    }
    Remove-ItemProperty -Path "HKLM:\Software\Microsoft\Virtual Machine\Guest" -Name $('GuestCert' + $certCount) -ErrorAction Ignore
    New-ItemProperty -Path "HKLM:\Software\Microsoft\Virtual Machine\Guest" -Name $('GuestCert' + $certCount) -PropertyType String -Value $base64.Substring(($certCount - 1) * 1000)
}
catch
{
   Log "Caught an exception:";
   Log "    Exception Type: $($_.Exception.GetType().FullName)";
   Log "    Exception Message: $($_.Exception.Message)";
   Log "    Exception HResult: $($_.Exception.HResult)";
   Exit $ErrorCode_Failed;
}

Log "Giving permission to network service for the mux certificate";
GivePermissionToNetworkService $cert

$controllerCertSubjectFqdn = $ControllerDefaultSubjectName;
if ($selfSigned)
{
	Log " Adding Network Controller Certificates to trusted Root Store"
	$certFiles = Get-ChildItem $ControllerCertificateFolder -Filter "*.cer"

    $certFile = $certFiles[0];

    Log "Found certificate at path: $($certFile.FullName)"
    Log "Adding certificate to root store.."
    AddCertToLocalMachineStore $certFile.FullName "Root" 

    Log "Extracting subject Name from Certificate "
    $controllerCertSubjectFqdn = GetSubjectFqdnFromCertificatePath $certFile.FullName

}
else
{
	Log "Getting the NC certifcate from the certificate folder"
	$certFiles = Get-ChildItem $ControllerCertificateFolder -Filter "*.cer"

    $certFile = $certFiles[0];
	
	Log "Extracting subject Name from Certificate "
    $controllerCertSubjectFqdn = GetSubjectFqdnFromCertificatePath $certFile.FullName
}

Log "Updating registry values for Mux...";
try
{

	
    $muxService = "slbmux";
    Stop-Service -Name $muxService -ErrorAction Ignore

    # TODO: Remove this once NC certificate provisioning story is enabled
    Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\SlbMux" -Name SlbmThumb -ErrorAction Ignore
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\SlbMux" -Name SlbmThumb -PropertyType String -Value $controllerCertSubjectFqdn

    Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\SlbMux" -Name MuxCert -ErrorAction Ignore
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\SlbMux" -Name MuxCert -PropertyType String -Value $muxCertSubjectFqdn

    Log "Setting slbmux service to autostart"
    Set-Service $muxService -StartupType Automatic

}
catch
{
   Log "Caught an exception:";
   Log "    Exception Type: $($_.Exception.GetType().FullName)";
   Log "    Exception Message: $($_.Exception.Message)";
   Log "    Exception HResult: $($_.Exception.HResult)";
   Exit $ErrorCode_Failed;
}

try
{
    Log "Set Encap Over head on backend nic which is disconnected";
    $adapters = @(get-netadapter | where { $_.Status -eq "Disconnected"});
    if($adapters -ne $null )
    {
        foreach($adapter in $adapters)
        {
            Log "Found the back end Nic Setting Encap Overhead on the nic";
            SetEncapOverheadPropertyOnNic($adapter);
        }
    }
}
catch
{
   Log "Caught an exception:";
   Log "    Exception Type: $($_.Exception.GetType().FullName)";
   Log "    Exception Message: $($_.Exception.Message)";
   Log "    Exception HResult: $($_.Exception.HResult)";
   Exit $ErrorCode_Failed;
}

for($i=0; $i -le 6; $i++)
{
    try
    {
        Log "Starting slbmux service"
        Start-Service -Name $muxService
    }
    catch
    {
       Log "Caught an exception:";
       Log "    Exception Type: $($_.Exception.GetType().FullName)";
       Log "    Exception Message: $($_.Exception.Message)";
       Log "    Exception HResult: $($_.Exception.HResult)";
       Log "retrying";
       if($i -eq 5)
       {
        Exit $ErrorCode_Failed;
       }
       continue;
    }
    break;
}
Log "Changing WinRM envelope size ..."
$MaxEnvelopeSize = (Get-Item WSMan:\localhost\MaxEnvelopeSizekb).Value
if($MaxEnvelopeSize -lt 4000)
{
    Set-Item WSMan:\localhost\MaxEnvelopeSizekb -Value 5000
    Restart-Service WinRM
}

Log "Creating WinRM listener ..."

Get-ChildItem -Path WSMan:\localhost\Listener | Where {$_.Keys.Contains("Transport=HTTPS") } | Remove-Item -Recurse -Force
New-Item -Path WSMan:\localhost\Listener -Address * -HostName $certName -Transport HTTPS -CertificateThumbPrint $cert.Thumbprint -Force

Log "WinRM listener configuration successful..."

Log "Enabling firewall rule for software load balancer mux"
Get-Netfirewallrule -Group "@%SystemRoot%\system32\firewallapi.dll,-36902" | Enable-NetFirewallRule
Log "Completed Enabling firewall rule for software load balancer mux"
