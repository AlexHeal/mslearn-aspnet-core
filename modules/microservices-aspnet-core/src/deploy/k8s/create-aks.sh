#!/bin/bash

# Color theming
if [ -f ~/clouddrive/aspnet-learn/setup/theme.sh ]
then
  . <(cat ~/clouddrive/aspnet-learn/setup/theme.sh)
fi

eshopSubs=${ESHOP_SUBS}
eshopRg=${ESHOP_RG}
eshopLocation=${ESHOP_LOCATION}
eshopNodeCount=${ESHOP_NODECOUNT:-1}
eshopRegistry=${ESHOP_REGISTRY}
eshopAcrName=${ESHOP_ACRNAME}
eshopClientId=${ESHOP_CLIENTID}
eshopClientSecret=${ESHOP_CLIENTSECRET}

while [ "$1" != "" ]; do
    case $1 in
        -s | --subscription)            shift
                                        eshopSubs=$1
                                        ;;
        -g | --resource-group)          shift
                                        eshopRg=$1
                                        ;;
        -l | --location)                shift
                                        eshopLocation=$1
                                        ;;
             --acr-name)                shift
                                        eshopAcrName=$1
                                        ;;
             --appid)                   shift
                                        eshopClientId=$1
                                        ;;
             --password)                shift
                                        eshopClientSecret=$1
                                        ;;
             * )                        echo "Invalid param: $1"
                                        exit 1
    esac
    shift
done

if [ -z "$eshopRg" ]
then
    echo "${newline}${errorStyle}ERROR: resource group is mandatory. Use -g to set it.${defaultTextStyle}${newline}"
    exit 1
fi

if [ -z "$eshopAcrName" ]&&[ -z "$ESHOP_QUICKSTART" ]
then
    echo "${newline}${errorStyle}ERROR: ACR name is mandatory. Use --acr-name to set it.${defaultTextStyle}${newline}"
    exit 1
fi

if [ ! -z "$eshopSubs" ]
then
    echo "Switching to subscription $eshopSubs..."
    az account set -s $eshopSubs
fi

if [ ! $? -eq 0 ]
then
    echo "${newline}${errorStyle}ERROR: Can't switch to subscription $eshopSubs.${defaultTextStyle}${newline}"
    exit 1
fi

# Swallow STDERR so we don't get red text here from expected error if the RG doesn't exist
exec 3>&2
exec 2> /dev/null

rg=`az group show -g $eshopRg -o json`

# Reset STDERR
exec 2>&3

if [ -z "$rg" ]
then
    if [ -z "eshopSubs" ]
    then
        echo "${newline}${errorStyle}ERROR: If resource group has to be created, location is mandatory. Use -l to set it.${defaultTextStyle}${newline}"
        exit 1
    fi
    echo "Creating resource group $eshopRg in location $eshopLocation..."
    echo "${newline} > ${azCliCommandStyle}az group create -n $eshopRg -l $eshopLocation --output none${defaultTextStyle}${newline}"
    az group create -n $eshopRg -l $eshopLocation --output none
    if [ ! $? -eq 0 ]
    then
        echo "${newline}${errorStyle}ERROR: Can't create resource group!${defaultTextStyle}${newline}"
        exit 1
    fi
else
    if [ -z "$eshopLocation" ]
    then
        eshopLocation=`az group show -g $eshopRg --query "location" -otsv`
    fi
fi



# AKS Cluster creation

eshopAksName="eshop-learn-aks"

echo
echo "Creating AKS cluster \"$eshopAksName\" in resource group \"$eshopRg\" and location \"westus2\"..."
aksCreateCommand="az aks create -n $eshopAksName -g $eshopRg --node-count $eshopNodeCount --node-vm-size Standard_D2_v5 --vm-set-type VirtualMachineScaleSets -l westus2 --enable-managed-identity --generate-ssh-keys -o json"
echo "${newline} > ${azCliCommandStyle}$aksCreateCommand${defaultTextStyle}${newline}"
retry=5
aks=`$aksCreateCommand`
while [ ! $? -eq 0 ]&&[ $retry -gt 0 ]&&[ ! -z "$spHomepage" ]
do
    echo
    echo "Not yet ready for AKS cluster creation. ${bold}This is normal and expected.${defaultTextStyle} Retrying in 5s..."
    let retry--
    sleep 5
    echo
    echo "Retrying AKS cluster creation..."
    aks=`$aksCreateCommand`
done

if [ ! $? -eq 0 ]
then
    echo "${newline}${errorStyle}Error creating AKS cluster!${defaultTextStyle}${newline}"
    exit 1
fi

echo
echo "AKS cluster created."

if [ ! -z "$eshopAcrName" ]
then
    echo
    echo "Granting AKS pull permissions from ACR $eshopAcrName"
    az aks update -n $eshopAksName -g $eshopRg --attach-acr $eshopAcrName
fi

echo
echo "Getting credentials for AKS..."
az aks get-credentials -n $eshopAksName -g $eshopRg --overwrite-existing

# Ingress controller and load balancer (LB) deployment

echo
echo "Installing NGINX ingress controller"
kubectl apply -f ingress-controller/nginx-mandatory.yaml
kubectl apply -f ingress-controller/nginx-service-loadbalancer.yaml
kubectl apply -f ingress-controller/nginx-cm.yaml

echo
echo "Getting load balancer public IP"

while [ -z "$eshopLbIp" ]
do
    eshopLbIpCommand="kubectl get svc -n ingress-nginx -o json | jq -r -e '.items[0].status.loadBalancer.ingress[0].ip // empty'"
    echo "${newline} > ${genericCommandStyle}$eshopLbIpCommand${defaultTextStyle}${newline}"
    eshopLbIp=$(eval $eshopLbIpCommand)
    if [ -z "$eshopLbIp" ]
    then
        echo "Waiting for load balancer IP..."
        sleep 5
    fi
done

echo "Load balancer IP is $eshopLbIp"

echo export ESHOP_SUBS=$eshopSubs > create-aks-exports.txt
echo export ESHOP_RG=$eshopRg >> create-aks-exports.txt
echo export ESHOP_LOCATION=$eshopLocation >> create-aks-exports.txt

if [ ! -z "$eshopAcrName" ]
then
    echo export ESHOP_ACRNAME=$eshopAcrName >> create-aks-exports.txt
fi

if [ ! -z "$eshopRegistry" ]
then
    echo export ESHOP_REGISTRY=$eshopRegistry >> create-aks-exports.txt
fi

if [ "$spHomepage" != "" ]
then
    echo export ESHOP_CLIENTID=$eshopClientId >> create-aks-exports.txt
    echo export ESHOP_CLIENTPASSWORD=$eshopClientSecret >> create-aks-exports.txt
fi

echo export ESHOP_LBIP=$eshopLbIp >> create-aks-exports.txt

if [ -z "$ESHOP_QUICKSTART" ]
then
    echo "Run the following command to update the environment"
    echo 'eval $(cat ~/clouddrive/aspnet-learn/create-aks-exports.txt)'
    echo
fi

mv -f create-aks-exports.txt ~/clouddrive/aspnet-learn/
