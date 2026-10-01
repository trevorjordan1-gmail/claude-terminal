# claude-terminal has moved to https://github.com/adnettech/ai-terminal — forwarding.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$sb = [scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/adnettech/ai-terminal/main/windows/get.ps1'))
& $sb @args
