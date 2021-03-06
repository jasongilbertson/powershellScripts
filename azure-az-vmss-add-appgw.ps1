# script to add app gateway to existing service fabric deployment
# script requires existing rg, vnet, sub (sf deployment)
<#
 "error": {
    "code": "SubnetIsRequired",
    "message": "Subnet reference is required for ipconfiguration ../Microsoft.Network/applicationGateways/sfjagilber1nano1-ag/gatewayIPConfigurations/sfjagilber1nano1ApplicationGatewayIPConfig.",
#>

[cmdletbinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$resourceGroupName = "",
    [int]$sleepSeconds = 10, 
    [int]$maxSleepCount = 360,
    [string]$vmssName = "", #"nt0",
    [string]$appGatewayName = "$($resourceGroupName)-ag",
    [string]$agAddressPrefix = "10.0.1.0/24",
    [string]$agSku = "Standard_Small",
    [string]$location = "",
    [string]$vnetName = "", #"VNet",
    [string]$agSubnetName = "Subnet-AG",
    #[string[]]$backendIpAddresses = @(), 
    [string]$agGatewayIpConfigName = "$($resourceGroupName)ApplicationGatewayIPConfig",
    [string]$agBackendAddressPoolName = "$($resourceGroupName)ApplicationGatewayBEAddressPool", # LoadBalancerBEAddressPool
    [string]$agFrontendIPConfigName = "$($resourceGroupName)ApplicationGatewayFEAddressPool", # LoadBalancerFEAddressPool
    [string]$publicIpName = "$($resourceGroupName)agPublicIp1",
    [string]$listenerName = "$($resourceGroupName)agListener1",
    [ValidateSet('http', 'https')]
    [string]$protocol = "http",
    [int]$frontEndPort = 80,
    [string]$frontEndPortName = "FrontEndPort01",
    [string]$backendPoolName = "PoolSetting01",
    [string]$agRuleName = "Rule01",
    [int]$backendPort = 80,
    [ValidateSet('attach', 'create')]
    [string]$action = 'create',
    [hashtable]$additionalParameters
)

$ErrorActionPreference = $DebugPreference = $VerbosePreference = 'continue'
$error.Clear()
write-host "$pscommandpath $($PSBoundParameters | out-string)"
write-host "variables: `r`n$(get-variable | select Name,Value | ft -AutoSize * | out-string)"

function main() {
    if (!$resourceGroupName -or !$appGatewayName) {
        help $MyInvocation.ScriptName -full
        Write-warning 'pass arguments'
        return
    }

    if (!(Get-AzResourceGroup | out-null)) {
        if (!(Connect-AzAccount)) { return }
    }

    if (!$location) {
        $location = (Get-AzResourceGroup $resourceGroupName).location
    }
    write-host "using location $location"

    if (!($vnet = check-vnet)) { return }
    if (!($vmss = check-vmss)) { return }
    if (!($agw = check-agw -vnet $vnet)) { return }
    
    modify-vmssIpConfig -vmss -$vmss -agw $agw
    write-host "finished"
}

function check-agw($vnet) {
    #app gateway
    $agw = Get-azApplicationGateway -ResourceGroupName $resourceGroupName -Name $appGatewayName -ErrorAction SilentlyContinue
    if ((!$agw -or !$agw.BackendAddressPools) -and $action -ieq 'attach') {
        write-warning "unable to enumerate existing ag or backend pool in resource group. returning"
        return $null
    }
    elseif ($agw -and $action -ieq 'attach') {
        write-host "app gateway config:`r`n$($agw|convertto-json -depth 5)" -ForegroundColor Magenta
    }
    elseif ($agw -and $action -ieq 'create' -and !$force) {
        write-warning "ag already exists in resource group. returning"
        return $null
    }
    elseif (!$agw -and $action -ieq 'create') {
        write-warning "ag does not exist in resource group. creating"
        return create-agw -vnet $vnet
    }
    return $agw
}

function check-subnet($vnet, $subnetName = $agSubnetName) {
    # ag needs separate subnet that is empty or only other ags
    write-host "Get-azVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnet" -ForegroundColor Cyan
    $config = Get-azVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnet
    if(!$config){
        $configs = @(Get-azVirtualNetworkSubnetConfig -VirtualNetwork $vnet)
        if($configs.Count -eq 1){
            $config = $configs[0]
        }
    }

    if (!$config.Id) {
        Write-Warning "unable to get subnet $subnetName $error"
        $error.Clear()
        return $null
    }

    write-host "subnet config:`r`n$($config|convertto-json -depth 5)" -ForegroundColor Magenta
    return $config
}
function check-vmss() {
    $vmss
    if($vmssScaleSetName){
        $vmss = Get-azVmss -ResourceGroupName $resourceGroupName -VMScaleSetName $vmssScaleSetName
    }
    else {
        $vmsss = @(Get-azVmss -ResourceGroupName $resourceGroupName)
        if($vmsss.Count -eq 1){
            $vmss = $vmsss[0]
        }
    }

    if (!$vmss) {
        write-warning "unable to enumerate existing vm scaleset $vmssScaleSetName"
        return $null
    }
    write-host "vmss config:`r`n$($vmss|convertto-json -depth 5)" -ForegroundColor Magenta

    $vmssIpConfig = $vmss.VirtualMachineProfile.NetworkProfile[0].NetworkInterfaceConfigurations[0].IpConfigurations[0]
    write-host "vmss ip config:`r`n$($vmssIpConfig|convertto-json -depth 5)" -ForegroundColor Magenta

    if (!$force -and $vmssIpConfig.ApplicationGatewayBackendAddressPools.Count -gt 0) {
        write-warning "vmss nic already configured for applicationgateway. returning"
        return $null
    }

    return $vmss
}

function check-vnet ($name = $vnetName) {
    if($name){
        $vnet = Get-azvirtualNetwork -Name $name -ResourceGroupName $resourceGroupName
    }
    else {
        $vnets = @(Get-azvirtualNetwork -ResourceGroupName $resourceGroupName)
        if($vnets.Count -eq 1){
            $vnet = $vnets[0]
        }
    }

    if (!$vnet) {
        write-warning "unable to enumerate existing vnet $vnet"
        return $null
    }
    write-host "vnet config:`r`n$($vnet|convertto-json -depth 5)" -ForegroundColor Magenta
    return $vnet
}

function create-agw($vnet) {
    $agSubnet = $null
    $count = 0

    $error.clear()
    if (!($agSubnet = create-subnet -vnet $vnet -maxSleepCount $maxSleepCount -sleepSeconds $sleepSeconds)) { 
        return $null 
    }

    write-host "agsubnet: $($agSubnet| out-string)" -ForegroundColor Cyan

    $gatewayIpConfig = New-azApplicationGatewayIPConfiguration `
        -Name $agGatewayIpConfigName `
        -Subnet $agSubnet
    write-host "gatewayIpConfig: $($gatewayIpConfig| out-string)" -ForegroundColor Cyan

    $pool = New-azApplicationGatewayBackendAddressPool `
        -Name $agBackendAddressPoolName 
    write-host "pool: $($pool| out-string)" -ForegroundColor Cyan
    
    $poolSetting = New-azApplicationGatewayBackendHttpSettings `
        -Name $backendPoolName `
        -Port $backendPort `
        -Protocol $protocol `
        -CookieBasedAffinity "Disabled"
    write-host "poolsetting: $($poolsetting| out-string)" -ForegroundColor Cyan

    $frontEndPort = New-azApplicationGatewayFrontendPort `
        -Name $frontEndPortName `
        -Port $frontEndPort
    write-host "frontendport: $($frontendport| out-string)" -ForegroundColor Cyan

    # Create a public IP address
    $publicIp = New-azPublicIpAddress `
        -ResourceGroupName $resourceGroupName `
        -Name $publicIpName `
        -Location $location `
        -AllocationMethod "Dynamic" `
        -Force
    write-host "new ip config:`r`n$($publicIp | convertto-json)" -ForegroundColor Green

    # create application gateway
    $frontEndIpConfig = New-azApplicationGatewayFrontendIPConfig `
        -Name $agFrontendIPConfigName `
        -PublicIPAddress $publicIp `
        #-Subnet $agSubnet # for internal
    write-host "frontend ip config:`r`n$($frontendIpConfig | convertto-json)" -ForegroundColor Green

    $listener = New-azApplicationGatewayHttpListener `
        -Name $listenerName  `
        -Protocol $protocol `
        -FrontendIpConfiguration $frontEndIpConfig `
        -FrontendPort $frontEndPort
    write-host "listener:`r`n$($listener | convertto-json)" -ForegroundColor Green

    $rule = New-azApplicationGatewayRequestRoutingRule `
        -Name $agRuleName `
        -RuleType basic `
        -BackendHttpSettings $poolSetting `
        -HttpListener $listener `
        -BackendAddressPool $pool
    write-host "request routing rule:`r`n$($rule | convertto-json)" -ForegroundColor Green

    $agSku = New-azApplicationGatewaySku `
        -Name $agSku `
        -Tier Standard `
        -Capacity 2
    write-host "ag sku:`r`n$($agsku | convertto-json)" -ForegroundColor Green

    write-host "$gateway = New-azApplicationGateway -Name $appGatewayName `
        -ResourceGroupName $resourceGroupName `
        -Location $location `
        -BackendAddressPools $($pool |out-string)`
        -BackendHttpSettingsCollection $($poolSetting |out-string) `
        -FrontendIpConfigurations $($frontEndIpConfig |out-string) `
        -GatewayIpConfigurations $($gatewayIPconfig |out-string) `
        -FrontendPorts $($frontEndPort |out-string) `
        -HttpListeners $($listener |out-string) `
        -RequestRoutingRules $($rule |out-string) `
        -Sku $($agSku |out-string) `
        -Force `
        $($additionalParameters | out-string)" -ForegroundColor Green
        
    $gateway = New-azApplicationGateway -Name $appGatewayName `
        -ResourceGroupName $resourceGroupName `
        -Location $location `
        -BackendAddressPools $pool `
        -BackendHttpSettingsCollection $poolSetting `
        -FrontendIpConfigurations $frontEndIpConfig `
        -GatewayIpConfigurations $gatewayIPconfig `
        -FrontendPorts $frontEndPort `
        -HttpListeners $listener `
        -RequestRoutingRules $rule `
        -Sku $agSku `
        -Force

        #-Verbose `
    #-Debug `
    #@additionalParameters
    write-host "new application gateway:`r`n$($gateway|convertto-json -depth 5)" -ForegroundColor Magenta

    if (!$error -and $gateway) {
        write-host "gateway created successfully" -ForegroundColor green
        return $true
    }

    write-warning "gateway creation failed"
    return $null
}

function create-agSku($skuName, $tier = 'Standard', $capacity = 2) {
    return New-azApplicationGatewaySku -Name $skuName `
        -Tier $tier `
        -Capacity $capacity
}

function create-subnet($vnet, $sleepSeconds, $maxSleepCount) {
    # ag needs separate subnet that is empty or only other ags
    $retval = $null

    if (!(check-subnet -vnet $vnet)) {
        $retval = Add-azVirtualNetworkSubnetConfig -Name $agSubnetName -VirtualNetwork $vnet -AddressPrefix $agAddressPrefix
        write-host "adding subnet:Add-azVirtualNetworkSubnetConfig -Name $agSubnetName -VirtualNetwork $vnet -AddressPrefix $agAddressPrefix `r`n$retval" -ForegroundColor Cyan
        
        $retval = Set-azVirtualNetwork -VirtualNetwork $vnet 
        write-host "setting subnet: Set-azVirtualNetwork -VirtualNetwork $vnet `r`n$retval" -ForegroundColor Cyan
    }
    
    while ((!$agSubnet.Id) -and ++$count -lt $maxSleepCount) {
        $agSubnet = check-subnet -vnet (check-vnet -name $vnetName) -subnetName $agSubnetName
        start-sleep -Seconds $sleepSeconds
    }

    if ($count -ge $maxSleepCount) {
        write-error "timed out waiting for subnet change maxsleepcount $maxsleepcount sleepseconds $sleepseconds"
        return $null
    }

    return $agSubnet
}

function modify-vmssIpConfig ($vmss, $agw) {
    # change ip configuration on vmss
    $error.clear()
    $vmss = Get-azVmss -ResourceGroupName $resourceGroupName -VMScaleSetName $vmssName
    $vmss.VirtualMachineProfile.NetworkProfile.NetworkInterfaceConfigurations[0].IpConfigurations 
 
    $agw = Get-azApplicationGateway -ResourceGroupName $resourceGroupName
    $agw.BackendAddressPools 
 
    $vmssipconf_LB_BEAddPools = $vmss.VirtualMachineProfile.NetworkProfile[0].NetworkInterfaceConfigurations[0].IpConfigurations[0].LoadBalancerBackendAddressPools[0].Id
    $vmssipconf_LB_InNATPools = $vmss.VirtualMachineProfile.NetworkProfile[0].NetworkInterfaceConfigurations[0].IpConfigurations[0].LoadBalancerInboundNatPools[0].Id
    $vmssipconf_Name = $vmss.VirtualMachineProfile.NetworkProfile[0].NetworkInterfaceConfigurations[0].IpConfigurations[0].Name
    $vmssipconf_Subnet = $vmss.VirtualMachineProfile.NetworkProfile.NetworkInterfaceConfigurations[0].IpConfigurations[0].Subnet.Id
    $vmssipconf_AppGW_BEAddPools = $agw.BackendAddressPools[0].Id
 
    $vmssipConfig = New-azVmssIPConfig -Name $vmssipconf_Name `
        -LoadBalancerInboundNatPoolsId $vmssipconf_LB_InNATPools `
        -LoadBalancerBackendAddressPoolsId $vmssipconf_LB_BEAddPools `
        -SubnetId $vmssipconf_Subnet `
        -ApplicationGatewayBackendAddressPoolsId $vmssipconf_AppGW_BEAddPools
 
    $nicconfigname = $vmss.VirtualMachineProfile.NetworkProfile.NetworkInterfaceConfigurations[0].Name
    Remove-azVmssNetworkInterfaceConfiguration -VirtualMachineScaleSet $vmss -Name $nicconfigname 
    Add-azVmssNetworkInterfaceConfiguration -VirtualMachineScaleSet $vmss -Name $nicconfigname -Primary $true -IPConfiguration $vmssipConfig
    Update-azVmss -ResourceGroupName $resourceGroupName -VirtualMachineScaleSet $vmss -Name $vmssName 
    if (!$error) {
        write-host "vmss updated successfully" -ForegroundColor green
        return $true
    }

    write-warning "vmss update failed"
    return $null

}

main
$ErrorActionPreference = 'continue'
$DebugPreference = $VerbosePreference = 'silentlycontinue'