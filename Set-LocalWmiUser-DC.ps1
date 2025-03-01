# Richard Hart, McAfee, LLC

# Add Non-Admin user to system for the purposes of collecting Windows Event Logs via WMI from member server, workstation, or non domain controller.

# For personal use only.  Provided AS IS and WITH ALL FAULTS.

# Set-LocalWmiUser.ps1

# Example: Set-LocalWmiUser add domain\user 

Param ( [parameter(Mandatory=$true,Position=0)][string] $operation,  [parameter(Mandatory=$true,Position=2)][string] $account, [bool] $allowInherit = $true, [bool] $deny = $false, [string] $computerName = ".", [System.Management.Automation.PSCredential] $credential = $null)

Process {
    Import-Module ActiveDirectory
    $ErrorActionPreference = "Stop"
    $namespace = "root/cimv2"
    $permissions = "Enable","RemoteAccess"
    
    Function Get-AccessMaskFromPermission($permissions) {

        $WBEM_ENABLE                  = 1

        $WBEM_METHOD_EXECUTE          = 2

        $WBEM_FULL_WRITE_REP          = 4

        $WBEM_PARTIAL_WRITE_REP       = 8

        $WBEM_WRITE_PROVIDER          = 0x10

        $WBEM_REMOTE_ACCESS           = 0x20

        $READ_CONTROL                 = 0x20000

        $WRITE_DAC                    = 0x40000

        $WBEM_RIGHTS_FLAGS = $WBEM_ENABLE,$WBEM_METHOD_EXECUTE,$WBEM_FULL_WRITE_REP,`
           
        $WBEM_PARTIAL_WRITE_REP,$WBEM_WRITE_PROVIDER,$WBEM_REMOTE_ACCESS,`
           
        $WBEM_RIGHT_SUBSCRIBE,$WBEM_RIGHT_PUBLISH,$READ_CONTROL,$WRITE_DAC

        $WBEM_RIGHTS_STRINGS = "Enable","MethodExecute","FullWrite","PartialWrite","ProviderWrite","RemoteAccess","Subscribe","Publish","ReadSecurity","WriteSecurity" 

        $permissionTable = @{}

        for ($i = 0; $i -lt $WBEM_RIGHTS_FLAGS.Length; $i++) {
           $permissionTable.Add($WBEM_RIGHTS_STRINGS[$i].ToLower(), $WBEM_RIGHTS_FLAGS[$i])
        }
  
        $accessMask = 0

        foreach ($permission in $permissions){
            if (-not $permissionTable.ContainsKey($permission.ToLower())) {
                throw "Unknown permission: $permission Valid permissions: $($permissionTable.Keys)"
            }

            $accessMask += $permissionTable[$permission.ToLower()]
        }

        $accessMask

    }


    if ($PSBoundParameters.ContainsKey("Credential")) {
        $remoteparams = @{ComputerName=$computer;Credential=$credential}
    } else {
        $remoteparams = @{}
    }
   
    $invokeparams = @{Namespace=$namespace;Path="__systemsecurity=@"} + $remoteParams

    $output = Invoke-WmiMethod @invokeparams -Name GetSecurityDescriptor

    if ($output.ReturnValue -ne 0) {
        throw "GetSecurityDescriptor failed: $($output.ReturnValue)"
    }
 
    $acl = $output.Descriptor

    $CONTAINER_INHERIT_ACE_FLAG = 0x2

    $computerName = (Get-WmiObject @remoteparams Win32_ComputerSystem).Name

    if ($account.Contains('\')) {
        $domainaccount = $account.Split('\')
        $domain = $domainaccount[0]

        if (($domain -eq ".") -or ($domain -eq "BUILTIN")) {
            $domain = $computerName
        }
        $accountname = $domainaccount[1]
    } elseif ($account.Contains('@')) {
        $domainaccount = $account.Split('@')
        $domain = $domainaccount[1].Split('.')[0]
        $accountname = $domainaccount[0]
    } else {
        $domain = $computerName
        $accountname = $account
    }

 

    $getparams = @{Class="Win32_Account";Filter="Domain='$domain' and Name='$accountname'"} + $remoteParams

    $win32account = Get-WmiObject @getparams

    if ($win32account -eq $null) {
        throw "Account was not found: $account"
    }

    switch ($operation) {

        "add" {
            
            if ($permissions -eq $null) {
                throw "-Permissions must be specified for an add operation"
            }

            $accessMask = Get-AccessMaskFromPermission($permissions)

            $ace = (New-Object System.Management.ManagementClass("win32_Ace")).CreateInstance()

            $ace.AccessMask = $accessMask

            if ($allowInherit) {

                $ace.AceFlags = $CONTAINER_INHERIT_ACE_FLAG

            } else {

                $ace.AceFlags = 0

            }

                       
            $trustee = (New-Object System.Management.ManagementClass("win32_Trustee")).CreateInstance()

            $trustee.SidString = $win32account.Sid

            $ace.Trustee = $trustee

            $ACCESS_ALLOWED_ACE_TYPE = 0x0

            $ACCESS_DENIED_ACE_TYPE = 0x1

            if ($deny) {

                $ace.AceType = $ACCESS_DENIED_ACE_TYPE

            } else {

                $ace.AceType = $ACCESS_ALLOWED_ACE_TYPE

            }

            $acl.DACL += $ace.psobject.immediateBaseObject
            
            $SourceGroups = "Event Log Readers","Distributed COM Users" 
            
            ForEach ($Group in $SourceGroups) {
            
                Add-ADGroupMember $Group $accountname
                
            }
            
            $inherit = [system.security.accesscontrol.InheritanceFlags]"ContainerInherit, ObjectInherit"
            
            $propagation = [system.security.accesscontrol.PropagationFlags]"None"
            
            $registry_acl = Get-Acl HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Security
            
            $registry_rule = New-Object System.Security.AccessControl.RegistryAccessRule ($accountname,"ReadKey",$inherit,$propagation,"Allow")
            
            $registry_acl.SetAccessRule($registry_rule)
            
            $registry_acl | Set-Acl -Path HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Security
            
        }

        "delete" {
        
            $permissions = $null
            
            if ($permissions -ne $null) {
                throw "Permissions cannot be specified for a delete operation"
            }
           
            [System.Management.ManagementBaseObject[]]$newDACL = @()

            foreach ($ace in $acl.DACL) {
                if ($ace.Trustee.SidString -ne $win32account.Sid) {
                    $newDACL += $ace.psobject.immediateBaseObject
                }
            }

            $acl.DACL = $newDACL.psobject.immediateBaseObject

            $SourceGroups = "Event Log Readers","Distributed COM Users" 
            
            ForEach ($Group in $SourceGroups) {
            
                Remove-ADGroupMember $Group $accountname
                
            }
            
            $inherit = [system.security.accesscontrol.InheritanceFlags]"ContainerInherit, ObjectInherit"
            
            $propagation = [system.security.accesscontrol.PropagationFlags]"None"
            
            $registry_acl = Get-Acl HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Security
            
            $registry_rule = New-Object System.Security.AccessControl.RegistryAccessRule ($accountname,"ReadKey",$inherit,$propagation,"Allow")
            
            $registry_acl.RemoveAccessRule($registry_rule)
            
            $registry_acl | Set-Acl -Path HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Security
            
        }
    
        default {
            throw "Unknown operation: $operation. Allowed operations: add or delete"
        }
    }

    $setparams = @{Name="SetSecurityDescriptor";ArgumentList=$acl.psobject.immediateBaseObject} + $invokeParams

    $output = Invoke-WmiMethod @setparams

    if ($output.ReturnValue -ne 0) {
        throw "SetSecurityDescriptor failed: $($output.ReturnValue)"
    }
    
    $service = Get-Service -name "Windows Management Instrumentation"
    
    $servicenames = @()
    
    $servicenames += $service.Name
    
    $dependencies = $service.DependentServices

    foreach ($dependency in $dependencies) {
    
        If ($dependency.Status -eq "Running") {
        
            $servicenames += $dependency.Name
        }
    }
    
    [array]::Reverse($servicenames)
    
    foreach ($servicename in $servicenames) {
    
        Stop-Service $servicename -Verbose
    }
        
    foreach ($servicename in $servicenames) {

        Start-Service $servicename -Verbose
    }
}
