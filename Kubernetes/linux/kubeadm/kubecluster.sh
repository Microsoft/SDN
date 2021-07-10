#
# Copyright 2019 (c) Microsoft Corporation.
# Licensed under the MIT license.
#

#!/bin/bash

function usage()
{
	bin=$(basename $0)
	cat << USAGE
	Usage: 
		$bin [--help] [--reset] [--init <--clustercidr CLUSTER_CIDR> <--servicecidr SERVICE_CIDR> --cni <flannel> --networkplugin <bridge/vxlan>] [--join]  [--cri <dockerd/containerd>] [--help] [--destination <InstallDestination>] [--release KUBE_RELEASE]

	Examples:
		$bin --help            print this help
		# Reset
				$bin --reset           reset the kubernetes cluster
		# Init
				$bin --init --clustercidr 10.244.0.0/16 --servicecidr 10.96.0.0/12 --cni flannel --networkplugin bridge --release 1.14.0
				$bin --init --clustercidr 10.244.0.0/16 --servicecidr 10.96.0.0/12 --cni flannel --networkplugin vxlan --release 1.14.0
				$bin --reset --clustercidr 10.244.0.0/16 --servicecidr 10.96.0.0/12 --cni flannel --networkplugin bridge --destination $HOME/kubeadm
				$bin --init --clustercidr 10.244.0.0/16 --servicecidr 10.96.0.0/12 --cni flannel --networkplugin bridge --destination $HOME/kubeadm
				$bin --installprerequisite 
    # Join
  			$bin --join  <join string from [kubeadm token create --print-join-command]> --clustercidr 10.244.0.0/16 --servicecidr 10.96.0.0/12 --cni flannel --networkplugin vxlan --release 1.14.0
	  		Example 
		  	   "kubeadm join 172.16.18.4:6443 --token aa.bb     --discovery-token-ca-cert-hash sha256:xxx"
			  $bin --join "172.16.18.4:6443 --token aa.bb     --discovery-token-ca-cert-hash sha256:xxx" --clustercidr 10.244.0.0/16 --servicecidr 10.96.0.0/12 --cni flannel --networkplugin vxlan --release 1.14.0
USAGE

}

function InstallPreReq()
{
	sudo apt-get install -y bridge-utils
}

function InstallKubernetes()
{
	curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
	cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
	deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF
	apt-get update && apt-get install -y kubelet=$1* kubeadm=$1* kubectl=$1*
}

function DownloadKubernetes()
{
	echo "Checking Kubernetes binaries"
	WorkingDir=$1
	Release=$2
	ReleaseDir="$WorkingDir/$Release"
	if [ ! -d $ReleaseDir ]; then
		mkdir -p $ReleaseDir
	fi

	return
	if [ "$(ls -A $ReleaseDir 2> /dev/null)" == "" ]; then
		# Download files only if not present
        dfile="https://dl.k8s.io/v${Release}/kubernetes-node-linux-amd64.tar.gz"
		echo "Downloading $dfile"
		wget $dfile -P $WorkingDir
		tar -vxzf $WorkingDir/kubernetes-node-linux-amd64.tar.gz -C ${ReleaseDir}
	fi
	export PATH=$PATH:$ReleaseDir/kubernetes/node/bin
}

function InstallKubeConfig()
{
	mkdir -p $HOME/.kube
	# When joining the cluster, kubeadm join is not copying the kube config. So copy kubelet.conf
	if [[ ! -z $join ]]; then
		cp -i /etc/kubernetes/kubelet.conf $HOME/.kube/config
	else
		cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
	fi
	chown --reference=$HOME $HOME/.kube/config
}

function CleanupKubeConfig()
{
	rm -rf $HOME/.kube/config
}

function InstallRuntime()
{
	case "$1" in
		dockerd )
		# Steps from https://kubernetes.io/docs/setup/cri/

		# Install Docker CE
		## Set up the repository:
		### Install packages to allow apt to use a repository over HTTPS
		apt-get update && apt-get install -y apt-transport-https ca-certificates curl software-properties-common

		### Add Docker’s official GPG key
		curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -

		### Add Docker apt repository.
		add-apt-repository \
		"deb [arch=amd64] https://download.docker.com/linux/ubuntu \
		$(lsb_release -cs) \
		stable"

		## Install Docker CE.
		apt-get update && apt-get install -y docker-ce=18.06* #=18.06.2~ce~3-0~ubuntu

		# Setup daemon.
		cat > /etc/docker/daemon.json <<EOF
		{
		"exec-opts": ["native.cgroupdriver=systemd"],
		"log-driver": "json-file",
		"log-opts": {
			"max-size": "100m"
		},
		"storage-driver": "overlay2"
		}
EOF

		mkdir -p /etc/systemd/system/docker.service.d

		# Restart docker.
		systemctl daemon-reload
		systemctl restart docker
		[ $? -ne 0 ] && echo "Failed to install docker" && exit
		;;

		containerd )
		;;
	esac
}

function CleanupNetworking()
{
	ifconfig cni0 down
	ifconfig flannel.4096 down
	brctl delbr cni0
	brctl delbr flannel.409
	sudo systemctl start docker
}

