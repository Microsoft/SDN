<#
.DESCRIPTION
    This script validates basic connectivity for Windows nodes in a Kubernetes cluster. 
    Assumes the cluster has no other services/pods deployed besides kube-system
#>

param(
    [Parameter()]
    [string] $networkName = "vxlan0"
)

import-module "$PSScriptRoot\ValidateKubernetesHelper.psm1" 

Describe 'Kubernetes Prerequisites' {
    Context 'Checking Docker images' {
        It "should have windowservercore image" {
            docker images mcr.microsoft.com/windows/servercore:latest -q | Should Not BeNullOrEmpty
        }
    }

    Context 'Checking Kubernetes Binaries are running' {
        It 'kubelet.exe is running' {
            get-process -Name 'kubelet' | Should be $true
        }
        It 'kube-proxy.exe is running' {
            docker ps --filter name="kube-proxy-windows" --format "{{.Status}}" | Measure-Object -Line | Select-Object -ExpandProperty Lines | Should BeGreaterThan 1
        }
        It 'flanneld.exe is running' {
            get-process -Name 'flanneld' | Should be $true
        }
    }
}

Describe 'Basic Connectivity Tests' {
    Context 'Windows Connectivity' {
        BeforeAll {
            $Name = "win-webserver"
            kubectl apply -f ./simpleweb.yml
            kubectl scale deployment $Name --replicas=4
            WaitForDeploymentCompletion -DeploymentName $Name
            $workloadContainers = GetContainers -DeploymentName $Name
            $localContainers = GetContainers -PodLocation Local -DeploymentName $Name
            $remoteContainers = GetContainers -PodLocation Remote -DeploymentName $Name

            $serviceVIP = (kubectl get services -o json | ConvertFrom-Json).items[1].spec.clusterIP
            $nodePort = (kubectl get services -o json | ConvertFrom-Json).items[1].spec.ports.nodePort
        }
        AfterAll {
            kubectl delete -f ./simpleweb.yml
        }
    
        It 'should have more than 1 local container' {
            $localContainers.count | Should BeGreaterThan 1
        }
        It 'should have at least 1 remote container' {
            $remoteContainers.count | Should BeGreaterThan 0
        }
        It 'Pods should have correct IP' {
            foreach ($container in $workloadContainers)
            {
                Write-Host "Checking $($container.Name) has IP address $($container.IPAddress)"
                $container.IPAddress -eq (GetContainerIPv4Address -containerName $container.Name) | Should be $true
            }
        }
        It 'Pods should have Internet connectivity' {
            foreach ($container in $workloadContainers)
            {
		        Write-Host "Testing from $($container.Name) $($container.IPAddress)"
                TestConnectivity -containerName $container.Name
            }
        }
        It 'Pods should be able to resolve Service Name' {
            foreach ($container in $workloadContainers)
            {
                Write-Host "Testing service $Name from ${container.Name} $($container.IPAddress)"
                TestConnectivity -containerName $container.Name -remoteHost $Name
            }
        }
        It 'Host should be able to reach Service Ip' {
            foreach ($container in $workloadContainers)
            {
                Write-Host "Testing service VIP ${serviceVIP} from host"
                TestConnectivity -fromHost -remoteHost $ServiceVip 
            }
        }
        It 'Pods should be able to reach localhost' {
            $managementIP = WaitForManagementIP -overlayNetwork $networkName
            foreach ($container in $localContainers)
            {
                PingTest -containerName $container.Name -destination $managementIP
            }
        }
        It 'Localhost should be able to reach local pod' {
            foreach ($container in $localContainers)
            {
                PingTest -destination $container.IPAddress -fromHost
            }
        }
        It 'Pod should be able to ping a local pod' {
            foreach ($container1 in $localContainers)
            {
                foreach ($container2 in $localContainers)
                {
                    if ($container1.Name -ne $container2.Name) {
                        PingTest -containerName $container1.Name -destination $container2.IPAddress
                    }
                }
            }
        } 
        It 'Pod should be able to ping a remote pod' {
            foreach ($container1 in $localContainers)
            {
                foreach ($container2 in $remoteContainers)
                {
                    PingTest -containerName $container1.Name -destination $container2.IPAddress
                }
            }
        } 
        It 'Remote host Should be able to access Node port' {
                foreach ($container2 in $remoteContainers)
                {
                    TestConnectivity -remoteHost $container2.HostIP -port $nodePort -fromHost
                }
        }
        '''
        # LocalRoutedVip
        It "Localhost Should be able to access Node port" {
            foreach ($container1 in $localContainers)
            {
                foreach ($container2 in $remoteContainers)
                {
                    TestConnectivity -remoteHost $container2.HostIP -port $nodePort -fromHost
                }
            }
        }
        '''
    }
} 