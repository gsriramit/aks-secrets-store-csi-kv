#!/bin/bash

export SUBSCRIPTION_ID=""
RESOURCEGROUP_LOCATION="EastUS"
RESOURCEGROUP_NAME="rg-akspodidentity-dev-01"
CLUSTER_NAME="aks-dev-01"
export IDENTITY_NAME="podidentity-test"
export KEYVAULT_NAME="kv-aks-secretstore"
export TENANT_ID=""


# login as a user and set the appropriate subscription ID
az login
az account set -s "${SUBSCRIPTION_ID}"

# install the needed features
az provider register --namespace Microsoft.OperationsManagement
az provider register --namespace Microsoft.OperationalInsights
az feature register --name EnablePodIdentityPreview --namespace Microsoft.ContainerService

# Install the aks-preview extension
az extension add --name aks-preview

# create the base resource group
az group create --location $RESOURCEGROUP_LOCATION --name $RESOURCEGROUP_NAME --subscription $SUBSCRIPTION_ID 

# Create an RBAC enabled AKS cluster
az aks create -g $RESOURCEGROUP_NAME -n $CLUSTER_NAME --enable-aad --enable-azure-rbac --network-plugin azure --node-count 1 --enable-addons monitoring
##--enable-pod-identity

# for this demo, we will be deploying a user-assigned identity to the AKS node resource group
export IDENTITY_RESOURCE_GROUP="$(az aks show -g ${RESOURCEGROUP_NAME} -n ${CLUSTER_NAME} --query nodeResourceGroup -otsv)"

# get the client-Id of the managed identity assigned to the node pool
AGENTPOOL_IDENTITY_CLIENTID=$(az aks show -g $RESOURCEGROUP_NAME -n $CLUSTER_NAME --query identityProfile.kubeletidentity.clientId -o tsv)

# perform the necessary role assignments to the managed identity of the nodepool (used by the kubelet)
# Important Note: The roles Managed Identity Operator and Virtual Machine Contributor must be assigned to the cluster managed identity or service principal, identified by the ID obtained above, 
# ""before deploying AAD Pod Identity"" so that it can assign and un-assign identities from the underlying VM/VMSS.
az role assignment create --role "Managed Identity Operator" --assignee $AGENTPOOL_IDENTITY_CLIENTID --scope /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${IDENTITY_RESOURCE_GROUP}
az role assignment create --role "Virtual Machine Contributor" --assignee $AGENTPOOL_IDENTITY_CLIENTID --scope /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${IDENTITY_RESOURCE_GROUP}

# get the cluster access credentials before executing the K8s API commands
# Note: the --admin switch is optional and not adviced for production setups
az aks get-credentials -n aks-dev-01 -g rg-akspodidentity-dev-01 --admin

# Test if the manual installation of these CRDs are necessary
# The manifests are downlaoded from the azure github repo
kubectl apply -f ../PodIdentityManifests/deployment-rbac.yaml
# For AKS clusters, deploy the MIC and AKS add-on exception by running -
kubectl apply -f ../PodIdentityManifests/mic-exception.yaml

#Deploy Azure Key Vault Provider for Secrets Store CSI Driver
helm repo add csi-secrets-store-provider-azure https://azure.github.io/secrets-store-csi-driver-provider-azure/charts
helm install csi csi-secrets-store-provider-azure/csi-secrets-store-provider-azure

# Create the managed (user-assigned) identity that will be assigned to the pods (in a specific namespace if required) to authenticate with AAD and access azure resources 
az identity create -g ${IDENTITY_RESOURCE_GROUP} -n ${IDENTITY_NAME}
export IDENTITY_CLIENT_ID="$(az identity show -g ${IDENTITY_RESOURCE_GROUP} -n ${IDENTITY_NAME} --query clientId -otsv)"
export IDENTITY_RESOURCE_ID="$(az identity show -g ${IDENTITY_RESOURCE_GROUP} -n ${IDENTITY_NAME} --query id -otsv)"

# Create the Azure Keyvault secret store that will store the secret required by the pods
az keyvault create -n ${KEYVAULT_NAME} -g ${RESOURCEGROUP_NAME} --location ${RESOURCEGROUP_LOCATION}

# set the access control policies that grant the necessary permissions to the MI to access the vault resources
# set policy to access keys in your keyvault
az keyvault set-policy -n $KEYVAULT_NAME --key-permissions get --spn $IDENTITY_CLIENT_ID
# set policy to access secrets in your keyvault
az keyvault set-policy -n $KEYVAULT_NAME --secret-permissions get --spn $IDENTITY_CLIENT_ID
# set policy to access certs in your keyvault
az keyvault set-policy -n $KEYVAULT_NAME --certificate-permissions get --spn $IDENTITY_CLIENT_ID

# Note: The following K8s manifests can be deployed to the cluster using the file as i/p param after the needed values are updated
# The Yq tool can be used to achieve this - https://github.com/mikefarah/yq

# Create the needed "AzureIdentity" resource kind
cat <<EOF | kubectl apply -f -
apiVersion: "aadpodidentity.k8s.io/v1"
kind: AzureIdentity
metadata:
  name: ${IDENTITY_NAME}
spec:
  type: 0
  resourceID: ${IDENTITY_RESOURCE_ID}
  clientID: ${IDENTITY_CLIENT_ID}
EOF

# Create the needed "AzureIdentityBinding" resource kind- this lets the NMI pods to communicate with the IMDS
cat <<EOF | kubectl apply -f -
apiVersion: "aadpodidentity.k8s.io/v1"
kind: AzureIdentityBinding
metadata:
  name: ${IDENTITY_NAME}-binding
spec:
  azureIdentity: ${IDENTITY_NAME}
  selector: ${IDENTITY_NAME}
EOF

# Create a sample secret in the vault that will be fetched by the pods
az keyvault secret set --vault-name ${KEYVAULT_NAME} --name testsecret --value "TestSecret!"

# Deploy the Azure Secret Provider Class. This will be referenced by the workload pod in the next step
# Note: The class exposes limited number of objects. Modify this to add as many objects as needed by the workload
cat <<EOF | kubectl apply -f -
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: azure-kvname-podid
spec:
  provider: azure
  parameters:
    usePodIdentity: "true"          # Set to true for using aad-pod-identity to access keyvault
    keyvaultName: $KEYVAULT_NAME
    objects:  |
      array:
        - |
          objectName: testsecret
          objectType: secret        # object types: secret, key or cert
          objectVersion: ""         # [OPTIONAL] object versions, default to latest if empty
    tenantId: $TENANT_ID                # the tenant ID of the KeyVault
EOF


# Deploy a sample workload that uses pod-identity and creates a secret volume mount request
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: busybox-secrets-store-inline-podid
  labels:
    aadpodidbinding: $IDENTITY_NAME                            # Set the label value to the selector defined in AzureIdentityBinding
spec:
  containers:
    - name: busybox
      image: k8s.gcr.io/e2e-test-images/busybox:1.29
      command:
        - "/bin/sleep"
        - "10000"
      volumeMounts:
      - name: secrets-store01-inline
        mountPath: "/mnt/secrets-store"
        readOnly: true
  volumes:
    - name: secrets-store01-inline
      csi:
        driver: secrets-store.csi.k8s.io
        readOnly: true
        volumeAttributes:
          secretProviderClass: "azure-kvname-podid"
EOF


## show secrets held in secrets-store
kubectl exec busybox-secrets-store-inline-podid -- ls /mnt/secrets-store/

## print a test secret held in secrets-store
kubectl exec busybox-secrets-store-inline-podid -- cat /mnt/secrets-store/testsecret



