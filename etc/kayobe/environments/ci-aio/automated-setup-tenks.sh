#!/bin/bash

set -eux

cat << EOF | sudo tee -a /etc/hosts
10.205.3.187 pulp-server pulp-server.internal.sms-cloud
EOF

sudo pvresize /dev/sda3
sudo lvextend -L 10G /dev/mapper/rootvg-lv_tmp -r
sudo lvextend -L 10G /dev/mapper/rootvg-lv_home -r

BASE_PATH=~
KAYOBE_BRANCH=stackhpc/yoga
KAYOBE_CONFIG_BRANCH=stackhpc/yoga

if [[ ! -f $BASE_PATH/vault-pw ]]; then
    echo "Vault password file not found at $BASE_PATH/vault-pw"
    exit 1
fi

if type dnf; then
    sudo dnf -y install git python3-virtualenv
else
    sudo apt update
    sudo apt -y install gcc git libffi-dev python3-dev python-is-python3 python3-virtualenv
fi

cd $BASE_PATH
mkdir -p src
pushd src
[[ -d kayobe ]] || git clone https://github.com/stackhpc/kayobe.git -b $KAYOBE_BRANCH
[[ -d kayobe-config ]] || git clone https://github.com/stackhpc/stackhpc-kayobe-config kayobe-config -b $KAYOBE_CONFIG_BRANCH
[[ -d kayobe/tenks ]] || (cd kayobe && git clone https://opendev.org/openstack/tenks.git)
popd

cat << EOF >> $BASE_PATH/src/kayobe-config/etc/kayobe/environments/ci-aio/stackhpc-ci.yml
stackhpc_pulp_repo_rocky_9_minor_version: 1
EOF
cat << EOF >> $BASE_PATH/src/kayobe-config/etc/kayobe/aio.yml
kolla_enable_ironic=true
EOF
sed "s/#os_release:/os_release: "9"/g" $BASE_PATH/src/kayobe-config/etc/kayobe/environments/ci-aio/globals.yml
sed "s/nova_tag: yoga-20230718T112646/nova_tag: yoga-20230310T170929/g" $BASE_PATH/src/kayobe-config/etc/kayobe/environments/ci-aio/globals.yml
sed "s/memory_mb: 1024/memory_mb: 4096/g" $BASE_PATH/src/kayobe/dev/tenks-deploy-config-compute.yml
sed "s/capacity: 4GiB/capacity: 10GiB/g" $BASE_PATH/src/kayobe/dev/tenks-deploy-config-compute.yml

mkdir -p venvs
pushd venvs
if [[ ! -d kayobe ]]; then
    virtualenv kayobe
fi
# NOTE: Virtualenv's activate and deactivate scripts reference an
# unbound variable.
set +u
source kayobe/bin/activate
set -u
pip install -U pip
pip install ../src/kayobe
popd

if ! ip l show breth1 >/dev/null 2>&1; then
    sudo ip l add breth1 type bridge
fi
sudo ip l set breth1 up
if ! ip a show breth1 | grep 192.168.33.3/24; then
    sudo ip a add 192.168.33.3/24 dev breth1
fi
if ! ip l show dummy1 >/dev/null 2>&1; then
    sudo ip l add dummy1 type dummy
fi
sudo ip l set dummy1 up
sudo ip l set dummy1 master breth1

export KAYOBE_VAULT_PASSWORD=$(cat $BASE_PATH/vault-pw)
pushd $BASE_PATH/src/kayobe-config
source kayobe-env --environment ci-aio

kayobe control host bootstrap

kayobe overcloud host configure

kayobe overcloud service deploy

source $BASE_PATH/src/kayobe-config/kolla/public-openrc.sh
kayobe overcloud post configure

pushd $BASE_PATH/src/kayobe
./dev/overcloud-test-vm.sh

export KAYOBE_CONFIG_SOURCE_PATH=~/src/kayobe-config
export KAYOBE_VENV_PATH=~/venvs/kayobe
./dev/tenks-deploy-compute.sh ./tenks/