<#
    Retry with exponential backoff for transient Graph failures (429 throttling
    is common when deleting a few hundred devices in a row).
#>

$script:MaxRetries       = 5
$script:RetryBaseSeconds = 3

function Invoke-DCUWithRetry {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [string]$Context = 'action'
    )

    for ($attempt = 1; $attempt -le $script:MaxRetries; $attempt++) {
        try {
            return & $ScriptBlock
        }
        catch [System.OperationCanceledException] {
            throw
        }
        catch {
            $message = $_.Exception.Message

            $isRetryable =
                $message -match '429' -or
                $message -match 'throttl' -or
                $message -match 'temporar' -or
                $message -match 'timeout' -or
                $message -match 'timed out' -or
                $message -match '503' -or
                $message -match '504'

            if (-not $isRetryable -or $attempt -eq $script:MaxRetries) { throw }

            $sleep = $script:RetryBaseSeconds * [math]::Pow(2, ($attempt - 1))
            Write-DCULog -Level Warn -Message "$Context failed. Attempt $attempt/$($script:MaxRetries). Retrying in $sleep seconds. Error: $message"

            $deadline = (Get-Date).AddSeconds($sleep)
            while ((Get-Date) -lt $deadline) {
                Test-DCUCancelled
                Start-Sleep -Milliseconds 250
            }
        }
    }
}
