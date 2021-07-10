. ./Helpers.ps1

# Stops script execution on first error
$ErrorActionPreference = "stop"

# Exit Codes
$ErrorCode_Success = 0
#$ErrorCode_Failed = 1
$ErrorCode_Failed = 0

try 
{
    Log 'Waiting for network to come up'
    $time = get-random -minimum 60 -maximum 180
    $seed = 60
    $sleeptime = $time + $seed
    Write-Host "Sleeping for $sleeptime seconds"
    sleep $sleeptime
}
catch 
{
    Log "Caught an exception:"
    Log "    Exception Type: $($_.Exception.GetType().FullName)"
    Log "    Exception Message: $($_.Exception.Message)"
    Log "    Exception HResult: $($_.Exception.HResult)"
    #Exit $($_.Exception.HResult)
    Exit $ErrorCode_Failed                
    
}  

Log "Completed execution of script."
Exit $ErrorCode_Success 