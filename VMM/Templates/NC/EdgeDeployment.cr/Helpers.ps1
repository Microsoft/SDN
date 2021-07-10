#------------------------------------------
# Logging helper functions
#------------------------------------------
Function PrettyTime()
{
    return "[" + (Get-Date -Format o) + "]"
}

Function Log($msg)
{
    Write-Host $( $(PrettyTime) + $msg)
}

#------------------------------------------
# Tries to start the NCLogger.exe tool
#------------------------------------------
Function StartNetworkControllerLogging()
{
    try
    {
        # Start the network controller cmdlet log collection
        Log "Starting NCLogger tool.."
        Start-Process Powershell -Args ".\NCLogger.exe"
        Start-Sleep -Seconds 10
    }
    catch
    {
        Log "Problem starting NCLogger.."
        Log "    Exception Type: $($_.Exception.GetType().FullName)";
        Log "    Exception Message: $($_.Exception.Message)";
        Log "    Exception HResult: $($_.Exception.HResult)";
    }
}

#------------------------------------------
# Tries to stop the NCLogger.exe process
#------------------------------------------
Function TryStopNetworkControllerLogging()
{
    # turn off logging
    Log "Attempting to stop NCLogger.."
    Start-Sleep -Seconds 5
    try
    {
        Log "Getting NCLogger process.."
        $logProcess = Get-Process -ProcessName NCLogger
        
        Log "Stopping process.."
        Stop-Process $logProcess
    }
    catch
    {
        Log "Problem cleaning up NCLogger process.."
        Log "    Exception Type: $($_.Exception.GetType().FullName)";
        Log "    Exception Message: $($_.Exception.Message)";
        Log "    Exception HResult: $($_.Exception.HResult)";
    }
}

#------------------------------------------
# Tries to run Get-NetworkControllerCluster on the local machine
#------------------------------------------
Function TryGetNetworkControllerCluster()
{   
    $ncCluster = $null
    try
    {
        Log "Discovering existing NC Cluster.."
        $ncCluster = Get-NetworkControllerCluster
        
        if($ncCluster -ne $null)
        {
            Log "Successfully found existing NC Cluster."
        }
    }
    catch
    {
        Log "Existing NC Cluster was not found."
    }
    
    return $ncCluster
}

#------------------------------------------
# Tries to run Get-NetworkController on the local machine
#------------------------------------------
Function TryGetNetworkController()
{
    $ncController = $null
    try
    {
        Log "Discovering existing configured Network Controller.."
        $ncController = Get-NetworkController 
        
        if($ncController -ne $null)
        {
            Log "Successfully found existing network controller."
        }
    }
    catch
    {
        Log "Existing Network Controller was not found."
        Log "    Exception Type: $($_.Exception.GetType().FullName)";
        Log "    Exception Message: $($_.Exception.Message)";
        Log "    Exception HResult: $($_.Exception.HResult)";
    }
    
    return $ncController
}

#------------------------------------------
# Tries to run Get-NetworkController from the REST IP address
#------------------------------------------
Function TryGetNetworkControllerRemote($restEndPoint, $mgmtDomainAccountUserName, $mgmtDomainAccountPassword)
{
    $credential = CreateCredential $mgmtDomainAccountUserName $mgmtDomainAccountPassword

    # In case of Rest IP, it will be provided in CIDR notation
    $restEndPointWithoutSubnet = $restEndPoint.Split("/")[0]
    
    $ncController = $null
    try
    {
        Log "Checking if network controller exists remotely..";
        $ncController = Get-NetworkController -ComputerName $restEndPointWithoutSubnet -Credential $credential
            
        Log "The network controller is up and running!";
    }
    catch
    {
        Log "The network controller does not exist.";
    } 
    
    return $ncController
}

