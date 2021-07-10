Copy CertHelpers.ps1, NetworkControllerRESTWrappers.ps1, NetworkControllerWorkloadHelpers.psm1 and SDNExplorer.ps1 to local folder.
From same folder run SDNExplorer.ps1 with below parameters:-
    NCIP - pass either network controller rest ip address or network controller restname. Make sure you pass same restname as of mentioned in rest certificate.
    NCCredential -  Optionally, pass System.Management.Automation.PSCredential if network controller is configured with Kerberos authentication.
    EnableMultiWindow - Don't change this parameter, it is for debugging purpose.   

To auto-setup SDNExplorer in the folder ~/SDNExplorer without having to download the whole repository, copy-paste and run the following lines in Powershell:
mkdir ~/SDNExplorer
cd ~/SDNExplorer
wget https://raw.githubusercontent.com/microsoft/SDN/master/SDNExpress/Tools/SDNExplorer/CertHelpers.ps1 -OutFile CertHelpers.ps1
wget https://raw.githubusercontent.com/microsoft/SDN/master/SDNExpress/Tools/SDNExplorer/NetworkControllerRESTWrappers.ps1 -OutFile NetworkControllerRESTWrappers.ps1
wget https://raw.githubusercontent.com/microsoft/SDN/master/SDNExpress/Tools/SDNExplorer/NetworkControllerWorkloadHelpers.psm1 -OutFile NetworkControllerWorkloadHelpers.psm1
wget https://raw.githubusercontent.com/microsoft/SDN/master/SDNExpress/Tools/SDNExplorer/SDNExplorer.ps1 -OutFile SDNExplorer.ps1
