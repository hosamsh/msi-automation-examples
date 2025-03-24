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
# Example Script to demonstrate authenticating from a VM to 
# access Azure Application Insights using Managed Identity
#################
# 
# DESCRIPTION:
# This script demonstrates how to set up and use Managed Service Identity (MSI) 
# with Azure Application Insights. It creates:
# 1. An Azure Application Insights resource with a connected Log Analytics workspace
# 2. A Linux VM with a system-assigned managed identity
# 3. Necessary permissions for the VM's identity to access the Application Insights resource
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
#    - Customize resource names and locations as needed
# 2. Run the script in PowerShell
# 3. The script will create all resources and demonstrate MSI authentication
# 4. Resources are automatically cleaned up at the end (resource group deletion)
#
# NOTE: This script is intended for demonstration/educational purposes.
# For production environments, you should implement proper security practices.
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
# Define Variables
# -----------------------------------------------------------------------------
$resourceGroupName = "MsiAppInsightsRG"  # Resource group will be created if it doesn't exist
$location = "northeurope"  # Change this to your preferred Azure region

# Application Insights variables
$appInsightsName = "msi-appinsights"
$logAnalyticsWorkspaceName = "msi-loganalytics"

# VM variables
$vmName = "MsiLinuxVM"
$vmSize = "Standard_B2s"
$vmUser = "msiuser"

# -----------------------------------------------------------------------------
# Ensure Required Providers Are Registered
# -----------------------------------------------------------------------------
$providers = @("Microsoft.Compute", "Microsoft.OperationalInsights", "Microsoft.OperationsManagement", "Microsoft.Insights")
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
# Create Log Analytics Workspace 
# Using the portal: https://learn.microsoft.com/en-us/azure/azure-monitor/app/create-workspace-resource?tabs=portal
# -----------------------------------------------------------------------------
Write-Host "Creating Log Analytics Workspace: $logAnalyticsWorkspaceName" -ForegroundColor Cyan
$workspaceId = az monitor log-analytics workspace create `
    --resource-group "$resourceGroupName" `
    --workspace-name "$logAnalyticsWorkspaceName" `
    --location "$location" `
    --query id `
    --output tsv

# -----------------------------------------------------------------------------
# Create Application Insights 
# -----------------------------------------------------------------------------
Write-Host "Creating Application Insights: $appInsightsName" -ForegroundColor Cyan
$appInsightsId = az monitor app-insights component create `
    --app "$appInsightsName" `
    --resource-group "$resourceGroupName" `
    --location "$location" `
    --workspace "$workspaceId" `
    --kind "web" `
    --application-type "web" `
    --query id `
    --output tsv

# Get the Application Insights instrumentation key
# $instrumentationKey = az monitor app-insights component show `
#     --app "$appInsightsName" `
#     --resource-group "$resourceGroupName" `
#     --query instrumentationKey `
#     --output tsv

# Write-Host "✅ Application Insights '$appInsightsName' created successfully!" -ForegroundColor Green
# Write-Host "Instrumentation Key: $instrumentationKey" -ForegroundColor Green

# -----------------------------------------------------------------------------
# Create Linux VM with System-Assigned MSI
# Using the portal: https://learn.microsoft.com/en-us/azure/virtual-machines/linux/quick-create-portal
# Configure msi's: https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/how-to-configure-managed-identities
# -----------------------------------------------------------------------------
Write-Host "Creating Linux VM with Managed Identity: $vmName" -ForegroundColor Cyan
az vm create `
    --resource-group $resourceGroupName `
    --name $vmName `
    --image Ubuntu2204 `
    --admin-username $vmUser `
    --generate-ssh-keys `
    --size $vmSize

az vm open-port `
    --port 22 `
    --resource-group $resourceGroupName `
    --name $vmName

az vm identity assign `
    --name $vmName `
    --resource-group $resourceGroupName

$msiObjectId = az vm show `
    --name $vmName `
    --resource-group $resourceGroupName `
    --query identity.principalId `
    --output tsv

Write-Host "✅ VM with MSI created successfully. MSI Principal ID: $msiObjectId" -ForegroundColor Green

# -----------------------------------------------------------------------------
# Quick SSH test to make sure the VM is accessible
# Use ssh: https://learn.microsoft.com/en-us/azure/virtual-machines/linux-vm-connect
# -----------------------------------------------------------------------------
$vmIp = az vm show `
    --name $vmName `
    --resource-group $resourceGroupName `
    --show-details `
    --query "publicIps" -o tsv

Write-Host "VM Public IP: $vmIp" -ForegroundColor Cyan

$sshKey = "$HOME\.ssh\id_rsa"   # or "C:\Users\<username>\.ssh\id_rsa"
ssh -i $sshKey $vmUser@$vmIp "echo Hello from inside the Linux VM!!!"

# -----------------------------------------------------------------------------
# Assign roles to the VM's MSI
# https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/how-to-assign-access-azure-resource
# -----------------------------------------------------------------------------
Write-Host "Assigning 'Monitoring Reader' role to VM's managed identity..." -ForegroundColor Cyan
az role assignment create `
    --assignee $msiObjectId `
    --role "Monitoring Reader" `
    --scope $appInsightsId