#------------------------------------------
# Tries to get an up and running NetworkControllerNode from a list of VMNames to test.
#------------------------------------------
Function TryGetNetworkControllerNodeRemote($vmNames, $mgmtDomainAccountUserName, $mgmtDomainAccountPassword)
{
    $credential = CreateCredential $mgmtDomainAccountUserName $mgmtDomainAccountPassword
    $remoteNodeName = $null
    
    foreach($vmName in $vmNames)
    {
        try
        {
            Log "Testing remote network controller node $vmName.."
            
            # ignore myself
            $vmNameWithoutSuffix = $vmName.Split(".")[0]
            if($vmNameWithoutSuffix.ToLower() -eq $env:COMPUTERNAME.ToLower())
            {
                Log "Found myself, ignoring.."
                continue
            }
        
            # Test if NC cmdlet is responsive and get node object
            $ncNodes = Get-NetworkControllerNode -ComputerName $vmName -Credential $credential
            $node = $ncNodes | where{$_.Server.Split(".")[0].ToLower() -eq $vmNameWithoutSuffix.ToLower()}
            
            # validate nc-node is active
            Log "Testing if node is Up.."
            if($node.Status -eq "Up")
            {
                Log "Remote node is up and running."
                $remoteNodeName = $node.Server
                break;
            }
            else 
            {
                Log "Remote node is down."
            }
        }
        catch
        {
            Log "There was a problem connecting to the remote node."
            Log "    Exception Type: $($_.Exception.GetType().FullName)";
            Log "    Exception Message: $($_.Exception.Message)";
            Log "    Exception HResult: $($_.Exception.HResult)";
        }
    }
    
    return $remoteNodeName
}

#------------------------------------------
# Converts a username + password pair into a PSCredential object
#------------------------------------------
Function CreateCredential($username, $plainPassword)
{
    Log "Creating credential for account $username.."
    $securePassword = ConvertTo-SecureString $plainPassword -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($username, $securePassword)
    return $credential
}

