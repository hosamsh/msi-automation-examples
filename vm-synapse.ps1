#########################################################
# DISCLAIMER: #########################
#########################################################
# This script is provided "as-is" without any guarantees 
# or warranties, express or implied.
# The author assumes no responsibility for any issues or
# damages resulting from its use.
#
# This script is provided for demonstration purposes only 
# and should be treated as guidance.
# The accuracy, completeness, or success of the code is 
# not guaranteed. 
# Use this code at your own risk, and adapt it to your 
# specific requirements as needed.
#
# NOTE: If you wish to perform these steps manually, use the 
# script as guidance and follow the equivalent steps 
# in the Azure portal. References are provided in the 
# comments where relevant.
#########################################################


#################
# Example Script to demonstrate authenticating from a VMto 
# access Azure Synapse Analytics using Managed Identity
#################
# 
# DESCRIPTION:
# This script demonstrates how to set up and use managed identity for a Linux VM
# with Azure Synapse Analytics. It creates:
# 1. An Azure Synapse workspace with a dedicated SQL pool
# 2. A Linux VM with a system-assigned managed identity
# 3. Necessary permissions for the VM's identity to access the Synapse workspace
# 4. Installs Azure CLI on the VM and tests the MSI authentication
#
# PREREQUISITES:
# - Azure CLI installed locally
# - Az PowerShell module
# - An active Azure subscription
# - Administrative permissions on your subscription
#
# USAGE:
# 1. Modify the variables in the "Define Variables" section:
#    - Set your subscription ID
#    - Customize resource names and locations as needed
#    - Set secure passwords for the Synapse admin
# 2. Run the script in PowerShell
# 3. The script will create all resources and demonstrate MSI authentication
# 4. Resources are automatically cleaned up at the end (resource group deletion)
#
# NOTE: This script is intended for demonstration/educational purposes.
# For production environments, you should implement proper security practices.
#################

#################
# Ensure Azure CLI & Az PowerShell Module are Installed
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host "Azure CLI (az) is not installed. Please install it first: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli" -ForegroundColor Red
    exit
}

if (-not (Get-Module -ListAvailable -Name Az)) {
    Write-Host "Azure PowerShell module is not installed. Installing now..." -ForegroundColor Yellow
    Install-Module -Name Az -AllowClobber -Force
    Import-Module Az
}


# If not installed yet (you can skip if already installed)
if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Install-Module -Name SqlServer -Scope CurrentUser -Force
}

# -----------------------------------------------------------------------------
# Define Variables
# -----------------------------------------------------------------------------
$resourceGroupName = "MsiResourceGroup" # NOTE: The RG will be created if it doesn't exist
$location = "East US" # NOTE: Change this to your preferred Azure region

# Synapse workspace variables
$synapseWorkspaceName = "msimove123" # NOTE: Set the Synapse workspace name
$synapseAdminUser = "SynapseAdmin"  # NOTE: This will be created as Synapse admin account name
$synapseAdminPassword =  "YourSecurePassword123!" # NOTE: Use a strong password for the Synapse admin account
$gatewayName = "MySynapseGateway"
$synapseSqlPoolName = "mysynapsedb" # NOTE: This will be created as the dedicated SQL pool name
$synapseSqlPoolPerfLevel = "DW100c" # NOTE: Set the performance level for the SQL pool

# Set vm variables
$vmName = "MsiLinuxVM"
$vmSize = "Standard_B2s"
$vmUser = "msiuser"
# $vmPassword = "YourSecureP@ssw0rd!" ## not needed for SSH in this scenario

# -----------------------------------------------------------------------------
# Azure Authentication and Subscription Selection
# -----------------------------------------------------------------------------
# Login to Azure if not already logged in
Write-Host "Logging in to Azure..." -ForegroundColor Cyan
az login

# Get list of subscriptions and let user select one
Write-Host "Fetching your subscriptions..." -ForegroundColor Cyan
$subscriptions = az account list --query "[].{Name:name, Id:id, IsDefault:isDefault}" --output json | ConvertFrom-Json

# Display subscriptions with index numbers
Write-Host "Available Subscriptions:" -ForegroundColor Green
for ($i = 0; $i -lt $subscriptions.Length; $i++) {
    $defaultIndicator = if ($subscriptions[$i].IsDefault) { " (Default)" } else { "" }
    Write-Host "[$i] $($subscriptions[$i].Name)$defaultIndicator - $($subscriptions[$i].Id)"
}

# Ask user to select a subscription
$selectedIndex = -1
do {
    $selectedIndex = Read-Host "Select a subscription by entering its index number"
    $selectedIndex = [int]$selectedIndex
} while ($selectedIndex -lt 0 -or $selectedIndex -ge $subscriptions.Length)

# Set the selected subscription
$selectedSubscription = $subscriptions[$selectedIndex]
$subscriptionId = $selectedSubscription.Id
az account set --subscription $subscriptionId
Write-Host "Using subscription: $($selectedSubscription.Name) ($subscriptionId)" -ForegroundColor Green