# Also assign Log Analytics Reader for querying logs
Write-Host "Assigning 'Log Analytics Reader' role to VM's managed identity..." -ForegroundColor Cyan
az role assignment create `
    --assignee $msiObjectId `
    --role "Log Analytics Reader" `
    --scope $workspaceId

# -----------------------------------------------------------------------------
# Here's a script to run on the VM to test the MSI authentication to Application Insights
# references:
# - Install Az CLI on Linux: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-linux
# - Use MSI on a VM to acquier access tokens: https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/how-to-use-vm-token
# -----------------------------------------------------------------------------
$scriptContent = @'
#!/bin/bash

set -e

# Helper function for better section separation
info() {
  echo -e "\n===== $1 ====="
}

# Install prerequisites
info "Installing prerequisites"
sudo apt-get update
sudo apt-get install -y jq curl
sudo apt-get install ca-certificates curl apt-transport-https lsb-release gnupg -y

# Install Azure CLI
info "Installing Azure CLI"
curl -sL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | \
  sudo tee /usr/share/keyrings/microsoft.gpg > /dev/null

echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] \
  https://packages.microsoft.com/repos/azure-cli/ \
  $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/azure-cli.list

sudo apt-get update
sudo apt-get install azure-cli -y

# Verify Azure CLI installation
info "Verifying Azure CLI installation"
if command -v az >/dev/null 2>&1; then
  echo "Azure CLI is installed at: $(which az)"
  az --version | head -n 1
else
  echo "ERROR: Azure CLI installation failed!"
  exit 1
fi

# Login using the VM's managed identity
info "Logging in using Managed Identity"
az login --identity

# Test accessing Application Insights
info "Testing Application Insights access"

APP_INSIGHTS_NAME="__APP_INSIGHTS_NAME__"
RESOURCE_GROUP="__RESOURCE_GROUP__"
WORKSPACE_ID="__WORKSPACE_ID__"

echo "Retrieving Application Insights details:"
az monitor app-insights component show --app $APP_INSIGHTS_NAME --resource-group $RESOURCE_GROUP

echo "Retrieving metrics:"
az monitor metrics list --resource $APP_INSIGHTS_NAME --resource-group $RESOURCE_GROUP --resource-type "microsoft.insights/components" --metric "requests/count" --interval 1h

echo "You could also querying logs (if available) at this stage for example:"
#QUERY="requests | summarize count() by bin(timestamp, 1h) | order by timestamp desc | limit 10"
#WORKSPACE_NAME=$(echo "$WORKSPACE_ID" | awk -F'/' '{print $NF}')
#echo "Attempting query with workspace name..."
#az monitor log-analytics query --workspace "$WORKSPACE_NAME" --analytics-query "$QUERY" --timespan "P1D" || \
#az monitor log-analytics query --workspace "$WORKSPACE_ID" --analytics-query "$QUERY" --timespan "P1D" || \

echo "✅ Application Insights access test successful!"
'@

# Replace the placeholder values with actual values
$scriptContent = $scriptContent.Replace("__APP_INSIGHTS_NAME__", $appInsightsName)
$scriptContent = $scriptContent.Replace("__RESOURCE_GROUP__", $resourceGroupName)
$scriptContent = $scriptContent.Replace("__WORKSPACE_ID__", $workspaceId)  # Use full workspace ID instead of just the name

# Create a temporary file locally
$tempFile = [System.IO.Path]::GetTempFileName()
Set-Content -Path $tempFile -Value $scriptContent

# Upload the temp file to the VM using SCP
Write-Host "Uploading script to VM..." -ForegroundColor Cyan
scp -i $sshKey $tempFile "$vmUser@$vmIp`:test_appinsights.sh"

# Set permissions and run the script
Write-Host "Running script on VM..." -ForegroundColor Cyan
ssh -i $sshKey $vmUser@$vmIp "chmod +x test_appinsights.sh && ./test_appinsights.sh"

# Clean up temp file
Remove-Item -Path $tempFile

# -----------------------------------------------------------------------------
# Clean up: Delete the VM and Resource Group
# -----------------------------------------------------------------------------
Write-Host "CLEANUP: About to delete resource group '$resourceGroupName' and all resources within it" -ForegroundColor Red
Write-Host "Press Ctrl+C within the next 5 seconds to cancel the cleanup operation..." -ForegroundColor Yellow

# Countdown timer to allow cancellation
for ($i = 5; $i -gt 0; $i--) {
    Write-Host "Deleting in $i seconds..." -ForegroundColor Red
    Start-Sleep -Seconds 1
}

Write-Host "Proceeding with deletion of resource group '$resourceGroupName'..." -ForegroundColor Red
az group delete --name "$resourceGroupName" --yes --no-wait