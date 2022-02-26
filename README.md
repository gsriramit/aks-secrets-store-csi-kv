# Secret Store CSI Driver for Azure Keyvault
Implementation of the Secrets Store CSI Driver for Azure KeyVault.The key take aways are
1. Azure Keyvault as a secrets store is implemented as a SecretProviderClass
2. The SecretProviderClass and other resources that are needed to make this work are deployed as AKS CRDs
3. Extensibility to other secret stores is the key highlight of this feature
4. The pods use the AAD pod identity to access the vault
5. The secret content when accessed from the vault eliminates the need to save sensitive data as native K8s secrets (which is only a base64 encoded version of your data and is not really encrypted. There are plenty of articles that talk about why the CSI driver for secrets store is a welcomed feature)

## Working of Azure KeyVault CSI driver

![basic-key-vault](https://user-images.githubusercontent.com/13979783/155843649-9fc9ae38-1cc9-4c97-96ea-202ac229a4d7.svg)
src: Microsoft docs (https://docs.microsoft.com/en-us/azure/aks/developer-best-practices-pod-security#use-azure-key-vault-with-secrets-store-csi-driver)


## References
1. Developer Best Practices -https://docs.microsoft.com/en-us/azure/aks/developer-best-practices-pod-security#use-azure-key-vault-with-secrets-store-csi-driver
2. Azure/secrets-store-csi-driver-provider-azure (open source github repo)- https://github.com/Azure/secrets-store-csi-driver-provider-azure
3. Walkthrough of Secrets Store CSI driver for multicloud scenarios- https://www.youtube.com/watch?v=w0k7MI6sCJg&list=PLQL1JGGe-t0u2bTkrVmek72nF-_vJACnG&index=22&t=302s
