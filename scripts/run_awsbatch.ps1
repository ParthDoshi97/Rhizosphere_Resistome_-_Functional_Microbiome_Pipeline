param(
    [Parameter(Mandatory = $true)]
    [string]$Input,

    [Parameter(Mandatory = $true)]
    [string]$Queue,

    [Parameter(Mandatory = $true)]
    [string]$BucketDir,

    [string]$Region = $(if ($env:AWS_REGION) { $env:AWS_REGION } elseif ($env:AWS_DEFAULT_REGION) { $env:AWS_DEFAULT_REGION } else { "us-east-1" }),
    [string]$Outdir = "",
    [string]$Entry = "main.nf",
    [string]$AwsProfile = "",
    [string]$AwsCliPath = "",
    [string]$JobRole = "",
    [string]$ExecutionRole = "",
    [switch]$Spot,
    [switch]$Fusion,
    [int]$SpotAttempts = -1,
    [switch]$NoResume,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs
)

$ErrorActionPreference = "Stop"

if ($BucketDir -notmatch '^s3://[^/]+/.+') {
    throw "BucketDir must be an S3 path with a bucket and prefix, for example s3://my-bucket/rhizo-work"
}

if (-not (Get-Command nextflow -ErrorAction SilentlyContinue)) {
    throw "nextflow is not available on PATH"
}

$env:AWS_REGION = $Region
$env:NXF_AWS_BATCH_QUEUE = $Queue
$env:NXF_AWS_WORKDIR = $BucketDir

if ($Outdir) {
    $env:NXF_AWS_OUTDIR = $Outdir
}

if ($AwsProfile) {
    $env:AWS_PROFILE = $AwsProfile
}

if ($AwsCliPath) {
    $env:NXF_AWS_CLI_PATH = $AwsCliPath
}

if ($JobRole) {
    $env:NXF_AWS_BATCH_JOB_ROLE = $JobRole
}

if ($ExecutionRole) {
    $env:NXF_AWS_BATCH_EXECUTION_ROLE = $ExecutionRole
}

if ($SpotAttempts -lt 0) {
    $SpotAttempts = if ($Spot) { 5 } else { 0 }
}
$env:NXF_AWS_BATCH_MAX_SPOT_ATTEMPTS = [string]$SpotAttempts

$profile = if ($Spot -and $Fusion) {
    "awsbatch_spot_fusion"
} elseif ($Spot) {
    "awsbatch_spot"
} elseif ($Fusion) {
    "awsbatch_fusion"
} else {
    "awsbatch"
}

if ($Fusion -and -not $env:TOWER_ACCESS_TOKEN) {
    throw "--fusion requires TOWER_ACCESS_TOKEN. Set TOWER_ACCESS_TOKEN before launching, or rerun without -Fusion. For shared Seqera workspaces, also set TOWER_WORKSPACE_ID."
}

$cmd = @("run", $Entry, "-profile", $profile, "-bucket-dir", $BucketDir)
if (-not $NoResume) {
    $cmd += "-resume"
}
$cmd += @("--input", $Input)
if ($Outdir) {
    $cmd += @("--outdir", $Outdir)
}
if ($ExtraArgs) {
    $cmd += $ExtraArgs
}

Write-Host "Running: nextflow $($cmd -join ' ')"
& nextflow @cmd
exit $LASTEXITCODE
