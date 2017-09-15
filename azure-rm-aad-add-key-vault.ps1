﻿<#
    script to add certificate to azure arm AAD key vault
    to enable script execution, you may need to Set-ExecutionPolicy Bypass -Force

    Copyright 2017 Microsoft Corporation

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.

    # Note: Certificates stored in Key Vault as secrets with content type 'application/x-pkcs12', this is why Set-AzureRmKeyVaultAccessPolivy cmdlet grants -PremissionsToSecrets (rather than -PermissionsToCertificates).
    # You will need 1) application id ($app.ApplicationId), and 2) the password from above step supplied as input parameters to the Template.
    # https://www.sslforfree.com/
    # 170914
    .\azure-rm-aad-add-key-vault.ps1 -certPassword "somePassw0rd123565!" -certNameInVault "sfjagilber1cert" -vaultName "sfjagilber1vault" -resourceGroup "certsjagilber" -adApplicationName "sfjagilber1"
#>

[cmdletbinding()]
param(
    [string]$pfxPath = "$($env:temp)\$($adApplicationName).pfx",
    [string]$certPassword, # password that was used to secure the pfx file at the time of export 
    [string]$certNameInVault, # cert name in vault, has to be '^[0-9a-zA-Z-]+$' pattern (digits, letters or dashes only, no spaces)
    [string]$vaultName, # has to be unique?
    [string]$resourceGroup,
    [string]$uri, #  a valid formatted URL, not validated for single-tenant deployments used for identification
    [string]$adApplicationName,
    [switch]$noprompt,
    [string]$location = "eastus"
)

# authenticate
try
{
    Get-AzureRmResourceGroup | Out-Null
}
catch
{
    try
    {
        Add-AzureRmAccount
    }
    catch [management.automation.commandNotFoundException]
    {
        write-host "installing azurerm sdk. this will take a while..."
        install-module azurerm
        import-module azurerm
        Add-AzureRmAccount
    }
}

if (!(Get-AzureRmResourceGroup -Name $resourceGroup -ErrorAction SilentlyContinue))
{
    New-AzureRmResourceGroup -Name $resourceGroup -location $location
}

if (Get-AzureKeyVaultCertificate -vaultname $vaultName -name $certNameInVault -ErrorAction SilentlyContinue)
{
    if ($noprompt -or (read-host "is it ok to remove existing cert in vault?[y|n]") -imatch "y")
    {
        write-host "removing old cert from existing vault."
        remove-AzureKeyVaultCertificate -vaultname $vaultName -name $certNameInVault -Force
    }
}
    
if ((Get-AzureRmKeyVault -VaultName $vaultName -ResourceGroupName $resourceGroup -ErrorAction SilentlyContinue))
{
    if ($noprompt -or (read-host "is it ok to remove existing vault?[y|n]") -imatch "y")
    {
        write-host "removing old existing vault."
        remove-AzureRmKeyVault -VaultName $vaultName -ResourceGroupName $resourceGroup -Force
    }
}

if (!(Get-AzureRmKeyVault -VaultName $vaultName -ResourceGroupName $resourceGroup -ErrorAction SilentlyContinue))
{
    write-host "creating new azure rm key vault"
    New-AzureRmKeyVault -VaultName $vaultName -ResourceGroupName $resourceGroup -Location $location -EnabledForDeployment -EnabledForTemplateDeployment
}

if (!$certPassword)
{
    $certPassword = (get-credential).Password
}

$pwd = ConvertTo-SecureString -String $certPassword -Force -AsPlainText

if (!$uri)
{
    $uri = "https://$($env:Computername)/$($adApplicationName)"
}

if (![IO.File]::Exists($pfxPath))
{
    #$cert = New-SelfSignedCertificate -CertStoreLocation "cert:\currentuser\My" -Subject "CN=$($adApplicationName)" -KeyExportPolicy Exportable -Provider "Microsoft Enhanced RSA and AES Cryptographic Provider"
    $cert = New-SelfSignedCertificate -CertStoreLocation "cert:\currentuser\My" -Subject "$($adApplicationName)" -KeyExportPolicy Exportable 
    #$cert = (Get-ChildItem Cert:\CurrentUser\My | Where-Object Thumbprint -eq $thumbPrint)
    Export-PfxCertificate -cert "cert:\currentuser\my\$($cert.thumbprint)" -FilePath $pfxPath -Password $pwd
    $cert509 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate($pfxPath, $pwd)
}

Import-AzureKeyVaultCertificate -vaultname $vaultName -name $certNameInVault -filepath $pfxpath -password $pwd

if ($oldapp = Get-AzureRmADApplication -IdentifierUri $uri -ErrorAction SilentlyContinue)
{
    if ($noprompt -or (read-host "is it ok to remove existing ad application?[y|n]") -imatch "y")
    {
        Remove-AzureRmADApplication -ObjectId $oldapp.ObjectId -Force

        if ($sp = get-AzureRmADServicePrincipal -ServicePrincipalName $oldapp.applicationid)
        {
            Remove-AzureRmADServicePrincipal -ObjectId $sp.ObjectId -Force
        }
    }
}

$app = New-AzureRmADApplication -DisplayName $adApplicationName -HomePage $uri -IdentifierUris $uri -password $certPassword
$sp = New-AzureRmADServicePrincipal -ApplicationId $app.ApplicationId

Set-AzureRmKeyVaultAccessPolicy -vaultname $vaultName -serviceprincipalname $sp.ApplicationId -permissionstosecrets get
$tenantId = (Get-AzureRmSubscription).TenantId | Select-Object -Unique
$subscriptionId = (Get-AzureRmSubscription).subscriptionid | Select-Object -Unique

if ([io.file]::Exists($pfxPath))
{
    if ($noprompt -or (read-host "is it ok to remove existing pfx file?[y|n]") -imatch "y")
    {
        write-host "removing existing file: $($pfxPath)"
        [io.file]::Delete($pfxPath)
    }
}

write-output "spn: $($spn | format-list *)"
write-output "application id: $($app.ApplicationId)"
write-output "tenant id: $($tenantId)"
write-output "subscription id: $($subscriptionId)"
write-output "uri: $($uri)"
write-output "cert thumbprint: $($cert.Thumbprint)"
write-output "vault id: /subscriptions/$($subscriptionId)/resourceGroups/$($resourceGroup)/providers/Microsoft.KeyVault/vaults/$($vaultName)"
