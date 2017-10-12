# Kubernetes On-Premises Deployment From Scratch -- Start to Finish #
This guide will walk you through deploying *Kubernetes 1.8* on a Linux master and join two Windows nodes to it without a cloud provider.

## Assumptions and Prerequisites ##

It is assumed you will be setting up the following:

- 1 Linux VM/host on an Ubuntu like OS. This will be the single master
- 2 Windows Server 2016 RS3+ VM/host as worker nodes
- Compilation of required binaries specific to this exercise can be done on the Linux host above, or a temporary Linux host via Vagrant, custom VM, or otherwise.
- Cluster subnet is assumed to be 192.168.0.0/16 but could be specified otherwise. Changes to this value are not covered.
- Service subnet is assumed to be 11.0.0.0/16 and is hardcoded throughout this repo. Changes to this value are not covered.

A few prerequisite definitions and requirements for networking:

- The **external network** is the physical network across which nodes communicate. This exists regardless of whether or not you follow this guide.
- The **cluster subnet** is a (<a href="#allow-routing">routable</a>) virtual network that must be a /16. Each _node_ will grab a /24 from the subnet to use for its pods.
- The **service subnet** is a hardcoded 11.0/16 network that is translated into cluster space by `kube-proxy` running on the node.

**Note**: The guide will assume a local working directory of `~/kube` for the Kubernetes setup. If you choose a different directory, just replace any references to that path.

## Building the Binaries ##
We will begin with a Linux master node on a recent Ubuntu-like distro and a Windows worker node on RS3+; all of these are assumed to be VMs.

First, install all of the pre-requisites on the master:

    $ sudo apt-get install git build-essential docker.io