# -----------------------------------------------------------------------------
# Ensure Required Providers Are Registered
# -----------------------------------------------------------------------------
$providers = @("Microsoft.Sql", "Microsoft.Synapse", "Microsoft.Storage")
foreach ($provider in $providers) {
    $registrationState = $(az provider show --namespace $provider --query registrationState -o tsv)
    if ($registrationState -ne "Registered") {
        Write-Host "Registering provider: $provider ..." -ForegroundColor Yellow
        az provider register --namespace $provider
        Start-Sleep -Seconds 30
    }
}

# -----------------------------------------------------------------------------
# Create Resource Group
# -----------------------------------------------------------------------------
if (-not (az group exists --name "$resourceGroupName")) {
    Write-Host "Creating Resource Group: $resourceGroupName" -ForegroundColor Cyan
    az group create --name "$resourceGroupName" --location "$location"
}

# -----------------------------------------------------------------------------
# Create Synapse Workspace
# Using the portal: https://learn.microsoft.com/azure/synapse-analytics/quickstart-create-workspace
# -----------------------------------------------------------------------------
Write-Host "Creating Synapse Workspace: $synapseWorkspaceName" -ForegroundColor Cyan
    az synapse workspace create --name "$synapseWorkspaceName" `
        --resource-group "$resourceGroupName" `
        --location "$location" `
        --sql-admin-login-user "$synapseAdminUser" `
        --sql-admin-login-password "$synapseAdminPassword" `
        --storage-account "$synapseWorkspaceName-adls"

# -----------------------------------------------------------------------------
# Create Synapse Managed Private Endpoint (Gateway)
# Using the portal: https://learn.microsoft.com/en-us/azure/synapse-analytics/security/how-to-create-managed-private-endpoints
# -----------------------------------------------------------------------------
Write-Host "Creating Synapse Managed Private Endpoint (Gateway): $gatewayName" -ForegroundColor Cyan
    az synapse managed-private-endpoint create `
        --workspace-name "$synapseWorkspaceName" `
        --name "$gatewayName" `
        --resource-group "$resourceGroupName" `
        --target-resource-id "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Sql/servers/$synapseWorkspaceName"

Write-Host "✅ Synapse Managed Private Endpoint '$gatewayName' created successfully!" -ForegroundColor Green

# -----------------------------------------------------------------------------
# The default workspace identity (system assigned) - Not used in the script
# -----------------------------------------------------------------------------
$workspaceIdentityId = az synapse workspace show --name $synapseWorkspaceName --resource-group "$resourceGroupName" --query identity.principalId --output tsv

# -----------------------------------------------------------------------------
# Optional: Create a new Synapse SQL Pool
# Using the portal: https://learn.microsoft.com/en-us/azure/synapse-analytics/quickstart-create-sql-pool-portal
# -----------------------------------------------------------------------------
# This creates a dedicated SQL pool named "mysynapsedb"
Write-Host "Creating Synapse SQL Pool: $synapseSqlPoolName" -ForegroundColor Cyan
az synapse sql pool create `
  --name $synapseSqlPoolName `
  --workspace-name $synapseWorkspaceName `
  --resource-group $resourceGroupName `
  --performance-level $synapseSqlPoolPerfLevel `

Write-Host "✅ Synapse SQL Pool '$synapseSqlPoolName' created successfully!" -ForegroundColor Green

# -----------------------------------------------------------------------------
# Create Linux VM with System-Assigned MSI
# Using the portal: https://learn.microsoft.com/en-us/azure/virtual-machines/linux/quick-create-portal
# Configure msi's: https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/how-to-configure-managed-identities
# -----------------------------------------------------------------------------
Write-Host "Creating Linux VM: $vmName" -ForegroundColor Cyan

az vm create `
  --resource-group $resourceGroupName `
  --name $vmName `
  --image Ubuntu2204 `
  --admin-username $vmUser `
  --generate-ssh-keys `
  --size $vmSize
Write-Host "✅ Linux VM '$vmName' created successfully!" -ForegroundColor Green

# Open port 22 for SSH access
az vm open-port `
  --port 22 `
  --resource-group $resourceGroupName `
  --name $vmName
Write-Host "✅ Port 22 opened for SSH access!" -ForegroundColor Green

# assign system-assigned managed identity to the VM
az vm identity assign `
  --name $vmName `
  --resource-group $resourceGroupName

  # get the VM's system-assigned managed identity principal id (object id)
# This is the object ID that will be used to assign roles and access Synapse workspace
$msiObjectId = az vm show `
  --name $vmName `
  --resource-group $resourceGroupName `
  --query identity.principalId `
  --output tsv
Write-Host "✅ Managed Identity assigned to VM '$vmName', principal id='$msiObjectId'!" -ForegroundColor Green

# -----------------------------------------------------------------------------
# Quick SSH test to make sure the VM is accessible
# Use ssh: https://learn.microsoft.com/en-us/azure/virtual-machines/linux-vm-connect
# -----------------------------------------------------------------------------
Write-Host "Getting Public IP of VM..." -ForegroundColor Cyan
$vmIp = az vm show `
  --name $vmName `
  --resource-group $resourceGroupName `
  --show-details `
  --query "publicIps" -o tsv

# Use the default SSH key location
$sshKey = "$HOME\.ssh\id_rsa"   # or "C:\Users\<username>\.ssh\id_rsa"

Write-Host "Performing a quick test connect to the VM via SSH..." -ForegroundColor Cyan
# test SSH access to the VM
# NOTE: accept the SSH key fingerprint on first connection
ssh -i $sshKey $vmUser@$vmIp "echo Hello from inside the Linux VM!!!"

# -----------------------------------------------------------------------------
# Allow the VM's public IP in Synapse workspace firewall
# Using the portal: https://learn.microsoft.com/en-us/azure/synapse-analytics/security/synapse-workspace-ip-firewall
# -----------------------------------------------------------------------------
Write-Host "Allowing VM's public IP in Synapse workspace firewall..." -ForegroundColor Cyan
az synapse workspace firewall-rule create `
  --name "AllowMyVMIp" `
  --resource-group $resourceGroupName `
  --workspace-name $synapseWorkspaceName `
  --start-ip-address $vmIp `
  --end-ip-address $vmIp