#------------------------------------------
# Add accounts to local adminstrators group
#------------------------------------------
Function AddToAdministrators($name)
{
    #add to local account
    $AdminGroupSID = New-Object System.Security.Principal.SecurityIdentifier ("S-1-5-32-544")
    $AdminGroup = $AdminGroupSID.Translate( [System.Security.Principal.NTAccount])
    $AdminGroupName = ([string]$AdminGroup.Value).Split("\")[1]

    $index = ([string]$name).IndexOf("\")
    if ($index -ne -1)
    {
        $CurUsername = ([string]$name).Replace("\","/")
        $name = ([string]$name).Split("\")[1]
    }

    $group = [ADSI]"WinNT://$env:COMPUTERNAME/$AdminGroupName,group"
    $members = $Group.psbase.invoke("Members") | %{ [System.__ComObject].InvokeMember("Name", 'GetProperty', $null, $_, $null) }
    if($members -notcontains $name)
    {
        $i = 0
        $attempts = 20
        $success = $false
        while(-not $success)
        {
            $i++
            try
            {
                Log "Attempt $i - Adding $CurUsername to Administrators group"
        $group.Add("WinNT://$CurUsername")

                $success = $true
                Log "Successfully added $CurUsername to Administrators group.";
            }
            catch
            {
                if($i -gt $attempts)
                {
                    # timeout after $attempts
                    Log "Caught an exception:";
                    Log "    Exception Type: $($_.Exception.GetType().FullName)";
                    Log "    Exception Message: $($_.Exception.Message)";
                    Log "    Exception HResult: $($_.Exception.HResult)";
                    Exit $ErrorCode_Failed   
                }
            }

            if(-not $success -and $i -gt $attempts)
            {
                # timeout after $attempts
                Log "There was a problem adding $CurUsername to administrators group."
                Log "Please check ensure that the VMs have joined the domain and the trust relationship between this workstation and domain controller exists."
                Exit $ErrorCode_Failed   
            }
            elseif(-not $success)
            {
                # sleep 1 minute
                [System.Threading.Thread]::Sleep(60 * 1000);
            }
        }
    }
}
    
#------------------------------------------
# Adds the certificate at the given path to the local machine into the specified store.
#------------------------------------------
Function AddCertToLocalMachineStore($certFullPath, $storeName, $securePassword, $saveInRegistry)
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
    
    # makes a record of the certificate's thumbprint
    if($saveInRegistry)
    {
        SaveSSLCertificateThumbprint $certificate.Thumbprint
    }
}

#------------------------------------------
# Wait for network controller to be configured before proceeding.
# This function checks connectivity to the REST Endpoint of the network controller.
#------------------------------------------
Function WaitForNetworkController($restEndPoint)
{
    # credential to access the network controller
    $credential = CreateCredential $mgmtDomainAccountUserName $mgmtDomainAccountPassword

    # In case of Rest IP, it will be provided in CIDR notation
    $restEndPointWithoutSubnet = $restEndPoint.Split("/")[0]

    $i = 0
    $attempts = 20
    $success = $false
    while(-not $success)
    {
        $i++
        try
        {
            Log "Checking if network controller is finished..";
            $success = Test-Connection $restEndPointWithoutSubnet -Quiet
            
            if($success)
            {
                Log "The network controller is up and running!";
            }
        }
        catch
        {
            if($i -gt $attempts)
            {
                # timeout after so many attempts
                Log "Caught an exception:";
                Log "    Exception Type: $($_.Exception.GetType().FullName)";
                Log "    Exception Message: $($_.Exception.Message)";
                Log "    Exception HResult: $($_.Exception.HResult)";
                Exit $ErrorCode_Failed   
            }
        }

        if(-not $success -and $i -gt $attempts)
        {
            # timeout after so many attempts
            Log "There was a problem connecting to the network controller at $restEndPointWithoutSubnet."
            Log "Please check the status of the controller and restart the service deployment job."
            Exit $ErrorCode_Failed   
        }
        elseif(-not $success)
        {
            # sleep 1 minute
            [System.Threading.Thread]::Sleep(60 * 1000);
        }
    }
}

#------------------------------------------
# Waits for connectivity to the provided machine name or IP.
#------------------------------------------
Function WaitForReadyNode($fqdn, $minutes)
{
    $i = 0
    $success = $false
    while(-not $success)
    {
        $i++
        try
        {
            Log "Checking if node '$fqdn' is ready for NC deployment..";
            $success = IsMachineIsReadyForNetworkControllerDeployment $fqdn
        }
        catch
        {
            if($i -gt $minutes)
            {
                Log "Caught an exception:";
                Log "    Exception Type: $($_.Exception.GetType().FullName)";
                Log "    Exception Message: $($_.Exception.Message)";
                Log "    Exception HResult: $($_.Exception.HResult)";
            }
        }
        
        if(-not $success)
        {
            if($i -gt $minutes)
            {
                Log "Exceeded timeout when waiting for node '$fqdn' to become ready.";
                Log "    Please check the state of the node and try again.";
                
                # timeout after so many minutes
                Exit $ErrorCode_Failed   
            }
            else
            {
                # sleep 1 minute
                [System.Threading.Thread]::Sleep(60 * 1000);
            }
        }
        else 
        {
            Log "Node '$fqdn' is ready for NC deployment.";
        }
    } 
}     

#------------------------------------------
# Gets the subnet in CIDR notation from the specified IPAddress and prefix length.
#------------------------------------------
Function GetSubnet {
    Param(
        [Net.IPAddress]$IPAddress,
        [int]          $PrefixLength)

    $AddressBytes = $IPAddress.GetAddressBytes();

    $NumberOfBytesToZero = $AddressBytes.Length - [int][System.Math]::Floor($PrefixLength / 8);
    $Remainder = $PrefixLength % 8;


    for($Index = 0; $Index -lt ($NumberOfBytesToZero - 1); $Index++) 
    {
        $AddressBytes[$AddressBytes.Length-1-$Index] = 0;
    }

    if( $Remainder -eq 0 ) 
    {
        $AddressBytes[$AddressBytes.Length - $NumberOfBytesToZero] = 0;
    }
    else 
    {
        $BitsToMove = 8 - $Remainder;
        $Mask = (255 -shr $BitsToMove) -shl $BitsToMove;
        $AddressBytes[$AddressBytes.Length - $NumberOfBytesToZero] = $AddressBytes[$AddressBytes.Length - $NumberOfBytesToZero] -band $Mask;
    }

    $SubnetIP = new-object System.Net.IPAddress(,$AddressBytes);
    $SubnetIPWithPrefixString = "{0}/{1}" -f $SubnetIP, $PrefixLength;

    Return $SubnetIPWithPrefixString;
}

#------------------------------------------
# Gets a list of computer names based on a list of computer names in the deployment tier, generated by VMM.
#------------------------------------------
Function GetVMNamesFromComputerTierString($serviceVMComputerNames)
{    
    # Parse all VMs that are part of this deployment
    # Sample string: "The Tier[NC-VM01.contoso.com:0,NC-VM02.contoso.com:0,NC-VM03.contoso.com:0]The Other Tier[...]"
    Log "Parsing serviceVMComputerNames string.. $serviceVMComputerNames"
    $leftBracketIndex = $serviceVMComputerNames.IndexOf("[") + 1
    $rightBracketIndex = $serviceVMComputerNames.IndexOf("]")
    $vmNames = $serviceVMComputerNames.SubString( $leftBracketIndex, $rightBracketIndex - $leftBracketIndex).Split(",")
    [array]$vmNames = $vmNames | Foreach-Object{$_.SubString(0, $_.IndexOf(":"))}
    Log "Parsed into: $vmNames"
    
    return $vmNames
}

#------------------------------------------
# Gets this machine's index, based on a list of computer names in the deployment tier, generated by VMM.
# This string is always identical on all machines during deployment.
#------------------------------------------
Function GetIndexFromComputerTierString($serviceVMComputerNames)
{    
    [array]$vmNames = GetVMNamesFromComputerTierString $serviceVMComputerNames
    
    # Find the index of this VM
    $indexInComputerTier = -1;
    for($i = 0; $i -lt $vmNames.Length; $i++)
    {
        $vmNameWithoutSuffix = $vmNames[$i].Split(".")[0]
        if($vmNameWithoutSuffix.ToLower() -eq $env:COMPUTERNAME.ToLower())
        {
            $indexInComputerTier = $i;
            break
        }
    }
    
    return $indexInComputerTier
}

#------------------------------------------
# Active Directory - Remove local machine from the SG using the credentials.
#------------------------------------------
Function TryRemoveLocalMachineAccountFromAD($mgmtDomainAccountUserName, $mgmtDomainAccountPassword, $mgmtSecurityGroupName)
{
    try
    {
        Log "Acquiring machine and group info from AD.."
        $credential = CreateCredential $mgmtDomainAccountUserName $mgmtDomainAccountPassword
        $myAdComputer = Get-ADComputer -Credential $credential -filter "Name -like '$env:computername'"
        $groupNameOnly =  $mgmtSecurityGroupName.Split("\")
        $groupNameOnly = $groupNameOnly[$groupNameOnly.Length - 1]
        $group = Get-ADGroup -Credential $credential -filter "Name -like '$groupNameOnly'"
        
        Log "Removing machine account '$myAdComputer' from the management security group '$group'"
        Remove-ADGroupMember $group -Members $myAdComputer -Credential $credential -Confirm:$false
    }
    catch
    {
        # this is non-blocking. don't exit the script
        Log "Caught an exception:";
        Log "    Exception Type: $($_.Exception.GetType().FullName)";
        Log "    Exception Message: $($_.Exception.Message)";
        Log "    Exception HResult: $($_.Exception.HResult)";
    }
}

#------------------------------------------
# Marks the local machine as ready for NC deployment.
#------------------------------------------
Function MarkAsReadyForNetworkControllerDeployment
{
    $remoteMachine = "localhost"
    $regLocalMachine = "LocalMachine"
    $regPath = "SOFTWARE\Microsoft\SCVMM Network Controller"
    $regName = "NCReady"
    $regValue = "1"
    
    Log "Marking as ready for network controller deployment."
    $registry = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey($regLocalMachine, $remoteMachine)
    $registryKey = $registry.CreateSubKey($regPath);
    $registryKey.SetValue($regName, $regValue)
}

#------------------------------------------
# Checks a remote machine if it is ready for NC deployment.
#------------------------------------------
Function IsMachineIsReadyForNetworkControllerDeployment($remoteMachine)
{
    Invoke-Command -ComputerName $remoteMachine -ScriptBlock {
        $regLocalMachine = "LocalMachine"
        $regPath = "SOFTWARE\Microsoft\SCVMM Network Controller"
        $regName = "NCReady"
        $regValue = "1"
        
        $isReady = $false
        $registry = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey($regLocalMachine, "localhost")
        $registryKey = $registry.OpenSubKey($regPath)
        
        if($registryKey -ne $null)
        {
            $isReady = $registryKey.GetValue($regName) -eq $regValue
        }
        return $isReady
    }
}

#------------------------------------------
# Saves a value in the registery.
#------------------------------------------
Function SaveSSLCertificateThumbprint($value)
{
    $remoteMachine = "localhost"
    $regLocalMachine = "LocalMachine"
    $regPath = "SOFTWARE\Microsoft\SCVMM Network Controller"
    $regName = "NCThumbprint"
    $regValue = $value
    
    Log "Saving SSL thumbprint to registry: $value."
    $registry = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey($regLocalMachine, $remoteMachine)
    $registryKey = $registry.CreateSubKey($regPath);
    $registryKey.SetValue($regName, $regValue)
}

#------------------------------------------
# Gets a value from the registry.
#------------------------------------------
Function GetSSLCertificateThumbprint()
{
    $remoteMachine = "localhost"
    $regLocalMachine = "LocalMachine"
    $regPath = "SOFTWARE\Microsoft\SCVMM Network Controller"
    $regName = "NCThumbprint"
    
    $registry = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey($regLocalMachine, $remoteMachine)
    $registryKey = $registry.OpenSubKey($regPath)
    
    if($registryKey -ne $null)
    {
        $value = $registryKey.GetValue($regName)
        Log "Retrieved SSL thumbprint from registry: $value."
        return $value 
    }
        
    Log "Error retrieving SSL thumbprint from registry."
    return $null
}

#------------------------------------------
# Gives the Network Service account permission to read the certificate.
#------------------------------------------
Function GivePermissionToNetworkService($targetCert)
{
    $targetCertPrivKey = $targetCert.PrivateKey 
    $privKeyCertFile = Get-Item -path "$ENV:ProgramData\Microsoft\Crypto\RSA\MachineKeys\*"  | where {$_.Name -eq $targetCertPrivKey.CspKeyContainerInfo.UniqueKeyContainerName} 
    $privKeyAcl = (Get-Item -Path $privKeyCertFile.FullName).GetAccessControl("Access") 
    $networkServiceAccountName = [string] (New-Object System.Security.Principal.SecurityIdentifier("S-1-5-20")).Translate([System.Security.Principal.NTAccount])
    $permission = $networkServiceAccountName,"Read","Allow"
    $accessRule = new-object System.Security.AccessControl.FileSystemAccessRule $permission 
    $privKeyAcl.AddAccessRule($accessRule) 
    Set-Acl $privKeyCertFile.FullName $privKeyAcl
}

#---------------------------------------------------
# Gives IPv4 Subnet Length for Localhost
#---------------------------------------------------
Function GetLocalHostIPv4Subnet()
{
    $ipConfig = Get-WmiObject -Class Win32_NetworkAdapterConfiguration -Filter IPEnabled=True
    $mask = $ipConfig.IPSubnet[0]
    $mask = $mask.Split('.')

    $bits = 0
    $mask | % { $bits = $bits * 256; $bits += $_ }
    
    $zeros = 0
    $k = 1
    for($i = 0; $i -lt 32; ++$i) { 
        if(-not ($bits -band $k)) {
            ++$zeros;
            $k *= 2;
        } else {
            break;
        }
    }
    
    return (32 - $zeros)
}