function InstallNetworkPlugins()
{
	cni=$1
	NetworkPlugin=$2
	WorkingDir=$3
	cidr=$4
	# Deploy Network Plugins
	echo "Deploying Networking Plugins"
	case "$cni" in
		flannel )
		wget https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml -P $WorkingDir
		sudo sysctl net.bridge.bridge-nf-call-iptables=1
		tmp=${cidr/\//\\\/}
		sed  -ri "s/\"Network\": \"10.244.0.0\/16\"/\"Network\": \"${tmp}\"/"  $WorkingDir/kube-flannel.yml

		case "$NetworkPlugin" in 
			vxlan )
			sed  -ri 's/"name": "cbr0"/"name": "vxlan0"/'  $WorkingDir/kube-flannel.yml
			sed  -ri 's/"Type": "vxlan"/"Type": "vxlan",\n        "VNI": 4096,\n        "Port": 4789/'  $WorkingDir/kube-flannel.yml
			;;

			bridge )
			sed  -ri 's/"Type": "vxlan"/"Type": "host-gw"/'  $WorkingDir/kube-flannel.yml
			;;
		esac

		kubectl apply -f $WorkingDir/kube-flannel.yml
		kubectl get ds -n kube-system
		wget https://raw.githubusercontent.com/Microsoft/SDN/master/Kubernetes/flannel/l2bridge/manifests/node-selector-patch.yml -P $WorkingDir
		kubectl patch ds/kube-flannel-ds-amd64 --patch "$(cat $WorkingDir/node-selector-patch.yml)" -n=kube-system

		;;

		kubenet )

		;;

	esac	
}

# Init
OPTS=$(getopt -o "hirpc:s:d:r:i:n:u:j:" --long "help,init,reset,installprerequisite,clustercidr:,servicecidr:,destination:,release:,cni:,networkplugin:,runtime:,join:" -n "$(basename $0)" -- "$@")
if [ $? != 0 ] ; then echo "Error in command line arguments." >&2 ; exit 1 ; fi
eval set -- "$OPTS"

init=0
WorkingDir="$HOME/KubeTest"
Release="1.14.0"
CLUSTER_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.96.0.0/12"
cni="flannel"  # Supported flannel
NetworkPlugin="bridge"  # Supported bridge, vxlan
cri="dockerd"
installprerequisite=1

while true; do
	case "$1" in
	-h | --help )  
		usage; 
		exit 
		;;
	-i | --init )  
		init=1; 
		shift 
		;;
	-p | --installprerequisite )  
		installprerequisite=1; 
		shift 
		;;
	-r | --reset )  
		shift
		;;
	-c | --clustercidr )  
		CLUSTER_CIDR=$2; 
		shift 2 
		;;
	-s | --servicecidr )  
		SERVICE_CIDR=$2; 
		shift 2 
		;;
	-d | --destination )  
		WorkingDir=$2; 
		shift 2 
		;;
	-r | --release )  
		Release=$2; 
		shift 2 
		;;
	-i | --cni)  
		cni=$2; 
		shift 2
		;;
	-n | --networkplugin)  
		NetworkPlugin=$2; 
		shift 2 
		;;
	-u | --runtime)  
		cri=$2; 
		shift 2 
		;;
	-j | --join)  
		init=1; 
		join=$2; 
		shift 2 
		;;
    *) 
		break 
		;;
	esac

done

echo "++++++++++++++++++++++++++++++++++++++++++++++++++"
echo "User Input:"
echo "++++++++++++++++++++++++++++++++++++++++++++++++++"
echo "Destination      $WorkingDir"
echo "Release          $Release"
echo "ClusterCidr      $CLUSTER_CIDR"
echo "ServiceCidr      $SERVICE_CIDR"
echo "CNI              $cni"
echo "CRI              $cri"
echo "NetworkPlugin    $NetworkPlugin"
echo "++++++++++++++++++++++++++++++++++++++++++++++++++"

# Main
# Pre-Requisites
InstallPreReq
DownloadKubernetes $WorkingDir $Release
InstallKubernetes $Release
# Kubeadm pre-requisites
# Turn off Swap
sudo swapoff -a 
# 
if [ ! -f /proc/sys/net/bridge/bridge-nf-call-iptables ]; then
	modprobe br_netfilter
fi

sudo sysctl -w net.ipv4.ip_forward=1
# Install Runtime
InstallRuntime $cri

# Init
if [[ $init -gt "0" ]]; then 
	if [[ ! -z $join ]]; then 
		# Join the node to the master
		echo "Joining the node to cluster using $join"
		kubeadm join $join
		[ $? -ne 0 ] && echo "Failed to join the cluster" && exit
		# not sure, if this is needed only for master node. So, adding for worker node as well.
		sudo sysctl net.bridge.bridge-nf-call-iptables=1
		# Explicitly copy the kube config to ensure the worker node can communicate with master.
		InstallKubeConfig
	else
		if kubeadm init --pod-network-cidr=${CLUSTER_CIDR} --service-cidr=${SERVICE_CIDR}; then
			InstallKubeConfig
			# Deploy Network Plugins
			# This should only be run on the control-plane, when initializing.
			InstallNetworkPlugins $cni $NetworkPlugin $WorkingDir $CLUSTER_CIDR
			kubectl patch ds/kube-proxy --patch "$(cat $WorkingDir/node-selector-patch.yml)" -n=kube-system
			echo "Successfully deployed the cluster"
		else
			echo "Failed to init kubeadm"
			exit;
		fi
	fi
else
  kubeadm reset
  iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
  rm -rf $WorkingDir
  CleanupKubeConfig
  docker ps -a  |  awk '{print $1}' | xargs --no-run-if-empty docker rm -f
  sudo systemctl stop docker

  CleanupNetworking
fi
