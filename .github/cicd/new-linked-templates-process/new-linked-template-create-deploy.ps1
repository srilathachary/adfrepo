

<#
PowerShell script can be used to deploy Data Factory (ADF) via linked templates in a more secure way instead of using a Storage Account and SAS token. 

Use linked templates when the Data Factory ARM template is over 4 MB.

Original linked template ADF approach for context: https://learn.microsoft.com/en-us/azure/data-factory/continuous-integration-delivery-linked-templates
ARM Template limits: https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/best-practices#template-limits

This script does the following things:

Step 1:
- Grabs the ADF linked template files 
- For each ADF linked template file, creates a new Template Spec which stores the ADF linked template file (JSON). The ADF linked template file is not updated at all.


Step 2:
- Grabs the ADF linked template master file (ArmTemplate_master.json) and does the following:
    - Removes the containerUri and containerSasToken parameters as they aren't needed anymore (using linked Template Specs instead)
    - For each resource in the ArmTemplate_master.json file (linked ADF ARM template in the file):
        - Retrieves the Template Spec Resource ID for that file (ArmTemplate_0 for example)
        - Adds a new id property and adds the Template Spec Resource ID as the value
        - Removes the uri and contentVersion properties
    - Updates the apiVersion property to one that can use the Template Spec id property (2019-11-01 for example) 
    - Ensures the special characters in JSON are escaped properly when generating the updated file (see https://stackoverflow.com/questions/47779157/convertto-json-and-convertfrom-json-with-special-characters)
    - Outputs the new file (doesn't overwrite the existing file) to the root of the repository: Ex: "$(Build.Repository.LocalPath)/NewARMTemplateV2_master.json"


# Helpful Links:
# https://dev.to/adbertram/running-powershell-scripts-in-azure-devops-pipelines-2-of-2-3j0e
# https://stackoverflow.com/questions/47779157/convertto-json-and-convertfrom-json-with-special-characters
# https://learn.microsoft.com/en-us/cli/azure/delete-azure-resources-at-scale#delete-all-azure-resources-of-a-type
# https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_automatic_variables?view=powershell-7.4#matches
# https://learn.microsoft.com/en-us/azure/data-factory/continuous-integration-delivery-linked-templates

#>


# Defining parameters for the script. The values are passed in from the cicd-pipeline.yml pipeline (Create Template Specs for ADF Linked ARM Templates) task
# All of the parameter values come from the variables files (variables/dev-variables.yml, etc.)
[CmdletBinding()]
param(
  $FolderPathADFLinkedARMTemplates,
  $DeployTemplateSpecsResourceGroupName,
  $DeployTemplateSpecsResourceGroupLocation,
  $TemplateSpecsVersionNumber,
  $TemplateSpecMasterName,
  $OutputFolderPathNewADFMasterARMTemplate
)


# Grabs the ADF linked template files
$LinkedARMTemplateFiles = Get-ChildItem -Path $FolderPathADFLinkedARMTemplates -Exclude *master* # Excludes the ArmTemplate_master.json and ArmTemplateParameters_master.json files

    Write-Host "Attempting to create the Template Specs for the Linked ARM Templates. Template Spec resources will be deployed in Resource Group $DeployTemplateSpecsResourceGroupName. This may take a few of minutes."
    Write-Host `n

    foreach ($FileName in $LinkedARMTemplateFiles.Name) {
      
      # Removes .json from the file name. Ex: ArmTemplate_0.json becomes ArmTemplate_0
      $TemplateSpecName = $FileName.split('.')[0]
      
      # Create a new Template Spec for each ARM Template. Doesn't update the ARM Template at all
      Write-Host "Attempting to create a new Template Spec for linked ARM template $TemplateSpecName.json"
      az ts create --name $TemplateSpecName --version $TemplateSpecsVersionNumber --resource-group $DeployTemplateSpecsResourceGroupName --location $DeployTemplateSpecsResourceGroupLocation `
        --template-file $FolderPathADFLinkedARMTemplates/$FileName --yes --output none # --yes means don't prompt for confirmation and overwrite the existing Template Spec if it exists
      
      Write-Host "Successfully created a new Template Spec called $TemplateSpecName for Linked ARM Template $TemplateSpecName.json"
      Write-Host `n
    }

    Write-Host "Successfully created all necessary Template Specs in Resource Group $DeployTemplateSpecsResourceGroupName"
    Write-Host `n


    # Reading the ArmTemplate_master.json file
    Write-Host "Attempting to read the ArmTemplate_master.json file"
    $MasterARMTemplateFile = Get-Content $FolderPathADFLinkedARMTemplates/ArmTemplate_master.json -Raw | ConvertFrom-Json
    Write-Host "Successfully read the ArmTemplate_master.json file"

    # Remove the containerUri and containerSasToken parameters
    ($MasterARMTemplateFile.parameters).PSObject.Properties.Remove('containerUri')
    ($MasterARMTemplateFile.parameters).PSObject.Properties.Remove('containerSasToken')

    
    foreach ($Resource in $MasterARMTemplateFile.resources) {

    $ResourceName = $Resource.Name -Match 'ArmTemplate_.*' # Extracts the ARM Template name out of the resource name property. Ex: my-datafactory-name_ArmTemplate_0 returns ArmTemplate_0
    $TemplateSpecExtractedName = $matches[0] # $matches is an automatic variable in PowerShell. https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_automatic_variables?view=powershell-7.4#matches
                                             # $matches[0] will use the output of the above expression $Resources.Name - Match 'ArmTemplate_.*'. Ex: ArmTemplate_0

    $TemplateSpecResourceID = $(az ts show --name $TemplateSpecExtractedName --resource-group $DeployTemplateSpecsResourceGroupName --version $TemplateSpecsVersionNumber --query "id")

    $Resource.properties.templateLink | Add-Member -Name "id" -value $TemplateSpecResourceID.replace("`"","") -MemberType NoteProperty # removes the initial and ending double quotes from the string
    
    ($Resource.properties.templateLink).PSObject.Properties.Remove('uri')
    ($Resource.properties.templateLink).PSObject.Properties.Remove('contentVersion')

    # Updates the API version to one that can use the Template Spec ID
    $Resource.apiVersion = '2019-11-01'
    }

    Write-Host "Attempting to output the new Master.json file"

    # Ensures the JSON special characters are escaped and come through correctly. For example, not returning a \u0027 string value.
    # See https://stackoverflow.com/questions/47779157/convertto-json-and-convertfrom-json-with-special-characters for more details.
    $MasterARMTemplateFile | ConvertTo-Json -Depth 15 | ForEach-Object{
    [Regex]::Replace($_, 
        "\\u(?<Value>[a-zA-Z0-9]{4})", {
            param($m) ([char]([int]::Parse($m.Groups['Value'].Value,
                [System.Globalization.NumberStyles]::HexNumber))).ToString() } )} |  Set-Content "$TemplateSpecMasterName.json"

    Write-Host "Successfully created the $TemplateSpecMasterName.json file"
    
    Write-Host "Attempting to create the Template Spec for the $TemplateSpecMasterName.json file"

    az ts create --name $TemplateSpecMasterName --version $TemplateSpecsVersionNumber --resource-group $DeployTemplateSpecsResourceGroupName --location $DeployTemplateSpecsResourceGroupLocation `
      --template-file "$OutputFolderPathNewADFMasterARMTemplate/$TemplateSpecMasterName.json" --output none
    
    Write-Host "Successfully created the master Template Spec. Name: $TemplateSpecMasterName in Resource Group $DeployTemplateSpecsResourceGroupName"

    