### Building Kubernetes ###
We will need to build the `kubelet` and `kubeproxy` binaries for Windows from scratch _cross-compiling from Linux_, so is a non-issue by leveraging the [standard containerized build scripts](https://github.com/kubernetes/kubernetes/tree/master/build#key-scripts) leveraged in the Kubernetes project.

Various permission denied errors are avoided by building the linux kubelet first, per the note at [acs-engine](https://github.com/Azure/acs-engine/blob/master/scripts/build-windows-k8s.sh#L176) of
> Due to what appears to be a bug in the Kubernetes Windows build system, one has to first build a linux binary to generate _output/bin/deepcopy-gen. Building to Windows w/o doing this will generate an empty deepcopy-gen.

You can optionally execute this in a Vagrant box

```bash
DIST_DIR="${HOME}/kube/"
mkdir ${DIST_DIR}
SRC_DIR="${HOME}/src/kubernetes/"
mkdir -p "${SRC_DIR}"
git clone https://github.com/madhanrm/kubernetes.git ${SRC_DIR}
cd ${SRC_DIR}
git checkout cniwindows
build/run.sh make WHAT=cmd/kubelet KUBE_BUILD_PLATFORMS=linux/amd64
build/run.sh make WHAT=cmd/kubelet KUBE_BUILD_PLATFORMS=windows/amd64
cp ${SRC_DIR}/_output/dockerized/bin/windows/amd64/kubelet.exe ${DIST_DIR}
#winkernelproxy has already been merged but still needs to be built
git checkout winkernelproxy 
build/run.sh make WHAT=cmd/kube-proxy KUBE_BUILD_PLATFORMS=windows/amd64
cp ${SRC_DIR}/_output/dockerized/bin/windows/amd64/kube-proxy.exe ${DIST_DIR}
ls ${DIST_DIR}
```

Done! Now, we also need the actual Linux Kubernetes binaries for v1.8. You can pull these from [the Kubernetes mainline](https://github.com/kubernetes/kubernetes/releases/tag/v1.8.0), or build them from source as above, except using `K8SREPO=k8s.io/kubernetes` and the `release-1.8` branch, stopping before the `export ...` line.

If you built them from source, copy the binaries (at least `hyperkube`, `kubectl`, and `kubeadm`) directly to `~/kube/bin`. Otherwise, you will need to extract the downloaded archive and run the `cluster/get-kube-binaries.sh` script before copying the binaries.

 Copy these to `~/kube/bin` (note the extra `/bin` compared to the above path; we actual need to use these during master configuration, rather than just copying them to the Windows node). The v1.8 Windows binary `kubectl.exe` is included in the `windows/` directory of this repo, but you can also build it here (setting `KUBE_BUILD_PLATFORMS=windows/amd64` and `WHAT=cmd/kubectl` as above).

### Install CNI Plugins ###

We also need to install the basic CNI plugin binaries so that networking works. Download them from [here](https://github.com/containernetworking/plugins/releases) and copy them to `/opt/cni/bin/`.

```bash
DOWNLOAD_DIR="${HOME}/kube/cni-plugins"
CNI_BIN="/opt/cni/bin/"
mkdir ${DOWNLOAD_DIR}
cd $DOWNLOAD_DIR
curl -L $(curl -s https://api.github.com/repos/containernetworking/plugins/releases/latest | grep browser_download_url | grep 'amd64.*tgz' | head -n 1 | cut -d '"' -f 4) -o cni-plugins-amd64.tgz
tar -xvzf cni-plugins-amd64.tgz
sudo mkdir -p ${CNI_BIN}
sudo cp -r !(*.tgz) ${CNI_BIN}
ls ${CNI_BIN}
```

## Prepare the Master ##

Copy the entire directory from [this repository](https://github.com/Microsoft/SDN/tree/master/Kubernetes/linux), which contains a lot of the setup scripts and Kubernetes files that are essential to this process. Check them all out to `~/kube/` and make the scripts executable. This entire directory will be getting mounted for a lot of the docker containers in future steps, so keep its structure the same as outlined in the guide.

We'll be creating the service cluster on the virtual subnet 11.0/16. This isn't configurable, so if you want to tweak this, it'll require manual modification.

### Certificates ###

First, prepare the certificates that will be used for nodes to communicate in the cluster. Create a `certs/` directory, then move & run `generate-certs.sh` passing **your** external IP as its (only) parameter -- this is likely whatever the IP address of your `eth0` interface is. You can acquire this through `ifconfig` or through:

    $ ip addr show dev eth0

if you already know the interface name. Then:

    ~/kube $ mkdir certs && cd certs
    ~/kube/certs $ mv ../generate-certs.sh .
    ~/kube/certs $ ./generate-certs.sh 10.123.45.67   # example! replace

### Allow Routing ###

_This step may be optional, depending on whether or not you've configured your intended cluster subnet to be routable already_.

Windows nodes will each grab a /24 from the cluster CIDR, so it's 192.168.0.0/16, the first Windows node will use 192.168.0.1/24 for its pods. Pass the first two octets of your clister CIDR to generate the routes:

    ~/kube $ generate-routes.sh 192.168

### Prepare Manifests & Addons ###

In the `manifest` folder, run the Python script, passing your master IP and the _full_ cluster CIDR:

    $ python2 generate.py 10.123.45.67 192.168.0.0/16

This will generate a set of YAML files. You should [re]move the Python script so that K8s doesn't mistake it for a manifest and cause problems.

### Configure & Run Kubernetes ###

Run the script `configure-kubectl.sh` passing your external IP again. This will create a configuration in `~/.kube/config` containing all of the certificate data and other parameters:

    ~/kube $ ./configure-kubectl.sh 10.123.45.67

Run the script `start-kubelet.sh`. You may need to run it with `sudo`. Then, in another shell, watch your working directory (`~/kube`) until the folder `kubelet/` appears. Immediately copy the Kubernetes configuration file to it:

    ~/kube $ sudo cp ~/.kube/config kubelet/

**TODO**: Why is this necessary? Shouldn't this be done automatically by one of the containers? **What does this do?**

In another terminal session, run the Kubeproxy script, passing your cluster CIDR (you may also need to run this one with `sudo`):

    ~/kube $ ./kubeproxy.sh 192.168

After a few minutes, you should see the following system state:

- Under `docker ps`, you should see worker and pod containers mirroring the configs in `manifest/` and in `addons/`.
- A call to `~/kube/bin/kubectl cluster-info` should show info for the Kubernetes master API server, plus the DNS and heapster addons.
- A new interface `cbr0` under `ifconfig`, with your chosen cluster CIDR.

## Prepare a Windows Node ##

We need a baseline of configuration on Windows nodes. This assumes Windows Server 2016, RS3+. This can be in a hypervisor or otherwise, but the instances require a external network IP (accessible by other hosts, not the public internet).

The following is for current insider builds, at an *elevated* Powershell prompt

```powershell
Install-Module -Name DockerMsftProviderInsider -Repository PSGallery -Force
Install-Package -Name docker -ProviderName DockerMsftProviderInsider -RequiredVersion preview
Restart-Computer -Force
```

## Join a Windows Node ##

Like for Linux, we need an assortment of scripts to prepare things for us. They can be found [here](https://github.com/Microsoft/SDN/tree/master/Kubernetes/windows). Place these in a new folder, `C:\k\`. We also need to copy the .exe binaries we compiled earlier (which we placed in `~/kube/`), as well as the Kubectl config file (from `~/.kube/config`), into this folder. This can be done with something like [WinSCP](https://winscp.net/eng/download.php) or [pscp](https://www.chiark.greenend.org.uk/~sgtatham/putty/latest.html).

### Build Docker Image ###

We need to build the docker image for the Kubernetes infrastructure. Navigate to `C:\k\` and run:

    C:\k> docker pull microsoft/windowsservercore-insider:latest
    C:\k> docker tag [SHA from previous cmd] microsoft/windowsservercore:latest
    C:\k> docker build -t kubeletwin/pause .

**Note:** the Windows Server Core Insider image is retagged as non-insider to avoid extra changes once it becomes non-insder

### Join to Cluster ###

In two PowerShell windows, simply run:

    PS> ./start-kubelet.ps1 -ClusterCidr [Full cluster CIDR]
    PS> ./start-kubeproxy.ps1

(in that order). You should be able to see the Windows node when running `./bin/kubectl get nodes` on the Linux master, shortly!)

Now, if your cluster CIDR isn't routable, just run this in PowerShell:

    C:\k> AddRoutes.ps1 -MasterIp [Linux Master IP]