# -----------------------------------------------------------------------------
# Assign the "Contributor" role to the VM's MSI on the Synapse workspace scope
# Using the portal: https://learn.microsoft.com/en-us/azure/synapse-analytics/security/how-to-manage-synapse-rbac-role-assignments#add-a-synapse-role-assignment
# -----------------------------------------------------------------------------
Write-Host "Assigning Contributor role to the VM" -ForegroundColor Cyan

$synapseWorkspaceId = az synapse workspace show `
    --name $synapseWorkspaceName `
    --resource-group $resourceGroupName `
    --query id `
    --output tsv

# Assign the "Contributor" role to the VM's MSI on the Synapse workspace scope
# This allows the VM's MSI to access the Synapse management plane
az role assignment create `
    --assignee $msiObjectId `
    --role "Contributor" `
    --scope $synapseWorkspaceId

# -----------------------------------------------------------------------------
# Here's a script that installs the Azure CLI inside the VM and tests
# Synapse management-plane access with the VM's MSI
# references:
# - Install Az CLI on Linux: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-linux
# - Use MSI on a VM to acquier access tokens: https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/how-to-use-vm-token
# -----------------------------------------------------------------------------
Write-Host "Using SSH to test Synapse access from the VM..." -ForegroundColor Cyan
$scriptContent = @'
#!/bin/bash

set -e

# Install prerequisites
echo "📦 Installing prerequisites..."
sudo apt-get update
sudo apt-get install -y jq curl
sudo apt-get install ca-certificates curl apt-transport-https lsb-release gnupg -y

# Install Az
curl -sL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | \
  sudo tee /usr/share/keyrings/microsoft.gpg > /dev/null

echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] \
  https://packages.microsoft.com/repos/azure-cli/ \
  $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/azure-cli.list

sudo apt-get update
sudo apt-get install azure-cli -y

# login using msi
az login --identity

# List Synapse SQL pools, will work only if the VM's MSI has "Contributor" (or appropriate role)
# on the Synapse workspace scope:
az synapse sql pool list --workspace-name "msimove123" --resource-group "MyResourceGroup"

echo "✅ Accessing synapse management plane with the VM identity was successful!"

echo "If you need to test the data plane, you’ll have to add the MSI as an AAD user in that dedicated pool, using T-SQL"

'@

# NOTE: The command below inlines the entire script as a single argument to ssh
# If single-quotes appear, it can break. Great if it works for you. 
# Otherwise, consider using scp + ssh or a bash heredoc approach.
# example with scp + ssh:
# 
# $tempFile = [System.IO.Path]::GetTempFileName()
# Set-Content -Path $tempFile -Value $scriptContent

## Upload the temp file to the VM using SCP
# Write-Host "Uploading script to VM..." -ForegroundColor Cyan
# scp -i $sshKey $tempFile "$vmUser@$vmIp`:test_synapse.sh"

# # Set permissions and run the script
# Write-Host "Running script on VM..." -ForegroundColor Cyan
# ssh -i $sshKey $vmUser@$vmIp "chmod +x test_synapse.sh && ./test_synapse.sh"
###### If the script fails, try SSH'ing to the VM and running the script.


ssh -i $sshKey $vmUser@$vmIp "$scriptContent"

# -----------------------------------------------------------------------------
# Clean up: Delete the VM, Synapse SQL Pool, and Resource Group
# -----------------------------------------------------------------------------
Write-Host "CLEANUP: About to delete resource group '$resourceGroupName' and all resources within it" -ForegroundColor Red
Write-Host "Press Ctrl+C within the next 5 seconds to cancel the cleanup operation..." -ForegroundColor Yellow

# Countdown timer to allow cancellation
for ($i = 4; $i -gt 0; $i--) {
    Write-Host "Deleting in $i seconds..." -ForegroundColor Red
    Start-Sleep -Seconds 1
}

Write-Host "Proceeding with deletion of resource group '$resourceGroupName'..." -ForegroundColor Red
Start-Sleep -Seconds 1
az group delete --name "$resourceGroupName" --yes --no-wait